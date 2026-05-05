import SwiftUI

/// Stable hash-based color tint per category name. Same name → same color.
enum CategoryColors {
    static func tint(for category: String?) -> Color? {
        guard let c = category, !c.isEmpty else { return nil }
        let h = abs(c.hashValue) % palette.count
        return palette[h]
    }

    private static let palette: [Color] = [
        Color.blue, Color.green, Color.orange, Color.purple,
        Color.pink, Color.teal, Color.indigo, Color.brown,
        Color.cyan, Color.mint,
    ]
}
