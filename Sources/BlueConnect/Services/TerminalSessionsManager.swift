import Foundation

@MainActor
@Observable
final class TerminalSessionsManager {
    private(set) var sessions: [TerminalSession] = []
    private(set) var tunnels: [TrackedTunnel] = []
    var activeSelection: BottomPaneSelection?

    var activeSession: TerminalSession? {
        guard case .session(let id) = activeSelection else { return nil }
        return sessions.first(where: { $0.id == id })
    }

    var hasContent: Bool { !sessions.isEmpty || !tunnels.isEmpty }

    var activeSessionID: UUID? {
        get {
            if case .session(let id) = activeSelection { return id }
            return nil
        }
        set { if let id = newValue { activeSelection = .session(id) } }
    }

    func openSSH(blueskyid: Int, displayName: String, executable: String, args: [String]) -> TerminalSession {
        let s = TerminalSession(
            blueskyid: blueskyid,
            title: "\(displayName) (#\(blueskyid))",
            kind: .ssh, executable: executable, args: args
        )
        sessions.append(s)
        activeSelection = .session(s.id)
        return s
    }

    func openSCP(blueskyid: Int, displayName: String, executable: String, args: [String]) -> TerminalSession {
        let s = TerminalSession(
            blueskyid: blueskyid,
            title: "scp → \(displayName)",
            kind: .scp, executable: executable, args: args
        )
        sessions.append(s)
        activeSelection = .session(s.id)
        return s
    }

    func registerTunnel(_ tunnel: TrackedTunnel) {
        tunnels.append(tunnel)
        let displayName = tunnel.displayName
        let blueskyid = tunnel.blueskyid
        let port = tunnel.localPort
        let kind = tunnel.kind
        Log.info("Tunnel", "\(kind) registered #\(blueskyid) \(displayName) on localhost:\(port) (pid \(tunnel.process.processIdentifier))")
        tunnel.process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.tunnels.removeAll { $0.id == tunnel.id }
                Log.info("Tunnel", "\(kind) exited #\(blueskyid) \(displayName) (status \(proc.terminationStatus))")
            }
        }
    }

    func killTunnel(_ id: UUID) {
        if let t = tunnels.first(where: { $0.id == id }) {
            Log.info("Tunnel", "manual kill #\(t.blueskyid) \(t.displayName)")
            t.process.terminate()
        }
    }

    func killAllTunnels() {
        if !tunnels.isEmpty { Log.info("Tunnel", "kill all (\(tunnels.count))") }
        for t in tunnels { t.process.terminate() }
    }

    func tunnels(forBlueskyid id: Int) -> [TrackedTunnel] {
        tunnels.filter { $0.blueskyid == id }
    }

    func killTunnels(forBlueskyid id: Int) {
        for t in tunnels where t.blueskyid == id {
            Log.info("Tunnel", "killing stale #\(t.blueskyid) \(t.displayName) before reconnect")
            t.process.terminate()
        }
    }

    func close(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].terminate()
        sessions.remove(at: i)
        if case .session(let active) = activeSelection, active == id {
            if let last = sessions.last { activeSelection = .session(last.id) }
            else if !tunnels.isEmpty { activeSelection = .connections }
            else { activeSelection = nil }
        }
    }

    func closeAll() {
        sessions.forEach { $0.terminate() }
        sessions.removeAll()
        activeSelection = tunnels.isEmpty ? nil : .connections
    }

    func selectPrevious() {
        guard let id = activeSessionID, let i = sessions.firstIndex(where: { $0.id == id }) else {
            activeSessionID = sessions.last?.id; return
        }
        let prev = i == 0 ? sessions.count - 1 : i - 1
        if prev >= 0 && prev < sessions.count { activeSessionID = sessions[prev].id }
    }

    func selectNext() {
        guard let id = activeSessionID, let i = sessions.firstIndex(where: { $0.id == id }) else {
            activeSessionID = sessions.first?.id; return
        }
        activeSessionID = sessions[(i + 1) % max(1, sessions.count)].id
    }
}
