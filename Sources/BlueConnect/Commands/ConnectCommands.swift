import SwiftUI

/// Application-wide menu providing keyboard shortcuts for the active
/// host selection. Reads `HostActions` from the focused-value chain that
/// `ContentView` publishes. Terminal tab management used to live in its
/// own top-level menu — folded in here under a divider since terminal
/// tabs ARE remote connections and the standalone menu was sparse.
struct ConnectCommands: Commands {
    @FocusedValue(\.hostActions) private var actions
    @FocusedValue(\.terminalCommands) private var term

    var body: some Commands {
        CommandMenu("Connect") {
            Button("Open SSH Session") { actions?.ssh() }
                .keyboardShortcut("1", modifiers: [.command])
                .disabled(!(actions?.hasTarget ?? false))

            Button("Open VNC Session") { actions?.vnc() }
                .keyboardShortcut("2", modifiers: [.command])
                .disabled(!(actions?.hasTarget ?? false))

            Button("Send File via SCP…") { actions?.scp() }
                .keyboardShortcut("3", modifiers: [.command])
                .disabled(!(actions?.hasTarget ?? false))

            Button("Install Package…") { actions?.installPackage() }
                .keyboardShortcut("4", modifiers: [.command])
                .disabled(!(actions?.hasTarget ?? false) || !(actions?.hasPackages ?? false))

            Button("Upload Package to Repo…") { actions?.uploadToRepo() }
                .keyboardShortcut("u", modifiers: [.command, .shift])

            Button("Erase / Reinstall macOS…") { actions?.eraseInstall() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!(actions?.hasTarget ?? false))

            Divider()

            Button("Browse Munki Repo…") { actions?.browseMunkiRepo() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!(actions?.hasMunkiRepo ?? false))

            Divider()

            Button("Refresh Hosts") { actions?.refresh() }
                .keyboardShortcut("r", modifiers: [.command])

            Button("Search Hosts") { actions?.focusSearch() }
                .keyboardShortcut("f", modifiers: [.command])

            Button("Toggle Favorite") { actions?.toggleFavorite() }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(!(actions?.hasTarget ?? false))

            Divider()

            // Terminal tab management — was a standalone "Terminal" menu
            // before; folded in here so the menubar isn't padded with a
            // sparse standalone menu.
            Button("Previous Tab") { term?.previousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(!(term?.hasMultiple ?? false))
            Button("Next Tab") { term?.nextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(!(term?.hasMultiple ?? false))
            // ⌘W is intercepted globally by `MainWindowGuard` (NSEvent
            // local monitor) — see installation in BlueConnectApp.
            Button("Close Tab") { term?.closeActiveTab() }
            Button("Close All Tabs") { term?.closeAllTabs() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!(term?.hasAny ?? false))
        }
    }
}
