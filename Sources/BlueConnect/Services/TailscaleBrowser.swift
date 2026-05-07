import Foundation

/// Polls `tailscale status --json` for online peers and exposes them as
/// `LocalService` rows alongside Bonjour-discovered ones. Tailscale peers
/// are NOT visible to mDNS because Tailscale is a separate overlay
/// network — we have to ask the daemon directly.
///
/// macOS and Linux peers both qualify (you can SSH to either). VNC is
/// only offered for macOS peers, since `_rfb._tcp` is a Mac thing in
/// practice.
@MainActor
@Observable
final class TailscaleBrowser {
    private(set) var services: [LocalService] = []
    private(set) var lastError: String?

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        Log.info("Tailscale", "started polling tailscale status")
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        services = []
        lastError = nil
    }

    private func poll() async {
        let data = await Task.detached(priority: .background) {
            Self.runStatus()
        }.value
        guard let data else {
            lastError = "tailscale CLI not found"
            services = []
            return
        }
        do {
            let result = try JSONDecoder().decode(TailscaleStatus.self, from: data)
            let peers = (result.peers ?? [:]).values.compactMap(Self.makeService)
            services = peers.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            lastError = nil
            Log.info("Tailscale", "discovered \(services.count) online peers")
        } catch {
            lastError = "JSON parse: \(error.localizedDescription)"
            Log.error("Tailscale", "JSON parse failed: \(error.localizedDescription)")
        }
    }

    private static func makeService(_ peer: TailscalePeer) -> LocalService? {
        guard peer.online == true else { return nil }
        // Skip non-Mac/non-Linux (Windows/iOS aren't useful for SSH or VNC).
        let os = peer.os ?? ""
        let isMac = os == "macOS"
        let isLinux = os == "linux"
        guard isMac || isLinux else { return nil }
        // Prefer IPv4 over IPv6 — older sshd setups dislike v6 addresses.
        let ip = (peer.tailscaleIPs ?? []).first { !$0.contains(":") }
        guard let connectHost = ip ?? peer.hostName else { return nil }
        return LocalService(
            name: peer.hostName ?? connectHost,
            hostname: connectHost,
            sshPort: 22,
            vncPort: isMac ? 5900 : nil,
            source: .tailscale
        )
    }

    /// Run `tailscale status --json` from one of the standard install
    /// locations. Returns nil if the binary isn't found or exits non-zero.
    nonisolated private static func runStatus() -> Data? {
        let candidates = [
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["status", "--json"]
            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            do {
                try p.run()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else { continue }
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                return data.isEmpty ? nil : data
            } catch {
                continue
            }
        }
        return nil
    }
}

// MARK: - JSON shapes (subset of `tailscale status --json`)

private struct TailscaleStatus: Decodable {
    let selfPeer: TailscalePeer?
    let peers: [String: TailscalePeer]?

    enum CodingKeys: String, CodingKey {
        case selfPeer = "Self"
        case peers = "Peer"
    }
}

private struct TailscalePeer: Decodable {
    let hostName: String?
    let dnsName: String?
    let os: String?
    let tailscaleIPs: [String]?
    let online: Bool?

    enum CodingKeys: String, CodingKey {
        case hostName = "HostName"
        case dnsName = "DNSName"
        case os = "OS"
        case tailscaleIPs = "TailscaleIPs"
        case online = "Online"
    }
}
