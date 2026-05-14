import SwiftUI

/// Sidebar section for the Munki repo. Collapsible like the other groups,
/// keeps the repo accessible from the main window without rooting through
/// Settings or a context menu. The single row shows package count when
/// loaded; clicking it opens the full browser sheet.
struct MunkiRepoSidebarSection: View {
    @EnvironmentObject private var settings: SettingsStore
    let store: MunkiRepoStore
    let onOpenBrowser: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.snappy(duration: 0.15)) {
                    settings.sidebarMunkiCollapsed.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: settings.sidebarMunkiCollapsed
                          ? "chevron.right" : "chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: "cube.box.fill")
                        .font(.caption).foregroundStyle(.blue)
                    Text("Munki Repo").font(.caption).bold().foregroundStyle(.secondary)
                    Spacer()
                    if !store.packages.isEmpty {
                        Text("\(uniqueNameCount)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 2)

            if !settings.sidebarMunkiCollapsed {
                Button {
                    onOpenBrowser()
                    if store.packages.isEmpty && !store.isLoading && store.lastError == nil {
                        Task { await store.refresh(settings: settings) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass.circle")
                            .foregroundStyle(.tint).frame(width: 16)
                        Text("Browse Packages…").lineLimit(1)
                        Spacer()
                        if store.isLoading {
                            ProgressView().controlSize(.small)
                        } else if !store.packages.isEmpty {
                            Text("\(store.packages.count) total")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let err = store.lastError {
                    Text(err)
                        .font(.caption2).foregroundStyle(.orange)
                        .lineLimit(2)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
            }
        }
    }

    /// One row per unique package name — matches the picker's "latest only"
    /// grouping so the sidebar count tracks what the user sees there.
    private var uniqueNameCount: Int {
        Set(store.packages.map(\.name)).count
    }
}
