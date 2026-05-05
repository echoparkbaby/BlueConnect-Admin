import Foundation

/// Background SSH local-forward (no PTY) — used for VNC port-forwards.
@MainActor
@Observable
final class TrackedTunnel: Identifiable {
    let id = UUID()
    let blueskyid: Int
    let displayName: String
    let localPort: Int
    let remotePort: Int
    let kind: String
    let startedAt: Date
    let process: Process

    init(blueskyid: Int, displayName: String, localPort: Int, remotePort: Int, kind: String, process: Process) {
        self.blueskyid = blueskyid
        self.displayName = displayName
        self.localPort = localPort
        self.remotePort = remotePort
        self.kind = kind
        self.startedAt = Date()
        self.process = process
    }
}
