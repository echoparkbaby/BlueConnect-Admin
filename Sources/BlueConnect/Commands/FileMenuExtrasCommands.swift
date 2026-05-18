import SwiftUI
import AppKit

/// File menu additions for the BlueConnect app: New Terminal, New SCP
/// Transfer, and a focus-scoped Close Tab.
///
/// Close Tab is gated on `@FocusedValue(\.hostActions)`. ContentView is
/// the only view that publishes that value, so the menu item — and its
/// ⌘W shortcut — only fires when the main window has focus. Other
/// windows (Settings, SCP Transfer, Package Picker, Detached Terminal)
/// see the item as disabled, which lets the shortcut fall through to
/// the system's auto-injected Close Window for that front window.
struct FileMenuExtrasCommands: Commands {
    @Bindable var terminals: TerminalSessionsManager
    @FocusedValue(\.hostActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Terminal") { terminals.openLocalShell() }
                .keyboardShortcut("t", modifiers: [.command])

            Divider()

            Button("Close Tab") { actions?.closeActiveTab() }
                .keyboardShortcut("w", modifiers: [.command])
                .disabled(!(actions?.canCloseActiveTab ?? false))
        }
    }
}
