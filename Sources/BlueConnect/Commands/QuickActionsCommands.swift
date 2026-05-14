import SwiftUI

/// Top-level "Quick Actions" menu — mirrors the host context menu's
/// "Maintenance → Quick Admin Actions" submenu so admins can keyboard-
/// shortcut their way to common host operations without right-clicking.
/// Reads QuickAction definitions from `QuickActionStore` so user-defined
/// custom actions show up here too.
///
/// `store` is passed explicitly by the App because `@EnvironmentObject`
/// in a top-level `Commands` block doesn't reliably resolve through the
/// WindowGroup's content environment — crashes on launch when the
/// resolution fails. Explicit `@ObservedObject` is the safe pattern.
struct QuickActionsCommands: Commands {
    @ObservedObject var store: QuickActionStore
    @FocusedValue(\.hostActions) private var actions

    var body: some Commands {
        CommandMenu("Quick Actions") {
            ForEach(Array(store.allEnabled.grouped.enumerated()),
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
            if store.allEnabled.isEmpty {
                Text("All actions disabled — see Settings → Quick Actions")
            }
        }
    }
}
