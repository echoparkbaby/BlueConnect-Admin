import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var auth: AuthGate
    @Environment(BlueSkyHostListStore.self) var hostStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

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
    }
}

private extension String {
    func nilIfEmpty() -> String? { isEmpty ? nil : self }
}
