import Foundation

/// Per-peer connection overrides for Tailscale rows. Any nil/empty
/// field means "use the global default in SettingsStore"
/// (`tailscaleSSHPort`, `tailscaleVNCPort`, `tailscaleDefaultUser`,
/// or finally `defaultRemoteUser` for the user fallback chain).
///
/// Name kept as `PortOverride` for storage compatibility with existing
/// `tailscalePortOverridesJSON` shape.
struct PortOverride: Codable, Hashable {
    var ssh: Int?
    var vnc: Int?
    var user: String?
}
