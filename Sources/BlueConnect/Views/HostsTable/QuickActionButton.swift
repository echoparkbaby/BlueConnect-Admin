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
            // .borderless (vs .plain) wins the click race with the
            // surrounding Table row's selection handler — otherwise the
            // first click selects the row and only the second fires
            // the button. .borderless is also visually identical to .plain
            // for our icon-only labels, so no UX regression.
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .help(help)
    }
}
