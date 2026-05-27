import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(BlueSkyHostListStore.self) var hostStore
    @Environment(RecentConnectStore.self) var recents
    @Environment(CategoryStore.self) var categories
    @Environment(TerminalSessionsManager.self) var terminals
    @Environment(SCPController.self) var scpController
    @Environment(ActivityLog.self) var activity
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var query: String = ""
    @State private var keyboardSelection: BlueSkyHost.ID? = nil
    @FocusState private var listFocused: Bool
    /// Inline filter chips below the search bar. AppStorage so the user's
    /// last triage stance survives across dropdown opens.
    @AppStorage("menubarActiveOnly") private var menubarActiveOnly: Bool = false
    @AppStorage("menubarFavoritesOnly") private var menubarFavoritesOnly: Bool = false
    @State private var tunnelsExpanded: Bool = true

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
        var l = list
        if menubarActiveOnly { l = l.filter { $0.active } }
        if menubarFavoritesOnly { l = l.filter { $0.isFavorite } }
        guard !query.isEmpty else { return l }
        return l.filter { matchesQuery($0) }
    }

    /// Shared query predicate so the "Search Results" section + the
    /// Return-key launch use the same matching logic. Without this the
    /// menu's favs/recents-only sections silently hid hosts the user
    /// could see in the main window, and Return fell through to the
    /// last-connected host because no visible row matched.
    private func matchesQuery(_ h: BlueSkyHost) -> Bool {
        guard !query.isEmpty else { return true }
        return h.displayName.localizedStandardContains(query)
            || String(h.blueskyid).contains(query)
            || (h.sharingname?.localizedStandardContains(query) ?? false)
            || (h.category?.localizedStandardContains(query) ?? false)
    }

    /// Full-corpus search across `hostStore.hosts` (not just favs +
    /// recents). Only used when the user has typed something — when
    /// the query is empty we fall back to the curated favs/recents
    /// sections.
    private var searchHits: [BlueSkyHost] {
        guard !query.isEmpty else { return [] }
        return hostStore.hosts
            .filter { matchesQuery($0) }
            .filter { !menubarActiveOnly || $0.active }
            .filter { !menubarFavoritesOnly || $0.isFavorite }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Pick the host a Return/V/S keypress should fire against. With
    /// a non-empty query, prefer the first active search hit (so the
    /// user can type then hit Return to launch the obvious result);
    /// without a query, fall back to whatever the arrow keys / default
    /// put in keyboardSelection. Returns nil for inactive hosts so the
    /// keypress reports `.ignored` (matches the pre-fix semantics).
    private func launchTargetForKeyboardShortcut() -> BlueSkyHost? {
        if !query.isEmpty {
            return searchHits.first(where: { $0.active })
        }
        guard let id = keyboardSelection,
              let h = hostStore.hosts.first(where: { $0.id == id }),
              h.active
        else { return nil }
        return h
    }

    private var activeCount: Int { hostStore.hosts.filter { $0.active }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            activeTunnelsStrip
            connectToLast
            searchBar
            filterChips
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
            // Return prefers the first search hit when the user is
            // searching — otherwise it falls back to whichever host
            // the arrow keys (or default) put in keyboardSelection.
            // Previously this always used keyboardSelection, which
            // defaulted to last-connected, so typing then hitting
            // Return launched Connect-to-last regardless of query.
            if let target = launchTargetForKeyboardShortcut() {
                connect(target, .ssh)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.init("v")) {
            if let target = launchTargetForKeyboardShortcut() {
                connect(target, .vnc)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.init("s")) {
            if let target = launchTargetForKeyboardShortcut() {
                connect(target, .scp)
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
                serverStatusLine
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

    /// Server pill — shows BSC version + last-refresh time + error
    /// indicator. Failure mode is the *only* time the active/total
    /// counts get out of the way, so the user immediately sees why
    /// the list looks stale.
    @ViewBuilder
    private var serverStatusLine: some View {
        if let err = hostStore.lastError, !err.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.red)
                Text(err.prefix(40))
                    .font(.caption2).foregroundStyle(.red)
                    .lineLimit(1).truncationMode(.tail)
            }
        } else {
            let parts = [
                "\(activeCount) active · \(hostStore.hosts.count) total",
                hostStore.lastResponse?.blueSkyVersion.flatMap { $0.isEmpty ? nil : "BSC \($0)" },
                hostStore.lastUpdated.map { "·  \($0.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))" },
            ].compactMap { $0 }
            Text(parts.joined(separator: "  "))
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    /// Collapsible strip of currently-running tunnels with kill buttons.
    /// Only renders when there's at least one tunnel — keeps the dropdown
    /// compact for the common case of "I just want to connect."
    @ViewBuilder
    private var activeTunnelsStrip: some View {
        if !terminals.tunnels.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    tunnelsExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tunnelsExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.secondary)
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption2).foregroundStyle(.green)
                        Text("Active Tunnels (\(terminals.tunnels.count))")
                            .font(.caption).bold().foregroundStyle(.secondary)
                        Spacer()
                        if terminals.tunnels.count > 1 {
                            Button("Kill all") { terminals.killAllTunnels() }
                                .buttonStyle(.plain)
                                .font(.caption2).foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if tunnelsExpanded {
                    ForEach(terminals.tunnels, id: \.id) { t in
                        HStack(spacing: 8) {
                            Image(systemName: t.kind == "VNC" ? "display" : "terminal")
                                .font(.caption).foregroundStyle(t.kind == "VNC" ? .blue : .green)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.displayName).font(.caption).lineLimit(1)
                                Text("\(t.kind) · #\(t.blueskyid) · localhost:\(t.localPort)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                terminals.killTunnel(t.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.callout).foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Kill this tunnel")
                        }
                        .padding(.horizontal, 14).padding(.vertical, 4)
                    }
                }
            }
            .padding(.bottom, 4)
            Divider().padding(.horizontal, 10)
        }
    }

    /// Two toggleable chips beneath the search bar — Active only / Favorites
    /// only — for quick triage without dropping into the main window's
    /// sidebar filter. Persists across dropdown opens.
    private var filterChips: some View {
        HStack(spacing: 6) {
            chip(label: "Active", icon: "circle.fill", color: .green, isOn: $menubarActiveOnly)
            chip(label: "Favorites", icon: "star.fill", color: .yellow, isOn: $menubarFavoritesOnly)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    private func chip(label: String, icon: String, color: Color, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2).foregroundStyle(color)
                Text(label).font(.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(
                Capsule().fill(isOn.wrappedValue
                               ? Color.accentColor.opacity(0.25)
                               : Color.secondary.opacity(0.10))
            )
            .overlay(
                Capsule().stroke(isOn.wrappedValue
                                 ? Color.accentColor.opacity(0.5)
                                 : Color.clear, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("Find host…")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                }
                TextField("", text: $query)
                    .textFieldStyle(.plain).font(.callout)
            }
            if !query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    query = ""
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(NSColor.textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    // MARK: - Sections

    @ViewBuilder
    private var sections: some View {
        let favs = filtered(favorites)
        let recent = filtered(recentlyConnected)
        let hits = searchHits

        // When the user is actively searching, the curated favs/recents
        // sections aren't enough — they don't include every host the
        // user can SSH into. Promote a "Search Results" section at the
        // top that runs against the full inventory; fall back to the
        // original curated layout when the field is empty.
        if !query.isEmpty {
            if hits.isEmpty {
                Text("No matches.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
            } else {
                sectionHeader("Search Results", icon: "magnifyingglass", iconColor: .accentColor)
                ForEach(hits) { h in
                    HostRow(host: h, kbSelected: keyboardSelection == h.id)
                }
            }
        } else if favs.isEmpty && recent.isEmpty && categories.categories.isEmpty {
            Text("Star a host or connect to one to see it here.")
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
            FooterButton(label: "New Terminal", icon: "terminal") {
                terminals.openLocalShell()
                NSApp.activate(ignoringOtherApps: true)
                if let win = NSApp.windows.first(where: { $0.title.contains("BlueConnect") }) {
                    win.makeKeyAndOrderFront(nil)
                }
            }
            FooterButton(label: "Activity Log…", icon: "list.bullet.rectangle") {
                NSApp.activate(ignoringOtherApps: true)
                if let win = NSApp.windows.first(where: { $0.title.contains("BlueConnect") }) {
                    win.makeKeyAndOrderFront(nil)
                }
                // ContentView listens for this and flips its
                // `showingActivityLog` state, opening the sheet. The
                // sheet lives on the main window, so we order-front
                // first to make sure the post lands on a visible
                // window.
                NotificationCenter.default.post(name: .blueConnectOpenActivityLog, object: nil)
            }
            FooterButton(label: "Settings…", icon: "gearshape") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            FooterButton(label: "Quit", icon: "power", role: .destructive) {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Connect

    private enum Action { case ssh, vnc, scp }

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
        let kind = action == .ssh ? "SSH" : (action == .vnc ? "VNC" : "SCP")
        Log.info("MenuBar", "\(kind) to #\(host.blueskyid) \(host.displayName)")
        switch action {
        case .ssh: svc.openSSH(host: host, remoteUser: user)
        case .vnc: svc.openVNC(host: host, remoteUser: user)
        case .scp:
            scpController.begin(with: host)
            openWindow(id: "scp-transfer")
        }
    }
}

extension Notification.Name {
    /// Posted by the MenuBar Activity Log button. ContentView listens
    /// and flips `showingActivityLog = true` so the sheet appears on
    /// the (already-fronted) main window.
    static let blueConnectOpenActivityLog = Notification.Name("BlueConnectOpenActivityLog")
}

