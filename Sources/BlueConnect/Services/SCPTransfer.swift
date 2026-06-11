import Foundation

/// Model + runner for a single in-app file transfer to a BSC host.
/// Spawns `scp` directly (no embedded terminal), parses the progress
/// output, and exposes observable state for the sheet UI.
@MainActor
@Observable
final class SCPTransfer {
    enum Phase: Equatable {
        case idle, running, succeeded, failed(String), cancelled
    }

    var sourceURL: URL? = nil
    var destinationPath: String = "~/Desktop/"
    var phase: Phase = .idle
    var progressPercent: Int = 0
    var transferred: String = ""
    var rate: String = ""
    var eta: String = ""
    /// Source file size in bytes (for context, even before transfer starts).
    var totalSize: Int64 = 0

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stderrAccumulator: String = ""

    func reset() {
        process?.terminate()
        process = nil
        stderrAccumulator = ""
        sourceURL = nil
        destinationPath = "~/Desktop/"
        phase = .idle
        progressPercent = 0
        transferred = ""
        rate = ""
        eta = ""
        totalSize = 0
    }

    func setSource(_ url: URL) {
        sourceURL = url
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            totalSize = size
        } else {
            totalSize = 0
        }
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var canStart: Bool {
        if case .idle = phase { return sourceURL != nil && !destinationPath.isEmpty }
        return false
    }

    func start(host: BlueSkyHost, settings: SettingsStore) {
        guard canStart, let src = sourceURL else { return }
        let user = host.effectiveUser(default: settings.defaultRemoteUser)
        let dest = "\(user)@localhost:\(destinationPath)"
        // IdentitiesOnly=yes — see VNCConnectController for rationale.
        // Stops the BSC-server hop from offering every agent key
        // before bluesky_admin and tripping MaxAuthTries=6.
        let proxy = "ProxyCommand=ssh -o WarnWeakCrypto=no -o IdentitiesOnly=yes -p \(settings.sshTunnelPort) -i \(settings.expandedKeyPath) admin@\(settings.serverFqdn) /bin/nc %h %p"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        // BatchMode=yes dropped v1.5.6 for the same reason it left
        // VNCConnectController: it blocks macOS keychain from silently
        // answering the bluesky_admin passphrase prompt, so operators
        // with the legacy AppleScript-app keychain entry got
        // "Permission denied" on a key that would have unlocked fine
        // in Terminal.
        p.arguments = [
            "-o", proxy,
            "-o", "StrictHostKeyChecking=no",
            "-o", "WarnWeakCrypto=no",
            "-P", "\(host.sshPort)",
            src.path,
            dest,
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice

        // scp writes its progress line to stderr, repeatedly overwriting
        // via \r. Parse the latest progress fragment after every chunk.
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty,
                  let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.consumeStderr(s)
            }
        }

        let srcName = src.lastPathComponent
        p.terminationHandler = { [weak self] proc in
            // Drain any final stderr written between the last readability
            // callback and exit.
            let leftover = errPipe.fileHandleForReading.readDataToEndOfFile()
            let leftoverStr = String(data: leftover, encoding: .utf8) ?? ""
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.consumeStderr(leftoverStr)
                errPipe.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                if proc.terminationStatus == 0 {
                    self.progressPercent = 100
                    self.phase = .succeeded
                    Log.info("SCP", "transferred \(srcName) → \(dest)")
                } else if case .cancelled = self.phase {
                    Log.info("SCP", "cancelled \(srcName) → \(dest)")
                } else {
                    let msg = self.extractError() ?? "exit \(proc.terminationStatus)"
                    self.phase = .failed(msg)
                    Log.error("SCP", "failed \(srcName) → \(dest): \(msg)")
                }
            }
        }

        do {
            try p.run()
            phase = .running
            stderrAccumulator = ""
            process = p
            Log.info("SCP", "starting \(src.path) → \(dest)")
        } catch {
            phase = .failed(error.localizedDescription)
            Log.error("SCP", "spawn failed: \(error.localizedDescription)")
        }
    }

    func cancel() {
        guard let p = process, p.isRunning else { return }
        phase = .cancelled
        p.terminate()
    }

    /// Append latest stderr fragment, parse every progress line we can
    /// find, and update observable state. Lines are split on \r and \n
    /// since scp uses \r to update the same line in place.
    private func consumeStderr(_ s: String) {
        stderrAccumulator.append(s)
        let frags = s.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .filter { !$0.isEmpty }
        for frag in frags {
            if let p = Self.parseProgress(frag) {
                progressPercent = p.percent
                transferred = p.transferred
                rate = p.rate
                eta = p.eta
            }
        }
    }

    /// Pull a useful one-liner out of the accumulated stderr after a
    /// failed transfer — skip the progress noise.
    private func extractError() -> String? {
        let lines = stderrAccumulator
            .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && Self.parseProgress($0) == nil }
        return lines.last.map { String($0.prefix(240)) }
    }

    /// Match the scp progress format:
    /// `<filename>  45%  500MB  12.3MB/s   01:25`
    @ObservationIgnored
    private static let progressRegex: NSRegularExpression =
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"(\d+)%\s+(\S+)\s+(\S+)\s+(\d+:\d+)"#)

    private static func parseProgress(_ line: String) -> (percent: Int, transferred: String, rate: String, eta: String)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = progressRegex.firstMatch(in: line, range: range),
              m.numberOfRanges >= 5,
              let r1 = Range(m.range(at: 1), in: line),
              let r2 = Range(m.range(at: 2), in: line),
              let r3 = Range(m.range(at: 3), in: line),
              let r4 = Range(m.range(at: 4), in: line)
        else { return nil }
        let percent = Int(line[r1]) ?? 0
        return (percent, String(line[r2]), String(line[r3]), String(line[r4]))
    }
}
