import SwiftUI

struct FooterButton: View {
    let label: String
    let icon: String
    var role: ButtonRole? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 14)
                    .foregroundStyle(role == .destructive ? Color.red : Color.accentColor)
                Text(label).foregroundStyle(.primary)
                Spacer()
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
