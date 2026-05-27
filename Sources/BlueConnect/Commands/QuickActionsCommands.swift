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
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Quick Actions") {
            Button("Browse All Quick Actions…") {
                openWindow(id: "quick-actions-browser")
            }
            .keyboardShortcut("k", modifiers: [.command])
            Divider()
            // Starred items get pinned at the top, flat — no category
            // detour for the user's most-used commands.
            let favorites = store.allEnabled.favorites
            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { action in
                        Button(action.label) {
                            actions?.runQuickAction(action)
                        }
                        .disabled(!(actions?.hasTarget ?? false))
                    }
                }
                Divider()
            }
            // Each category becomes its own submenu so the top-level
            // Quick Actions menu stays a one-screen scan instead of a
            // 50-item wall. Categories are alphabetized in `grouped`.
            ForEach(Array(store.allEnabled.grouped.enumerated()),
                    id: \.offset) { entry in
                Menu(entry.element.0) {
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

