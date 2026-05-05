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

            Divider()

            Button("Refresh Hosts") { actions?.refresh() }
                .keyboardShortcut("r", modifiers: [.command])

            Button("Search Hosts") { actions?.focusSearch() }
                .keyboardShortcut("f", modifiers: [.command])

            Button("Toggle Favorite") { actions?.toggleFavorite() }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(!(actions?.hasTarget ?? false))
        }
    }
}
