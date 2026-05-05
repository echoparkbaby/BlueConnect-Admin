import SwiftUI

struct QuickActionButton: View {
    let icon: String
    let color: Color
    let enabled: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(help, systemImage: icon, action: action)
            .labelStyle(.iconOnly)
            .foregroundStyle(enabled ? color : .secondary.opacity(0.4))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .disabled(!enabled)
            .help(help)
    }
}
