import SwiftUI

/// Settings → UniFi. Read-only integration API key for the home/SOHO
/// UniFi Network Application. When configured, the network scanner
/// enriches each scanned IP with the UniFi client's friendly name,
/// MAC address, link speed, and wired/wireless flag — info the bare
/// TCP probe + mDNS can't get.
///
/// The key is generated in the UniFi Network Application:
///   Settings → Control Plane → Integrations → Create API Key
/// "Read-only" scope is sufficient.
struct UniFiSettingsPane: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var testing: Bool = false
    @State private var testResult: TestResult?

    private enum TestResult: Equatable {
        case success(siteCount: Int, clientCount: Int)
        case failure(String)
    }

    var body: some View {
        Form {
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

            Section("UniFi controller") {
                Text("When configured, the network scanner enriches each scanned IP with UniFi's hostname, MAC, link speed, and Wi-Fi vs Wired flag. UniFi-known DHCP clients that don't respond to TCP probes (gaming rigs, printers, Hue bridge, etc.) also get included in the result table.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Controller URL", text: $settings.unifiBaseURL,
                          prompt: Text(verbatim: "https://10.0.0.1"))
                    .help("Base URL of your UniFi Network Application — typically the IP or hostname of your UDM/Cloud Key/host. Self-signed certs are accepted.")
                SecureField("API Key", text: $settings.unifiAPIKey)
                    .onChange(of: settings.unifiAPIKey) { _, _ in
                        settings.saveUnifiAPIKeyToKeychain()
                        testResult = nil
                    }
                    .help("Generated in UniFi: Settings → Control Plane → Integrations → API → Create API Key. The Integration API is read-only by design — there's no scope/role to pick.")
                TextField("Site", text: $settings.unifiSite,
                          prompt: Text(verbatim: "default"))
                    .help("Site internalReference. Default UniFi installs have one site named 'default'.")

                HStack {
                    Button {
                        Task { await runTest() }
                    } label: {
                        if testing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    }
                    .disabled(!settings.isUnifiConfigured || testing)
                    Spacer()
                }

                if let result = testResult {
                    switch result {
                    case .success(let sites, let clients):
                        Label("Connected: \(sites) site\(sites == 1 ? "" : "s"), \(clients) clients on '\(settings.unifiSite)'",
                              systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    case .failure(let msg):
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("How to set up the API key")
                        .font(.caption).bold().foregroundStyle(.secondary)
                    Text("""
                        1. In the UniFi Network Application, open Settings → Control Plane → Integrations → API.
                        2. Click Create API Key. Copy the token (UniFi only shows it once).
                        3. Paste the token above. Click Test Connection.
                        4. Once green, the Network Scan results inherit hostname, MAC, link speed, and Wi-Fi vs Wired from UniFi automatically.

                        The Integration API is GET-only — only read endpoints exist. There's no scope/role to pick when creating the key.
                        """)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    @MainActor
    private func runTest() async {
        testing = true
        testResult = nil
        defer { testing = false }
        let client = UniFiClient(
            baseURL: settings.unifiBaseURL,
            apiKey: settings.unifiAPIKey
        )
        do {
            // Hit /sites first as an auth+URL sanity check, then
            // the legacy `/stat/sta` endpoint via the site name —
            // matches what the scanner does at runtime, so what
            // Test Connection says agrees with what the scan will
            // experience.
            let sites = try await client.sites()
            let siteName = settings.unifiSite.trimmingCharacters(in: .whitespaces).isEmpty
                ? "default"
                : settings.unifiSite
            let clients = try await client.clients(siteName: siteName)
            testResult = .success(siteCount: sites.count, clientCount: clients.count)
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }
}
