import SwiftUI

/// Application-wide menu providing keyboard shortcuts for the active
/// host selection. Reads `HostActions` from the focused-value chain that
/// `ContentView` publishes.
struct ConnectCommands: Commands {
    @FocusedValue(\.hostActions) private var actions

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

            Button("Chat…") { actions?.openChat() }
                .keyboardShortcut("5", modifiers: [.command])
                .disabled(!(actions?.hasTarget ?? false))

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

            // Lifecycle — routed through HostActions so replay rebuilds
            // against current Settings, not the stale launch args from
            // the original open.
            Button("Reopen Last Closed Session") { actions?.reopenLastClosed() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!(actions?.canReopenLastClosed ?? false))

            Button("Reconnect") { actions?.reconnectActive() }
                .keyboardShortcut("r", modifiers: [.control, .command])
                .disabled(!(actions?.canReconnectActive ?? false))

            Divider()

            Button("Copy SSH Command") { actions?.copySSHCommand() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!(actions?.hasTarget ?? false))

            Button("Copy BSC ProxyCommand") { actions?.copyProxyCommand() }
        }
    }
}
