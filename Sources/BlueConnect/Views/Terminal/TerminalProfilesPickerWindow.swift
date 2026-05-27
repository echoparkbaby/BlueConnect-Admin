import SwiftUI
import AppKit

/// Floating picker for the four built-in Terminal presets plus the
/// generic high-contrast / reset shortcuts. Opens with ⌘⇧I — mirrors
/// the Apple Terminal "Profiles" feel without committing to the full
/// terminal-prefs window. Each card paints itself in the actual
/// profile colors so the operator can pick by sight.
struct TerminalProfilesPickerWindow: View {
    @EnvironmentObject private var settings: SettingsStore
    /// Still referenced by `KeyboardEscapeCatcher` for the Esc-to-
    /// close path. Card clicks no longer dismiss — the operator can
    /// switch presets and watch live terminals update without losing
    /// the picker.
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    /// One displayable preset. `matches(settings:)` says whether the
    /// live SettingsStore is currently on this preset, so its card
    /// can be drawn highlighted.
    fileprivate struct Profile: Identifiable {
        let id: String
        let label: String
        let backgroundHex: String
        let foregroundHex: String
        let cursorHex: String
        let fontSize: Double
        let useInconsolata: Bool

        /// Font name comparison is loose (empty vs Inconsolata) so the
        /// "Default" card still highlights on machines without the
        /// third-party font. `@MainActor` because SettingsStore's
        /// `@AppStorage` properties are main-actor-isolated.
        @MainActor
        func matches(settings: SettingsStore) -> Bool {
            settings.terminalBackgroundHex.lowercased() == backgroundHex.lowercased()
                && settings.terminalForegroundHex.lowercased() == foregroundHex.lowercased()
                && settings.terminalCursorHex.lowercased() == cursorHex.lowercased()
                && Int(settings.terminalFontSize) == Int(fontSize)
        }
    }

    /// Foreground for the four colored presets — bright green
    /// (Dracula palette) instead of white. Readable against red,
    /// bright blue, navy, and black backgrounds — the four bg colors
    /// used by Red Dead, Open Water, Deep Sea, and Peppermint.
    private static let presetForeground = "#50FA7B"

    private static let profiles: [Profile] = [
        Profile(id: "red-dead",   label: "Red Dead",
                backgroundHex: "#8a0c0f", foregroundHex: presetForeground,
                cursorHex: "#ffffff", fontSize: 14, useInconsolata: true),
        Profile(id: "open-water", label: "Open Water",
                backgroundHex: "#2f32ff", foregroundHex: presetForeground,
                cursorHex: "#ffffff", fontSize: 14, useInconsolata: true),
        Profile(id: "deep-sea",   label: "Deep Sea",
                backgroundHex: "#121172", foregroundHex: presetForeground,
                cursorHex: "#ffffff", fontSize: 14, useInconsolata: true),
        Profile(id: "peppermint", label: "Peppermint",
                backgroundHex: "#0f0f0f", foregroundHex: presetForeground,
                cursorHex: "#ff2734", fontSize: 14, useInconsolata: true),
        Profile(id: "high-contrast", label: "High Contrast",
                backgroundHex: "#000000", foregroundHex: "#ffffff",
                cursorHex: "#ffeb3b", fontSize: 14, useInconsolata: false),
        Profile(id: "defaults", label: "Default",
                backgroundHex: "#0f0f0f", foregroundHex: presetForeground,
                cursorHex: "#ff2734", fontSize: 14, useInconsolata: false),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Terminal Profile")
                    .font(.title3).bold()
                Spacer()
                Button("Customize…") {
                    // Write the AppStorage key SettingsView reads on
                    // mount, then open Settings. Doing this directly
                    // (rather than via NotificationCenter) means the
                    // value is present before SettingsView is even
                    // constructed — no first-open timing race. Also
                    // post the notification so any already-open
                    // SettingsView jumps panes immediately.
                    UserDefaults.standard.set("terminal", forKey: "settingsSelection")
                    NotificationCenter.default.post(
                        name: .blueConnectOpenTerminalSettings,
                        object: nil
                    )
                    openSettings()
                }
                .controlSize(.small)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ],
                spacing: 12
            ) {
                ForEach(Self.profiles) { p in
                    profileCard(p)
                }
            }

            Text("Press a card to apply. ⌘⇧I reopens this picker; ⌘, takes you to Settings → Terminal for full color control.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 460, height: 380)
        .background(KeyboardEscapeCatcher { dismissWindow() })
    }

    /// One color-bath card showing how the preset will look when
    /// applied. Click → apply + dismiss. Hover gives a faint outline
    /// so the click target is unambiguous.
    private func profileCard(_ p: Profile) -> some View {
        let bg = NSColor.fromHex(p.backgroundHex) ?? .black
        let fg = NSColor.fromHex(p.foregroundHex) ?? .white
        let cursor = NSColor.fromHex(p.cursorHex) ?? fg
        let isActive = p.matches(settings: settings)
        return Button {
            // Apply without dismissing — the operator can tab through
            // presets and see each one applied to live terminals in
            // real time without losing the picker window.
            apply(p)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("admin@bluesky")
                    .font(previewFont(p))
                    .foregroundStyle(Color(nsColor: fg))
                HStack(spacing: 0) {
                    Text(" ~$ ls -la ")
                        .font(previewFont(p))
                        .foregroundStyle(Color(nsColor: fg))
                    Rectangle()
                        .fill(Color(nsColor: cursor))
                        .frame(width: p.fontSize * 0.55, height: p.fontSize * 1.1)
                }
                Spacer(minLength: 0)
                Text(p.label)
                    .font(.callout).bold()
                    .foregroundStyle(Color(nsColor: fg))
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color(nsColor: bg))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? Color.accentColor : Color.secondary.opacity(0.25),
                            lineWidth: isActive ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .help(isActive ? "Currently active" : "Click to apply")
    }

    /// SwiftUI Font built from the preset's font + size. Inconsolata if
    /// installed, else the system monospaced face — keeps the preview
    /// readable on machines without the third-party font.
    private func previewFont(_ p: Profile) -> Font {
        if p.useInconsolata,
           let ns = NSFont(name: "Inconsolata-Regular", size: CGFloat(p.fontSize)) {
            return Font(ns as CTFont)
        }
        return .system(size: p.fontSize, design: .monospaced)
    }

    private func apply(_ p: Profile) {
        settings.terminalBackgroundHex = p.backgroundHex
        settings.terminalForegroundHex = p.foregroundHex
        settings.terminalCursorHex     = p.cursorHex
        settings.terminalFontSize      = p.fontSize
        if p.useInconsolata,
           NSFont(name: "Inconsolata-Regular", size: CGFloat(p.fontSize)) != nil {
            settings.terminalFontName = "Inconsolata-Regular"
        } else {
            settings.terminalFontName = ""
        }
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
