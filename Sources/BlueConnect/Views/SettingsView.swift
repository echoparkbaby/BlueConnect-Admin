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

    @State private var selection: Section = .blueConnect

    // Local string mirrors of the Tailscale port settings (String binding —
    // IntegerFormatStyle's locale grouping silently corrupts port input).
    @State private var tailscaleSSHPortText: String = ""
    @State private var tailscaleVNCPortText: String = ""
    @State private var ftpPortText: String = ""
    @State private var showingMunkiBrowser = false
    /// Local browser store for the Settings → Browse Repository button.
    /// Uses the same on-disk cache as the sidebar/picker, so the catalog
    /// still loads instantly even though the instance isn't shared.
    @State private var settingsMunkiStore = MunkiRepoStore()
    @Environment(PackagePickerController.self) private var packagePicker
    @State private var munkiTestRunning = false
    @State private var munkiTestResult: MunkiTestResult?

    private enum MunkiTestResult: Equatable {
        case success(packageCount: Int)
        case failure(String)
    }

    enum Section: String, CaseIterable, Identifiable {
        /// `blueConnect` merges what used to be Account + Defaults — one
        /// page for the BSC server URL, login, admin SSH key, default
        /// remote user, and Sign Out.
        case blueConnect, security, discovery,
             tailscaleDefaults, packageRepo, eraseInstall,
             munkiRepo, munkiReport, quickActions,
             notifications, about

        var id: String { rawValue }
        var label: String {
            switch self {
            case .blueConnect:      return "BlueConnect"
            case .security:         return "Security"
            case .discovery:        return "Discovery"
            case .tailscaleDefaults:return "Tailscale Defaults"
            case .packageRepo:      return "Package Repo"
            case .eraseInstall:     return "Erase Install"
            case .munkiRepo:        return "Munki Repo"
            case .munkiReport:      return "MunkiReport"
            case .quickActions:     return "Quick Actions"
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
            case .quickActions:     return "bolt.fill"
            case .notifications:    return "bell"
            case .about:            return "info.circle"
            }
        }
    }

    /// Sidebar order — alphabetical, but with "About" pinned to the
    /// bottom so the credits page is reliably out of the way of
    /// everyday-setting traffic.
    private var sortedSections: [Section] {
        let (about, rest) = Section.allCases.reduce(into: ([Section](), [Section]())) {
            partial, sec in
            if sec == .about { partial.0.append(sec) } else { partial.1.append(sec) }
        }
        return rest.sorted {
            $0.label.localizedCompare($1.label) == .orderedAscending
        } + about
    }

    var body: some View {
        NavigationSplitView {
            List(sortedSections, selection: $selection) { s in
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
        case .munkiRepo:        munkiRepoPane
        case .munkiReport:      munkiReportPane
        case .quickActions:     quickActionsPane
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

    private var munkiRepoPane: some View {
        Form {
            munkiEndpointFields
            munkiAuthPicker
            if settings.munkiRepoAuthMode == "s3" || settings.munkiRepoAuthMode == "both" {
                munkiS3Fields
            }
            if settings.munkiRepoAuthMode != "s3" {
                munkiBasicFields
            }
            munkiPreviewSection
            munkiStatusLine
            munkiTestResultLine

            HStack {
                Button {
                    Task { await runMunkiTest() }
                } label: {
                    if munkiTestRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(!settings.isMunkiRepoConfigured || munkiTestRunning)
                Spacer()
                Button {
                    showingMunkiBrowser = true
                } label: {
                    Label("Browse Repository…", systemImage: "cube.box")
                }
                .disabled(!settings.isMunkiRepoConfigured)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingMunkiBrowser) {
            MunkiBrowserView(store: settingsMunkiStore)
                .environmentObject(settings)
                .environment(hostStore)
                .environment(packagePicker)
        }
    }

    @ViewBuilder
    private var munkiEndpointFields: some View {
        TextField("Endpoint host",
                  text: $settings.munkiRepoEndpoint,
                  prompt: Text(verbatim: "munki.example.com"))
            .help("Hostname only — no scheme, no path. For Wasabi with a custom CNAME, this is your domain. For raw Wasabi, it's s3.<region>.wasabisys.com.")
        TextField("Bucket (optional if endpoint IS the bucket)",
                  text: $settings.munkiRepoBucket,
                  prompt: Text(verbatim: "my-munki-bucket"))
            .help("Leave blank when the endpoint already points at the bucket. For raw Wasabi/AWS S3 endpoints, put the bucket here.")
        TextField("Repo prefix (path inside bucket)",
                  text: $settings.munkiRepoPrefix,
                  prompt: Text(verbatim: "munki_repo"))
            .help("Folder inside the bucket where the Munki repo lives. Leave blank if catalogs/, pkgs/, pkgsinfo/ sit at the bucket root.")
    }

    private var munkiAuthPicker: some View {
        Picker("Auth mode", selection: $settings.munkiRepoAuthMode) {
            Text("S3 SigV4 (Wasabi / AWS / R2 / B2 / Spaces)").tag("s3")
            Text("None (plain HTTPS web server)").tag("none")
            Text("HTTP Basic Auth (proxy / Cloudflare Worker)").tag("basic")
            Text("Both (Basic + SigV4 passthrough)").tag("both")
        }
        .help("S3 SigV4 — direct to any S3-compatible storage. None — Apache/nginx/Caddy serving the repo over plain HTTPS. Basic — Cloudflare Worker or nginx with HTTP Basic Auth in front. Both — passthrough proxy that needs Basic AND forwards SigV4.")
        .onChange(of: settings.munkiRepoAuthMode) { _, _ in munkiTestResult = nil }
    }

    @ViewBuilder
    private var munkiS3Fields: some View {
        // SwiftUI.Section qualified — our `Section` enum (for the
        // settings sidebar) would otherwise shadow it inside this body.
        Picker("Region", selection: $settings.munkiRepoRegion) {
            SwiftUI.Section("Wasabi") {
                Text("us-east-1 (Virginia)").tag("us-east-1")
                Text("us-east-2 (Virginia)").tag("us-east-2")
                Text("us-central-1 (Texas)").tag("us-central-1")
                Text("us-west-1 (Oregon)").tag("us-west-1")
                Text("ca-central-1 (Toronto)").tag("ca-central-1")
                Text("eu-central-1 (Amsterdam)").tag("eu-central-1")
                Text("eu-central-2 (Frankfurt)").tag("eu-central-2")
                Text("eu-west-1 (London)").tag("eu-west-1")
                Text("eu-west-2 (Paris)").tag("eu-west-2")
                Text("ap-northeast-1 (Tokyo)").tag("ap-northeast-1")
                Text("ap-southeast-1 (Singapore)").tag("ap-southeast-1")
                Text("ap-southeast-2 (Sydney)").tag("ap-southeast-2")
            }
            SwiftUI.Section("AWS S3") {
                Text("us-west-2 (Oregon)").tag("us-west-2")
                Text("eu-north-1 (Stockholm)").tag("eu-north-1")
                Text("ap-south-1 (Mumbai)").tag("ap-south-1")
            }
            SwiftUI.Section("Other S3-compatible") {
                Text("auto (Cloudflare R2)").tag("auto")
                Text("us-west-000 (Backblaze B2)").tag("us-west-000")
                Text("nyc3 (DigitalOcean Spaces)").tag("nyc3")
                Text("sfo3 (DigitalOcean Spaces)").tag("sfo3")
            }
        }
        .help("Region used in the SigV4 credential scope. Wrong region = SignatureDoesNotMatch. For Cloudflare R2 use 'auto'.")
        TextField("Access key", text: $settings.munkiRepoAccessKey,
                  prompt: Text(verbatim: "AKIA… / WASABI key / R2 token"))
        SecureField("Secret key", text: $settings.munkiRepoSecretKey)
            .onChange(of: settings.munkiRepoSecretKey) { _, _ in
                settings.saveMunkiSecretToKeychain()
            }
            .help("Stored in macOS Keychain — never written to disk in plain text.")
    }

    @ViewBuilder
    private var munkiBasicFields: some View {
        TextField("Basic Auth username", text: $settings.munkiRepoBasicUser,
                  prompt: Text(verbatim: "munki"))
            .help("HTTP Basic Auth user, configured at your Cloudflare Worker / nginx / Caddy layer in front of Wasabi.")
        SecureField("Basic Auth password", text: $settings.munkiRepoBasicPassword)
            .onChange(of: settings.munkiRepoBasicPassword) { _, _ in
                settings.saveMunkiBasicPasswordToKeychain()
            }
            .help("Stored in macOS Keychain.")
    }

    private var munkiPreviewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Will fetch:")
                .font(.caption).foregroundStyle(.secondary)
            Text(munkiCatalogPreviewURL)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(6)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3)))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var munkiStatusLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: settings.isMunkiRepoConfigured
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(settings.isMunkiRepoConfigured ? .green : .orange)
                Text(settings.isMunkiRepoConfigured
                     ? "Credentials present. Right-click a host → Browse Munki Repo… opens the picker."
                     : "Fill in the fields for your selected auth mode to enable the Munki browser.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Show Munki Repo group in sidebar",
                   isOn: Binding(
                    get: { !settings.sidebarMunkiHidden },
                    set: { settings.sidebarMunkiHidden = !$0 }
                   ))
                .help("Removes the Munki Repo entry from the left sidebar. The repo browser and the Munki tab in the Install Package picker still work — this is sidebar visibility only.")
        }
    }

    @ViewBuilder
    private var munkiTestResultLine: some View {
        if let result = munkiTestResult {
            switch result {
            case .success(let count):
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Connection OK — fetched catalogs/all (\(count) package\(count == 1 ? "" : "s")).")
                        .font(.caption)
                }
            case .failure(let msg):
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(msg)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Live preview of the catalogs/all URL the fetcher will hit, built
    /// from the currently-typed Settings fields. Helps the user spot
    /// typos in Endpoint / Bucket / Prefix at a glance instead of after
    /// a round-trip through the test button.
    private var munkiCatalogPreviewURL: String {
        guard !settings.munkiRepoEndpoint.isEmpty else { return "(endpoint required)" }
        return MunkiRepoStore.catalogURL(
            endpoint: settings.munkiRepoEndpoint,
            bucket: settings.munkiRepoBucket,
            prefix: settings.munkiRepoPrefix,
            key: "catalogs/all"
        )
    }

    /// One-shot fetch of catalogs/all so the user can verify creds without
    /// opening the full browser sheet.
    private func runMunkiTest() async {
        munkiTestRunning = true
        defer { munkiTestRunning = false }
        let store = MunkiRepoStore()
        do {
            let data = try await store.fetch(key: "catalogs/all", settings: settings)
            let pkgs = try MunkiRepoStore.parse(data: data)
            munkiTestResult = .success(packageCount: pkgs.count)
        } catch {
            munkiTestResult = .failure(error.localizedDescription)
        }
    }

    private var quickActionsPane: some View {
        QuickActionsSettingsPane()
    }

    private var munkiReportPane: some View {
        Form {
            TextField("MunkiReport server URL",
                      text: $settings.munkiReportURL,
                      prompt: Text(verbatim: "https://munkireport.example.com"))
                .help("Root URL of your MunkiReport server (no trailing slash). Used both for the per-host browser link and as the base for the blueconnect_api.php JSON endpoint.")
            SecureField("API token", text: $settings.munkiReportAPIToken)
                .onChange(of: settings.munkiReportAPIToken) { _, _ in
                    settings.saveMunkiReportTokenToKeychain()
                    munkiReportTestResult = nil
                }
                .help("Bearer token for blueconnect_api.php. Must match the BLUECONNECT_API_TOKEN env var on the MR container.")
            TextField("API path",
                      text: $settings.munkiReportAPIPath,
                      prompt: Text(verbatim: "blueconnect_api.php"))
                .onChange(of: settings.munkiReportAPIPath) { _, _ in munkiReportTestResult = nil }
                .help("Path appended to the server URL to reach the PHP endpoint. Default works when the file is at the MR webroot. Use `custom/blueconnect_api.php` when the file lives under MR's bind-mounted custom/ directory.")

            VStack(alignment: .leading, spacing: 6) {
                Text("How to set up the API")
                    .font(.caption).bold().foregroundStyle(.secondary)
                Text("""
                    1. Copy server/munkireport-module/blueconnect_api.php from this project into the MR container's public/ directory.
                    2. Add BLUECONNECT_API_TOKEN=<random 32+ chars> to the MR container's env file and restart it.
                    3. Paste the same token into the field above. Click Test Connection.
                    """)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    Task { await runMunkiReportTest() }
                } label: {
                    if munkiReportTestRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(!settings.isMunkiReportAPIConfigured || munkiReportTestRunning)
                Spacer()
            }

            if let result = munkiReportTestResult {
                switch result {
                case .success:
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text("API reachable — token accepted, DB query succeeded.")
                            .font(.caption)
                    }
                case .failure(let msg):
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        Text(msg).font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("Without the API token, this section is link-out only: right-click a host → Software Inventory → Open in MunkiReport launches the browser.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }

    @State private var munkiReportTestRunning: Bool = false
    @State private var munkiReportTestResult: MunkiReportTestResult? = nil
    private enum MunkiReportTestResult: Equatable {
        case success
        case failure(String)
    }

    private func runMunkiReportTest() async {
        munkiReportTestRunning = true
        defer { munkiReportTestRunning = false }
        let client = MunkiReportClient()
        do {
            try await client.ping(settings: settings)
            munkiReportTestResult = .success
        } catch {
            munkiReportTestResult = .failure(error.localizedDescription)
        }
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
                    openURL(URL(string: "https://hub.docker.com/r/sphen/bluesky/tags")!)
                } label: {
                    Label("sphen/bluesky tags ↗", systemImage: "arrow.up.right.square")
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
