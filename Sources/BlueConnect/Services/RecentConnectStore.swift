import Foundation
import SwiftUI

/// Local "I last connected to this host at…" tracking, per-Mac (UserDefaults).
/// Records when the operator clicks SSH/VNC/SCP from this BlueConnect Admin
/// instance.
@MainActor
@Observable
final class RecentConnectStore {
    private(set) var lastConnect: [Int: Date] = [:]
    @ObservationIgnored private let key = "recentConnects"

    init() { load() }

    @ObservationIgnored private let maxEntries = 100

    func recordConnect(blueskyid: Int, at date: Date = Date()) {
        lastConnect[blueskyid] = date
        // Cap to the N most-recent entries to avoid unbounded growth.
        if lastConnect.count > maxEntries {
            let sorted = lastConnect.sorted { $0.value > $1.value }
            lastConnect = Dictionary(uniqueKeysWithValues: sorted.prefix(maxEntries).map { ($0.key, $0.value) })
        }
        persist()
    }

    func date(for blueskyid: Int) -> Date? { lastConnect[blueskyid] }

    func relativeString(for blueskyid: Int) -> String {
        guard let d = lastConnect[blueskyid] else { return "—" }
        return d.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    func clear(for blueskyid: Int) {
        lastConnect.removeValue(forKey: blueskyid)
        persist()
    }

    func clearAll() {
        lastConnect = [:]
        persist()
    }

    private func load() {
        guard let str = UserDefaults.standard.string(forKey: key),
              let data = str.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return }
        var m: [Int: Date] = [:]
        for (k, v) in raw {
            if let id = Int(k) { m[id] = Date(timeIntervalSince1970: v) }
        }
        self.lastConnect = m
    }

    private func persist() {
        let raw = lastConnect.reduce(into: [String: Double]()) { d, kv in
            d[String(kv.key)] = kv.value.timeIntervalSince1970
        }
        if let data = try? JSONEncoder().encode(raw),
           let str = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: key)
        }
    }
}
