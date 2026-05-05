import AppKit
import SwiftUI

struct LogTab: View {
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft").font(.caption).foregroundStyle(.purple)
                Text("Log").foregroundStyle(isActive ? .primary : .secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Rectangle().fill(isActive ? Color(NSColor.windowBackgroundColor) : Color.clear))
            .overlay(alignment: .top) { Rectangle().fill(isActive ? Color.accentColor : Color.clear).frame(height: 2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
