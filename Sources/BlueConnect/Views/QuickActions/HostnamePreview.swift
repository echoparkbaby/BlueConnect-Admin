import SwiftUI
import AppKit

/// Live preview card for the Set Computer Name action: shows what each
/// of macOS's three hostname slots (ComputerName / LocalHostName /
/// HostName) will be set to, given the operator's typed name and the
/// chosen scope. Used in both the per-host right-click sheet
/// (`QuickActionSheet`) and the standalone browser window
/// (`QuickActionsBrowserWindow`).
///
/// `raw` is the unsanitized text the operator typed; `scope` is one of
/// `"all"`, `"computer"`, `"local"`, `"host"` (matching the picker
/// values in the setHostname QuickAction).
struct HostnamePreview: View {
    let raw: String
    let scope: String

    var body: some View {
        let safe = Self.sanitizeForBSDHostname(raw)
        let willTouchCN = scope == "all" || scope == "computer"
        let willTouchLH = scope == "all" || scope == "local"
        let willTouchHN = scope == "all" || scope == "host"

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "tag").foregroundStyle(.tint)
                Text("Will set:").font(.subheadline).bold()
            }
            VStack(alignment: .leading, spacing: 4) {
                row("ComputerName",
                    value: raw, active: willTouchCN, isEmpty: raw.isEmpty,
                    note: "Friendly name — spaces + special chars OK")
                row("LocalHostName",
                    value: safe, active: willTouchLH, isEmpty: safe.isEmpty,
                    suffix: ".local",
                    note: "Bonjour — sanitized to A–Z, 0–9, hyphens")
                row("HostName",
                    value: safe, active: willTouchHN, isEmpty: safe.isEmpty,
                    note: "BSD / terminal prompt — same sanitize")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25)))
        }
    }

    @ViewBuilder
    private func row(_ label: String,
                     value: String,
                     active: Bool,
                     isEmpty: Bool,
                     suffix: String = "",
                     note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.caption.monospaced())
                    .foregroundStyle(active ? .secondary : Color.secondary.opacity(0.5))
                    .frame(width: 110, alignment: .leading)
                ((Text(isEmpty ? "—" : value)
                    .foregroundStyle(active
                                     ? (isEmpty ? AnyShapeStyle(HierarchicalShapeStyle.secondary)
                                                : AnyShapeStyle(HierarchicalShapeStyle.primary))
                                     : AnyShapeStyle(Color.secondary.opacity(0.5))))
                 + (suffix.isEmpty
                    ? Text("")
                    : Text(suffix).foregroundStyle(.secondary)))
                    .font(.callout.monospaced().bold())
                Spacer(minLength: 0)
                if !active {
                    Text("unchanged")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            Text(note)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 118)
        }
    }

    /// Swift port of the shell sanitize pipeline the setHostname
    /// QuickAction runs (`tr -c 'A-Za-z0-9-' '-' | tr -s '-' | sed 's/^-*//;s/-*$//'`).
    /// Steps: 1) replace any non `[A-Za-z0-9-]` char with `-`;
    /// 2) collapse runs of `-` to one; 3) trim leading/trailing `-`.
    static func sanitizeForBSDHostname(_ raw: String) -> String {
        let mapped = String(raw.map { ch -> Character in
            if ch.isASCII, (ch.isLetter || ch.isNumber || ch == "-") {
                return ch
            }
            return "-"
        })
        var collapsed = mapped
        while collapsed.contains("--") {
            collapsed = collapsed.replacingOccurrences(of: "--", with: "-")
        }
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
