import SwiftUI

/// Per-peer SSH / VNC port override sheet for a single Tailscale peer.
/// Opened via the right-click context menu on a Tailscale row. Empty
/// fields fall back to the global defaults in Settings.
struct TailscalePortSheet: View {
    let peerName: String
    @EnvironmentObject private var settings: SettingsStore
    @Environment(TailscaleBrowser.self) private var tailscale
    @Environment(\.dismiss) private var dismiss

    @State private var userText: String = ""
    @State private var sshText: String = ""
    @State private var vncText: String = ""

    private var defaultUserPlaceholder: String {
        settings.tailscaleDefaultUser.isEmpty
            ? settings.defaultRemoteUser
            : settings.tailscaleDefaultUser
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Custom Connection").font(.headline)
                Text("Override the user and ports for **\(peerName)**.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                userRow(label: "User",
                        text: $userText,
                        placeholder: defaultUserPlaceholder)
                portRow(label: "SSH port",
                        text: $sshText,
                        placeholder: settings.tailscaleSSHPort)
                portRow(label: "VNC port",
                        text: $vncText,
                        placeholder: settings.tailscaleVNCPort)
            }

            Text("Leave a field blank to use the global default. Defaults are configured in Settings → Tailscale Defaults.")
                .font(.caption2).foregroundStyle(.secondary)

            HStack {
                Button("Reset to Defaults", role: .destructive) {
                    var current = settings.tailscalePortOverrides
                    current.removeValue(forKey: peerName)
                    settings.tailscalePortOverrides = current
                    tailscale.refreshPorts()
                    dismiss()
                }
                .disabled(settings.tailscalePortOverrides[peerName] == nil)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            let existing = settings.tailscalePortOverrides[peerName]
            sshText = existing?.ssh.map(String.init) ?? ""
            vncText = existing?.vnc.map(String.init) ?? ""
        }
    }

    private func portRow(label: String, text: Binding<String>, placeholder: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", text: text, prompt: Text(verbatim: String(placeholder)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .multilineTextAlignment(.trailing)
        }
    }

    private func userRow(label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", text: text, prompt: Text(verbatim: placeholder))
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .multilineTextAlignment(.trailing)
        }
    }

    private func save() {
        var current = settings.tailscalePortOverrides
        let trimmedUser = userText.trimmingCharacters(in: .whitespaces)
        let ssh = Int(sshText.trimmingCharacters(in: .whitespaces))
        let vnc = Int(vncText.trimmingCharacters(in: .whitespaces))
        // Only persist values that differ from the resolved defaults — no-ops
        // just clutter the JSON.
        let resolvedSSH = (ssh == settings.tailscaleSSHPort) ? nil : ssh
        let resolvedVNC = (vnc == settings.tailscaleVNCPort) ? nil : vnc
        let resolvedUser = (trimmedUser.isEmpty
                            || trimmedUser == defaultUserPlaceholder) ? nil : trimmedUser
        if resolvedSSH == nil && resolvedVNC == nil && resolvedUser == nil {
            current.removeValue(forKey: peerName)
        } else {
            current[peerName] = PortOverride(ssh: resolvedSSH,
                                             vnc: resolvedVNC,
                                             user: resolvedUser)
        }
        settings.tailscalePortOverrides = current
        tailscale.refreshPorts()
        dismiss()
    }
}
