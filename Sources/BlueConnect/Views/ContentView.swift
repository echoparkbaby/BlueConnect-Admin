import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(BlueSkyHostListStore.self) var hostStore
    @Environment(CategoryStore.self) var categories
    @Environment(RecentConnectStore.self) var recents
    @Environment(ActivityLog.self) var activity
    @Environment(TerminalSessionsManager.self) var terminals
    @EnvironmentObject var auth: AuthGate
    @Environment(HostStateNotifier.self) var notifier

    @State private var searchText: String = ""
    @State private var selection: Set<BlueSkyHost.ID> = []
    @Environment(SCPController.self) private var scpController
    @Environment(PackageCatalogStore.self) private var packageCatalog
    @Environment(InstallController.self) private var installer
    @Environment(PackagePickerController.self) private var packagePicker
    @EnvironmentObject private var quickActionStore: QuickActionStore
    @Environment(QuickActionLauncher.self) private var quickActionLauncher
    @Environment(ChatSessionController.self) private var chatController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showingSettingsSheet = false
    @State private var sortOrder: [KeyPathComparator<BlueSkyHost>] = [
        KeyPathComparator(\.blueskyid, order: .forward)
    ]
    @State private var alert: AlertContent?
    @State private var renameTarget: BlueSkyHost?
    @State private var setUsernameTargets: [BlueSkyHost] = []
    @State private var showingSetUsernameSheet = false
    @State private var categoryTargets: [BlueSkyHost] = []
    @State private var showingCategorySheet = false
    @State private var showingActivityLog = false
    @State private var showingBlockedHosts = false
    @State private var showingIconPicker = false
    // Live row icons: each PersistentIconButton owns its own
    // @AppStorage internally so Table's row caching doesn't swallow
    // updates. The picker writes the same keys this view reads.
    @State private var vncController: VNCConnectController?
    @Environment(\.openSettings) private var openSettings
    @State private var showingExporter = false
    @State private var exportDoc: HostsCSVDocument?
    @State private var serverHealthOK: Bool = true
    @State private var deleteChooserHosts: [BlueSkyHost] = []
    @State private var pendingTerminalScpHost: BlueSkyHost?
    @State private var showingTerminalScpPicker = false
    /// Hosts captured when the user opens the package picker window —
    /// stashed alongside the controller so install intents from the
    /// (separate, movable) picker window can still target the right
    /// hosts after the user moves around in the main window.
    @State private var packagePickerHosts: [BlueSkyHost] = []
    @State private var installFileHost: BlueSkyHost?
    @State private var showingInstallFilePicker = false
    @State private var pendingAppInstall: (host: BlueSkyHost, url: URL)?
    @State private var showingUploadOnlyPicker = false
    @State private var eraseInstallTarget: BlueSkyHost?
    @State private var quickActionTarget: QuickActionTarget?
    /// Host the user just picked "Open Chat with specific user…" on —
    /// surfaces the small target-user sheet so they can pick which
    /// Aqua-session user the chat-start job is addressed to.
    @State private var chatTargetSheet: BlueSkyHost?
    @State private var showingMunkiBrowser = false
    @State private var munkiReportInventoryHost: BlueSkyHost?
    /// Shared Munki repo store — held at the ContentView level so the
    /// sidebar count + the picker + the browser all see the same fetched
    /// catalog without re-fetching independently.
    @State private var munkiStore = MunkiRepoStore()

    /// Wrapper so `.sheet(item:)` can identify the pending action — the
    /// id changes any time host or action changes.
    private struct QuickActionTarget: Identifiable {
        let host: BlueSkyHost
        let action: QuickAction
        var id: String { "\(host.blueskyid)|\(action.id)" }
    }
    @FocusState private var searchFocused: Bool
    @AppStorage("sidebarFilter") private var sidebarFilterRaw: String = "all"
    /// Pane visibility — toggled from the View menu (⌘B for sidebar).
    /// Persisted across launches so the user's preferred layout sticks.
    @AppStorage("sidebarVisible") private var sidebarVisible: Bool = true
    @AppStorage("connectPanelVisible") private var connectPanelVisible: Bool = true
    // Persist the hosts-table column order + visibility across launches.
    // Previously used `@SceneStorage`, which only writes back when the
    // system has scene restoration enabled (off by default for users
    // who untick "Close windows when quitting an app"). The
    // `@AppStorage` + JSON round-trip matches ScannedTableWindow's
    // approach and persists unconditionally.
    @AppStorage("hostsTableColumnsJSON") private var hostsColumnsRaw: String = ""
    @State private var columnCustomization: TableColumnCustomization<BlueSkyHost> = .init()

    private var sidebarFilter: SidebarFilter {
        get { decode(sidebarFilterRaw) }
        nonmutating set { sidebarFilterRaw = encode(newValue) }
    }
    private var sidebarFilterBinding: Binding<SidebarFilter> {
        Binding(get: { decode(sidebarFilterRaw) },
                set: { sidebarFilterRaw = encode($0) })
    }

    private enum AlertContent: Identifiable {
        case singleAction(host: BlueSkyHost, action: HostAction)
        case bulkAction(hosts: [BlueSkyHost], action: HostAction)
        case result(title: String, message: String)
        case error(String)

        var id: String {
            switch self {
            case .singleAction(let h, let a): return "single-\(a.rawValue)-\(h.blueskyid)"
            case .bulkAction(let hs, let a): return "bulk-\(a.rawValue)-\(hs.map { String($0.blueskyid) }.joined(separator: ","))"
            case .result(let t, _): return "result-\(t)"
            case .error(let m): return "err-\(m.prefix(40))"
            }
        }
    }

    /// Cached filter+sort result. Recomputed only when an input changes;
    /// `body` may be called many times per state-change pass (selection
    /// changes, focus changes, etc.) — each of those previously paid the
    /// full filter+sort cost.
    @State private var filteredAndSorted: [BlueSkyHost] = []

    private func computeFilteredAndSorted() -> [BlueSkyHost] {
        var result = hostStore.hosts
        switch sidebarFilter {
        case .all:           break
        case .favorites:     result = result.filter { $0.isFavorite }
        case .recent:        result = result.filter { recents.date(for: $0.blueskyid) != nil }
        case .active:        result = result.filter { $0.active }
        case .inactive:      result = result.filter { !$0.active }
        case .uncategorized: result = result.filter { ($0.category ?? "").isEmpty }
        case .category(let c): result = result.filter { ($0.category ?? "") == c }
        }
        if !searchText.isEmpty {
            let q = searchText
            result = result.filter { h in
                h.displayName.localizedStandardContains(q)
                    || String(h.blueskyid).contains(q)
                    || (h.username?.localizedStandardContains(q) ?? false)
                    || (h.sharingname?.localizedStandardContains(q) ?? false)
                    || (h.category?.localizedStandardContains(q) ?? false)
            }
        }
        let sorted = result.sorted(using: sortOrder)
        if sidebarFilter == .recent {
            return sorted.sorted {
                let a = recents.date(for: $0.blueskyid) ?? .distantPast
                let b = recents.date(for: $1.blueskyid) ?? .distantPast
                return a > b
            }
        }
        return sorted
    }

    private var selectedHosts: [BlueSkyHost] {
        filteredAndSorted.filter { selection.contains($0.id) }
    }

    private var bottomPaneVisible: Bool {
        terminals.hasContent || terminals.activeSelection == .log
    }

    var body: some View {
        bodyWithPresentations
            .alert(item: $alert) { content in alertView(for: content) }
            .task { await autoRefreshLoop() }
            .task {
                // Hydrate the Munki cache from disk so the sidebar count
                // and the browser open instantly; refresh in background
                // only when the cache is stale.
                if settings.isMunkiRepoConfigured {
                    munkiStore.loadFromCacheIfPresent(settings: settings)
                    Task { await munkiStore.refresh(settings: settings) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .bcDetachActiveTerminal)) { _ in
                if let id = terminals.detachActive() {
                    openWindow(id: "detached-terminal", value: id)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .bcDetachActiveTerminalFullScreen)) { _ in
                // Detach + open the window, then toggle full-screen on
                // *this* session's window — not whichever window's
                // title happens to start with "Terminal". With more
                // than one detached terminal open, the old
                // title-prefix lookup full-screened the wrong window.
                // Walking up from `session.view.window` is exact: the
                // SwiftTerm NSView is hosted by exactly the window we
                // just opened.
                guard let id = terminals.detachActive() else { return }
                openWindow(id: "detached-terminal", value: id)
                guard let session = terminals.sessions.first(where: { $0.id == id }) else { return }
                fullScreenWhenReady(view: session.view, attemptsLeft: 12)
            }
            .onReceive(NotificationCenter.default.publisher(for: .blueConnectOpenActivityLog)) { _ in
                showingActivityLog = true
            }
            .onChange(of: hostStore.lastResponse) { _, newValue in handleResponseChange(newValue) }
            .onChange(of: settings.notifyOnStateChange) { _, newValue in
                if newValue { notifier.requestAuthorizationIfNeeded() }
            }
            // Push terminal-appearance changes into every already-open
            // session so the operator sees the result of a Settings
            // tweak without having to close and reopen each tab.
            .onChange(of: settings.terminalFontName)      { _, _ in terminals.reapplyAppearanceToAllSessions() }
            .onChange(of: settings.terminalFontSize)      { _, _ in terminals.reapplyAppearanceToAllSessions() }
            .onChange(of: settings.terminalForegroundHex) { _, _ in terminals.reapplyAppearanceToAllSessions() }
            .onChange(of: settings.terminalBackgroundHex) { _, _ in terminals.reapplyAppearanceToAllSessions() }
            .onChange(of: settings.terminalCursorHex)     { _, _ in terminals.reapplyAppearanceToAllSessions() }
            // Hosts-table column persistence: load on first appear,
            // save on every customization change. Matches the
            // ScannedTableWindow pattern; replaces the old
            // @SceneStorage which didn't reliably survive launches.
            .onAppear {
                if !hostsColumnsRaw.isEmpty,
                   let data = hostsColumnsRaw.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(TableColumnCustomization<BlueSkyHost>.self, from: data) {
                    columnCustomization = decoded
                }
            }
            .onChange(of: columnCustomization) { _, new in
                if let data = try? JSONEncoder().encode(new),
                   let s = String(data: data, encoding: .utf8) {
                    hostsColumnsRaw = s
                }
            }
            .onChange(of: hostStore.lastError) { _, newValue in handleLastErrorChange(newValue) }
            .focusedSceneValue(\.hostActions, currentHostActions)
            .modifier(FilteredAndSortedCacheInvalidator(
                recompute: { filteredAndSorted = computeFilteredAndSorted() },
                hosts: hostStore.hosts,
                search: searchText,
                sidebarFilterRaw: sidebarFilterRaw,
                sortOrder: sortOrder,
                recentConnects: recents.lastConnect
            ))
    }

    /// Wired into the App's `Connect` menu via `@FocusedValue`. Each
    /// closure operates on the first selected host (or the host currently
    /// shown in ConnectPanel for single-row workflows).
    private var currentHostActions: HostActions {
        let target: BlueSkyHost? = selectedHosts.first ?? filteredAndSorted.first
        return HostActions(
            hasTarget: target != nil,
            ssh:  { if let h = target, h.active { runQuickAction(host: h, kind: .ssh) } },
            vnc:  { if let h = target, h.active { runQuickAction(host: h, kind: .vnc) } },
            scp:  { if let h = target, h.active { runQuickAction(host: h, kind: .scp) } },
            installPackage: {
                if let h = target { openPackagePicker(for: [h]) }
            },
            uploadToRepo: { showingUploadOnlyPicker = true },
            eraseInstall: {
                if let h = target { eraseInstallTarget = h }
            },
            browseMunkiRepo: { showingMunkiBrowser = true },
            refresh: { Task { await hostStore.refresh(settings: settings) } },
            focusSearch: { searchFocused = true },
            toggleFavorite: {
                if let h = target {
                    Task { await setFavorite(!h.isFavorite, on: [h]) }
                }
            },
            runQuickAction: { action in
                if let h = target {
                    quickActionTarget = QuickActionTarget(host: h, action: action)
                }
            },
            hasPackages: !(packageCatalog.catalog?.packages.isEmpty ?? true)
                || settings.isMunkiRepoConfigured,
            hasMunkiRepo: settings.isMunkiRepoConfigured,
            setSidebarFilter: { f in sidebarFilterRaw = encode(f) },
            setSortField: { field in
                switch field {
                case "name":      sortOrder = [KeyPathComparator(\BlueSkyHost.displayName)]
                case "id":        sortOrder = [KeyPathComparator(\BlueSkyHost.blueskyid)]
                case "status":    sortOrder = [KeyPathComparator(\BlueSkyHost.statusSortKey)]
                case "last_seen": sortOrder = [KeyPathComparator(\BlueSkyHost.timestamp, order: .reverse)]
                default: break
                }
            },
            toggleSidebar:      { sidebarVisible.toggle() },
            toggleConnectPanel: { connectPanelVisible.toggle() },
            isSidebarVisible: sidebarVisible,
            isConnectPanelVisible: connectPanelVisible,
            closeActiveTab:      { terminals.closeActive() },
            canCloseActiveTab:    terminals.activeSessionID != nil,
            reopenLastClosed:    { rebuildAndReopen() },
            canReopenLastClosed:  terminals.lastClosed != nil,
            reconnectActive:     { rebuildAndReconnect() },
            canReconnectActive:   terminals.activeSession != nil,
            copySSHCommand: {
                if let h = target {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sshCommandString(for: h), forType: .string)
                }
            },
            copyProxyCommand: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(proxyCommandString(), forType: .string)
            },
            exportCSV:             { exportCSV() },
            showActivityLog:       { showingActivityLog = true },
            showBlockedHosts:      { showingBlockedHosts = true },
            showCustomizeRowIcons: { showingIconPicker = true },
            openChat: {
                if let h = target, h.active {
                    chatController.present(
                        ChatService(host: h, settings: settings, targetUser: "", launcher: quickActionLauncher),
                        openWindow: { openWindow(id: "blueconnect-chat") }
                    )
                }
            },
            openChatWithSpecificUser: {
                if let h = target, h.active {
                    chatTargetSheet = h
                }
            }
        )
    }

    /// Rebuild the last-closed session against *current* Settings — so a
    /// changed server FQDN / key path / tunnel port / remote user applies
    /// on replay. Originally we re-spawned with the stored launch args,
    /// which froze those values at original-launch time (codex review).
    private func rebuildAndReopen() {
        guard let stub = terminals.consumeLastClosed() else { return }
        switch stub.kind {
        case .local:
            terminals.openLocalShell()
        case .ssh:
            guard let host = hostStore.hosts.first(where: { $0.blueskyid == stub.blueskyid }) else {
                return
            }
            runQuickAction(host: host, kind: .ssh)
        case .scp:
            // SCP replay would need the original source file URL — not
            // captured. User picks a new file via the normal SCP flow.
            return
        }
    }

    /// Re-run the active session's connection in a fresh tab, rebuilding
    /// from current Settings (same rationale as `rebuildAndReopen`).
    private func rebuildAndReconnect() {
        guard let s = terminals.activeSession else { return }
        switch s.kind {
        case .local:
            terminals.openLocalShell()
        case .ssh:
            guard let host = hostStore.hosts.first(where: { $0.blueskyid == s.blueskyid }) else {
                return
            }
            runQuickAction(host: host, kind: .ssh)
        case .scp:
            return
        }
    }

    private func sshCommandString(for host: BlueSkyHost) -> String {
        let user = host.effectiveUser(default: settings.defaultRemoteUser)
        let proxy = proxyCommandString()
        return "ssh -t -o 'ProxyCommand=\(proxy)' -o StrictHostKeyChecking=no -o WarnWeakCrypto=no -p \(host.sshPort) \(user)@localhost"
    }

    private func proxyCommandString() -> String {
        let port = settings.sshTunnelPort
        let key = shellSingleQuote(settings.expandedKeyPath)
        let server = settings.serverFqdn
        return "ssh -o WarnWeakCrypto=no -p \(port) -i \(key) admin@\(server) /bin/nc %h %p"
    }

    /// POSIX single-quote escape — keys/paths with spaces survive the
    /// copy-to-clipboard round trip. Mirrors ConnectionService.shq.
    private func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// First pass: layout + sheets/file pickers. Splitting body into two
    /// computed properties lets the type-checker commit each half before
    /// composing — body was timing out as a single 100-line chain.
    private var bodyWithPresentations: some View {
        VSplitView {
            mainSplitView
                .frame(minHeight: 280)
            if bottomPaneVisible {
                TerminalPaneView(manager: terminals)
                    .frame(minHeight: 200, idealHeight: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Toolbar removed — all former actions live in the standard
        // menus now (File / View / app). Kept the modifier off so the
        // window's titlebar stays clean.
        .sheet(isPresented: $showingSettingsSheet) {
            SettingsView()
                .environmentObject(settings)
                .frame(width: 560, height: 720)
        }
        .sheet(item: $renameTarget) { h in
            RenameSheet(host: h) { newName in
                runRename(host: h, newHostname: newName)
            }
        }
        .sheet(isPresented: $showingSetUsernameSheet) {
            SetUsernameSheet(hosts: setUsernameTargets, currentDefault: settings.defaultRemoteUser) { newUser in
                runSetUsername(hosts: setUsernameTargets, newUsername: newUser)
            }
        }
        .sheet(isPresented: $showingActivityLog) {
            ActivityLogView().environment(activity)
        }
        .sheet(isPresented: $showingBlockedHosts) {
            BlockedHostsView()
                .environmentObject(settings)
                .environmentObject(auth)
        }
        .sheet(isPresented: $showingIconPicker) {
            RowIconPicker()
        }
        .sheet(item: vncSheetItem) { item in
            VNCConnectSheet(controller: item.controller)
                .onDisappear { vncController = nil }
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDoc,
            contentType: .commaSeparatedText,
            defaultFilename: exportFilename,
            onCompletion: handleExportResult
        )
        .sheet(isPresented: $showingCategorySheet) {
            CategorySheet(hosts: categoryTargets, categories: categories,
                          onAssign: assignCategoryFromSheet)
        }
        .fileImporter(isPresented: $showingTerminalScpPicker, allowedContentTypes: [.item],
                      onCompletion: handleTerminalScpPicker)
        .fileImporter(isPresented: $showingInstallFilePicker,
                      allowedContentTypes: [
                        UTType(filenameExtension: "pkg") ?? .data,
                        UTType(filenameExtension: "dmg") ?? .data,
                        .application,
                      ]) { result in
            if case .success(let url) = result, let h = installFileHost {
                let ext = url.pathExtension.lowercased()
                if ext == "app" {
                    pendingAppInstall = (host: h, url: url)
                } else {
                    installLocalPackage(url: url, on: h)
                }
            }
            installFileHost = nil
        }
        .fileImporter(isPresented: $showingUploadOnlyPicker,
                      allowedContentTypes: [
                        UTType(filenameExtension: "pkg") ?? .data,
                        UTType(filenameExtension: "dmg") ?? .data,
                        .application,
                      ]) { result in
            if case .success(let url) = result {
                handlePackagePickerDrop(url: url, hosts: [])  // upload-only, no install
            }
        }
        .confirmationDialog(
            "Install \(pendingAppInstall?.url.lastPathComponent ?? "")?",
            isPresented: Binding(
                get: { pendingAppInstall != nil },
                set: { if !$0 { pendingAppInstall = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingAppInstall
        ) { pair in
            Button("Compress to DMG") {
                installAppWithMode(url: pair.url, on: pair.host, mode: .compress)
                pendingAppInstall = nil
            }
            Button("Send Raw") {
                installAppWithMode(url: pair.url, on: pair.host, mode: .raw)
                pendingAppInstall = nil
            }
            Button("Cancel", role: .cancel) { pendingAppInstall = nil }
        }
        .sheet(item: $eraseInstallTarget) { h in
            EraseInstallSheet(host: h) { spec in
                runEraseInstall(host: h, spec: spec)
            }
            .environmentObject(settings)
        }
        .sheet(item: $quickActionTarget) { target in
            // Check for an existing SSH tab against this host at sheet
            // open time. If one exists, the sheet renders a secondary
            // "Run in Existing Tab" button that injects the command
            // into that tab's PTY instead of opening a fresh one.
            let existing = terminals.reusableSSHSession(for: target.host.blueskyid)
            QuickActionSheet(
                host: target.host,
                action: target.action,
                existingTabTitle: existing?.title,
                onRun: { command, values in
                    runQuickAction(host: target.host,
                                   action: target.action,
                                   command: command,
                                   values: values)
                },
                onRunInExistingTab: existing.map { session in
                    { command, values in
                        // Append a trailing newline so the remote shell
                        // processes the line. quickActionStore.noteUsed
                        // mirrors the analytics side-effect in
                        // runQuickAction so the usage counter ticks
                        // even on the reuse path. Also fire the BSC
                        // hostname sync if this is a setHostname run —
                        // the BSC agent doesn't re-report hostname
                        // after initial registration, so we POST to
                        // bs_host_update.json.php directly to keep the
                        // server-side record current.
                        quickActionStore.noteUsed(target.action.id)
                        recents.recordConnect(blueskyid: target.host.blueskyid)
                        terminals.activeSessionID = session.id
                        session.sendInput(command + "\n")
                        if target.action.id == "setHostname",
                           let newName = values["name"], !newName.isEmpty {
                            runRename(host: target.host, newHostname: newName)
                        }
                    }
                }
            )
        }
        .sheet(item: $chatTargetSheet) { host in
            ChatTargetUserSheet(host: host) { targetUser in
                chatController.present(
                    ChatService(host: host, settings: settings, targetUser: targetUser, launcher: quickActionLauncher),
                    openWindow: { openWindow(id: "blueconnect-chat") }
                )
            }
            .environmentObject(settings)
        }
        // The Install Package window is a top-level Scene (see
        // BlueConnectApp.swift) so it can be moved + resized. ContentView
        // reacts here to install intents written by that window into the
        // shared `packagePicker` controller. Clear-after-dispatch so each
        // pick fires exactly once even if the window stays open.
        .onChange(of: packagePicker.pendingDirectInstall) { _, pkg in
            guard let pkg = pkg else { return }
            handlePendingDirectInstall(pkg)
        }
        .onChange(of: packagePicker.pendingMunkiInstall) { _, pkg in
            guard let pkg = pkg else { return }
            handlePendingMunkiInstall(pkg)
        }
        .onChange(of: packagePicker.pendingFileDrop) { _, url in
            guard let url = url else { return }
            handlePendingFileDrop(url)
        }
        // Quick Actions browser window writes a Run intent here; we
        // dispatch via the same SSH path as the inline sheet flow, then
        // clear so the next click fires .onChange cleanly.
        .onChange(of: quickActionLauncher.pendingRun) { _, run in
            guard let run = run else { return }
            runQuickAction(host: run.host, action: run.action, command: run.command)
            quickActionLauncher.pendingRun = nil
        }
        // Drain any pending window intent that was queued while ContentView
        // wasn't mounted. .onChange only fires on subsequent transitions;
        // this picks up the value-already-set case after openWindow("main").
        .task {
            drainPackagePickerIntents()
            if let run = quickActionLauncher.pendingRun {
                runQuickAction(host: run.host, action: run.action, command: run.command)
                quickActionLauncher.pendingRun = nil
            }
        }
        .sheet(isPresented: $showingMunkiBrowser) {
            MunkiBrowserView(store: munkiStore)
                .environmentObject(settings)
                .environment(hostStore)
                .environment(packagePicker)
        }
        .sheet(item: $munkiReportInventoryHost) { h in
            MunkiReportInventoryView(host: h)
                .environmentObject(settings)
        }
    }

    /// Poll for the NSWindow that hosts `view` to materialize, then
    /// call `toggleFullScreen`. Necessary because SwiftUI doesn't
    /// install the new `WindowGroup` window synchronously when
    /// `openWindow` returns — there's a brief gap during which
    /// `view.window` is nil. Up to ~600ms of polling at 50ms ticks
    /// (12 attempts), then give up silently so a missed-window race
    /// doesn't leak a timer.
    private func fullScreenWhenReady(view: NSView, attemptsLeft: Int) {
        if let window = view.window {
            window.toggleFullScreen(nil)
            return
        }
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            fullScreenWhenReady(view: view, attemptsLeft: attemptsLeft - 1)
        }
    }

    private func handleResponseChange(_ newValue: BlueSkyHostsResponse?) {
        if let resp = newValue {
            categories.updateFromHostsResponse(resp)
            notifier.diff(resp.hosts, settings: settings, activity: activity)
        }
        serverHealthOK = (newValue != nil)
    }

    private func handleLastErrorChange(_ newValue: String?) {
        if let m = newValue {
            alert = .error(m); hostStore.lastError = nil
            serverHealthOK = false
        }
    }

    // MARK: - Sheet/picker helpers (factored out so the body type-checks)

    private var vncSheetItem: Binding<VNCSheetItem?> {
        Binding(
            get: { vncController.map(VNCSheetItem.init(controller:)) },
            set: { vncController = $0?.controller }
        )
    }

    private var exportFilename: String { "BlueSkyHosts-\(Self.dateStamp()).csv" }

    private func handleExportResult(_ result: Result<URL, Error>) {
        if case .failure(let e) = result { NSLog("export err: \(e)") }
        exportDoc = nil
    }

    private func assignCategoryFromSheet(_ newCategory: String?) {
        Task {
            let r = await categories.assign(newCategory, to: categoryTargets, settings: settings)
            await hostStore.refresh(settings: settings)
            if !r.failed.isEmpty {
                alert = .result(
                    title: "Category Partial",
                    message: "Succeeded: \(r.ok)\nFailed:\n\(r.failed.prefix(5).joined(separator: "\n"))"
                )
            }
        }
    }

    private func handleTerminalScpPicker(_ result: Result<URL, Error>) {
        guard let host = pendingTerminalScpHost else { return }
        switch result {
        case .success(let url):
            var svc = ConnectionService(
                server: settings.serverFqdn,
                adminKeyPath: settings.expandedKeyPath,
                serverSshPort: settings.sshTunnelPort,
                terminals: terminals
            )
            svc.onConnect = { h in recents.recordConnect(blueskyid: h.blueskyid) }
            svc.openSCPInTerminal(host: host, remoteUser: effectiveRemoteUser(host: host), sourceURL: url)
        case .failure(let e): NSLog("terminal scp picker err: \(e)")
        }
        pendingTerminalScpHost = nil
    }

    private func autoRefreshLoop() async {
        if !settings.webAdminPass.isEmpty && hostStore.hosts.isEmpty {
            await hostStore.refresh(settings: settings)
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            if !settings.webAdminPass.isEmpty {
                await hostStore.refresh(settings: settings)
            }
        }
    }

    private var mainSplitView: some View {
        // IMPORTANT: HSplitView (NSSplitView-backed) crashes when its child
        // count changes mid-render — "NSPerformVisuallyAtomicChange" fault.
        // PaneCollapser keeps a stable view in each slot; only its inner
        // contents swap between full pane and a thin chevron rail.
        HSplitView {
            PaneCollapser(side: .leading, visible: $sidebarVisible) {
                SidebarView(
                    selection: sidebarFilterBinding,
                    onAssign: { ids, categoryName in
                        let toAssign = hostStore.hosts.filter { ids.contains($0.blueskyid) }
                        Task {
                            let r = await categories.assign(categoryName, to: toAssign, settings: settings)
                            await hostStore.refresh(settings: settings)
                            if !r.failed.isEmpty {
                                alert = .result(
                                    title: "Assign Partial",
                                    message: "Succeeded: \(r.ok)\nFailed:\n\(r.failed.prefix(5).joined(separator: "\n"))"
                                )
                            }
                        }
                    },
                    onFavorite: { ids in
                        let hosts = hostStore.hosts.filter { ids.contains($0.blueskyid) }
                        Task { await setFavorite(true, on: hosts) }
                    },
                    onSetUsernameForCategory: { name in
                        let matched = hostStore.hosts.filter { ($0.category ?? "") == name }
                        if matched.isEmpty {
                            alert = .result(title: "No Hosts in Category", message: "No hosts are currently assigned to \"\(name)\".")
                            return
                        }
                        setUsernameTargets = matched
                        showingSetUsernameSheet = true
                    },
                    onOpenMunkiBrowser: { showingMunkiBrowser = true },
                    munkiStore: munkiStore
                )
            }
            .frame(
                minWidth: sidebarVisible ? 180 : 22,
                idealWidth: sidebarVisible ? 220 : 22,
                maxWidth: sidebarVisible ? 280 : 22
            )

            VStack(spacing: 0) {
                topBar
                Divider()
                hostsTable
                statusBar
            }
            .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)

            PaneCollapser(side: .trailing, visible: $connectPanelVisible) {
                ConnectPanel(
                    hosts: selectedHosts,
                    onSCPNeedsFile: { h in
                        scpController.begin(with: h)
                        openWindow(id: "scp-transfer")
                    },
                    onVNCRequest: { h, user in
                        let svc = ConnectionService(
                            server: settings.serverFqdn,
                            adminKeyPath: settings.expandedKeyPath,
                            serverSshPort: settings.sshTunnelPort,
                            terminals: terminals
                        )
                        vncController = svc.makeVNCController(host: h, remoteUser: user, recents: recents)
                    },
                    onInstallPackage: { h in openPackagePicker(for: [h]) },
                    onDeleteRequest: { h, action in alert = .singleAction(host: h, action: action) },
                    onBulkRequest: { hs, action in alert = .bulkAction(hosts: hs, action: action) },
                    onRenameRequest: { h in renameTarget = h },
                    onCategoryRequest: { hs in
                        categoryTargets = hs
                        showingCategorySheet = true
                    },
                    onConnect: { h in recents.recordConnect(blueskyid: h.blueskyid) },
                    onSaveNotes: { h, newNotes in saveNotes(host: h, notes: newNotes) },
                    onUpdateField: { h, field, value in updateField(host: h, field: field, value: value) }
                )
            }
            .frame(
                minWidth: connectPanelVisible ? 280 : 22,
                idealWidth: connectPanelVisible ? 320 : 22,
                maxWidth: connectPanelVisible ? 360 : 22,
                maxHeight: .infinity
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // The old `toolbarContent` builder is gone — see the note at
    // `.toolbar { ... }` removal above. All actions migrated to:
    //   File menu  → Activity Log…, Export Hosts as CSV…
    //   View menu  → Customize Row Icons…
    //   app menu   → Blocked Hosts… (after Settings)
    //   ⌘, opens   → Settings (auto-injected)
    //   ⌘R refresh → wired in HostActions if/when a shortcut is desired.

    private func exportCSV() {
        let csv = HostsCSVBuilder.build(filteredAndSorted)
        exportDoc = HostsCSVDocument(csv: csv)
        showingExporter = true
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: Date())
    }

    /// Uses the deprecated `Alert` API on purpose — the modern
    /// `.alert(_:isPresented:presenting:actions:message:)` form pushes the
    /// body's type-checker over its budget when combined with this view's
    /// many sheets and onChange observers.
    private func alertView(for content: AlertContent) -> Alert {
        switch content {
        case .singleAction(let host, .selfdestruct):
            return Alert(
                title: Text("Send Delete Command?"),
                message: Text("Setting selfdestruct=1 on \(host.displayName) (#\(host.blueskyid)). The Mac client will uninstall itself on next check-in. The DB row stays."),
                primaryButton: .destructive(Text("Send")) { runAction(.selfdestruct, on: host) },
                secondaryButton: .cancel()
            )
        case .singleAction(let host, .delete):
            return Alert(
                title: Text("Delete Permanently?"),
                message: Text("Removes \(host.displayName) (#\(host.blueskyid)) from the BlueSky database AND scrubs the corresponding pubkey. This is irreversible."),
                primaryButton: .destructive(Text("Delete")) { runAction(.delete, on: host) },
                secondaryButton: .cancel()
            )
        case .singleAction(let host, .block):
            let serial = (host.serialnum ?? "—")
            return Alert(
                title: Text("Block Host Permanently?"),
                message: Text("""
                    Adds serial \(serial) to the BSC server's blocked_serials list, installs a DB trigger that rejects any future registration with that serial, and runs the same teardown as Delete (scrub key, drop row).

                    Use this for \(host.displayName) (#\(host.blueskyid)) when the Mac is out of your control (sold, transferred) and you can't uninstall BlueSky on the client. The agent will keep retrying — the server will keep refusing.

                    Reversible only by removing the serial from blocked_serials manually on the BSC server.
                    """),
                primaryButton: .destructive(Text("Block Forever")) { runAction(.block, on: host) },
                secondaryButton: .cancel()
            )
        case .bulkAction(let hosts, .selfdestruct):
            return Alert(
                title: Text("Send Delete Command to \(hosts.count) Hosts?"),
                message: Text(bulkMessage(hosts: hosts, base: "Each Mac client will uninstall itself on next check-in.")),
                primaryButton: .destructive(Text("Send to \(hosts.count)")) { runBulk(.selfdestruct, on: hosts) },
                secondaryButton: .cancel()
            )
        case .bulkAction(let hosts, .delete):
            return Alert(
                title: Text("Delete \(hosts.count) Hosts?"),
                message: Text(bulkMessage(hosts: hosts, base: "Removes the rows from the DB AND scrubs each pubkey. Irreversible.")),
                primaryButton: .destructive(Text("Delete \(hosts.count)")) { runBulk(.delete, on: hosts) },
                secondaryButton: .cancel()
            )
        case .bulkAction(let hosts, .block):
            return Alert(
                title: Text("Block \(hosts.count) Hosts Permanently?"),
                message: Text(bulkMessage(hosts: hosts, base: "Adds each host's serial to BlueSky.blocked_serials, scrubs key + row, and refuses any future re-registration with the same serial. Reversible only via the BSC server.")),
                primaryButton: .destructive(Text("Block \(hosts.count)")) { runBulk(.block, on: hosts) },
                secondaryButton: .cancel()
            )
        case .result(let title, let message):
            return Alert(title: Text(title), message: Text(message), dismissButton: .default(Text("OK")))
        case .error(let msg):
            return Alert(title: Text("Error"), message: Text(msg), dismissButton: .default(Text("OK")))
        }
    }

    private func bulkMessage(hosts: [BlueSkyHost], base: String) -> String {
        let names = hosts.prefix(5).map { "#\($0.blueskyid) \($0.displayName)" }.joined(separator: "\n")
        let suffix = hosts.count > 5 ? "\n…and \(hosts.count - 5) more" : ""
        return "\(base)\n\n\(names)\(suffix)"
    }

    private var hostsTable: some View {
        Table(of: BlueSkyHost.self,
              selection: $selection,
              sortOrder: $sortOrder,
              columnCustomization: $columnCustomization) {
            TableColumn("★", value: \BlueSkyHost.favoriteSortKey) { h in
                StarButton(host: h) { Task { await setFavorite(!h.isFavorite, on: [h]) } }
            }
            .width(28)
            .customizationID("favorite")
            .disabledCustomizationBehavior(.resize)
            TableColumn("●", value: \BlueSkyHost.activeSortKey) { h in
                Image(systemName: h.active ? "circle.fill" : "circle")
                    .foregroundStyle(h.active ? .green : .secondary)
                    .help(h.active ? "Tunnel is active" : "Not currently tunneled")
            }
            .width(30)
            .customizationID("active")
            .disabledCustomizationBehavior(.resize)
            TableColumn("ID", value: \BlueSkyHost.blueskyid) { h in
                Text("\(h.blueskyid)")
            }
            .width(min: 40, ideal: 50, max: 80)
            .customizationID("id")
            TableColumn("Hostname", value: \BlueSkyHost.displayName) { h in
                HostnameCell(host: h, category: categories.category(for: h),
                             tint: CategoryColors.tint(for: categories.category(for: h)))
            }
            .width(min: 160, ideal: 220, max: 420)
            .customizationID("hostname")
            .disabledCustomizationBehavior(.visibility)  // can't be hidden — primary identifier
            TableColumn("Connect") { h in
                HStack(spacing: 6) {
                    PersistentIconButton(
                        storageKey: "sshRowIconSymbol",
                        defaultIcon: "terminal",
                        color: .green,
                        enabled: h.active,
                        help: "Remote Shell (SSH)"
                    ) { runQuickAction(host: h, kind: .ssh) }
                    PersistentIconButton(
                        storageKey: "vncRowIconSymbol",
                        defaultIcon: "display",
                        color: .blue,
                        enabled: h.active,
                        help: "Screen Share (VNC)"
                    ) { runQuickAction(host: h, kind: .vnc) }
                    // Group 1 → Group 2 boundary: separates remote-
                    // control actions (SSH/VNC) from file/install
                    // actions (SCP/Install).
                    rowDivider
                    PersistentIconButton(
                        storageKey: "scpRowIconSymbol",
                        defaultIcon: "arrow.up.doc.fill",
                        color: .orange,
                        enabled: h.active,
                        help: "File Upload (SCP)"
                    ) { runQuickAction(host: h, kind: .scp) }
                    PersistentIconButton(
                        storageKey: "installRowIconSymbol",
                        defaultIcon: "shippingbox.fill",
                        color: .purple,
                        enabled: h.active && (hasPackageCatalog || settings.isMunkiRepoConfigured),
                        help: "Install Package"
                    ) { openPackagePicker(for: [h]) }
                    // Group 2 → Group 3 boundary: separates file /
                    // install from communication / automation
                    // (Chat / Quick Actions).
                    rowDivider
                    PersistentIconButton(
                        storageKey: "chatRowIconSymbol",
                        defaultIcon: "bubble.left.and.bubble.right.fill",
                        color: .teal,
                        enabled: h.active,
                        help: "Chat"
                    ) {
                        chatController.present(ChatService(host: h, settings: settings, targetUser: "", launcher: quickActionLauncher))
                        openWindow(id: "blueconnect-chat")
                    }
                    QuickActionsMenuButton(
                        host: h,
                        enabled: h.active,
                        quickActionStore: quickActionStore,
                        onPick: { action in
                            quickActionTarget = QuickActionTarget(host: h, action: action)
                        }
                    )
                }
            }
            .width(min: 200, ideal: 210, max: 240)
            .customizationID("connect")
            TableColumn("User", value: \BlueSkyHost.usernameSortKey) { h in
                UserCell(host: h, defaultUser: settings.defaultRemoteUser) {
                    setUsernameTargets = [h]
                    showingSetUsernameSheet = true
                }
            }
            .width(min: 90, ideal: 130, max: 200)
            .customizationID("user")
            TableColumn("Recent") { (h: BlueSkyHost) in
                Text(recents.relativeString(for: h.blueskyid))
                    .foregroundStyle(recents.date(for: h.blueskyid) == nil ? .secondary : .primary)
            }
            .width(min: 100, ideal: 130, max: 170)
            .customizationID("recent")
            TableColumn("Status", value: \BlueSkyHost.statusSortKey) { h in
                Text(h.status ?? "—")
            }
            .width(min: 140, ideal: 200, max: 280)
            .customizationID("status")
            TableColumn("Last Seen", value: \BlueSkyHost.timestamp) { h in
                Text(h.lastSeen ?? "—")
            }
            .width(min: 160, ideal: 220, max: 280)
            .customizationID("last_seen")
        } rows: {
            ForEach(filteredAndSorted) { h in
                TableRow(h)
                    .draggable(dragPayload(for: h))
                    .dropDestination(for: URL.self) { urls in
                        guard let url = urls.first, h.active else { return }
                        let ext = url.pathExtension.lowercased()
                        if ext == "pkg" || ext == "dmg" {
                            installLocalPackage(url: url, on: h)
                        } else if ext == "app" {
                            pendingAppInstall = (host: h, url: url)
                        } else {
                            scpController.begin(with: h, source: url)
                            openWindow(id: "scp-transfer")
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contextMenu(forSelectionType: BlueSkyHost.ID.self) { sel in
            let menuTargets: [BlueSkyHost] = {
                let setForMenu = sel.isEmpty ? selection : sel
                return filteredAndSorted.filter { setForMenu.contains($0.id) }
            }()
            if menuTargets.count == 1, let h = menuTargets.first {
                // Order requested by user: Quick Actions → divider →
                // SSH/VNC/SCP (open in Terminal.app) → divider → Open
                // Chat → divider → Set Category → rest (Install,
                // Software Inventory, Rename, Danger Zone).
                Menu("Quick Actions") {
                    let enabled = quickActionStore.allEnabled
                    let recents = enabled.recents
                    if !recents.isEmpty {
                        Section("Recent") {
                            ForEach(recents) { action in
                                Button(action.label) {
                                    quickActionTarget = QuickActionTarget(host: h, action: action)
                                }
                            }
                        }
                        Divider()
                    }
                    let favorites = enabled.favorites
                    if !favorites.isEmpty {
                        Section("Favorites") {
                            ForEach(favorites) { action in
                                Button(action.label) {
                                    quickActionTarget = QuickActionTarget(host: h, action: action)
                                }
                            }
                        }
                        Divider()
                    }
                    ForEach(Array(enabled.grouped.enumerated()),
                            id: \.offset) { entry in
                        Menu(entry.element.0) {
                            ForEach(entry.element.1) { action in
                                Button(action.label) {
                                    quickActionTarget = QuickActionTarget(host: h, action: action)
                                }
                            }
                        }
                    }
                }
                .disabled(!h.active)
                Divider()
                // Connection commands — flat top-level instead of an
                // "Open in Terminal" submenu. They route through
                // `openInTerminal(host:kind:)` which dispatches to
                // macOS Terminal.app, not the in-app bottom-pane
                // terminal drawer (the row icons already cover that).
                // SCP intentionally omitted from the context menu —
                // file uploads are driven by the row icon + drag-and-
                // drop on the host row.
                Button("SSH (Remote Shell)") { openInTerminal(host: h, kind: .ssh) }
                    .disabled(!h.active)
                Button("VNC (Screen Share)")  { openInTerminal(host: h, kind: .vnc) }
                    .disabled(!h.active)
                // Install — flat single button (no submenu). Opens the
                // picker window with all three source tabs (Munki /
                // Remote / Local), so all install paths are reachable
                // without nesting menus in the context menu. Sits
                // directly under the connection items because Install
                // is the next-most-common destructive-ish action after
                // SSH / VNC.
                Button("Install…") {
                    Task { @MainActor in openPackagePicker(for: [h]) }
                }
                .disabled(!h.active)
                Divider()
                // Single Chat button — defaults to "whoever's at the
                // screen". "With specific user…" lives in the menu
                // bar's Connect → Chat submenu instead, keeping the
                // host context menu compact.
                Button("Chat") {
                    chatController.present(
                        ChatService(host: h, settings: settings, targetUser: "", launcher: quickActionLauncher),
                        openWindow: { openWindow(id: "blueconnect-chat") }
                    )
                }
                .disabled(!h.active)
                Divider()
                Button("Rename…") { renameTarget = h }
                Button("Set Username…") {
                    setUsernameTargets = [h]
                    showingSetUsernameSheet = true
                }
                Menu("Set Category") {
                    if !categories.categories.isEmpty {
                        ForEach(categories.categories, id: \.self) { cat in
                            Button(cat) { assignCategoryDirect(cat, to: [h]) }
                        }
                        Divider()
                    }
                    Button("Clear Category") { assignCategoryDirect(nil, to: [h]) }
                    Divider()
                    Button("New Category…") {
                        categoryTargets = [h]
                        showingCategorySheet = true
                    }
                }
                Divider()
                // (Install moved up — see the flat "Install…" button
                // just under SSH / VNC. Source picking (Munki /
                // Remote / Local) happens inside the picker window
                // now, not via a nested menu here.)
                Menu("Danger Zone") {
                    Button("Erase / Reinstall macOS…", role: .destructive) {
                        eraseInstallTarget = h
                    }
                    .disabled(!h.active)
                    Divider()
                    Button("Send Delete Command (selfdestruct)") {
                        alert = .singleAction(host: h, action: .selfdestruct)
                    }
                    Button("Delete from Database…", role: .destructive) {
                        alert = .singleAction(host: h, action: .delete)
                    }
                    Button("Block Host Permanently…", role: .destructive) {
                        alert = .singleAction(host: h, action: .block)
                    }
                    .disabled((h.serialnum ?? "").isEmpty)
                }
                // (Quick Actions + Open Chat moved to the top of the
                // menu per user spec — see the block above the
                // Connections section.)
            } else if menuTargets.count > 1 {
                Button("Set Username for \(menuTargets.count) Hosts…") {
                    setUsernameTargets = menuTargets
                    showingSetUsernameSheet = true
                }
                Menu("Set Category for \(menuTargets.count) Hosts") {
                    if !categories.categories.isEmpty {
                        ForEach(categories.categories, id: \.self) { cat in
                            Button(cat) { assignCategoryDirect(cat, to: menuTargets) }
                        }
                        Divider()
                    }
                    Button("Clear Category") { assignCategoryDirect(nil, to: menuTargets) }
                    Divider()
                    Button("New Category…") {
                        categoryTargets = menuTargets
                        showingCategorySheet = true
                    }
                }
                if let cat = packageCatalog.catalog, !cat.packages.isEmpty {
                    Button("Install Package on \(menuTargets.count) Hosts…") {
                        openPackagePicker(for: menuTargets)
                    }
                    .disabled(!menuTargets.contains(where: \.active))
                }
                Divider()
                Button("Send Delete Command to \(menuTargets.count) Hosts") {
                    alert = .bulkAction(hosts: menuTargets, action: .selfdestruct)
                }
                Button("Delete \(menuTargets.count) Hosts from Database…", role: .destructive) {
                    alert = .bulkAction(hosts: menuTargets, action: .delete)
                }
            }
        }
        .focusable()
        .onKeyPress(keys: [.delete], phases: .down) { press in
            let hosts = selectedHosts
            guard !hosts.isEmpty else { return .ignored }
            let mods = press.modifiers
            if mods.contains(.command) && mods.contains(.shift) {
                triggerHostAction(.selfdestruct, on: hosts)
                return .handled
            }
            if mods.contains(.command) {
                triggerHostAction(.delete, on: hosts)
                return .handled
            }
            if mods.isEmpty {
                deleteChooserHosts = hosts
                return .handled
            }
            return .ignored
        }
        .confirmationDialog(
            deleteChooserHosts.count == 1
                ? "Delete \(deleteChooserHosts.first?.displayName ?? "host")?"
                : "Delete \(deleteChooserHosts.count) hosts?",
            isPresented: Binding(
                get: { !deleteChooserHosts.isEmpty },
                set: { if !$0 { deleteChooserHosts = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Send Remote Delete Command", role: .destructive) {
                let h = deleteChooserHosts
                deleteChooserHosts = []
                triggerHostAction(.selfdestruct, on: h)
            }
            Button("Delete from Database…", role: .destructive) {
                let h = deleteChooserHosts
                deleteChooserHosts = []
                triggerHostAction(.delete, on: h)
            }
            Button("Cancel", role: .cancel) { deleteChooserHosts = [] }
        } message: {
            Text("“Send Remote Delete Command” tells the Mac client to uninstall itself; the DB row stays.\n“Delete from Database” permanently removes the row and scrubs the pubkey.")
        }
    }

    private func triggerHostAction(_ action: HostAction, on hosts: [BlueSkyHost]) {
        guard !hosts.isEmpty else { return }
        if hosts.count == 1, let h = hosts.first {
            alert = .singleAction(host: h, action: action)
        } else {
            alert = .bulkAction(hosts: hosts, action: action)
        }
    }

    private func dragPayload(for host: BlueSkyHost) -> String {
        if selection.contains(host.id), selection.count > 1 {
            return DragPayload.hosts(Array(selection))
        }
        return DragPayload.hosts([host.blueskyid])
    }

    /// Vertical gutter rendered between groups of row icons in the
    /// Connect column. Two of these appear today: between
    /// SSH/VNC and SCP/Install, and between SCP/Install and
    /// Chat/Quick Actions.
    private var rowDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 3)
    }

    private var hasPackageCatalog: Bool {
        !(packageCatalog.catalog?.packages.isEmpty ?? true)
    }

    private enum QuickActionKind: String { case ssh, vnc, scp }

    private func runQuickAction(host: BlueSkyHost, kind: QuickActionKind) {
        let user = host.effectiveUser(default: settings.defaultRemoteUser)
        guard !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alert = .result(
                title: "No Remote Username",
                message: "There's no per-host username on #\(host.blueskyid) and no Default remote user in Settings. Set one via right-click → Set Username… on the host, or Settings → Connection defaults → Default remote user."
            )
            return
        }
        var svc = ConnectionService(
            server: settings.serverFqdn,
            adminKeyPath: settings.expandedKeyPath,
            serverSshPort: settings.sshTunnelPort,
            terminals: terminals
        )
        svc.onConnect = { h in
            recents.recordConnect(blueskyid: h.blueskyid)
            let label = kind == .ssh ? "SSH" : (kind == .vnc ? "VNC" : "SCP")
            activity.record(.connect, title: "\(label) to \(h.displayName)", detail: "#\(h.blueskyid) as \(user)")
        }
        switch kind {
        case .ssh: svc.openSSH(host: host, remoteUser: user)
        case .vnc:
            vncController = svc.makeVNCController(host: host, remoteUser: user, recents: recents)
        case .scp:
            scpController.begin(with: host)
            openWindow(id: "scp-transfer")
        }
    }

    private func openInTerminal(host: BlueSkyHost, kind: QuickActionKind) {
        let user = host.effectiveUser(default: settings.defaultRemoteUser)
        guard !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alert = .result(
                title: "No Remote Username",
                message: "There's no per-host username on #\(host.blueskyid) and no Default remote user in Settings. Set one via right-click → Set Username… on the host, or Settings → Connection defaults → Default remote user."
            )
            return
        }
        var svc = ConnectionService(
            server: settings.serverFqdn,
            adminKeyPath: settings.expandedKeyPath,
            serverSshPort: settings.sshTunnelPort,
            terminals: terminals
        )
        svc.onConnect = { h in
            recents.recordConnect(blueskyid: h.blueskyid)
            let label = kind == .ssh ? "SSH" : (kind == .vnc ? "VNC" : "SCP")
            activity.record(.connect, title: "\(label) (Terminal) to \(h.displayName)", detail: "#\(h.blueskyid) as \(user)")
        }
        switch kind {
        case .ssh: svc.openSSHInTerminal(host: host, remoteUser: user)
        case .vnc: svc.openVNCInTerminal(host: host, remoteUser: user)
        case .scp:
            pendingTerminalScpHost = host
            showingTerminalScpPicker = true
        }
    }

    /// Handler for files dropped onto the Package Picker sheet. Installs
    /// the file on every selected active host. If `packageUploadSCPPath`
    /// is configured, also scp's it to the catalog backend and refreshes
    /// the catalog so the new file appears permanently.
    private func handlePackagePickerDrop(url: URL, hosts: [BlueSkyHost]) {
        let activeHosts = hosts.filter(\.active)
        let ext = url.pathExtension.lowercased()

        // 1. Install side — only runs if at least one host is targeted.
        if !activeHosts.isEmpty {
            if ext == "app" {
                // First host kicks off the compress-vs-raw confirmation.
                if let h = activeHosts.first {
                    pendingAppInstall = (host: h, url: url)
                }
            } else {
                for h in activeHosts {
                    installLocalPackage(url: url, on: h)
                }
            }
        }

        // 2. Repo upload side — runs regardless of host selection.
        if !settings.isPackageRepoConfigured {
            alert = .result(
                title: "Package Repo not configured",
                message: "Open Settings → Package Repo, pick a service (SSH / FTP / Nextcloud) and fill in its fields. The file was \(activeHosts.isEmpty ? "not installed and not uploaded — nothing happened." : "installed on \(activeHosts.count) host\(activeHosts.count == 1 ? "" : "s") but NOT uploaded to the repo.")"
            )
            return
        }

        Task {
            let err = await packageCatalog.upload(
                localFile: url,
                scpPath: settings.packageRepoUploadURL,
                keyPath: settings.expandedPackageUploadKeyPath,
                service: settings.packageRepoService,
                catalogURL: settings.packageCatalogURL
            )
            if let err {
                alert = .result(title: "Repo upload failed", message: err)
            } else {
                alert = .result(
                    title: "Added to repo",
                    message: "\(url.lastPathComponent) is now in your repo. It will show up in the picker on the next refresh."
                )
            }
        }
    }

    /// Open the host's page on the configured MunkiReport server in the
    /// default browser. MunkiReport-php 5.x doesn't expose a usable REST
    /// API for external clients, so this is the most useful integration
    /// without scraping the session-auth web UI.
    private func openMunkiReport(for host: BlueSkyHost) {
        guard let serial = host.serialnum, !serial.isEmpty else { return }
        let root = settings.munkiReportURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !root.isEmpty else { return }
        let urlString = "\(root)/clients/show/\(serial)"
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    /// Run a `QuickAction`'s built command on the host via the standard
    /// BSC ssh path. Output streams into a terminal tab named with the
    /// action's `tabLabel`. `values` is the raw form-input dict; most
    /// actions don't need it, but `setHostname` uses it to also POST
    /// the new name to BSC's `bs_host_update.json.php` (the BSC agent
    /// only reports hostname during initial registration, so without
    /// this side-channel BSC stays stale even after `scutil` succeeds).
    private func runQuickAction(host: BlueSkyHost, action: QuickAction, command: String, values: [String: String] = [:]) {
        recents.recordConnect(blueskyid: host.blueskyid)
        quickActionStore.noteUsed(action.id)
        // Set Hostname → also update BSC's record so the display name
        // in BlueConnect Admin matches what the Mac now reports. Fires
        // independently of the SSH command — if scutil fails on the
        // Mac, BSC still gets updated and the user sees the new name;
        // if BSC fails, the Mac is still renamed and the next refresh
        // surfaces the mismatch via Activity Log.
        if action.id == "setHostname",
           let newName = values["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !newName.isEmpty {
            runRename(host: host, newHostname: newName)
        }
        let svc = ConnectionService(
            server: settings.serverFqdn,
            adminKeyPath: settings.expandedKeyPath,
            serverSshPort: settings.sshTunnelPort,
            terminals: terminals
        )
        // Setup intercepts: this Quick Action's shell script installs
        // the chat binary from /tmp/blueconnect-chat IF staged. We
        // SCP-push the binary from the app bundle to /tmp on the
        // target before opening the install terminal tab. SCP uses
        // its own data channel so the 237KB binary isn't subject to
        // the inline-base64 truncation we hit with the BSC nc proxy.
        // Background task: SCP first, then dispatch. If SCP fails we
        // still run the install — helper + Large Type + Notify User
        // work without the chat binary, just no chat on this host
        // until the operator pushes it manually.
        // GUI Helper action is now mode-pickered (install / uninstall) on
        // a single QuickAction id. Only the install branch needs the
        // chat binary staged at /tmp; the uninstall command just rm's
        // /usr/local/bin/blueconnect-chat so an SCP push beforehand
        // would be wasted bytes. Detect install mode by the unique
        // install-only substring in the resolved command.
        let isHelperInstall =
            action.id == "setupGuiHelper" &&
            command.contains("/usr/local/bin/blueconnect-gui-helper")
        let user = host.effectiveUser(default: settings.defaultRemoteUser)
        if isHelperInstall,
           let chatURL = Bundle.main.url(forResource: "blueconnect-chat", withExtension: nil) {
            Task { @MainActor in
                let (status, stderr) = await svc.pushFileViaSCP(
                    localPath: chatURL.path,
                    remotePath: "/tmp/blueconnect-chat",
                    host: host,
                    remoteUser: user
                )
                if status != 0 {
                    Log.warn("Setup",
                             "SCP of chat binary to \(host.displayName) failed (status \(status)): \(stderr.prefix(200))")
                }
                svc.openRemoteCommand(host: host,
                                      remoteUser: user,
                                      command: command,
                                      label: action.tabLabel)
            }
            return
        }
        svc.openRemoteCommand(host: host,
                              remoteUser: user,
                              command: command,
                              label: action.tabLabel)
    }

    /// Build the erase-install bash command (full flag set) and run it
    /// on the host via the existing one-shot ssh helper. Output streams
    /// into a terminal tab named `reinstall: <host>` / `erase: <host>` /
    /// `list: <host>` / `test-run: <host>` per chosen mode.
    private func runEraseInstall(host: BlueSkyHost, spec: EraseInstallSheet.RunSpec) {
        recents.recordConnect(blueskyid: host.blueskyid)
        EraseInstallSheet.pushRecent(spec: spec,
                                     hostName: host.displayName,
                                     settings: settings)
        let command = EraseInstallSheet.buildCommand(
            spec: spec,
            scriptPath: settings.eraseInstallPath,
            defaultFlags: settings.eraseInstallDefaultFlags
        )
        let svc = ConnectionService(
            server: settings.serverFqdn,
            adminKeyPath: settings.expandedKeyPath,
            serverSshPort: settings.sshTunnelPort,
            terminals: terminals
        )
        let label: String
        switch spec.mode {
        case .reinstall: label = "reinstall"
        case .erase:     label = "erase"
        case .list:      label = "list"
        case .testRun:   label = "test-run"
        }
        svc.openRemoteCommand(host: host,
                              remoteUser: host.effectiveUser(default: settings.defaultRemoteUser),
                              command: command,
                              label: label)
    }

    /// Hand off a local .pkg / .dmg / .app to the install controller
    /// and open the progress window. The window shows source/target,
    /// asks for a sudo password if needed, then runs phased install
    /// with a progress bar — no terminal tab spam.
    private func installLocalPackage(url: URL, on host: BlueSkyHost) {
        beginInstallWindow(url: url, on: host, appMode: .compress)
    }

    private func installAppWithMode(url: URL, on host: BlueSkyHost,
                                    mode: InstallController.AppMode) {
        beginInstallWindow(url: url, on: host, appMode: mode)
    }

    private func beginInstallWindow(url: URL, on host: BlueSkyHost,
                                    appMode: InstallController.AppMode) {
        recents.recordConnect(blueskyid: host.blueskyid)
        installer.prepare(host: host, localFile: url, appMode: appMode)
        openWindow(id: "install-progress")
    }

    /// Open the install window IMMEDIATELY for a Munki package, in the
    /// usual `.idle` state (sudo password prompt + Install button). The
    /// S3 download closure is stashed on the controller and only runs
    /// after the user clicks Install — same gather-creds-first flow as
    /// the local-file install path. The download then shows up as the
    /// leading `.download` step in the progress checklist.
    private func installMunkiPackage(_ pkg: MunkiPkg, on host: BlueSkyHost) {
        guard let loc = pkg.installerItemLocation, !loc.isEmpty else {
            alert = .result(title: "Munki Install",
                            message: "This pkginfo has no installer_item_location — nothing to download.")
            return
        }
        let ext = (loc as NSString).pathExtension.isEmpty
            ? "pkg" : (loc as NSString).pathExtension
        let fileName = (loc as NSString).lastPathComponent
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bcadmin-munki-\(UUID().uuidString).\(ext)")
        let store = munkiStore
        let settingsRef = settings

        recents.recordConnect(blueskyid: host.blueskyid)
        installer.prepareMunkiPending(host: host, expectedFileName: fileName) {
            try await store.fetch(key: "pkgs/\(loc)", to: tmp, settings: settingsRef)
            return tmp
        }
        openWindow(id: "install-progress")
    }

    /// Present the floating Install Package window for these hosts.
    private func openPackagePicker(for hosts: [BlueSkyHost]) {
        packagePickerHosts = hosts
        packagePicker.present(hosts: hosts)
        openWindow(id: "package-picker")
    }

    private func installPackage(_ pkg: Package, on host: BlueSkyHost) {
        guard let cat = packageCatalog.catalog,
              let cmd = cat.remoteCommand(for: pkg) else { return }
        recents.recordConnect(blueskyid: host.blueskyid)
        let svc = ConnectionService(
            server: settings.serverFqdn,
            adminKeyPath: settings.expandedKeyPath,
            serverSshPort: settings.sshTunnelPort,
            terminals: terminals
        )
        svc.openRemoteCommand(host: host,
                              remoteUser: host.effectiveUser(default: settings.defaultRemoteUser),
                              command: cmd,
                              label: "install: \(pkg.name)")
    }

    private func installPackage(_ pkg: Package, on service: LocalService) {
        guard let cat = packageCatalog.catalog else {
            Log.warn("Install", "installPackage(Local) → no catalog loaded; pkg=\(pkg.name)")
            return
        }
        guard let cmd = cat.remoteCommand(for: pkg) else {
            Log.warn("Install", "installPackage(Local) → no remoteCommand for pkg=\(pkg.name) file=\(pkg.file ?? "-") cmd=\(pkg.command ?? "-")")
            return
        }
        Log.info("Install",
                 "installPackage(Local) → \(service.name):\(service.sshPort ?? -1) cmd=\(cmd.prefix(120))")
        runDirectRemoteCommand(cmd, label: "install: \(pkg.name)", on: service)
    }

    private func installLocalFile(_ url: URL, on service: LocalService) {
        guard let port = service.sshPort else { return }
        let target = InstallController.DirectTarget(
            hostname: service.hostname,
            port: port,
            remoteUser: resolvedRemoteUser(for: service),
            displayName: service.name
        )
        installer.prepareDirect(target: target, localFile: url, appMode: .compress)
        openWindow(id: "install-progress")
    }

    private func installMunkiPackage(_ pkg: MunkiPkg, on service: LocalService) {
        guard let port = service.sshPort else { return }
        guard let loc = pkg.installerItemLocation, !loc.isEmpty else { return }
        let ext = (loc as NSString).pathExtension.isEmpty
            ? "pkg" : (loc as NSString).pathExtension
        let fileName = (loc as NSString).lastPathComponent
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bcadmin-munki-\(UUID().uuidString).\(ext)")
        let store = munkiStore
        let settingsRef = settings
        let target = InstallController.DirectTarget(
            hostname: service.hostname,
            port: port,
            remoteUser: resolvedRemoteUser(for: service),
            displayName: service.name
        )
        installer.prepareMunkiPendingDirect(target: target,
                                            expectedFileName: fileName) {
            try await store.fetch(key: "pkgs/\(loc)", to: tmp, settings: settingsRef)
            return tmp
        }
        openWindow(id: "install-progress")
    }

    private func runDirectRemoteCommand(_ command: String, label: String,
                                        on service: LocalService) {
        guard let port = service.sshPort else {
            Log.warn("Install", "runDirectRemoteCommand → no sshPort on service=\(service.name)")
            return
        }
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        Log.info("Install",
                 "runDirectRemoteCommand → ssh \(resolvedRemoteUser(for: service))@\(service.hostname):\(port) label=\(label)")
        let svc = ConnectionService(
            server: settings.serverFqdn,
            adminKeyPath: settings.expandedKeyPath,
            serverSshPort: settings.sshTunnelPort,
            terminals: terminals
        )
        svc.openDirectRemoteCommand(hostname: service.hostname,
                                    port: port,
                                    remoteUser: resolvedRemoteUser(for: service),
                                    command: cmd,
                                    label: label)
    }

    private func resolvedRemoteUser(for service: LocalService) -> String {
        service.source == .tailscale
            ? settings.tailscaleUser(for: service.name)
            : settings.defaultRemoteUser
    }

    private func drainPackagePickerIntents() {
        if let pkg = packagePicker.pendingDirectInstall {
            handlePendingDirectInstall(pkg)
        } else if let pkg = packagePicker.pendingMunkiInstall {
            handlePendingMunkiInstall(pkg)
        } else if let url = packagePicker.pendingFileDrop {
            handlePendingFileDrop(url)
        }
    }

    private func handlePendingDirectInstall(_ pkg: Package) {
        Log.info("Install",
                 "handlePendingDirectInstall pkg=\(pkg.name) hosts=\(packagePicker.hosts.count) localTarget=\(packagePicker.localTarget?.name ?? "-")")
        if let localTarget = packagePicker.localTarget {
            installPackage(pkg, on: localTarget)
            packagePicker.pendingDirectInstall = nil
            packagePicker.localTarget = nil
            dismissPackagePickerIfNeeded()
            return
        }
        for h in packagePicker.hosts where h.active {
            installPackage(pkg, on: h)
        }
        packagePicker.pendingDirectInstall = nil
        dismissPackagePickerIfNeeded()
    }

    private func handlePendingMunkiInstall(_ pkg: MunkiPkg) {
        Log.info("Install",
                 "handlePendingMunkiInstall pkg=\(pkg.name) hosts=\(packagePicker.hosts.count) localTarget=\(packagePicker.localTarget?.name ?? "-")")
        if let localTarget = packagePicker.localTarget {
            installMunkiPackage(pkg, on: localTarget)
            packagePicker.pendingMunkiInstall = nil
            packagePicker.localTarget = nil
            dismissPackagePickerIfNeeded()
            return
        }
        for h in packagePicker.hosts where h.active {
            installMunkiPackage(pkg, on: h)
        }
        packagePicker.pendingMunkiInstall = nil
        dismissPackagePickerIfNeeded()
    }

    private func handlePendingFileDrop(_ url: URL) {
        if let localTarget = packagePicker.localTarget {
            installLocalFile(url, on: localTarget)
            packagePicker.pendingFileDrop = nil
            packagePicker.localTarget = nil
            dismissPackagePickerIfNeeded()
            return
        }
        handlePackagePickerDrop(url: url, hosts: packagePicker.hosts)
        packagePicker.pendingFileDrop = nil
        dismissPackagePickerIfNeeded()
    }

    private func dismissPackagePickerIfNeeded() {
        guard packagePicker.dismissPickerAfterPendingIntent else { return }
        packagePicker.dismissPickerAfterPendingIntent = false
        dismissWindow(id: "package-picker")
    }

    private func assignCategoryDirect(_ category: String?, to hosts: [BlueSkyHost]) {
        Task {
            let r = await categories.assign(category, to: hosts, settings: settings)
            await hostStore.refresh(settings: settings)
            if !r.failed.isEmpty {
                alert = .result(
                    title: "Category Partial",
                    message: "Succeeded: \(r.ok)\nFailed:\n\(r.failed.prefix(5).joined(separator: "\n"))"
                )
            }
        }
    }

    private func updateField(host: BlueSkyHost, field: String, value: Any) {
        Task {
            do {
                _ = try await BlueSkyAPI.shared.updateHost(
                    blueskyid: host.blueskyid,
                    fields: [field: value],
                    apiURL: settings.apiURL,
                    username: settings.apiUsername,
                    password: settings.webAdminPass
                )
                await hostStore.refresh(settings: settings)
            } catch {
                let m = (error as? APIError)?.errorDescription ?? error.localizedDescription
                alert = .result(title: "Update Failed", message: m)
            }
        }
    }

    private func saveNotes(host: BlueSkyHost, notes: String) {
        Task {
            do {
                _ = try await BlueSkyAPI.shared.updateHost(
                    blueskyid: host.blueskyid,
                    fields: ["notes": notes],
                    apiURL: settings.apiURL,
                    username: settings.apiUsername,
                    password: settings.webAdminPass
                )
                await hostStore.refresh(settings: settings)
            } catch {
                let m = (error as? APIError)?.errorDescription ?? error.localizedDescription
                alert = .result(title: "Save Notes Failed", message: m)
            }
        }
    }

    private func runSetUsername(hosts: [BlueSkyHost], newUsername: String) {
        guard !hosts.isEmpty else { return }
        Task {
            var ok = 0
            var failed: [String] = []
            for h in hosts {
                do {
                    _ = try await BlueSkyAPI.shared.updateHost(
                        blueskyid: h.blueskyid,
                        fields: ["username": newUsername],
                        apiURL: settings.apiURL,
                        username: settings.apiUsername,
                        password: settings.webAdminPass
                    )
                    ok += 1
                } catch {
                    let m = (error as? APIError)?.errorDescription ?? error.localizedDescription
                    failed.append("#\(h.blueskyid) \(h.displayName): \(m.prefix(80))")
                }
            }
            await hostStore.refresh(settings: settings)
            let valueText = newUsername.isEmpty ? "cleared (fall back to default)" : "→ \(newUsername)"
            if hosts.count == 1 {
                let h = hosts[0]
                if failed.isEmpty {
                    activity.record(.rename, title: "Set username #\(h.blueskyid)", detail: "\(h.displayName) \(valueText)")
                } else {
                    activity.record(.error, title: "Set username failed", detail: failed.first ?? "")
                    alert = .result(title: "Set Username Failed", message: failed.first ?? "")
                }
            } else {
                activity.record(.rename, title: "Bulk set username", detail: "\(ok)/\(hosts.count) hosts \(valueText)")
                if !failed.isEmpty {
                    alert = .result(
                        title: "Bulk Set Username Partial",
                        message: "Succeeded: \(ok) of \(hosts.count)\n\nFailed:\n" + failed.prefix(8).joined(separator: "\n")
                    )
                }
            }
        }
    }

    private func setFavorite(_ favorite: Bool, on hosts: [BlueSkyHost]) async {
        var ok = 0
        var failed: [String] = []
        for h in hosts {
            do {
                _ = try await BlueSkyAPI.shared.updateHost(
                    blueskyid: h.blueskyid,
                    fields: ["favorite": favorite ? 1 : 0],
                    apiURL: settings.apiURL,
                    username: settings.apiUsername,
                    password: settings.webAdminPass
                )
                ok += 1
            } catch {
                let m = (error as? APIError)?.errorDescription ?? error.localizedDescription
                failed.append("#\(h.blueskyid): \(m.prefix(80))")
            }
        }
        await hostStore.refresh(settings: settings)
        if !failed.isEmpty {
            alert = .result(
                title: favorite ? "Favorite Failed" : "Unfavorite Failed",
                message: "Succeeded: \(ok)\nFailed:\n\(failed.prefix(5).joined(separator: "\n"))"
            )
        }
    }

    private func runRename(host: BlueSkyHost, newHostname: String) {
        let api = settings.apiURL
        let user = settings.apiUsername
        let pwd = settings.webAdminPass
        Task {
            do {
                _ = try await BlueSkyAPI.shared.renameHost(
                    blueskyid: host.blueskyid, newHostname: newHostname,
                    apiURL: api, username: user, password: pwd
                )
                await hostStore.refresh(settings: settings)
                activity.record(.rename, title: "Renamed #\(host.blueskyid)", detail: "\(host.displayName) → \(newHostname)")
            } catch {
                let m = (error as? APIError)?.errorDescription ?? error.localizedDescription
                activity.record(.error, title: "Rename failed", detail: m)
                alert = .result(title: "Rename Failed", message: m)
            }
        }
    }

    private func runAction(_ action: HostAction, on host: BlueSkyHost) {
        let api = settings.apiURL
        let user = settings.apiUsername
        let pwd = settings.webAdminPass
        Task {
            let reason: String
            switch action {
            case .selfdestruct: reason = "send delete command to \(host.displayName)"
            case .delete:       reason = "permanently delete \(host.displayName)"
            case .block:        reason = "permanently block \(host.displayName)"
            }
            guard await auth.confirmDestructive(reason: reason) else { return }
            do {
                let resp = try await BlueSkyAPI.shared.performAction(
                    action, blueskyid: host.blueskyid, apiURL: api, username: user, password: pwd
                )
                let note = (resp["note"] as? String) ?? "done"
                let (alertTitle, activityTitle): (String, String) = {
                    switch action {
                    case .selfdestruct: return ("Delete Command Sent", "Delete command sent")
                    case .delete:       return ("Host Deleted",        "Host deleted")
                    case .block:        return ("Host Blocked Forever","Host blocked forever")
                    }
                }()
                alert = .result(
                    title: alertTitle,
                    message: "\(host.displayName) (#\(host.blueskyid)) — \(note)"
                )
                activity.record(.delete, title: activityTitle, detail: "#\(host.blueskyid) \(host.displayName)")
                await hostStore.refresh(settings: settings)
            } catch {
                let msg = (error as? APIError)?.errorDescription ?? error.localizedDescription
                alert = .result(title: "Action Failed", message: msg)
            }
        }
    }

    private func runBulk(_ action: HostAction, on hosts: [BlueSkyHost]) {
        let api = settings.apiURL
        let user = settings.apiUsername
        let pwd = settings.webAdminPass
        Task {
            let reason: String
            switch action {
            case .selfdestruct: reason = "send delete command to \(hosts.count) hosts"
            case .delete:       reason = "permanently delete \(hosts.count) hosts"
            case .block:        reason = "permanently block \(hosts.count) hosts"
            }
            guard await auth.confirmDestructive(reason: reason) else { return }
            var ok = 0
            var failed: [String] = []
            for h in hosts {
                do {
                    _ = try await BlueSkyAPI.shared.performAction(
                        action, blueskyid: h.blueskyid, apiURL: api, username: user, password: pwd
                    )
                    ok += 1
                } catch {
                    let m = (error as? APIError)?.errorDescription ?? error.localizedDescription
                    failed.append("#\(h.blueskyid) \(h.displayName): \(m.prefix(80))")
                }
            }
            await hostStore.refresh(settings: settings)
            selection.removeAll()
            let title: String = {
                switch action {
                case .selfdestruct: return "Delete Command Sent"
                case .delete:       return "Bulk Delete Done"
                case .block:        return "Bulk Block Done"
                }
            }()
            var msg = "Succeeded: \(ok) of \(hosts.count)"
            if !failed.isEmpty {
                msg += "\n\nFailed:\n" + failed.prefix(8).joined(separator: "\n")
                if failed.count > 8 { msg += "\n…and \(failed.count - 8) more" }
            }
            alert = .result(title: title, message: msg)
        }
    }

    private func effectiveRemoteUser(host: BlueSkyHost) -> String {
        host.username?.nilIfEmpty() ?? settings.defaultRemoteUser
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                // ZStack lets us render a dimmer placeholder than TextField's
                // default — and gives us a visible click target the whole
                // width of the field, not just where the (faint) caret is.
                ZStack(alignment: .leading) {
                    if searchText.isEmpty {
                        Text("Search")
                            .foregroundStyle(.tertiary)
                    }
                    TextField("", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                }
                if !searchText.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") {
                        searchText = ""
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(searchFocused ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25),
                            lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onTapGesture { searchFocused = true }

            FqdnPill(text: settings.serverFqdn, healthy: serverHealthOK)

            Button("Refresh hosts", systemImage: "arrow.clockwise") {
                Task { await hostStore.refresh(settings: settings) }
            }
            .labelStyle(.iconOnly)
            .overlay {
                if hostStore.isLoading { ProgressView().controlSize(.small) }
            }
            .disabled(hostStore.isLoading)
            .keyboardShortcut("r")
            .help("Refresh (⌘R)")
        }
        .padding(10)
    }

    private var statusBar: some View {
        HStack {
            if let updated = hostStore.lastUpdated {
                Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !selection.isEmpty {
                Text("• \(selection.count) selected")
                    .font(.caption).foregroundStyle(.tint)
            }
            Spacer()
            Text("\(hostStore.activeCount) active / \(hostStore.hosts.count) total")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func decode(_ raw: String) -> SidebarFilter {
        switch raw {
        case "all": return .all
        case "fav": return .favorites
        case "recent": return .recent
        case "active": return .active
        case "inactive": return .inactive
        case "uncat": return .uncategorized
        default:
            if raw.hasPrefix("cat:") { return .category(String(raw.dropFirst(4))) }
            return .all
        }
    }

    private func encode(_ f: SidebarFilter) -> String {
        switch f {
        case .all: return "all"
        case .favorites: return "fav"
        case .recent: return "recent"
        case .active: return "active"
        case .inactive: return "inactive"
        case .uncategorized: return "uncat"
        case .category(let c): return "cat:\(c)"
        }
    }
}

private extension String {
    func nilIfEmpty() -> String? { isEmpty ? nil : self }
}


/// Lifts the filteredAndSorted cache-invalidation `.onChange` chain off
/// `ContentView.body` so the type-checker doesn't time out — body has a lot
/// of state already.
private struct FilteredAndSortedCacheInvalidator: ViewModifier {
    let recompute: () -> Void
    let hosts: [BlueSkyHost]
    let search: String
    let sidebarFilterRaw: String
    let sortOrder: [KeyPathComparator<BlueSkyHost>]
    let recentConnects: [Int: Date]

    func body(content: Content) -> some View {
        content
            .onAppear { recompute() }
            .onChange(of: hosts) { recompute() }
            .onChange(of: search) { recompute() }
            .onChange(of: sidebarFilterRaw) { recompute() }
            .onChange(of: sortOrder) { recompute() }
            .onChange(of: recentConnects) { recompute() }
    }
}
