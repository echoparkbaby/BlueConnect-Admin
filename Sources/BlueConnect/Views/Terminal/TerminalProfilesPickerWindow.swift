import SwiftUI
import AppKit

/// Floating ⌘⇧I theme picker: every built-in theme (Homebrew first) and the
/// operator's own, as cards painted in each theme's colors. Clicking applies
/// it to every open terminal without closing the picker.
struct TerminalProfilesPickerWindow: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @State private var active = TerminalThemeStore.active
    @State private var custom = TerminalThemeStore.custom

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Terminal Theme").font(.title3).bold()
                Spacer()
                Button("Customize…") {
                    // Write the key SettingsView reads on mount, then open
                    // Settings; the notification moves an already-open
                    // SettingsView to the Terminal pane.
                    UserDefaults.standard.set("terminal", forKey: "settingsSelection")
                    NotificationCenter.default.post(name: .blueConnectOpenTerminalSettings, object: nil)
                    openSettings()
                }
                .controlSize(.small)
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(TerminalTheme.presets + custom) { card($0) }
                }
                .padding(2)
            }
            Text("Click a theme to apply it. ⌘⇧I reopens this picker; Customize… edits colors, fonts and the cursor.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 520, height: 470)
        .background(KeyboardEscapeCatcher { dismissWindow() })
        .onReceive(NotificationCenter.default.publisher(for: TerminalThemeStore.changed)) { _ in
            active = TerminalThemeStore.active
            custom = TerminalThemeStore.custom
        }
    }

    private func card(_ t: TerminalTheme) -> some View {
        let isActive = active.id == t.id
        return Button {
            // Unsaved edits from Settings → Terminal: Save / Discard / Cancel first.
            guard TerminalThemeStore.confirmUnsaved(allowCancel: true) else { return }
            TerminalThemeStore.active = t.resolvedForThisMac
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 0) {
                    Text("~ % ls").foregroundStyle(Color(nsColor: t.ns(t.text)))
                    Rectangle().fill(Color(nsColor: t.ns(t.cursor))).frame(width: 7, height: 13).padding(.leading, 3)
                }
                .font(.system(size: 12, design: .monospaced))
                HStack(spacing: 3) {
                    ForEach(1..<7) { i in
                        Circle().fill(Color(nsColor: t.ns(t.ansi[i]))).frame(width: 7, height: 7)
                    }
                }
                Text(t.name).font(.callout.weight(.semibold)).foregroundStyle(Color(nsColor: t.ns(t.text)))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .background(Color(nsColor: t.ns(t.background, .black)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isActive ? 3 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isActive ? "Currently active" : "Click to apply · \(t.fontLabel)")
    }
}

extension Notification.Name {
    /// Posted by the Profile Picker's "Customize…" button. SettingsView
    /// listens and switches its sidebar selection to the Terminal pane
    /// so `openSettings()` lands directly on terminal preferences
    /// instead of whatever pane was last visible.
    static let blueConnectOpenTerminalSettings = Notification.Name("BlueConnectOpenTerminalSettings")
}

/// Wraps an invisible AppKit view that catches the Escape keypress
/// and runs `onEscape`. SwiftUI's `.onKeyPress(.escape)` requires the
/// view (or one of its children) to be focused, which isn't reliable
/// for a window that has no input controls — this hits the responder
/// chain directly.
private struct KeyboardEscapeCatcher: NSViewRepresentable {
    let onEscape: () -> Void
    func makeNSView(context: Context) -> NSView { CatcherView(onEscape: onEscape) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class CatcherView: NSView {
        let onEscape: () -> Void
        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        override func keyDown(with event: NSEvent) {
            // 53 = Escape keycode (matches AppKit's documented value)
            if event.keyCode == 53 { onEscape() } else { super.keyDown(with: event) }
        }
    }
}
