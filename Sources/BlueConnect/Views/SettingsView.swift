import SwiftUI
import AppKit

/// macOS Settings window. Sidebar on the left with section names + icons,
/// detail Form on the right shows the chosen section's controls. Matches
/// the modern System Settings shape (Ventura+).
struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var auth: AuthGate
    @Environment(BlueSkyHostListStore.self) var hostStore
    @Environment(PackageCatalogStore.self) var packageCatalog
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    // Persist the sidebar selection in @AppStorage so it survives
    // window close/reopen — and, more importantly, so other views
    // (e.g. the Terminal Profile picker's "Customize…" button) can
    // write to the same key BEFORE calling `openSettings()` and have
    // the Settings window come up on the right pane. With a plain
    // `@State` we used to lose the post-via-NotificationCenter
    // signal on first-open because the view wasn't yet in the
    // hierarchy to receive it.
    @AppStorage("settingsSelection") private var selectionRaw: String = Section.blueConnect.rawValue
    private var selection: Section {
        get { Section(rawValue: selectionRaw) ?? .blueConnect }
    }
    private var selectionBinding: Binding<Section> {
        Binding(
            get: { Section(rawValue: selectionRaw) ?? .blueConnect },
            set: { selectionRaw = $0.rawValue }
        )
    }

    // Local string mirrors of the Tailscale port settings (String binding —
    // IntegerFormatStyle's locale grouping silently corrupts port input).
    @State private var tailscaleSSHPortText: String = ""
    @State private var tailscaleVNCPortText: String = ""
    @State private var ftpPortText: String = ""

    enum Section: String, CaseIterable, Identifiable {
        /// `blueConnect` merges what used to be Account + Defaults — one
        /// page for the BSC server URL, login, admin SSH key, default
        /// remote user, and Sign Out.
        case blueConnect, security, discovery,
             tailscaleDefaults, packageRepo, eraseInstall,
             munkiRepo, munkiReport, unifi, quickActions,
             terminal, notifications, about

        var id: String { rawValue }
        var label: String {
            switch self {
            case .blueConnect:      return "General"
            case .security:         return "Security"
            case .discovery:        return "Discovery"
            case .tailscaleDefaults:return "Tailscale Defaults"
            case .packageRepo:      return "Package Repo"
            case .eraseInstall:     return "Erase Install"
            case .munkiRepo:        return "Munki Repo"
            case .munkiReport:      return "MunkiReport"
            case .unifi:            return "Network"
            case .quickActions:     return "Quick Actions"
            case .terminal:         return "Terminal"
            case .notifications:    return "Notifications"
            case .about:            return "About"
            }
        }
        var icon: String {
            switch self {
            case .blueConnect:      return "person.crop.circle"
            case .security:         return "lock.shield"
            case .discovery:        return "dot.radiowaves.left.and.right"
            case .tailscaleDefaults:return "shield.lefthalf.filled"
            case .packageRepo:      return "shippingbox"
            case .eraseInstall:     return "arrow.triangle.2.circlepath.icloud"
            case .munkiRepo:        return "cube.box"
            case .munkiReport:      return "chart.bar.doc.horizontal"
            case .unifi:            return "network"
            case .quickActions:     return "bolt.fill"
            case .terminal:         return "terminal"
            case .notifications:    return "bell"
            case .about:            return "info.circle"
            }
        }
    }

    /// Sidebar order — alphabetical, with "General" pinned to the
    /// top (it's the BSC server/login/key page, the first thing a
    /// new operator needs) and "About" pinned to the bottom (so the
    /// credits page is reliably out of the way).
    private var sortedSections: [Section] {
        let middle = Section.allCases
            .filter { $0 != .blueConnect && $0 != .about }
            .sorted { $0.label.localizedCompare($1.label) == .orderedAscending }
        return [.blueConnect] + middle + [.about]
    }

    var body: some View {
        NavigationSplitView {
            List(sortedSections, selection: selectionBinding) { s in
                Label(s.label, systemImage: s.icon).tag(s)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 720, height: 480)
        .background {
            // Hidden Escape-to-close shortcut. macOS Settings windows
            // normally only close on ⌘W / red traffic light — this gives
            // users an Escape muscle-memory exit.
            Button("Close Settings") { closeSettingsWindow() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onAppear {
            tailscaleSSHPortText = String(settings.tailscaleSSHPort)
            tailscaleVNCPortText = String(settings.tailscaleVNCPort)
            ftpPortText = String(settings.packageRepoFTPPort)
        }
        // Jump the sidebar to the Terminal pane when the Profile
        // Picker's "Customize…" button is pressed. The picker writes
        // the `settingsSelection` AppStorage key BEFORE calling
        // openSettings(), so the value is already in place by the
        // time SettingsView appears — no notification timing race.
        // This receiver remains as a belt-and-suspenders path for
        // already-mounted SettingsViews.
        .onReceive(NotificationCenter.default.publisher(for: .blueConnectOpenTerminalSettings)) { _ in
            selectionRaw = Section.terminal.rawValue
        }
    }

    /// Close whichever NSWindow is currently hosting this view. We can't
    /// use `@Environment(\.dismiss)` reliably on the SwiftUI Settings
    /// scene, so reach down to AppKit and `performClose` the key window.
    private func closeSettingsWindow() {
        if let w = NSApp.keyWindow {
            w.performClose(nil)
            return
        }
        // Fallback: find any window whose title matches the Settings
        // scene title (localized "Settings" on Ventura+, "Preferences"
        // on older OS strings — match both).
        for w in NSApp.windows where w.isVisible {
            let t = w.title.lowercased()
            if t.contains("settings") || t.contains("preferences") {
                w.performClose(nil)
                return
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selection {
        case .blueConnect:      blueConnectPane
        case .security:         securityPane
        case .discovery:        discoveryPane
        case .tailscaleDefaults: tailscalePane
        case .packageRepo:      packageRepoPane
        case .eraseInstall:     eraseInstallPane
        case .munkiRepo:        MunkiRepoSettingsPane()
        case .munkiReport:      MunkiReportSettingsPane()
        case .unifi:            UniFiSettingsPane()
        case .quickActions:     quickActionsPane
        case .terminal:         TerminalSettingsPane()
        case .notifications:    notificationsPane
        case .about:            aboutPane
        }
    }

    // MARK: - Section panes

    /// Merged Account + Defaults + SSH Tunnel page — was three sidebar
    /// entries before. Logical groups separated by Text/bold headers:
    ///   - Server     (read-only signed-in display)
    ///   - SSH tunnel (per-BSC host + port for the ProxyCommand)
    ///   - Connection defaults (admin key + remote user)
    /// Sign Out lives at the bottom.
    private var blueConnectPane: some View {
        Form {
            Text("Server")
                .font(.subheadline).bold().foregroundStyle(.secondary)
            LabeledContent("BlueConnect Server",
                           value: settings.apiURL.isEmpty ? "—" : settings.apiURL)
            LabeledContent("Username",
                           value: settings.apiUsername.isEmpty ? "—" : settings.apiUsername)

            Text("SSH tunnel")
                .font(.subheadline).bold().foregroundStyle(.secondary)
                .padding(.top, 6)
            TextField("SSH host", text: $settings.serverFqdn,
                      prompt: Text(verbatim: "bluesky.example.com"))
                .help("Hostname the SSH ProxyCommand connects to. Often the same as the BlueConnect Server URL host. Override here if your BSC is fronted by a proxy that splits HTTP and SSH onto different hostnames.")
            Stepper(value: $settings.sshTunnelPort, in: 22...65535) {
                Text("SSH port: \(String(settings.sshTunnelPort))")
            }
            .help("Port the BSC sshd listens on. BlueSkyConnect's standard public port is 3122.")

            Text("Connection defaults")
                .font(.subheadline).bold().foregroundStyle(.secondary)
                .padding(.top, 6)
            TextField("Admin SSH key path", text: $settings.adminKeyPath,
                      prompt: Text(verbatim: "~/.ssh/bluesky_admin"))
                .help("Private key used for the SSH ProxyCommand into BSC's reverse tunnel.")
            TextField("Default remote user", text: $settings.defaultRemoteUser,
                      prompt: Text(verbatim: "admin"))
                .help("Account opened by SSH/VNC/SCP on each remote Mac.")
            TextField("Chat window title", text: $settings.chatWindowTitle,
                      prompt: Text(verbatim: "Tech Support"))
                .help("Title shown on both the admin-side chat window and the remote chat client. Defaults to 'Tech Support' — set to your name or your department's name (e.g. 'Brandon', 'IT Help').")

            HStack {
                Spacer()
                Button("Sign Out…") {
                    auth.logout(settings: settings)
                    dismiss()
                }
                .help("Forgets the saved credentials and returns to the login screen.")
            }
        }
        .formStyle(.grouped)
    }

    private var securityPane: some View {
        Form {
            Toggle("Require Touch ID on launch", isOn: $auth.requireTouchID)
                .disabled(!auth.isBiometricsAvailable)
            Toggle("Confirm destructive actions with Touch ID", isOn: $auth.requireTouchIDForDestructive)
            Picker("Auto-lock when idle", selection: $settings.idleLockMinutes) {
                Text("Never").tag(0)
                Text("1 minute").tag(1)
                Text("5 minutes").tag(5)
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
                Text("2 hours").tag(120)
            }
            .disabled(!auth.requireTouchID)
            .help(auth.requireTouchID
                  ? "Locks the app after this much idle time."
                  : "Enable “Require Touch ID on launch” first to use auto-lock.")
            if !auth.isBiometricsAvailable {
                Text("Touch ID unavailable on this Mac — system password is used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var discoveryPane: some View {
        Form {
            Toggle("Show Local Network peers in sidebar", isOn: $settings.localNetworkEnabled)
                .help("Discovers Macs on your LAN via Bonjour/mDNS (SSH + Screen Sharing). Disabling stops the browser entirely and silences the macOS Local Network prompt.")
            Toggle("Show Tailscale peers in sidebar", isOn: $settings.tailscaleEnabled)
                .help("Lists online tailnet machines (macOS + Linux) under their own “Tailscale” section. Reads from the local `tailscale` CLI; off by default.")
        }
        .formStyle(.grouped)
    }

    private var tailscalePane: some View {
        Form {
            // Shares state with the "Show Tailscale peers in sidebar"
            // toggle in Settings → Discovery. Adding a second entry
            // here so users who look under "Tailscale Defaults" find it
            // without having to know it's in Discovery. Same backing
            // @AppStorage("tailscaleEnabled") flag — flipping either
            // toggle updates both.
            Toggle("Show Tailscale group in sidebar", isOn: $settings.tailscaleEnabled)
                .help("Disable to remove the Tailscale group from the left sidebar and stop polling the tailscale CLI. Per-peer overrides + the rest of these settings stay configured.")

            if settings.tailscaleEnabled {
                TextField("Default user",
                          text: $settings.tailscaleDefaultUser,
                          prompt: Text(verbatim: settings.defaultRemoteUser))
                    .help("Remote user used for SSH/VNC/SCP to a Tailscale peer. Leave blank to fall back to the global Default remote user. Per-peer overrides take precedence.")
                TextField("SSH port", text: $tailscaleSSHPortText)
                    .onChange(of: tailscaleSSHPortText) { _, _ in commitSSHPort() }
                    .help("Used when connecting via SSH to a Tailscale peer. Per-peer overrides (right-click a peer → Custom Connection…) take precedence.")
                TextField("VNC port", text: $tailscaleVNCPortText)
                    .onChange(of: tailscaleVNCPortText) { _, _ in commitVNCPort() }
                    .help("Used when connecting via Screen Sharing to a Tailscale peer. Per-peer overrides take precedence.")
            } else {
                Text("Re-enable the toggle above to expose the per-peer connection defaults.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var packageRepoPane: some View {
        Form {
            TextField("Repo URL",
                      text: $settings.packageCatalogURL,
                      prompt: Text(verbatim: "https://example.com/catalog.json"))
                .help("HTTPS URL to your repo's JSON listing (catalog.json or catalog.php). The Install Package menu reads from this.")
            Picker("Upload service", selection: $settings.packageRepoService) {
                Text("SSH / SFTP").tag("ssh")
                Text("FTP / FTPS").tag("ftp")
                Text("Nextcloud (WebDAV)").tag("nextcloud")
            }
            .pickerStyle(.segmented)
            .help("Only one service is active at a time. Pick the one your repo lives on.")

            switch settings.packageRepoService {
            case "ftp":       ftpFields
            case "nextcloud": nextcloudFields
            default:          sshFields
            }

            HStack(spacing: 4) {
                Image(systemName: uploadProtocolIcon).foregroundStyle(uploadProtocolTint)
                Text(uploadProtocolHint)
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if packageCatalog.isRefreshing {
                    ProgressView().controlSize(.small)
                    Text("Refreshing…").font(.caption).foregroundStyle(.secondary)
                } else if let err = packageCatalog.lastError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if let cat = packageCatalog.catalog {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(cat.packages.count) package\(cat.packages.count == 1 ? "" : "s")"
                         + (cat.name.map { " — \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                } else if !settings.packageCatalogURL.isEmpty {
                    Text("Not loaded").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") {
                    Task { await packageCatalog.refresh(urlString: settings.packageCatalogURL) }
                }
                .disabled(settings.packageCatalogURL.isEmpty || packageCatalog.isRefreshing)
            }
        }
        .formStyle(.grouped)
    }

    private var eraseInstallPane: some View {
        Form {
            // Labels are above their fields (instead of LabeledContent's
            // side-by-side layout) and the fields use `.roundedBorder`
            // so it's obvious where you can click and type.
            VStack(alignment: .leading, spacing: 4) {
                Text("Path to erase-install.sh on the host")
                    .font(.callout).bold()
                TextField("", text: $settings.eraseInstallPath,
                          prompt: Text(verbatim: "/Library/Management/erase-install/erase-install.sh"))
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                Text("Where Graham Pugh's `erase-install.sh` lives on the remote Mac. The default matches the standard pkg install. If it's missing on a host, install it from your Package Repo.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Default flags")
                    .font(.callout).bold()
                TextField("", text: $settings.eraseInstallDefaultFlags,
                          prompt: Text(verbatim: "--min-drive-space=50 --cleanup-after-use --check-power --power-wait-limit 180"))
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                Text("Appended to every erase-install run on top of the mode (`--reinstall` / `--erase`) and any per-run overrides set in the sheet.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Trigger from any host's right-click menu → Danger Zone → Erase / Reinstall macOS… (active hosts only).")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }

    private var quickActionsPane: some View {
        QuickActionsSettingsPane()
    }


    private var notificationsPane: some View {
        Form {
            Toggle("Notify on host online/offline transitions", isOn: $settings.notifyOnStateChange)
        }
        .formStyle(.grouped)
    }

    private var aboutPane: some View {
        Form {
            LabeledContent("BlueConnect Admin", value: appShortVersion)
            LabeledContent("Build",             value: appBuildNumber)
            LabeledContent("BlueSky Server",    value: hostStore.lastResponse?.blueSkyVersion?.nilIfEmpty() ?? "—")
            LabeledContent("PHP",               value: hostStore.lastResponse?.phpVersion ?? "—")
            LabeledContent("API",               value: hostStore.lastResponse?.apiVersion ?? "—")
            HStack {
                Spacer()
                Button {
                    openURL(URL(string: "https://github.com/BlueSkyTools/BlueSkyConnect/pkgs/container/blueskyconnect/versions")!)
                } label: {
                    Label("BlueSkyConnect image tags ↗", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
                Button {
                    openURL(URL(string: "https://github.com/BlueSkyTools/BlueSkyConnect")!)
                } label: {
                    Label("BlueSkyConnect repo ↗", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private var appVersion: String {
        "\(appShortVersion) (\(appBuildNumber))"
    }

    private var appShortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private var appBuildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    @ViewBuilder
    private var sshFields: some View {
        TextField("Upload URL",
                  text: $settings.packageUploadSCPPath,
                  prompt: Text(verbatim: "user@host:/path/  or  sftp://user@host:port/path/"))
            .help("SCP (user@host:/path/) or SFTP (sftp://user@host:port/path/). Auth via the SSH key below.")
        TextField("SSH key",
                  text: $settings.packageUploadKeyPath,
                  prompt: Text(verbatim: "~/.ssh/id_rsa"))
            .help("SSH private key for SCP/SFTP uploads.")
    }

    @ViewBuilder
    private var ftpFields: some View {
        Toggle("Use FTPS (TLS-encrypted)", isOn: $settings.packageRepoFTPSecure)
        TextField("Host", text: $settings.packageRepoFTPHost,
                  prompt: Text(verbatim: "ftp.example.com"))
        TextField("Port", text: $ftpPortText)
            .onChange(of: ftpPortText) { _, _ in commitFTPPort() }
        TextField("Username", text: $settings.packageRepoFTPUser)
        SecureField("Password", text: $settings.ftpPassword)
            .onChange(of: settings.ftpPassword) { _, _ in settings.saveFTPPassword() }
        TextField("Remote directory", text: $settings.packageRepoFTPPath,
                  prompt: Text(verbatim: "/path/to/pkgs/"))
            .help("Directory on the FTP server where installers land. Trailing slash recommended.")
    }

    @ViewBuilder
    private var nextcloudFields: some View {
        TextField("Server URL", text: $settings.packageRepoNextcloudServer,
                  prompt: Text(verbatim: "https://cloud.example.com"))
            .help("Your Nextcloud server, including https://. No path.")
        TextField("Username", text: $settings.packageRepoNextcloudUser)
            .help("Your Nextcloud login name (used in the WebDAV path too).")
        SecureField("App password", text: $settings.nextcloudPassword)
            .onChange(of: settings.nextcloudPassword) { _, _ in settings.saveNextcloudPassword() }
            .help("Generate at Nextcloud → Settings → Security → Devices & sessions → Create new app password. Do NOT use your account password.")
        TextField("Remote folder", text: $settings.packageRepoNextcloudPath,
                  prompt: Text(verbatim: "/Packages/"))
            .help("Folder inside your Nextcloud Files where installers land.")
    }

    private func commitFTPPort() {
        let trimmed = ftpPortText.trimmingCharacters(in: .whitespaces)
        if let v = Int(trimmed), (1...65535).contains(v) {
            settings.packageRepoFTPPort = v
        }
    }

    private var uploadURLPrompt: String {
        switch settings.packageRepoService {
        case "ftp":       return "ftp://user:pass@host/path/  or  ftps://…"
        case "nextcloud": return "https://user:apppw@cloud.example.com/remote.php/dav/files/<user>/<path>/"
        default:          return "user@host:/path/  or  sftp://user@host/path/"
        }
    }

    private var uploadURLHelp: String {
        switch settings.packageRepoService {
        case "ftp":       return "FTP or FTPS URL with user and password embedded. Trailing slash means upload as <local filename>."
        case "nextcloud": return "Nextcloud WebDAV path. Generate an app password in Nextcloud → Settings → Security and embed it as user:apppassword. Trailing slash uploads as <local filename>."
        default:          return "SCP (user@host:/path/) or SFTP (sftp://user@host:port/path/). Auth via the SSH key below."
        }
    }

    private var uploadProtocolHint: String {
        switch settings.packageRepoService {
        case "ftp":       return "FTP/FTPS — credentials embedded in URL. FTPS is TLS-encrypted; plain FTP is not."
        case "nextcloud": return "Nextcloud WebDAV PUT — credentials embedded in URL. Use an app password, not your account password."
        default:          return "SCP / SFTP — uses the SSH key below."
        }
    }

    private var uploadProtocolIcon: String {
        switch settings.packageRepoService {
        case "ftp":       return "exclamationmark.triangle"
        case "nextcloud": return "icloud"
        default:          return "lock.shield"
        }
    }

    private var uploadProtocolTint: Color {
        switch settings.packageRepoService {
        case "ftp":       return .orange
        case "nextcloud": return .blue
        default:          return .green
        }
    }

    private func commitSSHPort() {
        let trimmed = tailscaleSSHPortText.trimmingCharacters(in: .whitespaces)
        if let v = Int(trimmed), (1...65535).contains(v) {
            settings.tailscaleSSHPort = v
        }
    }

    private func commitVNCPort() {
        let trimmed = tailscaleVNCPortText.trimmingCharacters(in: .whitespaces)
        if let v = Int(trimmed), (1...65535).contains(v) {
            settings.tailscaleVNCPort = v
        }
    }
}

private extension String {
    func nilIfEmpty() -> String? { isEmpty ? nil : self }
}
