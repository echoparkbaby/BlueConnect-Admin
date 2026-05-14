import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(BlueSkyHostListStore.self) var hostStore
    @Environment(CategoryStore.self) var categories
    @Environment(RecentConnectStore.self) var recents
    @Binding var selection: SidebarFilter
    let onAssign: ([Int], String) -> Void
    let onFavorite: ([Int]) -> Void
    let onOpenMunkiBrowser: () -> Void
    /// Shared Munki store so the sidebar reflects refresh state too.
    let munkiStore: MunkiRepoStore

    @State private var showingNewCategorySheet = false
    @State private var newCategoryName = ""
    @State private var pendingDelete: String?
    @State private var showingDeleteAlert = false
    @State private var deleteAlsoClearHosts = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    statusGroup
                    Divider().padding(.vertical, 6)
                    categoriesGroup
                    if settings.localNetworkEnabled {
                        Divider().padding(.vertical, 6)
                        LocalNetworkSection()
                    }
                    if settings.tailscaleEnabled {
                        Divider().padding(.vertical, 6)
                        TailscaleSection()
                    }
                    if settings.isMunkiRepoConfigured && !settings.sidebarMunkiHidden {
                        Divider().padding(.vertical, 6)
                        MunkiRepoSidebarSection(
                            store: munkiStore,
                            onOpenBrowser: onOpenMunkiBrowser
                        )
                        .environmentObject(settings)
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 16)   // gutter so counts + labels don't crowd the scroller
                .padding(.top, 10)
            }
            .clipped()
            Divider()
            footer
        }
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $showingNewCategorySheet) { newCategorySheet }
        .alert("Delete Category?", isPresented: $showingDeleteAlert, presenting: pendingDelete) { name in
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                Task {
                    await categories.deleteCategory(name, clearFromHosts: deleteAlsoClearHosts, settings: settings)
                    await hostStore.refresh(settings: settings)
                    if case .category(let c) = selection, c == name { selection = .all }
                }
                pendingDelete = nil
            }
        } message: { name in
            let count = categories.count(of: name, in: hostStore.hosts)
            Text("Delete category “\(name)”? \(count) host\(count == 1 ? "" : "s") currently use it. Their category will be cleared.")
        }
    }

    // MARK: - Status group (reorderable)

    private static let statusKeyDefaults: [String] = ["all", "favorites", "recent", "active", "inactive", "uncat"]

    private var statusOrder: [String] {
        let raw = settings.statusOrderRaw
        let parsed = raw.split(separator: ",").map { String($0) }
        let known = Set(parsed)
        let merged = parsed + Self.statusKeyDefaults.filter { !known.contains($0) }
        return merged.filter { Self.statusKeyDefaults.contains($0) }
    }

    private func reorderStatus(dragKey: String, dropKey: String) {
        guard dragKey != dropKey else { return }
        var arr = statusOrder
        guard let from = arr.firstIndex(of: dragKey),
              let to = arr.firstIndex(of: dropKey) else { return }
        arr.remove(at: from)
        arr.insert(dragKey, at: to)
        settings.statusOrderRaw = arr.joined(separator: ",")
    }

    private struct StatusItem {
        let key: String
        let filter: SidebarFilter
        let label: String
        let icon: String
        let iconColor: Color
        let count: Int
        /// Accepts host drops (e.g. Favorites)
        let acceptsHostDrop: Bool
    }

    private var statusItems: [StatusItem] {
        statusOrder.compactMap { key in
            switch key {
            case "all":
                return StatusItem(key: key, filter: .all, label: "All Hosts",
                                  icon: "tray.full", iconColor: .accentColor,
                                  count: hostStore.hosts.count, acceptsHostDrop: false)
            case "favorites":
                return StatusItem(key: key, filter: .favorites, label: "Favorites",
                                  icon: "star.fill", iconColor: .yellow,
                                  count: hostStore.hosts.filter { $0.isFavorite }.count,
                                  acceptsHostDrop: true)
            case "recent":
                return StatusItem(key: key, filter: .recent, label: "Recently Connected",
                                  icon: "clock.arrow.circlepath", iconColor: .accentColor,
                                  count: recents.lastConnect.count, acceptsHostDrop: false)
            case "active":
                return StatusItem(key: key, filter: .active, label: "Active",
                                  icon: "circle.fill", iconColor: .green,
                                  count: hostStore.hosts.filter { $0.active }.count,
                                  acceptsHostDrop: false)
            case "inactive":
                return StatusItem(key: key, filter: .inactive, label: "Inactive",
                                  icon: "circle", iconColor: .secondary,
                                  count: hostStore.hosts.filter { !$0.active }.count,
                                  acceptsHostDrop: false)
            case "uncat":
                return StatusItem(key: key, filter: .uncategorized, label: "Uncategorized",
                                  icon: "tag.slash", iconColor: .accentColor,
                                  count: hostStore.hosts.filter { ($0.category ?? "").isEmpty }.count,
                                  acceptsHostDrop: false)
            default: return nil
            }
        }
    }

    private var statusGroup: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(statusItems, id: \.key) { item in
                let row = sidebarRow(item.filter, label: item.label, icon: item.icon,
                                     iconColor: item.iconColor, count: item.count)
                row
                    .draggable(DragPayload.status(item.key)) {
                        HStack(spacing: 4) {
                            Image(systemName: item.icon).foregroundStyle(item.iconColor)
                            Text(item.label)
                        }
                        .padding(6)
                        .background(Color(NSColor.controlBackgroundColor))
                    }
                    .dropDestination(for: String.self) { strings, _ in
                        for s in strings {
                            if let key = DragPayload.parseStatus(s) {
                                reorderStatus(dragKey: key, dropKey: item.key)
                                return true
                            }
                            if item.acceptsHostDrop, let ids = DragPayload.parseHosts(s) {
                                onFavorite(ids)
                                return true
                            }
                        }
                        return false
                    }
            }
        }
    }

    // MARK: - Categories (reorderable + accept host drops)

    private var categoriesGroup: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.snappy(duration: 0.15)) {
                    settings.sidebarCategoriesCollapsed.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: settings.sidebarCategoriesCollapsed
                          ? "chevron.right" : "chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text("Categories").font(.caption).bold().foregroundStyle(.secondary)
                    Spacer()
                    if settings.sidebarCategoriesCollapsed {
                        Text("\(categories.categories.count)")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if categories.categories.count > 1 {
                        Text("drag to reorder").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 2)

            if settings.sidebarCategoriesCollapsed {
                EmptyView()
            } else if categories.categories.isEmpty {
                Text("No categories yet").font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 6)
            } else {
                ForEach(categories.categories, id: \.self) { name in
                    sidebarRow(.category(name), label: name, icon: "tag",
                               iconColor: .accentColor,
                               count: hostStore.hosts.filter { ($0.category ?? "") == name }.count,
                               deletable: true)
                        .draggable(DragPayload.category(name)) {
                            HStack { Image(systemName: "tag"); Text(name) }
                                .padding(6).background(Color(NSColor.controlBackgroundColor))
                        }
                        .dropDestination(for: String.self) { strings, _ in
                            for s in strings {
                                if let dragged = DragPayload.parseCategory(s), dragged != name {
                                    var arr = categories.categories
                                    if let from = arr.firstIndex(of: dragged),
                                       let to = arr.firstIndex(of: name) {
                                        arr.remove(at: from)
                                        arr.insert(dragged, at: to)
                                        Task { await categories.reorder(arr, settings: settings) }
                                    }
                                    return true
                                }
                                if let ids = DragPayload.parseHosts(s) {
                                    onAssign(ids, name)
                                    return true
                                }
                            }
                            return false
                        }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                newCategoryName = ""
                showingNewCategorySheet = true
            } label: {
                Label("New Category", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain).padding(.vertical, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var newCategorySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Category").font(.headline)
            TextField("Name", text: $newCategoryName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { createNew() }
            HStack {
                Spacer()
                Button("Cancel") {
                    newCategoryName = ""
                    showingNewCategorySheet = false
                }.keyboardShortcut(.cancelAction)
                Button("Create") { createNew() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 360)
    }

    // MARK: - Row builder

    @ViewBuilder
    private func sidebarRow(
        _ filter: SidebarFilter,
        label: String,
        icon: String,
        iconColor: Color,
        count: Int,
        deletable: Bool = false
    ) -> some View {
        let isSelected = selection == filter
        Button { selection = filter } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(iconColor).frame(width: 16)
                Text(label).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor : Color.clear))
            .foregroundStyle(isSelected ? .white : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .if(deletable) { v in
            v.contextMenu {
                if case .category(let name) = filter {
                    Button("Delete category…", role: .destructive) {
                        deleteAlsoClearHosts = true
                        pendingDelete = name
                        showingDeleteAlert = true
                    }
                }
            }
        }
    }

    private func createNew() {
        let trimmed = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            await categories.createCategory(trimmed, settings: settings)
            selection = .category(trimmed)
        }
        newCategoryName = ""
        showingNewCategorySheet = false
    }
}

// Helper to conditionally apply a modifier.
private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
