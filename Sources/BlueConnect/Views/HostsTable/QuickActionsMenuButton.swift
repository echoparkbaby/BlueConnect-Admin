import SwiftUI

/// Wand-and-stars icon in the host row's Connect column that opens the
/// same Favorites + categorized submenu structure as the right-click
/// Quick Actions menu. Visually matches `QuickActionButton` so it sits
/// inline with SSH / VNC / SCP / Install. Disabled when the host is
/// inactive (tunnel down) — Quick Actions all run over SSH.
struct QuickActionsMenuButton: View {
    let host: BlueSkyHost
    let enabled: Bool
    @ObservedObject var quickActionStore: QuickActionStore
    let onPick: (QuickAction) -> Void

    /// Live-pickable SF Symbol — see the "Customize Row Icons…" sheet
    /// (Views/HostsTable/RowIconPicker.swift) accessible from the
    /// main overflow menu.
    @AppStorage("quickActionsRowIconSymbol") private var iconSymbol: String = "bolt.fill"

    var body: some View {
        Menu {
            menuContents
        } label: {
            Image(systemName: iconSymbol)
                .foregroundStyle(enabled ? Color.pink : .secondary.opacity(0.4))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 22)
        .disabled(!enabled)
        .help("Quick Actions")
    }

    @ViewBuilder
    private var menuContents: some View {
        let enabled = quickActionStore.allEnabled
        let recents = enabled.recents
        if !recents.isEmpty {
            Section("Recent") {
                ForEach(recents) { action in
                    Button(action.label) { onPick(action) }
                }
            }
            Divider()
        }
        let favorites = enabled.favorites
        if !favorites.isEmpty {
            Section("Favorites") {
                ForEach(favorites) { action in
                    Button(action.label) { onPick(action) }
                }
            }
            Divider()
        }
        ForEach(Array(enabled.grouped.enumerated()),
                id: \.offset) { entry in
            Menu(entry.element.0) {
                ForEach(entry.element.1) { action in
                    Button(action.label) { onPick(action) }
                }
            }
        }
        if enabled.isEmpty {
            Text("All actions disabled — see Settings → Quick Actions")
        }
    }
}
