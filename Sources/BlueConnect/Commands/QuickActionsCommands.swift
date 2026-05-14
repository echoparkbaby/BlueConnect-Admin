import SwiftUI

/// Top-level "Quick Actions" menu — mirrors the host context menu's
/// "Maintenance → Quick Admin Actions" submenu so admins can keyboard-
/// shortcut their way to common host operations without right-clicking.
/// Reads QuickAction definitions from `QuickActionStore` so user-defined
/// custom actions show up here too.
struct QuickActionsCommands: Commands {
    @FocusedValue(\.hostActions) private var actions
    @EnvironmentObject private var quickActions: QuickActionStore

    var body: some Commands {
        CommandMenu("Quick Actions") {
            ForEach(Array(quickActions.allEnabled.grouped.enumerated()),
                    id: \.offset) { entry in
                Section(entry.element.0) {
                    ForEach(entry.element.1) { action in
                        Button(action.label) {
                            actions?.runQuickAction(action)
                        }
                        .disabled(!(actions?.hasTarget ?? false))
                    }
                }
            }
            if quickActions.allEnabled.isEmpty {
                Text("All actions disabled — see Settings → Quick Actions")
            }
        }
    }
}
