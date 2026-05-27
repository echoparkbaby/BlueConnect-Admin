import Foundation

/// One row from `BlueSky.blocked_serials`, surfaced by
/// `bs_blocklist.json.php`. Identifiable by serial (the PK).
struct BlockedSerial: Codable, Hashable, Identifiable {
    let serial: String
    let added_at: String?
    let blueskyid_at_block: Int?
    let note: String?

    var id: String { serial }

    /// Parsed `added_at` in the server's local time. Returns nil when the
    /// string isn't in the expected `yyyy-MM-dd HH:mm:ss` shape.
    var addedDate: Date? {
        guard let s = added_at else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }
}

/// `bs_blocklist.json.php` response envelope.
struct BlockedSerialsResponse: Codable {
    let count: Int
    let items: [BlockedSerial]
}
