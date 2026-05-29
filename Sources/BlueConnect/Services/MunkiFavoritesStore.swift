import Foundation

/// Tiny helper for the Munki "favorite by name" feature. The browser
/// and the picker's Munki tab both call into the same `@AppStorage`
/// key (`munkiFavorites`) backed by a JSON `[String]` of package
/// **names**. Names rather than `MunkiPkg.id` (which is
/// `"name|version"`) so a favorited Firefox stays favorited when the
/// repo cuts a new Firefox version — each render resolves the name
/// to the newest available `MunkiPkg` at that moment.
enum MunkiFavorites {
    /// Decode the JSON blob a view captures via `@AppStorage`.
    static func decode(_ raw: String) -> Set<String> {
        guard let data = raw.data(using: .utf8),
              let arr  = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(arr)
    }

    /// Encode a set back to the canonical JSON-string shape the
    /// `@AppStorage` slot expects. Sorted alphabetically so the
    /// on-disk plist diff is stable across launches.
    static func encode(_ set: Set<String>) -> String {
        let arr = Array(set).sorted()
        guard let data = try? JSONEncoder().encode(arr),
              let str  = String(data: data, encoding: .utf8)
        else { return "[]" }
        return str
    }

    /// Toggle the favorite status of `name` against the current raw
    /// JSON. Returns the new encoded JSON the caller should assign
    /// back to the `@AppStorage` slot.
    static func toggling(_ name: String, in raw: String) -> String {
        var s = decode(raw)
        if s.contains(name) { s.remove(name) } else { s.insert(name) }
        return encode(s)
    }
}
