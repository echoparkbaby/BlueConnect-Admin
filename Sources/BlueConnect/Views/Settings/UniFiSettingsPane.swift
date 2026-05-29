import SwiftUI

/// Settings → UniFi. Manage one or more UniFi controller profiles
/// (one per site/customer/network you VPN into). Each profile has
/// its own base URL, site name, and API key. The picker in the
/// Network Scan window picks which profile is currently active for
/// scan enrichment.
///
/// The integration API key is generated in the UniFi Network
/// Application: Settings → Control Plane → Integrations → API →
/// Create API Key. Read-only is sufficient.
struct UniFiSettingsPane: View {
    @EnvironmentObject private var settings: SettingsStore

    /// Profile currently being edited. Defaults to the active one
    /// on first appearance; resets if the underlying profile gets
    /// deleted out from under us.
    @State private var editingID: UUID?
    @State private var testing: Bool = false
    @State private var testResult: TestResult?
    /// In-memory mirror of the editing profile's API key. We don't
    /// store secrets in `@AppStorage`, so the field is bound to this
    /// `@State` and flushed to Keychain via `onChange`.
    @State private var apiKeyBuffer: String = ""

    private enum TestResult: Equatable {
        case success(siteCount: Int, clientCount: Int, profileLabel: String)
        case failure(String, profileLabel: String)
    }

    var body: some View {
        Form {
            scanSection
            unifiSection
        }
        .formStyle(.grouped)
        .onAppear { syncEditingState() }
        .onChange(of: settings.unifiProfiles) { _, _ in syncEditingState() }
    }

    // MARK: - Sections

    private var scanSection: some View {
        Section("Scan") {
            // Multi-line TextEditor — the previous TextField
            // capped visible content at ~5 IPs and clipped the
            // rest. CIDR-per-line is more readable than the
            // comma-joined single line too.
            Text("Subnets to probe")
                .font(.subheadline).bold().foregroundStyle(.secondary)
            Text("One CIDR per line (or comma-separated). The scanner probes TCP 22 and 5900 on every IP in these ranges. /16 is the smallest accepted prefix.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $settings.scanSubnets)
                .font(.body.monospaced())
                .frame(minHeight: 90, idealHeight: 120, maxHeight: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private var unifiSection: some View {
        Section("UniFi controllers") {
            Text("Each profile points at one UniFi Network Application. Add a profile per controller you reach (home UDM, a customer's UDM-Pro when VPN'd into their network, etc.). The Network Scan window picks the active profile so scan results match the controller behind your current network.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            profilePicker

            if let profile = currentProfile {
                editor(for: profile)
            } else {
                emptyState
            }

            setupInstructions
        }
    }

    // MARK: - Picker row

    private var profilePicker: some View {
        HStack(spacing: 8) {
            Picker("Profile", selection: pickerSelection) {
                ForEach(settings.unifiProfiles) { p in
                    Text(profileMenuTitle(p)).tag(Optional(p.id))
                }
                if settings.unifiProfiles.isEmpty {
                    Text("No profiles").tag(Optional<UUID>.none)
                }
            }
            .labelsHidden()
            Button {
                addProfile()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add a new UniFi controller profile")
            Button {
                duplicateProfile()
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .disabled(currentProfile == nil)
            .help("Copy the current profile (URL + site, not the API key)")
            Button(role: .destructive) {
                deleteCurrentProfile()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(currentProfile == nil)
            .help("Remove this profile and its stored API key")
        }
    }

    private var pickerSelection: Binding<UUID?> {
        Binding(
            get: { editingID ?? settings.activeUnifiProfileID ?? settings.unifiProfiles.first?.id },
            set: { newValue in
                editingID = newValue
                reloadAPIKeyBuffer()
                testResult = nil
            }
        )
    }

    private func profileMenuTitle(_ p: UniFiProfile) -> String {
        let active = settings.activeUnifiProfile?.id == p.id
        return active ? "\(p.label) (Active)" : p.label
    }

    // MARK: - Editor

    @ViewBuilder
    private func editor(for profile: UniFiProfile) -> some View {
        Group {
            TextField("Label", text: binding(\.label, for: profile.id),
                      prompt: Text("Home UDM"))
                .help("Friendly name shown in the Network Scan switcher")
            TextField("Controller URL", text: binding(\.baseURL, for: profile.id),
                      prompt: Text(verbatim: "https://10.0.0.1"))
                .help("Base URL of the UniFi Network Application. Self-signed certs are accepted.")
            SecureField("API Key", text: $apiKeyBuffer)
                .onChange(of: apiKeyBuffer) { _, newValue in
                    settings.setUnifiAPIKey(newValue, for: profile)
                    testResult = nil
                }
                .help("Generated in UniFi: Settings → Control Plane → Integrations → API → Create API Key.")
            TextField("Site", text: binding(\.site, for: profile.id),
                      prompt: Text(verbatim: "default"))
                .help("Site short name (the segment used in `/api/s/<site>/…`). Most installs are `default`.")

            HStack {
                Button {
                    settings.activeUnifiProfileID = profile.id
                } label: {
                    if settings.activeUnifiProfile?.id == profile.id {
                        Label("Active", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Make Active", systemImage: "checkmark.seal")
                    }
                }
                .disabled(settings.activeUnifiProfile?.id == profile.id)
                .help("Use this profile for the next Network Scan")

                Spacer()

                Button {
                    Task { await runTest(profile: profile) }
                } label: {
                    if testing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(!settings.isConfigured(profile) || testing)
            }

            if let result = testResult {
                switch result {
                case .success(let sites, let clients, let label):
                    Label("\(label): connected — \(sites) site\(sites == 1 ? "" : "s"), \(clients) clients on '\(profile.resolvedSite)'",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                case .failure(let msg, let label):
                    Label("\(label): \(msg)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No UniFi profiles configured.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Click Add to create one — the Network Scan window enriches scanned IPs with whatever profile is active.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var setupInstructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How to set up an API key")
                .font(.caption).bold().foregroundStyle(.secondary)
            Text("""
                1. In the UniFi Network Application, open Settings → Control Plane → Integrations → API.
                2. Click Create API Key. Copy the token (UniFi only shows it once).
                3. Paste the token into the API Key field above. Click Test Connection.
                4. Once green, the Network Scan results inherit hostname, MAC, link speed, and Wi-Fi vs Wired from this controller.

                The Integration API is GET-only — only read endpoints exist. There's no scope/role to pick when creating the key.
                """)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - State plumbing

    /// Bind a WritableKeyPath into the currently-editing profile.
    /// Reads return the current value; writes mutate the array
    /// in-place so the @AppStorage JSON is rewritten exactly once
    /// per character (acceptable — the JSON is tiny).
    private func binding<T>(_ kp: WritableKeyPath<UniFiProfile, T>,
                            for id: UUID,
                            fallback: T? = nil) -> Binding<T> where T: Equatable {
        Binding(
            get: {
                let list = settings.unifiProfiles
                if let p = list.first(where: { $0.id == id }) { return p[keyPath: kp] }
                if let fb = fallback { return fb }
                fatalError("editing non-existent UniFi profile \(id)")
            },
            set: { newValue in
                var list = settings.unifiProfiles
                guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
                list[idx][keyPath: kp] = newValue
                settings.unifiProfiles = list
            }
        )
    }

    private var currentProfile: UniFiProfile? {
        let id = editingID ?? settings.activeUnifiProfileID ?? settings.unifiProfiles.first?.id
        guard let id else { return nil }
        return settings.unifiProfiles.first(where: { $0.id == id })
    }

    private func syncEditingState() {
        if editingID == nil || !settings.unifiProfiles.contains(where: { $0.id == editingID }) {
            editingID = settings.activeUnifiProfile?.id ?? settings.unifiProfiles.first?.id
        }
        reloadAPIKeyBuffer()
    }

    private func reloadAPIKeyBuffer() {
        if let p = currentProfile {
            apiKeyBuffer = settings.unifiAPIKey(for: p)
        } else {
            apiKeyBuffer = ""
        }
    }

    // MARK: - Actions

    private func addProfile() {
        var list = settings.unifiProfiles
        let label = nextProfileLabel(after: "New Profile", existing: list)
        let p = UniFiProfile(label: label)
        list.append(p)
        settings.unifiProfiles = list
        // First profile created → also make it active automatically
        // so the scan window has something to point at.
        if list.count == 1 { settings.activeUnifiProfileID = p.id }
        editingID = p.id
        reloadAPIKeyBuffer()
        testResult = nil
    }

    private func duplicateProfile() {
        guard let src = currentProfile else { return }
        var list = settings.unifiProfiles
        let copyLabel = nextProfileLabel(after: "\(src.label) Copy", existing: list)
        let copy = UniFiProfile(
            label: copyLabel,
            baseURL: src.baseURL,
            site: src.site
        )
        list.append(copy)
        settings.unifiProfiles = list
        // Deliberately do NOT copy the API key — it's a credential,
        // not a config detail, and the new profile probably points
        // at a different controller.
        editingID = copy.id
        reloadAPIKeyBuffer()
        testResult = nil
    }

    private func deleteCurrentProfile() {
        guard let target = currentProfile else { return }
        settings.deleteUnifiAPIKey(for: target)
        var list = settings.unifiProfiles
        list.removeAll { $0.id == target.id }
        settings.unifiProfiles = list
        if settings.activeUnifiProfileID == target.id {
            settings.activeUnifiProfileID = list.first?.id
        }
        editingID = list.first?.id
        reloadAPIKeyBuffer()
        testResult = nil
    }

    /// Avoid label collisions when the user keeps clicking Add or
    /// Duplicate. "New Profile" → "New Profile 2" → "New Profile 3".
    private func nextProfileLabel(after base: String,
                                  existing: [UniFiProfile]) -> String {
        let labels = Set(existing.map(\.label))
        if !labels.contains(base) { return base }
        var n = 2
        while labels.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    @MainActor
    private func runTest(profile: UniFiProfile) async {
        testing = true
        testResult = nil
        defer { testing = false }
        let client = UniFiClient(
            baseURL: profile.baseURL,
            apiKey: settings.unifiAPIKey(for: profile)
        )
        do {
            // Hit /sites first as an auth+URL sanity check, then
            // /stat/sta to confirm the configured site name actually
            // exists. Matches what the scanner does at runtime so
            // Test agrees with Scan.
            let sites = try await client.sites()
            let clients = try await client.clients(siteName: profile.resolvedSite)
            testResult = .success(siteCount: sites.count,
                                  clientCount: clients.count,
                                  profileLabel: profile.label)
        } catch {
            testResult = .failure(error.localizedDescription,
                                  profileLabel: profile.label)
        }
    }
}
