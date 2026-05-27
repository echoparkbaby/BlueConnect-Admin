import SwiftUI

/// Settings → Munki Repo. Endpoint/bucket/prefix fields, auth-mode picker
/// (S3 SigV4, plain HTTPS, HTTP Basic, or both), per-mode credential
/// fields (Keychain-backed secrets), live catalogs/all URL preview, a
/// Test Connection action, and the Browse Repository sheet entry point.
///
/// Extracted from `SettingsView.swift` so SettingsView stays under 600
/// lines — this pane alone is ~200. Pattern matches the rest of the
/// `Views/Settings/` panes.
struct MunkiRepoSettingsPane: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(BlueSkyHostListStore.self) private var hostStore
    @Environment(PackagePickerController.self) private var packagePicker

    @State private var showingBrowser: Bool = false
    @State private var browserStore = MunkiRepoStore()
    @State private var testRunning: Bool = false
    @State private var testResult: TestResult? = nil

    private enum TestResult: Equatable {
        case success(packageCount: Int)
        case failure(String)
    }

    var body: some View {
        Form {
            endpointFields
            authPicker
            if settings.munkiRepoAuthMode == "s3" || settings.munkiRepoAuthMode == "both" {
                s3Fields
            }
            if settings.munkiRepoAuthMode != "s3" {
                basicFields
            }
            previewSection
            statusLine
            testResultLine

            HStack {
                Button {
                    Task { await runTest() }
                } label: {
                    if testRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(!settings.isMunkiRepoConfigured || testRunning)
                Spacer()
                Button {
                    showingBrowser = true
                } label: {
                    Label("Browse Repository…", systemImage: "cube.box")
                }
                .disabled(!settings.isMunkiRepoConfigured)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingBrowser) {
            MunkiBrowserView(store: browserStore)
                .environmentObject(settings)
                .environment(hostStore)
                .environment(packagePicker)
        }
    }

    @ViewBuilder
    private var endpointFields: some View {
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

    private var authPicker: some View {
        Picker("Auth mode", selection: $settings.munkiRepoAuthMode) {
            Text("S3 SigV4 (Wasabi / AWS / R2 / B2 / Spaces)").tag("s3")
            Text("None (plain HTTPS web server)").tag("none")
            Text("HTTP Basic Auth (proxy / Cloudflare Worker)").tag("basic")
            Text("Both (Basic + SigV4 passthrough)").tag("both")
        }
        .help("S3 SigV4 — direct to any S3-compatible storage. None — Apache/nginx/Caddy serving the repo over plain HTTPS. Basic — Cloudflare Worker or nginx with HTTP Basic Auth in front. Both — passthrough proxy that needs Basic AND forwards SigV4.")
        .onChange(of: settings.munkiRepoAuthMode) { _, _ in testResult = nil }
    }

    @ViewBuilder
    private var s3Fields: some View {
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
    private var basicFields: some View {
        TextField("Basic Auth username", text: $settings.munkiRepoBasicUser,
                  prompt: Text(verbatim: "munki"))
            .help("HTTP Basic Auth user, configured at your Cloudflare Worker / nginx / Caddy layer in front of Wasabi.")
        SecureField("Basic Auth password", text: $settings.munkiRepoBasicPassword)
            .onChange(of: settings.munkiRepoBasicPassword) { _, _ in
                settings.saveMunkiBasicPasswordToKeychain()
            }
            .help("Stored in macOS Keychain.")
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Will fetch:")
                .font(.caption).foregroundStyle(.secondary)
            Text(catalogPreviewURL)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(6)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3)))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusLine: some View {
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
    private var testResultLine: some View {
        if let result = testResult {
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
    private var catalogPreviewURL: String {
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
    @MainActor
    private func runTest() async {
        testRunning = true
        defer { testRunning = false }
        let store = MunkiRepoStore()
        do {
            let data = try await store.fetch(key: "catalogs/all", settings: settings)
            let pkgs = try MunkiRepoStore.parse(data: data)
            testResult = .success(packageCount: pkgs.count)
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }
}
