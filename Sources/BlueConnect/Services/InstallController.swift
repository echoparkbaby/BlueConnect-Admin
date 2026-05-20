import Foundation

/// Owns the state of an in-flight ad-hoc package install on a single BSC
/// host. Drives the `InstallProgressWindow` UI: source file, target,
/// phase, status text, cancel.
///
/// Install is a single long-running bash pipeline. The bash script emits
/// `▶ phase=<name>` marker lines we parse to advance `phase`. Each phase
/// shows its own status text and an indeterminate progress bar; the bar
/// stops moving when the phase changes to `.succeeded` / `.failed` /
/// `.cancelled`. Sudo password (if non-empty) is piped via stdin to
/// `sudo -S` on the remote side, never appearing in argv or env'd into a
/// terminal where it could be scrolled back.
@MainActor
@Observable
final class InstallController {

    enum Phase: Equatable {
        case idle
        case downloading   // Munki: fetching from S3/HTTP to local /tmp before upload
        case compressing
        case uploading
        case mounting
        case installing
        case copying
        case detaching
        case cleaning
        case succeeded
        case failed(String)
        case cancelled

        var label: String {
            switch self {
            case .idle:        return "Ready"
            case .downloading: return "Downloading from Munki Repo…"
            case .compressing: return "Compressing .app into a disk image…"
            case .uploading:   return "Uploading to remote /tmp/…"
            case .mounting:    return "Mounting disk image on remote…"
            case .installing:  return "Running installer (sudo)…"
            case .copying:     return "Copying .app into /Applications…"
            case .detaching:   return "Detaching disk image…"
            case .cleaning:    return "Cleaning up /tmp/…"
            case .succeeded:   return "Installed."
            case .failed(let m): return "Failed: \(m)"
            case .cancelled:   return "Cancelled."
            }
        }

        var isTerminal: Bool {
            switch self {
            case .succeeded, .failed, .cancelled: return true
            default: return false
            }
        }

        var isRunning: Bool {
            self != .idle && !isTerminal
        }
    }

    /// How a `.app` bundle should be moved to the remote.
    enum AppMode: String, CaseIterable, Identifiable {
        case compress  // Local hdiutil + scp + remote mount/copy
        case raw       // scp -r the .app directly, sudo mv to /Applications
        var id: String { rawValue }
        var label: String {
            switch self {
            case .compress: return "Compress to DMG"
            case .raw:      return "Send Raw"
            }
        }
    }

    /// Ordered phases that make up an install run, derived from file type
    /// + AppMode. Drives the stepped-checklist progress UI in the install
    /// window. Note: this is intentionally a small subset of `Phase` —
    /// terminal states (`succeeded`, `failed`, `cancelled`) aren't steps.
    enum Step: Int, CaseIterable, Identifiable {
        case download, compress, upload, mount, install, copy, detach, clean
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .download: return "Download from Munki Repo"
            case .compress: return "Compress to DMG"
            case .upload:   return "Upload to remote /tmp"
            case .mount:    return "Mount disk image"
            case .install:  return "Run installer"
            case .copy:     return "Copy to /Applications"
            case .detach:   return "Detach disk image"
            case .clean:    return "Clean up"
            }
        }
        var matchingPhase: Phase {
            switch self {
            case .download: return .downloading
            case .compress: return .compressing
            case .upload:   return .uploading
            case .mount:    return .mounting
            case .install:  return .installing
            case .copy:     return .copying
            case .detach:   return .detaching
            case .clean:    return .cleaning
            }
        }
    }

    /// Where the install runs. BSC hosts route SSH/scp through the BSC
    /// gateway with a ProxyCommand; local-network hosts reach over the
    /// LAN directly with no proxy.
    struct DirectTarget: Equatable {
        let hostname: String
        let port: Int
        let remoteUser: String
        let displayName: String
    }

    var phase: Phase = .idle
    var sudoPassword: String = ""
    var trailingLogLine: String = ""
    var progressPercent: Int = 0       // 0…100; non-zero means we have real % progress
    var log: String = ""                // full stdout+stderr for the disclosed Log pane
    var appMode: AppMode = .compress    // only consulted when localFile is a .app
    var fileMetadata: PackageMetadata?  // extracted from the local .pkg / .app (async)
    /// True when this install was kicked off from the Munki Repo flow —
    /// causes a leading `.download` step to be prepended so the user sees
    /// fetching from S3 as part of the pipeline, not a silent gap.
    var isMunki: Bool = false
    /// What the file *will* be called once download finishes — lets the
    /// header show the package name immediately even before localFile is set.
    var pendingFileName: String = ""
    /// Populated by `prepareDirect(…)` when the install target is a
    /// Bonjour/Tailscale local-network host. When set, `makeScript`
    /// drops the BSC ProxyCommand and reaches the remote directly.
    private(set) var directTarget: DirectTarget?

    /// Step list for the current `localFile` + `appMode`. Used by the
    /// install window's stepped progress checklist.
    var steps: [Step] {
        let baseSteps: [Step]
        if let url = localFile {
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "pkg":
                baseSteps = [.upload, .install, .clean]
            case "dmg":
                baseSteps = [.upload, .mount, .install, .detach, .clean]
            case "app":
                baseSteps = appMode == .compress
                    ? [.compress, .upload, .mount, .copy, .detach, .clean]
                    : [.upload, .copy]
            default:
                baseSteps = []
            }
        } else if isMunki {
            // localFile not set yet — guess from the pending filename so the
            // step list isn't empty during the download phase.
            let ext = (pendingFileName as NSString).pathExtension.lowercased()
            switch ext {
            case "pkg":   baseSteps = [.upload, .install, .clean]
            case "dmg":   baseSteps = [.upload, .mount, .install, .detach, .clean]
            default:      baseSteps = [.upload, .install, .clean]
            }
        } else {
            return []
        }
        return isMunki ? [.download] + baseSteps : baseSteps
    }

    /// Where the package will land on the host, for display.
    var destinationDescription: String {
        guard let url = localFile else { return "" }
        let displayName: String
        if let host { displayName = host.displayName }
        else if let direct = directTarget { displayName = direct.displayName }
        else { return "" }
        let ext = url.pathExtension.lowercased()
        if ext == "app" {
            return "→ /Applications on \(displayName)"
        }
        return "→ \(displayName)"
    }

    /// Human-readable file size of `localFile` (recursive for .app bundles).
    var localFileSize: String {
        guard let url = localFile else { return "" }
        let bytes = recursiveSize(of: url)
        guard bytes > 0 else { return "" }
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useMB, .useGB, .useKB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }

    private func recursiveSize(of url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let type = attrs?[.type] as? FileAttributeType
        if type == .typeDirectory {
            var total: Int64 = 0
            if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let fileURL as URL in e {
                    let v = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
                    total += Int64(v?.fileSize ?? 0)
                }
            }
            return total
        }
        return Int64((attrs?[.size] as? Int) ?? 0)
    }

    private(set) var host: BlueSkyHost?
    private(set) var localFile: URL?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stdoutReader: Pipe?
    @ObservationIgnored private var lineBuffer: String = ""
    @ObservationIgnored private var errorTail: String = ""
    /// Closure that performs the Munki S3 download and returns the local
    /// path. Stored when `prepareMunkiPending` is called; consumed in
    /// `start()` after the user enters their password and clicks Install.
    /// Kept @ObservationIgnored — its identity isn't UI-relevant; the
    /// `isMunki` + `phase` fields already drive observation.
    @ObservationIgnored private var pendingDownload: (@MainActor () async throws -> URL)?

    var canStart: Bool {
        let hasTarget = host != nil || directTarget != nil
        guard hasTarget, (phase == .idle || phase.isTerminal) else { return false }
        // Local-file install needs the file already; Munki-pending only
        // needs the closure that will fetch it.
        return localFile != nil || (isMunki && pendingDownload != nil)
    }

    /// True when the install has produced no useful state yet — used to
    /// decide whether the window should auto-open into "fill the form"
    /// mode vs show stale results from a previous run.
    var isFresh: Bool { phase == .idle }

    func prepare(host: BlueSkyHost, localFile: URL, appMode: AppMode = .compress) {
        cancel()
        self.host = host
        self.directTarget = nil
        self.localFile = localFile
        self.appMode = appMode
        self.phase = .idle
        self.trailingLogLine = ""
        self.errorTail = ""
        self.lineBuffer = ""
        self.progressPercent = 0
        self.log = ""
        self.fileMetadata = nil
        self.isMunki = false
        self.pendingFileName = ""
        Task { [weak self] in
            let m = await PackageMetadata.read(from: localFile)
            await MainActor.run { self?.fileMetadata = m }
        }
    }

    /// Direct (no BSC tunnel) install — used by the Local Network sidebar
    /// rows. SSH/scp reaches the remote over the LAN directly. Same
    /// install pipeline shape as `prepare(host:…)`, just routed through
    /// `directTarget` instead of a BlueSkyHost.
    func prepareDirect(target: DirectTarget,
                       localFile: URL,
                       appMode: AppMode = .compress) {
        cancel()
        self.host = nil
        self.directTarget = target
        self.localFile = localFile
        self.appMode = appMode
        self.phase = .idle
        self.trailingLogLine = ""
        self.errorTail = ""
        self.lineBuffer = ""
        self.progressPercent = 0
        self.log = ""
        self.fileMetadata = nil
        self.isMunki = false
        self.pendingFileName = ""
        Task { [weak self] in
            let m = await PackageMetadata.read(from: localFile)
            await MainActor.run { self?.fileMetadata = m }
        }
    }

    /// Open the install window in `.idle` for a Munki install — the user
    /// fills in the sudo password and clicks Install, then `start()` runs
    /// the download FIRST (showing the `.download` step active) before
    /// the normal upload/install pipeline. Gathering creds before any
    /// network work matches the local-install flow and avoids the user
    /// wandering off mid-download.
    func prepareMunkiPending(host: BlueSkyHost,
                             expectedFileName: String,
                             download: @escaping @MainActor () async throws -> URL) {
        prepareMunkiCommon(expectedFileName: expectedFileName, download: download)
        self.host = host
        self.directTarget = nil
    }

    /// Direct (local-network) variant of `prepareMunkiPending`. Fetches
    /// the Munki package from S3 the same way, then runs the install
    /// pipeline against `target` over the LAN instead of through BSC.
    func prepareMunkiPendingDirect(target: DirectTarget,
                                   expectedFileName: String,
                                   download: @escaping @MainActor () async throws -> URL) {
        prepareMunkiCommon(expectedFileName: expectedFileName, download: download)
        self.host = nil
        self.directTarget = target
    }

    private func prepareMunkiCommon(expectedFileName: String,
                                    download: @escaping @MainActor () async throws -> URL) {
        cancel()
        self.localFile = nil
        self.appMode = .compress
        self.phase = .idle
        self.trailingLogLine = ""
        self.errorTail = ""
        self.lineBuffer = ""
        self.progressPercent = 0
        self.log = ""
        self.fileMetadata = nil
        self.isMunki = true
        self.pendingFileName = expectedFileName
        self.pendingDownload = download
    }

    func reset() {
        cancel()
        host = nil
        directTarget = nil
        localFile = nil
        phase = .idle
        sudoPassword = ""
        trailingLogLine = ""
        errorTail = ""
        lineBuffer = ""
        progressPercent = 0
        log = ""
        isMunki = false
        pendingFileName = ""
        pendingDownload = nil
    }

    func cancel() {
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
        stdoutReader = nil
        if phase.isRunning {
            phase = .cancelled
        }
    }

    /// Start the install. Spawns one bash process that runs all phases
    /// in sequence, parsing the `▶ phase=...` marker lines it emits.
    func start(settings: SettingsStore) {
        guard host != nil || directTarget != nil else { return }
        // Munki: download must complete (and set localFile) before we can
        // build the upload pipeline script. Kick the fetch off here so the
        // user only had to enter their password once.
        if isMunki, localFile == nil, let download = pendingDownload {
            pendingDownload = nil
            phase = .downloading
            log.append("▶ Downloading \(pendingFileName) from Munki Repo…\n")
            Task { [weak self] in
                do {
                    let url = try await download()
                    await MainActor.run {
                        guard let self else { return }
                        self.localFile = url
                        self.log.append("✓ Download complete: \(url.lastPathComponent)\n")
                        Task { [weak self] in
                            let m = await PackageMetadata.read(from: url)
                            await MainActor.run { self?.fileMetadata = m }
                        }
                        self.runInstallProcess(settings: settings)
                    }
                } catch {
                    await MainActor.run {
                        self?.log.append("✖ Download failed: \(error.localizedDescription)\n")
                        self?.phase = .failed("Download: \(error.localizedDescription)")
                    }
                }
            }
            return
        }
        runInstallProcess(settings: settings)
    }

    private func runInstallProcess(settings: SettingsStore) {
        guard let localFile else { return }
        guard host != nil || directTarget != nil else { return }
        let script = makeScript(localFile: localFile, settings: settings)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        var env = ProcessInfo.processInfo.environment
        env["BCADMIN_PW"] = sudoPassword
        p.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendOutput(s) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendErrors(s) }
        }

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.finish(exitCode: proc.terminationStatus)
            }
        }

        do {
            try p.run()
            self.process = p
            self.stdoutReader = stdout
            self.phase = .uploading  // initial — script may override immediately
        } catch {
            phase = .failed("spawn failed: \(error.localizedDescription)")
        }
    }

    private func appendOutput(_ chunk: String) {
        lineBuffer.append(chunk)
        while let nl = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<nl])
            lineBuffer.removeSubrange(...nl)
            handleLine(line)
        }
    }

    private func appendErrors(_ chunk: String) {
        errorTail.append(chunk)
        log.append(chunk)
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            trailingLogLine = trimmed
        }
        if errorTail.count > 4_000 {
            errorTail = String(errorTail.suffix(2_000))
        }
        if log.count > 32_000 {
            log = String(log.suffix(16_000))
        }
        // scp progress comes on stderr (under script wrapping). Parse a %.
        parsePercent(in: chunk)
    }

    private func handleLine(_ line: String) {
        // `script` injects the chunk into `log` only through appendErrors;
        // stdout lines go through here, so we capture them too.
        log.append(line)
        log.append("\n")
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        if let r = trimmed.range(of: "▶ phase=") {
            let name = String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            switch name {
            case "compressing": phase = .compressing; progressPercent = 0
            case "uploading":   phase = .uploading;   progressPercent = 0
            case "mounting":    phase = .mounting
            case "installing":  phase = .installing
            case "copying":     phase = .copying
            case "detaching":   phase = .detaching
            case "cleaning":    phase = .cleaning
            case "succeeded":   phase = .succeeded;   progressPercent = 100
            default: break
            }
            return
        }
        trailingLogLine = trimmed
        parsePercent(in: line)
    }

    /// scp under a TTY (we wrap it with `script -q /dev/null`) prints
    /// progress as `<file>  25%  12MB  4.3MB/s   00:03 ETA` separated by
    /// `\r`. Pick the highest "N%" we see in the chunk. Hand-parsed to
    /// dodge the Swift regex-literal/`/`-operator parsing conflict.
    private func parsePercent(in chunk: String) {
        var highest = -1
        let chars = Array(chunk)
        var i = 0
        while i < chars.count {
            if chars[i].isNumber {
                var digits = ""
                while i < chars.count, chars[i].isNumber, digits.count < 3 {
                    digits.append(chars[i]); i += 1
                }
                if i < chars.count, chars[i] == "%" {
                    if let v = Int(digits), (0...100).contains(v) {
                        highest = max(highest, v)
                    }
                    i += 1
                }
            } else {
                i += 1
            }
        }
        if highest >= 0 { progressPercent = highest }
    }

    private func finish(exitCode: Int32) {
        process = nil
        stdoutReader = nil
        if phase == .cancelled { return }
        if exitCode == 0 {
            phase = .succeeded
        } else if phase.isRunning || phase == .idle {
            let detail = errorTail
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .suffix(3)
                .joined(separator: " · ")
            phase = .failed(detail.isEmpty ? "exit \(exitCode)" : detail)
        }
    }

    // MARK: - Script construction

    /// Build the bash pipeline. Each phase emits a `▶ phase=...` marker
    /// so the UI can advance. scp is wrapped with `script -q /dev/null`
    /// so it sees a PTY and emits its `\r`-separated `N%` progress lines
    /// — we parse those into `progressPercent`. Sudo password (if set)
    /// comes from `$BCADMIN_PW` (Process env), never argv.
    private func makeScript(localFile: URL, settings: SettingsStore) -> String {
        // Pick transport: BSC tunnel (ProxyCommand to localhost on the
        // bastion) vs direct (LAN connection straight to the remote).
        // The two branches differ only in the SSH/scp argument prefix.
        let remoteUser: String
        let sshPortArg: Int
        let sshHostArg: String
        let proxyOption: String
        if let direct = directTarget {
            remoteUser = direct.remoteUser
            sshPortArg = direct.port
            sshHostArg = direct.hostname
            proxyOption = ""
        } else if let host {
            remoteUser = settings.defaultRemoteUser
            sshPortArg = host.sshPort
            sshHostArg = "localhost"
            let proxy = "ProxyCommand=ssh -o WarnWeakCrypto=no -p \(settings.sshTunnelPort) -i \(settings.expandedKeyPath) admin@\(settings.serverFqdn) /bin/nc %h %p"
            proxyOption = "-o \(Self.shq(proxy)) "
        } else {
            // canStart / start() guards prevent this, but make the
            // compiler happy with a default.
            remoteUser = settings.defaultRemoteUser
            sshPortArg = 22
            sshHostArg = "localhost"
            proxyOption = ""
        }
        let ext = localFile.pathExtension.lowercased()
        let isApp = ext == "app"
        let appRawMode = isApp && appMode == .raw
        let appDmgMode = isApp && appMode == .compress
        let isDmgInstall = ext == "dmg" || appDmgMode  // remote runs the mount/copy path

        let appName = localFile.deletingPathExtension().lastPathComponent
        let uploadName: String = {
            if appDmgMode { return "\(appName).dmg" }
            if appRawMode { return "\(appName).app" }
            return localFile.lastPathComponent
        }()
        let remotePath = "/tmp/\(uploadName)"

        // ---- Remote install steps (run under sudo) ----
        let installSteps: String
        if isDmgInstall {
            installSteps = """
            mp=$(mktemp -d) && \
            echo '▶ phase=mounting' && hdiutil attach -quiet -nobrowse -mountpoint "$mp" \(Self.shq(remotePath)) && \
            if pkg=$(find "$mp" -maxdepth 2 -name '*.pkg' -print -quit) && [ -n "$pkg" ]; then \
              echo '▶ phase=installing' && installer -pkg "$pkg" -target /; \
            elif app=$(find "$mp" -maxdepth 2 -name '*.app' -print -quit) && [ -n "$app" ]; then \
              echo '▶ phase=copying' && \
              rm -rf "/Applications/$(basename "$app")" && \
              cp -R "$app" /Applications/; \
            else \
              echo 'no .pkg or .app found in disk image' >&2; status=1; \
            fi; \
            echo '▶ phase=detaching' && hdiutil detach -quiet "$mp"; \
            [ -z "${status:-}" ] || exit "$status"
            """
        } else if appRawMode {
            installSteps = """
            echo '▶ phase=copying' && \
            rm -rf "/Applications/\(appName).app" && \
            mv \(Self.shq(remotePath)) /Applications/
            """
        } else {
            // .pkg
            installSteps = "echo '▶ phase=installing' && installer -pkg \(Self.shq(remotePath)) -target /"
        }

        let sudoWrap = sudoPassword.isEmpty
            ? "sudo bash -c \(Self.shq(installSteps))"
            : "sudo -S bash -c \(Self.shq(installSteps))"

        let sshBase = "ssh \(proxyOption)-o StrictHostKeyChecking=no -o WarnWeakCrypto=no -p \(sshPortArg) \(Self.shq("\(remoteUser)@\(sshHostArg)"))"
        let installSSH = sudoPassword.isEmpty
            ? sshBase.replacingOccurrences(of: "ssh ", with: "ssh -t ") + " \(Self.shq(sudoWrap))"
            : "printf '%s\\n' \"$BCADMIN_PW\" | \(sshBase) \(Self.shq(sudoWrap))"

        // ---- Upload command (scp through `script` so we get a TTY → % progress) ----
        // `script -q /dev/null` allocates a PTY transparently; scp sees a
        // terminal and emits its standard progress to stdout, which we parse.
        let scpFlags = "\(proxyOption)-o StrictHostKeyChecking=no -o WarnWeakCrypto=no -P \(sshPortArg)"
        let scpSrcLiteral: String        // safe to embed as bash literal (no shell metas)
        let scpDestArg = Self.shq("\(remoteUser)@\(sshHostArg):\(remotePath)")
        let scpRecurse: String
        if appDmgMode {
            scpSrcLiteral = "\"$tmp_dmg\""  // bash variable, double-quoted so it expands
            scpRecurse = ""
        } else if appRawMode {
            scpSrcLiteral = Self.shq(localFile.path)
            scpRecurse = "-r "
        } else {
            scpSrcLiteral = Self.shq(localFile.path)
            scpRecurse = ""
        }
        let uploadSCP = "script -q /dev/null scp \(scpRecurse)\(scpFlags) \(scpSrcLiteral) \(scpDestArg)"

        // ---- Cleanup: only for files we left in /tmp; raw .app is mv'd out ----
        let cleanupSSH: String? = appRawMode
            ? nil
            : "\(sshBase) \(Self.shq("rm -f \(remotePath)"))"

        var prelude = "set -e\n"
        if appDmgMode {
            prelude += """
            tmp_dmg=$(mktemp -t bcadmin-XXXXX).dmg
            trap 'rm -f "$tmp_dmg"' EXIT
            echo '▶ phase=compressing'
            hdiutil create -quiet -srcfolder \(Self.shq(localFile.path)) \
                           -format UDZO -volname \(Self.shq(appName)) "$tmp_dmg"

            """
        }

        var script = """
        \(prelude)echo '▶ phase=uploading'
        \(uploadSCP)
        \(installSSH)

        """
        if let cleanupSSH {
            script += """
            echo '▶ phase=cleaning'
            \(cleanupSSH)

            """
        }
        script += "echo '▶ phase=succeeded'\n"
        return script
    }

    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
