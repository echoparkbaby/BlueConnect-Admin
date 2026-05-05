import Foundation
import SwiftUI

struct RuntimeLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: Level
    let category: String
    let message: String

    enum Level: String {
        case info, warn, error

        var color: Color {
            switch self {
            case .info:  return .secondary
            case .warn:  return .orange
            case .error: return .red
            }
        }
    }
}

/// In-memory ring buffer of diagnostic events:
/// SSH lifecycle, tunnel binding, ssh stderr, openVNC retries, etc.
/// Singleton so anything in the app can write to it without plumbing.
@MainActor
@Observable
final class RuntimeLog {
    static let shared = RuntimeLog()

    private(set) var entries: [RuntimeLogEntry] = []
    @ObservationIgnored private let cap = 1000

    func info(_ category: String, _ msg: String) { add(.info, category, msg) }
    func warn(_ category: String, _ msg: String) { add(.warn, category, msg) }
    func error(_ category: String, _ msg: String) { add(.error, category, msg) }

    func clear() { entries = [] }

    func formattedDump() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return entries.reversed().map { e in
            "[\(f.string(from: e.timestamp))] \(e.level.rawValue.uppercased()) \(e.category): \(e.message)"
        }.joined(separator: "\n")
    }

    private func add(_ level: RuntimeLogEntry.Level, _ category: String, _ msg: String) {
        let e = RuntimeLogEntry(timestamp: Date(), level: level, category: category, message: msg)
        entries.insert(e, at: 0)
        if entries.count > cap { entries.removeLast(entries.count - cap) }
        // Mirror to NSLog so Console.app + stdout still see it.
        NSLog("[\(category)] \(msg)")
    }
}

/// Convenience entry point that hops to the main actor.
enum Log {
    static func info(_ cat: String, _ msg: String) {
        Task { @MainActor in RuntimeLog.shared.info(cat, msg) }
    }
    static func warn(_ cat: String, _ msg: String) {
        Task { @MainActor in RuntimeLog.shared.warn(cat, msg) }
    }
    static func error(_ cat: String, _ msg: String) {
        Task { @MainActor in RuntimeLog.shared.error(cat, msg) }
    }
}
