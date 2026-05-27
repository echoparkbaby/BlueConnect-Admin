import SwiftUI

/// Variant that reads its SF Symbol from `@AppStorage(storageKey)`,
/// falling back to `defaultIcon` when nothing has been picked yet. Use
/// this for the four non-Quick-Actions host-row icons (SSH / VNC /
/// SCP / Install) so that the live RowIconPicker can swap them without
/// a relaunch. `Table` caches TableColumn-rendered rows, so an
/// `@AppStorage` declared in the parent ContentView doesn't invalidate
/// individual rows — having the storage live *inside* this leaf view
/// is what makes the swap immediate.
struct PersistentIconButton: View {
    @AppStorage private var icon: String
    let color: Color
    let enabled: Bool
    let help: String
    let action: () -> Void

    init(storageKey: String,
         defaultIcon: String,
         color: Color,
         enabled: Bool,
         help: String,
         action: @escaping () -> Void) {
        _icon = AppStorage(wrappedValue: defaultIcon, storageKey)
        self.color = color
        self.enabled = enabled
        self.help = help
        self.action = action
    }

    var body: some View {
        QuickActionButton(icon: icon, color: color,
                          enabled: enabled, help: help, action: action)
    }
}

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
