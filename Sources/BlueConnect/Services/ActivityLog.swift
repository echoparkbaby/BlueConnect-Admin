import Foundation
import SwiftUI

struct ActivityEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let kind: Kind
    let title: String
    let detail: String?

    enum Kind: String {
        case connect = "arrow.right.circle.fill"
        case rename  = "pencil.circle.fill"
        case delete  = "trash.circle.fill"
        case favorite = "star.circle.fill"
        case category = "tag.circle.fill"
        case error   = "xmark.circle.fill"

        var color: Color {
            switch self {
            case .connect:  return .green
            case .rename:   return .blue
            case .delete:   return .red
            case .favorite: return .yellow
            case .category: return .accentColor
            case .error:    return .orange
            }
        }
    }
}

@MainActor
@Observable
final class ActivityLog {
    private(set) var entries: [ActivityEntry] = []
    @ObservationIgnored private let maxEntries = 200

    func record(_ kind: ActivityEntry.Kind, title: String, detail: String? = nil) {
        let e = ActivityEntry(timestamp: Date(), kind: kind, title: title, detail: detail)
        entries.insert(e, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }

    func clear() { entries = [] }
}
