import Foundation

/// A machine discovered on the local network via Bonjour/mDNS or
/// Tailscale. Aggregates `_ssh._tcp` and `_rfb._tcp` announcements for
/// the same hostname so the sidebar shows one entry per machine.
struct LocalService: Identifiable, Hashable, Sendable {
    enum Source: String, Hashable, Sendable {
        case bonjour, tailscale, scanned
    }

    /// Display name (Bonjour service name, or Tailscale HostName).
    let name: String
    /// Connection target — `.local.` hostname for Bonjour, IP for Tailscale.
    let hostname: String
    /// Port for SSH if the host announced `_ssh._tcp` (Bonjour) or is a
    /// macOS/Linux Tailscale peer.
    var sshPort: Int?
    /// Port for VNC / Screen Sharing.
    var vncPort: Int?
    /// Where this entry came from. Determines what we offer in the
    /// context menu (e.g. "Hide" only on Tailscale rows).
    var source: Source = .bonjour

    var id: String { hostname.lowercased() + "|" + name }

    var hasSSH: Bool { sshPort != nil }
    var hasVNC: Bool { vncPort != nil }

    /// Hostname shown in the sidebar — strips the trailing `.` that
    /// Bonjour leaves on `.local.` names. The dot is fine for SSH/VNC
    /// (both forms resolve), but it looks like a typo in the UI.
    var displayHostname: String {
        hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname
    }
}
