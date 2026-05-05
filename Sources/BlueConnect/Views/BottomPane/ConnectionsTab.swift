import AppKit
import SwiftUI

struct ConnectionsTab: View {
    let count: Int
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.swap").font(.caption).foregroundStyle(.tint)
                Text("Connections").foregroundStyle(isActive ? .primary : .secondary)
                if count > 0 {
                    Text("\(count)").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Rectangle().fill(isActive ? Color(NSColor.windowBackgroundColor) : Color.clear))
            .overlay(alignment: .top) { Rectangle().fill(isActive ? Color.accentColor : Color.clear).frame(height: 2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
