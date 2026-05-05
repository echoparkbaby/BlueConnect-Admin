import Foundation

/// Drag payloads are plain strings with a fixed prefix. Going through
/// `String` (built-in `public.utf8-plain-text`) avoids the custom-UTI
/// registration trap on ad-hoc-signed bundles, and lets a single drag
/// be discriminated by its prefix at the drop site.
enum DragPayload {
    static let statusPrefix = "bcadmin/status:"
    static let categoryPrefix = "bcadmin/category:"
    static let hostsPrefix = "bcadmin/hosts:"

    static func status(_ key: String) -> String { statusPrefix + key }
    static func category(_ name: String) -> String { categoryPrefix + name }
    static func hosts(_ ids: [Int]) -> String { hostsPrefix + ids.map(String.init).joined(separator: ",") }

    static func parseStatus(_ s: String) -> String? {
        guard s.hasPrefix(statusPrefix) else { return nil }
        return String(s.dropFirst(statusPrefix.count))
    }

    static func parseCategory(_ s: String) -> String? {
        guard s.hasPrefix(categoryPrefix) else { return nil }
        return String(s.dropFirst(categoryPrefix.count))
    }

    static func parseHosts(_ s: String) -> [Int]? {
        guard s.hasPrefix(hostsPrefix) else { return nil }
        let body = String(s.dropFirst(hostsPrefix.count))
        let ids = body.split(separator: ",").compactMap { Int($0) }
        return ids.isEmpty ? nil : ids
    }
}
