import AppKit
import SwiftUI
import SwiftTerm

struct TerminalContainer: NSViewRepresentable {
    let terminal: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = SeeThroughContainer()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        // Claim first responder so keystrokes go straight to ssh's
        // stdin without the operator needing to click the pane first.
        //
        // Tried as a no-delay call originally — that fired before the
        // view hierarchy was attached to a window when the bottom pane
        // was opening from empty (the common case for a fresh SSH
        // click), so `terminal.window` was nil and makeFirstResponder
        // silently no-op'd. Two-stage hop (one tick + a fallback
        // ~80ms later) covers both the warm-pane and cold-pane paths.
        Task { @MainActor in
            terminal.window?.makeFirstResponder(terminal)
            try? await Task.sleep(for: .milliseconds(80))
            if terminal.window?.firstResponder !== terminal {
                terminal.window?.makeFirstResponder(terminal)
            }
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // SwiftUI reparents the SwiftTerm view between attached and
        // detached layouts; re-take focus if we lost it during the
        // transition. Idempotent when we're already first responder.
        Task { @MainActor in
            if terminal.window?.firstResponder !== terminal {
                terminal.window?.makeFirstResponder(terminal)
            }
        }
    }
}

/// Behind the terminal: shows what is behind the window (desktop, other
/// apps) when the theme's background opacity is below 100 %. Only the
/// terminal is see-through; text is drawn fully opaque on top.
final class SeeThroughContainer: NSView {
    private let behind = NSVisualEffectView()
    private var observer: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        behind.blendingMode = .behindWindow
        behind.material = .underWindowBackground
        behind.state = .active
        behind.translatesAutoresizingMaskIntoConstraints = false
        addSubview(behind)
        NSLayoutConstraint.activate([
            behind.topAnchor.constraint(equalTo: topAnchor),
            behind.bottomAnchor.constraint(equalTo: bottomAnchor),
            behind.leadingAnchor.constraint(equalTo: leadingAnchor),
            behind.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        update()
        observer = NotificationCenter.default.addObserver(forName: TerminalThemeStore.changed, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func update(_ theme: TerminalTheme = TerminalThemeStore.active) {
        behind.isHidden = theme.opacity >= 0.999
        let brightness = TerminalTheme.color(theme.background)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0
        behind.appearance = NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)
    }
}

/// Live preview: a real terminal view showing sample output in the theme,
/// over a stand-in "desktop" so a see-through background shows.
struct TerminalThemePreview: NSViewRepresentable {
    let theme: TerminalTheme

    static let sample =
        "\u{1b}[32madmin@mac\u{1b}[0m ~ % ls -G\r\n" +
        "\u{1b}[34mApplications\u{1b}[0m  \u{1b}[34mLibrary\u{1b}[0m  \u{1b}[31mrun.sh\u{1b}[0m  \u{1b}[35mlatest\u{1b}[0m  notes.txt\r\n" +
        "\u{1b}[31m- old line\u{1b}[0m   \u{1b}[32m+ new line\u{1b}[0m   \u{1b}[33mwarning\u{1b}[0m   \u{1b}[36minfo\u{1b}[0m\r\n" +
        "\u{1b}[1mBold text looks like this\u{1b}[0m\r\n" +
        (0..<16).map { "\u{1b}[48;5;\($0)m  " }.joined() + "\u{1b}[0m\r\n" +
        "\u{1b}[32madmin@mac\u{1b}[0m ~ % "

    func makeNSView(context: Context) -> NSView {
        let container = PreviewContainer(frame: NSRect(x: 0, y: 0, width: 560, height: 180))
        TerminalSession.applyAppearance(to: container.terminal, theme: theme)
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let container = view as? PreviewContainer else { return }
        container.backdrop.isHidden = theme.opacity >= 0.999
        TerminalSession.applyAppearance(to: container.terminal, theme: theme)
    }

    /// Holds the backdrop and the terminal, and writes the sample again
    /// after a size change, so the text is laid out for the final width
    /// instead of reflowed from the first one.
    final class PreviewContainer: NSView {
        let backdrop = CAGradientLayer()
        let terminal: LocalProcessTerminalView
        private var fedWidth: CGFloat = -1

        override init(frame: NSRect) {
            terminal = LocalProcessTerminalView(frame: NSRect(origin: .zero, size: frame.size))
            super.init(frame: frame)
            wantsLayer = true
            backdrop.colors = [NSColor(srgbRed: 0.25, green: 0.45, blue: 0.85, alpha: 1).cgColor,
                               NSColor(srgbRed: 0.85, green: 0.45, blue: 0.35, alpha: 1).cgColor]
            backdrop.startPoint = CGPoint(x: 0, y: 1)
            backdrop.endPoint = CGPoint(x: 1, y: 0)
            layer?.addSublayer(backdrop)
            layer?.cornerRadius = 6
            layer?.masksToBounds = true
            terminal.autoresizingMask = [.width, .height]
            addSubview(terminal)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            backdrop.frame = bounds
            guard bounds.width > 0, bounds.width != fedWidth else { return }
            fedWidth = bounds.width
            terminal.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J" + TerminalThemePreview.sample)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 560, height: 180)
    }
}
