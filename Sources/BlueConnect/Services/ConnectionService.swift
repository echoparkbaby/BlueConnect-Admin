import Foundation
import AppKit

struct ConnectionService {
    let server: String
    let adminKeyPath: String
    let serverSshPort: Int
    /// Manager for in-app terminal sessions. SSH/SCP use it; VNC stays native.
    let terminals: TerminalSessionsManager
    /// Optional callback fired right before launching a connection — lets the
    /// caller record "I just connected to host X at <now>".
    var onConnect: ((BlueSkyHost) -> Void)? = nil

    private func proxyCommand() -> String {
        // Ports/keys here are quoted by the consumer's outer shell.
        "ssh -o WarnWeakCrypto=no -p \(serverSshPort) -i \(adminKeyPath) admin@\(server) /bin/nc %h %p"
    }

    /// Open an embedded terminal tab and run an interactive ssh.
    func openSSH(host: BlueSkyHost, remoteUser: String) {
        onConnect?(host)
        let proxy = "ProxyCommand=ssh -o WarnWeakCrypto=no -p \(serverSshPort) -i \(adminKeyPath) admin@\(server) /bin/nc %h %p"
        let args = [
            "-t", "-o", proxy,
            "-o", "StrictHostKeyChecking=no",
            "-o", "WarnWeakCrypto=no",
            "-p", "\(host.sshPort)", "\(remoteUser)@localhost",
        ]
        Task { @MainActor in
            _ = terminals.openSSH(blueskyid: host.blueskyid, displayName: host.displayName,
                                  executable: "/usr/bin/ssh", args: args)
        }
    }

    /// Build a controller for the modal VNC progress sheet.
    @MainActor
    func makeVNCController(host: BlueSkyHost, remoteUser: String, recents: RecentConnectStore) -> VNCConnectController {
        VNCConnectController(
            host: host,
            user: remoteUser.isEmpty ? "ladmin" : remoteUser,
            server: server,
            serverSshPort: serverSshPort,
            adminKeyPath: adminKeyPath,
            terminals: terminals,
            recents: recents
        )
    }

    /// Spawn the SSH port-forward in the background (no terminal window),
    /// register it with the terminals manager so it shows in the
    /// Connections tab, and hand off to Screen Sharing via `vnc://`.
    func openVNC(host: BlueSkyHost, remoteUser: String) {
        onConnect?(host)
        let user = remoteUser.isEmpty ? "ladmin" : remoteUser
        let server = self.server
        let serverSshPort = self.serverSshPort
        let adminKeyPath = self.adminKeyPath
        let terminalsRef = self.terminals

        Task.detached {
            // Always tear down any tunnel we registered for this host. Closing
            // Screen Sharing doesn't kill the ssh -L; a stale forward whose
            // remote 5900 is no longer responsive shows up as a beach ball.
            await MainActor.run {
                if !terminalsRef.tunnels(forBlueskyid: host.blueskyid).isEmpty {
                    terminalsRef.killTunnels(forBlueskyid: host.blueskyid)
                }
            }
            // Give the ssh process a moment to actually exit.
            try? await Task.sleep(for: .milliseconds(200))

            // Pick a fresh kernel-allocated port every time, instead of reusing
            // host.vncPort. This eliminates collisions with any other listener
            // on that port and makes it impossible to inadvertently connect
            // Screen Sharing to a stale forward.
            guard let localPort = Self.pickEphemeralPort() else {
                Log.error("VNC", "couldn't allocate a local port for #\(host.blueskyid)")
                return
            }
            Log.info("VNC", "openVNC #\(host.blueskyid) \(host.displayName): allocated local port \(localPort)")

            let proxy = "ProxyCommand=ssh -o WarnWeakCrypto=no -p \(serverSshPort) -i \(adminKeyPath) admin@\(server) /bin/nc %h %p"
            let p = Process()
            p.launchPath = "/usr/bin/ssh"
            p.arguments = [
                "-N", "-T",
                "-o", proxy,
                "-o", "StrictHostKeyChecking=no",
                "-o", "WarnWeakCrypto=no",
                "-o", "ExitOnForwardFailure=yes",
                "-L", "\(localPort):localhost:5900",
                "-p", "\(host.sshPort)",
                "\(user)@localhost",
            ]
            p.environment = ProcessInfo.processInfo.environment
            p.standardOutput = Pipe()
            let errPipe = Pipe()
            p.standardError = errPipe
            let bid = host.blueskyid
            let dn = host.displayName
            errPipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty,
                      let s = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !s.isEmpty else { return }
                Log.warn("VNC", "ssh stderr #\(bid) \(dn): \(s)")
            }
            do {
                try p.run()
                Log.info("VNC", "spawned ssh -L \(localPort):5900 → #\(host.blueskyid) \(host.displayName) (pid \(p.processIdentifier))")
            } catch {
                Log.error("VNC", "tunnel spawn error #\(host.blueskyid): \(error.localizedDescription)")
                return
            }

            let pCaptured = p
            let hostCaptured = host
            await MainActor.run {
                let tracked = TrackedTunnel(
                    blueskyid: hostCaptured.blueskyid,
                    displayName: hostCaptured.displayName,
                    localPort: localPort,
                    remotePort: 5900,
                    kind: "VNC",
                    process: pCaptured
                )
                terminalsRef.registerTunnel(tracked)
            }

            // Poll for the local port to bind (up to ~4s).
            var bound = false
            for _ in 0..<20 {
                if await Self.localPortIsListening(localPort) {
                    bound = true; break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            if bound {
                Log.info("VNC", "tunnel #\(host.blueskyid) bound on localhost:\(localPort)")
            } else {
                Log.error("VNC", "tunnel #\(host.blueskyid) never bound port \(localPort) within 4s — Screen Sharing will surface the underlying error")
            }

            await MainActor.run {
                if let url = URL(string: "vnc://\(user)@localhost:\(localPort)") {
                    Log.info("VNC", "open vnc://...localhost:\(localPort) for #\(host.blueskyid)")
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// Blocking BSD-socket probe (300 ms timeout) — Task.detached escapes
    /// the calling actor so SwiftUI updates aren't stalled. Justified
    /// despite the skill's general warning against detached tasks.
    private static func localPortIsListening(_ port: Int) async -> Bool {
        await Task.detached(priority: .userInitiated) { () -> Bool in
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            guard fd >= 0 else { return false }

            var tv = timeval(tv_sec: 0, tv_usec: 300_000)  // 300 ms
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

    /// Ask the kernel for a free local port. Bind a socket to 127.0.0.1:0,
    /// read back the assigned port, then close. There's a microscopic race
    /// window before ssh can re-bind the same port, but in practice the
    /// kernel won't hand the same port to another caller within ms.
    private static func pickEphemeralPort() -> Int? {
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

    // MARK: - Direct (no BSC proxy) — for Bonjour-discovered local hosts

    /// Open `ssh user@host -p port` in an embedded terminal tab. No
    /// ProxyCommand — the target is on the local network already.
    func openDirectSSH(hostname: String, port: Int, remoteUser: String) {
        Log.info("Local", "ssh \(remoteUser)@\(hostname):\(port)")
        let args = [
            "-t",
            "-o", "StrictHostKeyChecking=no",
            "-o", "WarnWeakCrypto=no",
            "-p", "\(port)",
            "\(remoteUser)@\(hostname)",
        ]
        Task { @MainActor in
            _ = terminals.openSSH(blueskyid: 0, displayName: hostname,
                                  executable: "/usr/bin/ssh", args: args)
        }
    }

    /// Hand off to Screen Sharing via `vnc://user@host:port`. No tunnel
    /// needed — local host reachable directly.
    func openDirectVNC(hostname: String, port: Int, remoteUser: String) {
        Log.info("Local", "vnc://\(remoteUser)@\(hostname):\(port)")
        let user = remoteUser.isEmpty ? "" : "\(remoteUser)@"
        if let url = URL(string: "vnc://\(user)\(hostname):\(port)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// SCP a single file to the remote ~/Desktop/ via embedded terminal tab.
    func openSCP(host: BlueSkyHost, remoteUser: String, sourceURL: URL) {
        onConnect?(host)
        let proxy = "ProxyCommand=ssh -o WarnWeakCrypto=no -p \(serverSshPort) -i \(adminKeyPath) admin@\(server) /bin/nc %h %p"
        let args = [
            "-o", proxy,
            "-o", "StrictHostKeyChecking=no",
            "-o", "WarnWeakCrypto=no",
            "-P", "\(host.sshPort)", sourceURL.path,
            "\(remoteUser)@localhost:~/Desktop/",
        ]
        Task { @MainActor in
            _ = terminals.openSCP(blueskyid: host.blueskyid, displayName: host.displayName,
                                  executable: "/usr/bin/scp", args: args)
        }
    }

    /// Open an interactive `ssh` session in macOS Terminal.app.
    func openSSHInTerminal(host: BlueSkyHost, remoteUser: String) {
        onConnect?(host)
        let proxy = "ProxyCommand=ssh -o WarnWeakCrypto=no -p \(serverSshPort) -i \(adminKeyPath) admin@\(server) /bin/nc %h %p"
        let cmd = "ssh -t -o '\(proxy)' -o StrictHostKeyChecking=no -o WarnWeakCrypto=no -p \(host.sshPort) \(shellQuote(remoteUser))@localhost"
        runInTerminal(command: cmd)
    }

    /// Run `scp` of a single file in Terminal.app, then leave the window open
    /// to show output. Adds `; echo; echo '— done —'` so the user can read
    /// the result before closing.
    func openSCPInTerminal(host: BlueSkyHost, remoteUser: String, sourceURL: URL) {
        onConnect?(host)
        let proxy = "ProxyCommand=ssh -o WarnWeakCrypto=no -p \(serverSshPort) -i \(adminKeyPath) admin@\(server) /bin/nc %h %p"
        let cmd = """
        scp -o '\(proxy)' -o StrictHostKeyChecking=no -o WarnWeakCrypto=no -P \(host.sshPort) \(shellQuote(sourceURL.path)) \(shellQuote(remoteUser))@localhost:~/Desktop/ ; echo ; echo '— done —'
        """
        runInTerminal(command: cmd)
    }

    /// Establish the SSH local-forward in Terminal.app and immediately
    /// hand off to Screen Sharing via `vnc://`. Tunnel runs in the
    /// foreground of the terminal tab so the user sees its lifetime.
    func openVNCInTerminal(host: BlueSkyHost, remoteUser: String) {
        onConnect?(host)
        let user = remoteUser.isEmpty ? "ladmin" : remoteUser
        guard let localPort = Self.pickEphemeralPort() else {
            Log.error("VNC", "couldn't allocate a local port for terminal-VNC #\(host.blueskyid)")
            return
        }
        Log.info("VNC", "openVNCInTerminal #\(host.blueskyid) \(host.displayName): local port \(localPort)")
        let proxy = "ProxyCommand=ssh -o WarnWeakCrypto=no -p \(serverSshPort) -i \(adminKeyPath) admin@\(server) /bin/nc %h %p"
        let cmd = """
        ssh -N -T -o '\(proxy)' -o StrictHostKeyChecking=no -o WarnWeakCrypto=no -o ExitOnForwardFailure=yes -L \(localPort):localhost:5900 -p \(host.sshPort) \(shellQuote(user))@localhost & TUN=$! ; sleep 1 ; open 'vnc://\(user)@localhost:\(localPort)' ; wait $TUN
        """
        runInTerminal(command: cmd)
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Send a command to a fresh Terminal.app tab.
    private func runInTerminal(command: String) {
        // Escape backslashes and double quotes for AppleScript string.
        let safe = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        tell application "Terminal"
            activate
            do script "\(safe)"
        end tell
        """
        if let s = NSAppleScript(source: appleScript) {
            var err: NSDictionary?
            s.executeAndReturnError(&err)
            if let err = err {
                NSLog("Terminal launch error: \(err)")
            }
        }
    }
}
