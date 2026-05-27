import SwiftUI

/// Live picker for every SF Symbol that appears in a host-row's
/// Connect column — SSH / VNC / SCP / Install / Quick Actions. Each
/// row in the sheet is one icon slot with five candidates rendered as
/// big tiles; clicking a tile updates the live host row through
/// `@AppStorage` so the user can cycle visuals without restarting.
///
/// Each slot's chosen symbol persists across launches.
struct RowIconPicker: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("sshRowIconSymbol")          private var sshIcon: String     = "terminal"
    @AppStorage("vncRowIconSymbol")          private var vncIcon: String     = "display"
    @AppStorage("scpRowIconSymbol")          private var scpIcon: String     = "arrow.up.doc.fill"
    @AppStorage("installRowIconSymbol")      private var installIcon: String = "shippingbox.fill"
    @AppStorage("quickActionsRowIconSymbol") private var qaIcon: String      = "bolt.fill"
    @AppStorage("chatRowIconSymbol")         private var chatIcon: String    = "bubble.left.and.bubble.right.fill"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    slot(title: "Remote Shell (SSH)", color: .green,
                         selection: $sshIcon, defaultValue: "terminal",
                         candidates: [
                            "terminal", "terminal.fill", "apple.terminal",
                            "chevron.left.forwardslash.chevron.right",
                            "command.circle.fill",
                         ])
                    slot(title: "Screen Share (VNC)", color: .blue,
                         selection: $vncIcon, defaultValue: "display",
                         candidates: [
                            "display", "display.2", "desktopcomputer",
                            "macwindow", "rectangle.on.rectangle",
                         ])
                    slot(title: "File Upload (SCP)", color: .orange,
                         selection: $scpIcon, defaultValue: "arrow.up.doc.fill",
                         candidates: [
                            "arrow.up.doc.fill", "doc.badge.arrow.up",
                            "square.and.arrow.up.fill", "paperplane.fill",
                            "externaldrive.fill.badge.plus",
                         ])
                    slot(title: "Install Package", color: .purple,
                         selection: $installIcon, defaultValue: "shippingbox.fill",
                         candidates: [
                            "shippingbox.fill", "shippingbox",
                            "archivebox.fill", "cube.box.fill",
                            "app.badge.fill",
                         ])
                    slot(title: "Quick Actions", color: .pink,
                         selection: $qaIcon, defaultValue: "bolt.fill",
                         candidates: [
                            "bolt.fill", "wand.and.stars", "sparkles",
                            "list.bullet.rectangle.fill",
                            "square.grid.2x2.fill",
                         ])
                    slot(title: "Chat", color: .teal,
                         selection: $chatIcon, defaultValue: "bubble.left.and.bubble.right.fill",
                         candidates: [
                            "bubble.left.and.bubble.right.fill",
                            "message.fill",
                            "ellipsis.bubble.fill",
                            "text.bubble.fill",
                            "captions.bubble.fill",
                         ])
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 620)
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack(spacing: 10) {
            // Mini live preview of all five row icons in their colors —
            // the user sees the row update behind the sheet too, but
            // this gives an at-a-glance summary.
            HStack(spacing: 6) {
                Image(systemName: sshIcon).foregroundStyle(.green)
                Image(systemName: vncIcon).foregroundStyle(.blue)
                Image(systemName: scpIcon).foregroundStyle(.orange)
                Image(systemName: installIcon).foregroundStyle(.purple)
                Image(systemName: qaIcon).foregroundStyle(.pink)
                Image(systemName: chatIcon).foregroundStyle(.teal)
            }
            .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Customize Row Icons").font(.headline)
                Text("Click any tile to swap the icon in every host row instantly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Button("Reset all to defaults") {
                sshIcon = "terminal"
                vncIcon = "display"
                scpIcon = "arrow.up.doc.fill"
                installIcon = "shippingbox.fill"
                qaIcon = "bolt.fill"
                chatIcon = "bubble.left.and.bubble.right.fill"
            }
            .controlSize(.small)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - Slot row

    @ViewBuilder
    private func slot(title: String,
                      color: Color,
                      selection: Binding<String>,
                      defaultValue: String,
                      candidates: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: selection.wrappedValue)
                    .foregroundStyle(color)
                    .frame(width: 18)
                Text(title).font(.subheadline).bold()
                Spacer()
                if selection.wrappedValue == defaultValue {
                    Text("default")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
                Text(selection.wrappedValue)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                ForEach(candidates, id: \.self) { sym in
                    tile(symbol: sym, color: color,
                         isSelected: sym == selection.wrappedValue) {
                        selection.wrappedValue = sym
                    }
                }
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2)))
    }

    @ViewBuilder
    private func tile(symbol: String, color: Color,
                      isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(isSelected ? color : Color.primary.opacity(0.85))
                    .frame(height: 36)
                Text(symbol)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 100, height: 70)
            .padding(4)
            .background(Color(NSColor.textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? color : Color.secondary.opacity(0.25),
                                lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help(symbol)
    }
}
