import Foundation

@MainActor
@Observable
final class TerminalSessionsManager {
    /// Stub captured when a session is closed so Reopen Last Closed (⌘⇧T)
    /// can spawn an equivalent one.
    ///
    /// Stores only enough to identify the *connection*, not the launch
    /// args themselves. ContentView reads this and re-runs the connection
    /// against current Settings (server, key path, tunnel port, user) so
    /// replay survives Settings changes — the args baked at original
    /// launch may be stale.
    struct ClosedSessionStub {
        let blueskyid: Int
        let displayName: String
        let kind: TerminalSession.Kind
    }

    private(set) var sessions: [TerminalSession] = []
    private(set) var tunnels: [TrackedTunnel] = []
    /// Most-recently-closed session, capped at 1 (matches "Reopen Last Closed"
    /// — not a tab history). Cleared after one reopen so a second ⌘⇧T does
    /// nothing rather than re-spawning the same tab.
    var lastClosed: ClosedSessionStub?
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

    @discardableResult
    func openLocalShell() -> TerminalSession {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let s = TerminalSession(
            blueskyid: 0,
            title: (shell as NSString).lastPathComponent,
            kind: .local, executable: shell, args: ["-l"]
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
        let s = sessions[i]
        lastClosed = ClosedSessionStub(
            blueskyid: s.blueskyid,
            displayName: s.title,
            kind: s.kind
        )
        s.terminate()
        sessions.remove(at: i)
        if case .session(let active) = activeSelection, active == id {
            if let last = sessions.last { activeSelection = .session(last.id) }
            else if !tunnels.isEmpty { activeSelection = .connections }
            else { activeSelection = nil }
        }
    }

    /// Close whichever session is currently focused in the bottom pane.
    /// No-op when the active selection isn't a session.
    func closeActive() {
        if let id = activeSessionID { close(id) }
    }

    /// Detach whichever session is currently focused. Caller is responsible
    /// for opening the matching detached-terminal window via openWindow().
    /// Returns the session id so the caller can pass it to openWindow.
    func detachActive() -> UUID? {
        guard let id = activeSessionID else { return nil }
        detach(id)
        return id
    }

    /// One-shot: clear `lastClosed`. Used by ContentView after it builds
    /// the actual reopen via current Settings.
    func consumeLastClosed() -> ClosedSessionStub? {
        let stub = lastClosed
        lastClosed = nil
        return stub
    }

    /// Select bottom-pane tab by 1-based index in the *attached*-only list.
    /// Index 1 = Log, 2..N+1 = attached sessions in insertion order.
    /// Detached sessions are excluded so the user can't land on a tab that
    /// isn't visible in the tab bar. Out-of-range = no-op.
    func selectBottomPaneTab(at oneBased: Int) {
        guard oneBased >= 1 else { return }
        if oneBased == 1 {
            activeSelection = .log
            return
        }
        let attached = sessions.filter { !$0.isDetached }
        let sessionIndex = oneBased - 2
        if sessionIndex < attached.count {
            activeSelection = .session(attached[sessionIndex].id)
        }
    }

    func closeAll() {
        sessions.forEach { $0.terminate() }
        sessions.removeAll()
        activeSelection = tunnels.isEmpty ? nil : .connections
    }

    /// Pop the session out of the tab bar into its own floating window.
    /// The matching `WindowGroup("Terminal", id: "detached-terminal")` in
    /// the App scene picks it up by UUID.
    func detach(_ id: UUID) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        s.isDetached = true
        // Pick a sensible new active selection — first non-detached session.
        if case .session(let active) = activeSelection, active == id {
            if let next = sessions.first(where: { $0.id != id && !$0.isDetached }) {
                activeSelection = .session(next.id)
            } else if !tunnels.isEmpty {
                activeSelection = .connections
            } else {
                activeSelection = nil
            }
        }
    }

    /// Pull a detached session back into the tab bar.
    func reattach(_ id: UUID) {
        guard let s = sessions.first(where: { $0.id == id }), s.isDetached else { return }
        s.isDetached = false
        activeSelection = .session(id)
    }

    /// Cycle backward through ATTACHED sessions only — detached sessions
    /// don't show in the tab bar, so navigating onto one would land on
    /// nothing visible.
    func selectPrevious() {
        let attached = sessions.filter { !$0.isDetached }
        guard !attached.isEmpty else { return }
        guard let id = activeSessionID,
              let i = attached.firstIndex(where: { $0.id == id }) else {
            activeSessionID = attached.last?.id; return
        }
        let prev = i == 0 ? attached.count - 1 : i - 1
        activeSessionID = attached[prev].id
    }

    func selectNext() {
        let attached = sessions.filter { !$0.isDetached }
        guard !attached.isEmpty else { return }
        guard let id = activeSessionID,
              let i = attached.firstIndex(where: { $0.id == id }) else {
            activeSessionID = attached.first?.id; return
        }
        activeSessionID = attached[(i + 1) % attached.count].id
    }
}
