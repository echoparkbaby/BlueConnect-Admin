import SwiftUI

/// Sheet that runs `munkireport-runner` on the inventory's host. The
/// password is collected here (per the operator's "no NOPASSWD"
/// preference) and forwarded to `sudo -S` via stdin — never cached
/// to Keychain, never written to defaults, and cleared on dismiss.
///
/// Lifecycle is per-sheet-instance: a `@State` on `Phase` drives the
/// spinner and Cancel/Done labels; an `@State` log buffer feeds the
/// expandable DisclosureGroup. No outer controller because the user
/// asked for single-host (no cross-window state to share).
struct MunkiReportRunnerSheet: View {
    let host: BlueSkyHost
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var password: String = ""
    @State private var phase: Phase = .needsPassword
    @State private var log: String = ""
    @State private var showLog: Bool = false
    /// The currently running `ssh` Process. Held so Cancel can SIGTERM it.
    @State private var process: Process? = nil

    private enum Phase: Equatable {
        case needsPassword       // sheet just appeared
        case running             // ssh+sudo in flight
        case success             // exit 0
        case failure(String)     // non-zero or spawn error
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 380)
        .onDisappear {
            // Belt-and-suspenders: kill any in-flight ssh and zero the
            // password buffer so an attacker with a memory dump after
            // the sheet closes finds nothing.
            process?.terminate()
            password = ""
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.rectangle.fill")
                .font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Run MunkiReport Runner").font(.headline)
                Text("\(host.displayName) · \(remoteUser)@\(host.displayName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusRow
            if phase == .needsPassword {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Admin password for \(remoteUser)@\(host.displayName)")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { runIfReady() }
                    Text("Used once for `sudo -S` and discarded — not saved to Keychain.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            DisclosureGroup(isExpanded: $showLog) {
                logView
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.caption)
                    Text("Show log")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            switch phase {
            case .needsPassword:
                Image(systemName: "key")
                    .foregroundStyle(.secondary)
                Text("Ready — enter password and click Run.")
                    .font(.callout).foregroundStyle(.secondary)
            case .running:
                ProgressView().controlSize(.small)
                Text("Running on \(host.displayName)…")
                    .font(.callout)
            case .success:
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Done. Runner exited cleanly.")
                    .font(.callout).foregroundStyle(.green)
            case .failure(let msg):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(msg).font(.callout).foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(log.isEmpty ? "No output yet." : log)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("logTail")
            }
            .frame(height: 160)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.2)))
            .onChange(of: log) { _, _ in
                // Stick to the bottom as new lines arrive — same UX
                // as `tail -f` in a Terminal.
                proxy.scrollTo("logTail", anchor: .bottom)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            if phase == .running {
                Button("Cancel", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run") { runIfReady() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - Run

    private var remoteUser: String {
        let trimmed = settings.defaultRemoteUser.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "ladmin" : trimmed
    }

    private func runIfReady() {
        guard phase != .running, !password.isEmpty else { return }
        phase = .running
        log = ""
        showLog = true
        let pw = password
        Task.detached(priority: .userInitiated) {
            await runRunner(password: pw)
        }
    }

    private func cancel() {
        process?.terminate()
    }

    /// Spawn `ssh -T` to the BSC-tunneled host, run the runner under
    /// `sudo -S`, pipe the password through stdin. -T (not -t) keeps
    /// stdin pure so sudo's stdin password read works cleanly without
    /// a remote PTY echo getting in the way.
    private func runRunner(password pw: String) async {
        // Snapshot every settings value we need before hopping off the
        // main actor — SettingsStore isn't Sendable.
        let server  = await MainActor.run { settings.serverFqdn }
        let keyPath = await MainActor.run { settings.expandedKeyPath }
        let sshPort = await MainActor.run { settings.sshTunnelPort }
        let user    = await MainActor.run { remoteUser }
        let hostPort = host.sshPort

        let proxy = "ProxyCommand=ssh -o WarnWeakCrypto=no -p \(sshPort) -i \(keyPath) admin@\(server) /bin/nc %h %p"
        // The remote command:
        //   1. Verify the runner script exists & is executable.
        //   2. Run it under sudo -S (password from stdin) with -p '' so
        //      no prompt string is echoed into the log.
        //   3. Merge stderr into stdout so a single readabilityHandler
        //      catches everything.
        let remote = """
        if [ -x /usr/local/munkireport/munkireport-runner ]; then \
          sudo -S -p '' /usr/local/munkireport/munkireport-runner 2>&1; \
        else \
          echo "munkireport-runner not found at /usr/local/munkireport/munkireport-runner — is MunkiReport installed?"; exit 1; \
        fi
        """

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = [
            "-T",
            "-o", proxy,
            "-o", "StrictHostKeyChecking=no",
            "-o", "WarnWeakCrypto=no",
            "-o", "BatchMode=no",
            "-p", "\(hostPort)",
            "\(user)@localhost",
            remote,
        ]
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput  = inPipe
        p.standardOutput = outPipe
        p.standardError  = outPipe

        outPipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty,
                  let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                appendToLog(chunk)
            }
        }

        await MainActor.run { process = p }
        do {
            try p.run()
        } catch {
            await MainActor.run {
                process = nil
                phase = .failure("ssh spawn failed: \(error.localizedDescription)")
            }
            return
        }

        // Push password + newline to sudo, then close stdin so the
        // remote command isn't waiting for more input.
        if let data = (pw + "\n").data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        try? inPipe.fileHandleForWriting.close()

        p.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        let exit = p.terminationStatus
        await MainActor.run {
            process = nil
            if exit == 0 {
                phase = .success
            } else {
                let tail = log.split(separator: "\n").suffix(2).joined(separator: " · ")
                phase = .failure("Runner exited \(exit). \(tail)")
            }
        }
    }

    @MainActor
    private func appendToLog(_ chunk: String) {
        log.append(chunk)
        // Cap to ~16 KB so a chatty runner can't make the sheet eat
        // memory; keep the tail.
        if log.count > 16_384 {
            log = String(log.suffix(12_288))
        }
    }
}
