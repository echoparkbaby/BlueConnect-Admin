import SwiftUI

/// Bottom-pane navigation: prev/next tab, detach-to-window, kill-all-tunnels,
/// and ⌃⌘1…⌃⌘9 to jump to a specific tab (1 = Log, 2..N = sessions).
///
/// Lives outside the View hierarchy because it's a top-level Commands
/// block. Anything that needs `@Environment(\.openWindow)` (detach) goes
/// through `bcDetachActiveTerminal` so ContentView (which does have the
/// environment) can perform the actual window open.
struct TerminalTabCommands: Commands {
    @Bindable var terminals: TerminalSessionsManager
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // ⌘⇧I → Terminal Profile picker. A separate CommandMenu
        // ("Terminal") keeps profile management visually distinct
        // from the per-tab nav controls in the "Tabs" menu below,
        // while still living in this file so we don't consume an
        // extra slot in BlueConnectApp's @CommandsBuilder (which
        // caps at 10).
        CommandMenu("Terminal") {
            Button("Profile Picker…") {
                openWindow(id: "terminal-profiles")
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandMenu("Tabs") {
            // ⌘⇧] / ⌘⇧[ — matches Terminal.app / Safari conventions for
            // next/previous tab. (Original choice of ⌘] / ⌘[ collided with
            // user muscle memory.)
            Button("Next Tab") { terminals.selectNext() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(terminals.sessions.isEmpty)

            Button("Previous Tab") { terminals.selectPrevious() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(terminals.sessions.isEmpty)

            Divider()

            Button("Detach Tab to Window") {
                NotificationCenter.default.post(name: .bcDetachActiveTerminal, object: nil)
            }
            // ⌘F = "break out current terminal" — pops the active tab
            // into its own floating window. The old ⌘⇧D binding is
            // kept as an alternate so muscle memory still works.
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(terminals.activeSessionID == nil)

            Button("Detach + Full Screen") {
                NotificationCenter.default.post(
                    name: .bcDetachActiveTerminalFullScreen, object: nil
                )
            }
            // ⌘⇧F = "detach and take it full screen" — same path as
            // ⌘F but ContentView's listener also toggles the new
            // window's fullScreen mode after open.
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(terminals.activeSessionID == nil)

            Button("Kill All Tunnels") { terminals.killAllTunnels() }
                .keyboardShortcut("k", modifiers: [.command, .shift, .control])
                .disabled(terminals.tunnels.isEmpty)

            Divider()

            Section("Jump to Tab") {
                // 1 = Log, 2..9 = first 8 sessions. ⌃⌘N to stay clear of
                // ⌘1..⌘4 (SSH/VNC/SCP/Install) which already collide.
                Button("Log") { terminals.selectBottomPaneTab(at: 1) }
                    .keyboardShortcut("1", modifiers: [.control, .command])

                // Snapshot into a stable array first — ForEach(0..<n) crashes
                // with "Index out of range" if sessions.count changes after
                // the range is captured but before the body fires.
                let indexed = Array(terminals.sessions.prefix(8).enumerated())
                ForEach(indexed, id: \.element.id) { pair in
                    let i = pair.offset
                    let s = pair.element
                    let label = "\(i + 2). \(s.title)"
                    Button(label) { terminals.selectBottomPaneTab(at: i + 2) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 2)")),
                                          modifiers: [.control, .command])
                }
            }
        }
    }
}

extension Notification.Name {
    /// Posted by TerminalTabCommands when the user invokes ⌘F (or
    /// the older ⌘⇧D). ContentView observes and calls
    /// openWindow(id: "detached-terminal", value:) — Commands can't
    /// access the openWindow environment value directly.
    static let bcDetachActiveTerminal = Notification.Name("BC.DetachActiveTerminal")

    /// ⌘⇧F variant — same detach path, but ContentView's listener
    /// also calls `toggleFullScreen` on the freshly-opened window
    /// once SwiftUI has finished hosting it. Posted as a separate
    /// notification so the open + full-screen pair can be observed
    /// in one place.
    static let bcDetachActiveTerminalFullScreen = Notification.Name("BC.DetachActiveTerminalFullScreen")
}
