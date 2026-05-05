import AppKit
import SwiftUI

struct CategoryRow: View {
    let name: String
    @Environment(BlueSkyHostListStore.self) var hostStore
    @State private var hovered = false

    private var count: Int {
        hostStore.hosts.filter { ($0.category ?? "") == name }.count
    }

    var body: some View {
        Button {
            UserDefaults.standard.set("cat:\(name)", forKey: "sidebarFilter")
            NSApp.activate(ignoringOtherApps: true)
            if let win = NSApp.windows.first(where: { $0.title.contains("BlueConnect") }) {
                win.makeKeyAndOrderFront(nil)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "tag.fill")
                    .font(.caption)
                    .foregroundStyle(CategoryColors.tint(for: name) ?? Color.accentColor)
                    .frame(width: 14)
                Text(name).foregroundStyle(.primary).lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? Color.accentColor.opacity(0.18) : Color.clear)
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
