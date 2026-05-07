import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var auth: AuthGate
    @Environment(BlueSkyHostListStore.self) var hostStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    // Local string mirrors of the Tailscale port settings. We use a plain
    // String binding (not TextField(value:format:)) because IntegerFormatStyle
    // auto-applies locale grouping (2225 → "2,225") and on round-trip parses
    // the comma weirdly — landing the user on port 25.
    @State private var tailscaleSSHPortText: String = ""
    @State private var tailscaleVNCPortText: String = ""

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = info?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Server", value: settings.apiURL.isEmpty ? "—" : settings.apiURL)
                LabeledContent("Username", value: settings.apiUsername.isEmpty ? "—" : settings.apiUsername)
                HStack {
                    Spacer()
                    Button("Sign Out…") {
                        auth.logout(settings: settings)
                        dismiss()
                    }
                    .help("Forgets the saved credentials and returns to the login screen.")
                }
            }
            Section("Security") {
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
            Section("SSH Tunnel") {
                TextField("SSH host", text: $settings.serverFqdn)
                Stepper(value: $settings.sshTunnelPort, in: 22...65535) {
                    Text("SSH port: \(String(settings.sshTunnelPort))")
                }
            }
            Section("Defaults") {
                TextField("Admin SSH key path", text: $settings.adminKeyPath)
                TextField("Default remote user", text: $settings.defaultRemoteUser)
            }
            Section("Discovery") {
                Toggle("Show Local Network peers in sidebar", isOn: $settings.localNetworkEnabled)
                    .help("Discovers Macs on your LAN via Bonjour/mDNS (SSH + Screen Sharing). Disabling stops the browser entirely and silences the macOS Local Network prompt.")
                Toggle("Show Tailscale peers in sidebar", isOn: $settings.tailscaleEnabled)
                    .help("Lists online tailnet machines (macOS + Linux) under their own “Tailscale” section. Reads from the local `tailscale` CLI; off by default.")
            }
            Section("Tailscale Defaults") {
                TextField("Default user",
                          text: $settings.tailscaleDefaultUser,
                          prompt: Text(verbatim: settings.defaultRemoteUser))
                    .help("Remote user used for SSH/VNC/SCP to a Tailscale peer. Leave blank to fall back to the global Default remote user above. Per-peer overrides take precedence.")
                TextField("SSH port", text: $tailscaleSSHPortText)
                    .onChange(of: tailscaleSSHPortText) { _, _ in commitSSHPort() }
                    .help("Used when connecting via SSH to a Tailscale peer. Per-peer overrides (right-click a peer → Custom Connection…) take precedence.")
                TextField("VNC port", text: $tailscaleVNCPortText)
                    .onChange(of: tailscaleVNCPortText) { _, _ in commitVNCPort() }
                    .help("Used when connecting via Screen Sharing to a Tailscale peer. Per-peer overrides take precedence.")
            }
            Section("Notifications") {
                Toggle("Notify on host online/offline transitions", isOn: $settings.notifyOnStateChange)
            }
            Section("About") {
                LabeledContent("BlueConnect Admin", value: appVersion)
                LabeledContent("BlueSky Server", value: hostStore.lastResponse?.blueSkyVersion?.nilIfEmpty() ?? "—")
                LabeledContent("PHP", value: hostStore.lastResponse?.phpVersion ?? "—")
                LabeledContent("API", value: hostStore.lastResponse?.apiVersion ?? "—")
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
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
        .onAppear {
            tailscaleSSHPortText = String(settings.tailscaleSSHPort)
            tailscaleVNCPortText = String(settings.tailscaleVNCPort)
        }
    }

    private func commitSSHPort() {
        let trimmed = tailscaleSSHPortText.trimmingCharacters(in: .whitespaces)
        if let v = Int(trimmed), (1...65535).contains(v) {
            settings.tailscaleSSHPort = v
        }
        // Don't reset the text on every keystroke — the user may be partway
        // through typing. They'll see only digits get committed.
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
