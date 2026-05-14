import Foundation

struct BlueSkyHost: Codable, Identifiable, Hashable {
    let blueskyid: Int
    let hostname: String?
    let sharingname: String?
    let username: String?
    let status: String?
    let lastSeen: String?
    let timestamp: Int
    let active: Bool
    let sshPort: Int
    let vncPort: Int
    let category: String?
    let favorite: Bool?
    let notes: String?
    let serialnum: String?
    let notify: Bool?
    let alert: Bool?
    let email: String?

    var id: Int { blueskyid }

    var displayName: String {
        if let h = hostname, !h.isEmpty { return h.unmojibake() }
        if let s = sharingname, !s.isEmpty { return s.unmojibake() }
        return "BlueSky #\(blueskyid)"
    }

    var lastSeenDate: Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    /// What user we'll actually SSH as for this host: DB value if non-empty,
    /// then user's default, then a hardcoded "ladmin" baseline.
    func effectiveUser(default fallback: String) -> String {
        if let u = username, !u.isEmpty { return u }
        if !fallback.isEmpty { return fallback }
        return "ladmin"
    }

    var isFavorite: Bool { favorite ?? false }
}

struct BlueSkyHostsResponse: Codable, Equatable {
    let hosts: [BlueSkyHost]
    let serverFqdn: String
    let activeCount: Int
    let categories: [String]?
    let blueSkyVersion: String?
    let phpVersion: String?
    let apiVersion: String?
}
