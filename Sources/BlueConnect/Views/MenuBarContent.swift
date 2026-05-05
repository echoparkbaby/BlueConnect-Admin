import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(BlueSkyHostListStore.self) var hostStore
    @Environment(RecentConnectStore.self) var recents
    @Environment(CategoryStore.self) var categories
    @Environment(TerminalSessionsManager.self) var terminals
    @State private var query: String = ""
    @State private var keyboardSelection: BlueSkyHost.ID? = nil
    @FocusState private var listFocused: Bool

    /// Cached, recomputed only when source data changes. Body may run many
    /// times per dropdown render (focus, hover); each run previously did the
    /// full filter+sort.
    @State private var favorites: [BlueSkyHost] = []
    @State private var recentlyConnected: [BlueSkyHost] = []

    private func computeFavorites() -> [BlueSkyHost] {
        hostStore.hosts
            .filter { $0.isFavorite }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func computeRecentlyConnected() -> [BlueSkyHost] {
        let withDates = hostStore.hosts.compactMap { h -> (BlueSkyHost, Date)? in
            guard let d = recents.date(for: h.blueskyid) else { return nil }
            return (h, d)
        }
        return withDates.sorted { $0.1 > $1.1 }.prefix(10).map { $0.0 }
    }

    private var lastHost: BlueSkyHost? { recentlyConnected.first }

    private func filtered(_ list: [BlueSkyHost]) -> [BlueSkyHost] {
        guard !query.isEmpty else { return list }
        return list.filter {
            $0.displayName.localizedStandardContains(query)
                || String($0.blueskyid).contains(query)
                || ($0.sharingname?.localizedStandardContains(query) ?? false)
                || ($0.category?.localizedStandardContains(query) ?? false)
        }
    }

    private var activeCount: Int { hostStore.hosts.filter { $0.active }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            connectToLast
            searchBar
            Divider()
            navigableList
            Divider()
            footer
        }
        .frame(width: 340)
        .task {
            // Pre-select the most recently connected host for keyboard launch.
            if keyboardSelection == nil {
                keyboardSelection = recentlyConnected.first?.id ?? favorites.first?.id
            }
            // Auto-refresh in background so we never block the dropdown render.
            guard !settings.webAdminPass.isEmpty else { return }
            await hostStore.refresh(settings: settings)
        }
        .onKeyPress(.return) {
            if let id = keyboardSelection,
               let h = hostStore.hosts.first(where: { $0.id == id }), h.active {
                connect(h, .ssh)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.init("v")) {
            if let id = keyboardSelection,
               let h = hostStore.hosts.first(where: { $0.id == id }), h.active {
                connect(h, .vnc)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.upArrow) {
            stepKeyboardSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            stepKeyboardSelection(by: 1)
            return .handled
        }
        .onAppear {
            favorites = computeFavorites()
            recentlyConnected = computeRecentlyConnected()
        }
        .onChange(of: hostStore.hosts) {
            favorites = computeFavorites()
            recentlyConnected = computeRecentlyConnected()
        }
        .onChange(of: recents.lastConnect) {
            recentlyConnected = computeRecentlyConnected()
        }
    }

    private var navigableList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sections
            }
        }
        .frame(maxHeight: 440)
        .focused($listFocused)
    }

    private func stepKeyboardSelection(by delta: Int) {
        let visible = filtered(favorites) + filtered(recentlyConnected)
        guard !visible.isEmpty else { return }
        let dedup = NSOrderedSet(array: visible.map { $0.id }).array as? [BlueSkyHost.ID] ?? visible.map { $0.id }
        if let cur = keyboardSelection, let i = dedup.firstIndex(of: cur) {
            let next = (i + delta + dedup.count) % dedup.count
            keyboardSelection = dedup[next]
        } else {
            keyboardSelection = delta > 0 ? dedup.first : dedup.last
        }
    }

    // MARK: - Header / Connect-to-Last / Search

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("BlueConnect Admin").font(.headline)
                Text("\(activeCount) active · \(hostStore.hosts.count) total")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh hosts", systemImage: "arrow.clockwise") {
                Task { await hostStore.refresh(settings: settings) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder
    private var connectToLast: some View {
        if let h = lastHost, h.active {
            Button {
                connect(h, .ssh)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Connect to last").font(.caption).foregroundStyle(.secondary)
                        Text(h.displayName).bold().lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "terminal")
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.12))
                        .padding(.horizontal, 8)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("Find host…", text: $query)
                .textFieldStyle(.plain).font(.callout)
            if !query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    query = ""
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color(NSColor.textBackgroundColor)).clipShape(.rect(cornerRadius: 6))
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    // MARK: - Sections

    @ViewBuilder
    private var sections: some View {
        let favs = filtered(favorites)
        let recent = filtered(recentlyConnected)

        if favs.isEmpty && recent.isEmpty && categories.categories.isEmpty {
            Text(query.isEmpty
                 ? "Star a host or connect to one to see it here."
                 : "No matches.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 16)
                .frame(maxWidth: .infinity)
        } else {
            if !favs.isEmpty {
                sectionHeader("Favorites", icon: "star.fill", iconColor: .yellow)
                ForEach(favs) { h in
                    HostRow(host: h, kbSelected: keyboardSelection == h.id)
                }
            }
            if !recent.isEmpty {
                if !favs.isEmpty {
                    Spacer().frame(height: 4)
                    Divider().padding(.horizontal, 10)
                }
                sectionHeader("Recently Connected", icon: "clock", iconColor: .accentColor)
                ForEach(recent) { h in
                    HostRow(host: h, kbSelected: keyboardSelection == h.id)
                }
            }
            if !categories.categories.isEmpty {
                Spacer().frame(height: 4)
                Divider().padding(.horizontal, 10)
                sectionHeader("Categories", icon: "tag", iconColor: .accentColor)
                ForEach(categories.categories, id: \.self) { CategoryRow(name: $0) }
            }
        }
    }

    private func sectionHeader(_ s: String, icon: String, iconColor: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(iconColor).font(.caption)
            Text(s).font(.caption).bold().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            FooterButton(label: "Open BlueConnect Admin", icon: "macwindow") {
                NSApp.activate(ignoringOtherApps: true)
                if let win = NSApp.windows.first(where: { $0.title.contains("BlueConnect") }) {
                    win.makeKeyAndOrderFront(nil)
                }
            }
            FooterButton(label: "Quit", icon: "power", role: .destructive) {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Connect

    private enum Action { case ssh, vnc }

    private func connect(_ host: BlueSkyHost, _ action: Action) {
        guard host.active else { return }
        var svc = ConnectionService(
            server: settings.serverFqdn,
            adminKeyPath: settings.expandedKeyPath,
            serverSshPort: settings.sshTunnelPort,
            terminals: terminals
        )
        svc.onConnect = { h in recents.recordConnect(blueskyid: h.blueskyid) }
        let user = host.effectiveUser(default: settings.defaultRemoteUser)
        Log.info("MenuBar", "\(action == .ssh ? "SSH" : "VNC") to #\(host.blueskyid) \(host.displayName)")
        switch action {
        case .ssh: svc.openSSH(host: host, remoteUser: user)
        case .vnc: svc.openVNC(host: host, remoteUser: user)
        }
    }
}

