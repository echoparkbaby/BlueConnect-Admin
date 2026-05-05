import AppKit
import SwiftUI

@MainActor
@Observable
final class VNCConnectController {
    enum Phase { case starting, connecting, opening, done, failed(String) }

    var phase: Phase = .starting
    private(set) var localPort: Int = 0
    @ObservationIgnored let host: BlueSkyHost
    @ObservationIgnored let user: String
    @ObservationIgnored let server: String
    @ObservationIgnored let serverSshPort: Int
    @ObservationIgnored let adminKeyPath: String
    @ObservationIgnored let terminals: TerminalSessionsManager
    @ObservationIgnored let recents: RecentConnectStore
    @ObservationIgnored private var task: Task<Void, Never>?

    init(host: BlueSkyHost, user: String, server: String, serverSshPort: Int,
         adminKeyPath: String, terminals: TerminalSessionsManager,
         recents: RecentConnectStore) {
        self.host = host
        self.user = user
        self.server = server
        self.serverSshPort = serverSshPort
        self.adminKeyPath = adminKeyPath
        self.terminals = terminals
        self.recents = recents
    }

    func start() {
        task?.cancel()
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
    }

    private func run() async {
        recents.recordConnect(blueskyid: host.blueskyid)

        // Drop any stale tunnel we registered for this host first.
        terminals.killTunnels(forBlueskyid: host.blueskyid)
        try? await Task.sleep(for: .milliseconds(200))

        phase = .connecting

        // Pick a fresh kernel-allocated local port for this attempt.
        guard let chosen = Self.pickEphemeralPort() else {
            phase = .failed("Couldn't allocate a local port for the VNC tunnel.")
            return
        }
        localPort = chosen
        Log.info("VNC", "modal openVNC #\(host.blueskyid) \(host.displayName): allocated local port \(chosen)")

        let proxy = "ProxyCommand=ssh -o WarnWeakCrypto=no -p \(serverSshPort) -i \(adminKeyPath) admin@\(server) /bin/nc %h %p"
        let p = Process()
        p.launchPath = "/usr/bin/ssh"
        p.arguments = [
            "-N", "-T",
            "-o", proxy,
            "-o", "StrictHostKeyChecking=no",
            "-o", "WarnWeakCrypto=no",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "BatchMode=yes",
            "-L", "\(chosen):localhost:5900",
            "-p", "\(host.sshPort)",
            "\(user)@localhost",
        ]
        p.environment = ProcessInfo.processInfo.environment
        p.standardOutput = Pipe()
        let errPipe = Pipe()
        p.standardError = errPipe

        do {
            try p.run()
        } catch {
            phase = .failed("Couldn't spawn ssh: \(error.localizedDescription)")
            return
        }

        // 3. Poll for the port to bind, up to ~5s. Don't register with the
        //    Connections tab yet — that would briefly pop the bottom pane
        //    open even on failures.
        var bound = false
        for _ in 0..<25 {
            if await Self.localPortIsListening(localPort) { bound = true; break }
            try? await Task.sleep(for: .milliseconds(200))
        }

        if !bound {
            let errData = errPipe.fileHandleForReading.availableData
            let errStr = (String(data: errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let detail: String
            if errStr.contains("Connection refused") && errStr.contains("22") {
                detail = "The host's reverse tunnel isn't currently listening on the bluesky server. The client may have gone offline between your last refresh and now. Refresh the list and try again, or pick a host that's currently green.\n\n\(errStr)"
            } else if errStr.contains("Permission denied") {
                detail = "SSH authentication failed. Run this once in Terminal then retry:\n\n  ssh-add --apple-use-keychain ~/.ssh/bluesky_admin\n\n\(errStr)"
            } else if errStr.isEmpty {
                detail = "Tunnel never bound. Likely your SSH key needs a passphrase or isn't loaded into the agent. Run:\n\n  ssh-add --apple-use-keychain ~/.ssh/bluesky_admin"
            } else {
                detail = errStr
            }
            phase = .failed(detail)
            p.terminate()
            return
        }

        // 4. Bound! Now register with the manager (Connections tab) so the
        //    bottom pane shows it and it can be killed.
        let tracked = TrackedTunnel(
            blueskyid: host.blueskyid, displayName: host.displayName,
            localPort: localPort, remotePort: 5900, kind: "VNC", process: p
        )
        terminals.registerTunnel(tracked)

        phase = .opening
        try? await Task.sleep(for: .milliseconds(200))
        await openURL()
    }

    private func openURL() async {
        if let url = URL(string: "vnc://\(user)@localhost:\(localPort)") {
            Log.info("VNC", "modal open vnc://...localhost:\(localPort) for #\(host.blueskyid)")
            NSWorkspace.shared.open(url)
        }
        phase = .done
    }

    static func pickEphemeralPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindOK: Int32 = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else { return nil }
        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameOK: Int32 = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameOK == 0 else { return nil }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }

    /// Blocking BSD-socket probe — must escape the calling actor or it
    /// stalls SwiftUI updates for up to 300 ms. `Task.detached` is the
    /// right tool here despite the skill warning.
    static func localPortIsListening(_ port: Int) async -> Bool {
        await Task.detached(priority: .userInitiated) { () -> Bool in
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            guard fd >= 0 else { return false }
            var tv = timeval(tv_sec: 0, tv_usec: 300_000)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result: Int32 = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    connect(fd, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            return result == 0
        }.value
    }
}
