import Foundation

enum HostAction: String {
    case selfdestruct
    case delete
    /// "Block forever" — server-side adds the host's serial to
    /// BlueSky.blocked_serials and installs a BEFORE INSERT trigger so any
    /// future re-registration with the same serial is rejected at the DB
    /// layer. Same teardown as `delete` (row deleted, pubkey scrubbed)
    /// runs in the same request. Use for Macs that have been sold /
    /// transferred / are otherwise out of admin reach.
    case block
}
