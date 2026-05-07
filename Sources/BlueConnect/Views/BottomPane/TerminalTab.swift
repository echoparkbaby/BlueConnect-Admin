import AppKit
import SwiftUI

struct TerminalTab: View {
    var session: TerminalSession
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: session.kind == .ssh ? "terminal" : "doc.badge.arrow.up")
                    .font(.caption)
                    .foregroundStyle(session.kind == .ssh ? .green : .orange)
                Text(session.title).lineLimit(1).foregroundStyle(isActive ? .primary : .secondary)
                Button("Close tab", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(2)
                    .background(Circle().fill(hovered ? Color.secondary.opacity(0.25) : Color.clear))
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Rectangle().fill(isActive ? Color(NSColor.windowBackgroundColor) : Color.clear))
            .overlay(alignment: .top) { Rectangle().fill(isActive ? Color.accentColor : Color.clear).frame(height: 2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
