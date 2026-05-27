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
        }
        // Menu-only "Close Tab" item (no ⌘W shortcut). The keystroke is
        // intercepted by `MainWindowCloseGuard` at the NSEvent layer so
        // it wins the race against SwiftUI's auto File → Close Window
        // binding — that race is what caused the regression where ⌘W on
        // the main window with no active tab closed the entire window.
        CommandGroup(after: .saveItem) {
            Button("Close Tab") {
                actions?.closeActiveTab()
            }
            .disabled(!(actions?.canCloseActiveTab ?? false))
        }
        // Items migrated out of the old toolbar ⋯ menu. Activity Log
        // mid-file; Export Hosts as CSV pinned to the bottom with a
        // divider above so it sits in the "file-y / save-y" zone.
        CommandGroup(after: .printItem) {
            Button("Activity Log…") { actions?.showActivityLog() }
                .disabled(actions == nil)
            Divider()
            Button("Export Hosts as CSV…") { actions?.exportCSV() }
                .keyboardShortcut("e")
                .disabled(actions == nil)
        }
        // App-menu addition (under Settings). Rolled into this struct
        // rather than its own commands type because SwiftUI's
        // CommandsBuilder caps the .commands modifier at 10 top-level
        // items — adding another Commands struct above blew that
        // limit. Logical group is fine either way; this just keeps
        // the registration site happy.
        CommandGroup(after: .appSettings) {
            Divider()
            Button("Blocked Hosts…") { actions?.showBlockedHosts() }
                .disabled(actions == nil)
        }
    }
}
