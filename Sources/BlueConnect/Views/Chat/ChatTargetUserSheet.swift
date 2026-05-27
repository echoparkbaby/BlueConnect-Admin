import SwiftUI

/// Quick sheet that runs `users` over SSH on the host and lets the
/// admin pick which logged-in Mac user the chat-start job is
/// addressed to. Resolves the "I'm logged in as jennifer AND ladmin,
/// which one gets the message?" problem by letting the operator pick
/// instead of relying on whichever helper-agent happened to grab the
/// job first.
struct ChatTargetUserSheet: View {
    let host: BlueSkyHost
    let onStart: (String) -> Void

    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [String] = []
    @State private var selected: String = ""
    @State private var loading: Bool = true
    @State private var loadError: String?
    /// Free-text fallback when the discovered list is empty or the
    /// operator wants to address a user not currently logged in.
    @State private var custom: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 380)
        .padding(16)
        .task { await loadUsers() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Open Chat with…").font(.headline)
            Text("on \(host.displayName)").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Detecting logged-in users…").font(.caption)
            }
        } else if let err = loadError {
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't detect users: \(err)")
                    .font(.caption).foregroundStyle(.orange)
                Text("You can still type a username below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if candidates.isEmpty {
            Text("No users found via `users` — type a name below.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Currently logged in:")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(candidates, id: \.self) { user in
                    Button {
                        selected = user
                        custom = ""
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: selected == user
                                  ? "largecircle.fill.circle"
                                  : "circle")
                                .foregroundStyle(selected == user
                                                 ? AnyShapeStyle(Color.accentColor)
                                                 : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                            Text(user).monospaced()
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Other (type a username):")
                .font(.caption).foregroundStyle(.secondary)
            TextField("e.g. jennifer", text: $custom)
                .textFieldStyle(.roundedBorder)
                .onChange(of: custom) { _, v in
                    if !v.isEmpty { selected = "" }
                }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Start Chat") {
                let user = custom.trimmingCharacters(in: .whitespaces).isEmpty
                    ? selected
                    : custom.trimmingCharacters(in: .whitespaces)
                guard !user.isEmpty else { return }
                onStart(user)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty && custom.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// Run `users` over SSH to enumerate logged-in accounts. Returns
    /// deduplicated, sorted shortnames. Best-effort: failures are
    /// surfaced but don't block the operator from typing a name.
    @MainActor
    private func loadUsers() async {
        let cmd = "users | tr ' ' '\\n' | sort -u"
        let result = await Self.captureShell(cmd, host: host, settings: settings)
        loading = false
        if result.status == 0 {
            candidates = result.stdout
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "root" }
            // Auto-pick if there's exactly one — saves a click.
            if candidates.count == 1, selected.isEmpty { selected = candidates[0] }
        } else {
            loadError = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").first.map(String.init) ?? "ssh exit \(result.status)"
        }
    }

    private struct ShellResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// One-shot SSH capture using the same ProxyCommand pattern as
    /// ChatService — kept inline (no shared utility) because the
    /// surface area is small and the sheet is short-lived.
    private static func captureShell(_ command: String,
                                     host: BlueSkyHost,
                                     settings: SettingsStore) async -> ShellResult {
        guard host.active else {
            return ShellResult(status: -1, stdout: "", stderr: "host not active")
        }
        let proxy = "ssh -o WarnWeakCrypto=no -p \(settings.sshTunnelPort) -i \(settings.expandedKeyPath) admin@\(settings.serverFqdn) /bin/nc %h %p"
        let args = [
            "-T",
            "-o", "StrictHostKeyChecking=no",
            "-o", "WarnWeakCrypto=no",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ProxyCommand=\(proxy)",
            "-p", "\(host.sshPort)",
            "\(settings.defaultRemoteUser)@localhost",
            command
        ]
        return await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.launchPath = "/usr/bin/ssh"
            proc.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            do { try proc.run() } catch {
                return ShellResult(status: -2, stdout: "", stderr: "\(error)")
            }
            proc.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            return ShellResult(
                status: proc.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        }.value
    }
}
