import SwiftUI

/// Field-driven sheet for the canned admin actions in `QuickAction.all`.
/// Renders one row per declared field (text / secure / picker), shows a
/// live command preview, runs on confirm.
struct QuickActionSheet: View {
    /// Display name shown in the header ("on \(targetName)"). Decoupled
    /// from BlueSkyHost so local-network sidebar rows can present the
    /// same sheet against a Bonjour/Tailscale peer name.
    let targetName: String
    let action: QuickAction
    let onRun: (String) -> Void  // receives the fully-built shell command

    /// Convenience init used by the existing BSC-host call sites.
    init(host: BlueSkyHost, action: QuickAction, onRun: @escaping (String) -> Void) {
        self.targetName = host.displayName
        self.action = action
        self.onRun = onRun
    }

    /// Init used by the local-network sidebar's Quick Actions submenu.
    init(targetName: String, action: QuickAction, onRun: @escaping (String) -> Void) {
        self.targetName = targetName
        self.action = action
        self.onRun = onRun
    }

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            if action.id == "setHostname" {
                Divider()
                hostnamePreview
            }
            Divider()
            preview
            Divider()
            footer
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { primeDefaults() }
    }

    /// Live preview of what each of macOS's three hostname slots will
    /// resolve to as the user types. The ComputerName slot accepts the
    /// raw input as-is; LocalHostName and HostName get the same sanitize
    /// pipeline the remote shell command applies — `tr -c 'A-Za-z0-9-'
    /// '-' | tr -s '-' | sed 's/^-*//;s/-*$//'` — replicated in Swift so
    /// the operator can confirm the final names before running.
    private var hostnamePreview: some View {
        let raw = values["name"] ?? ""
        let scope = values["scope"] ?? "all"
        let safe = Self.sanitizeForBSDHostname(raw)
        let willTouchCN = scope == "all" || scope == "computer"
        let willTouchLH = scope == "all" || scope == "local"
        let willTouchHN = scope == "all" || scope == "host"

        return VStack(alignment: .leading, spacing: 6) {
            Text("Resolved names:")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                hostnamePreviewRow("ComputerName", value: raw,
                                   active: willTouchCN,
                                   isEmpty: raw.isEmpty,
                                   note: "Friendly name. Spaces and special characters OK.")
                hostnamePreviewRow("LocalHostName", value: safe,
                                   active: willTouchLH,
                                   isEmpty: safe.isEmpty,
                                   suffix: ".local",
                                   note: "Bonjour. Sanitized to A–Z, 0–9, hyphens.")
                hostnamePreviewRow("HostName", value: safe,
                                   active: willTouchHN,
                                   isEmpty: safe.isEmpty,
                                   note: "BSD / terminal prompt. Same sanitize.")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder
    private func hostnamePreviewRow(_ label: String,
                                    value: String,
                                    active: Bool,
                                    isEmpty: Bool,
                                    suffix: String = "",
                                    note: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(active ? .primary : .secondary)
            HStack(spacing: 4) {
                // Concatenate value + suffix into a single Text so the
                // ".local" / etc. renders flush against the name with no
                // inter-Text gap — HStack adds a spacing pt between
                // sibling Texts that looked like an unwanted space.
                ((Text(isEmpty ? "—" : value)
                    .foregroundStyle(active
                                     ? (isEmpty ? AnyShapeStyle(HierarchicalShapeStyle.secondary)
                                                : AnyShapeStyle(HierarchicalShapeStyle.primary))
                                     : AnyShapeStyle(Color.secondary.opacity(0.5))))
                 + (suffix.isEmpty
                    ? Text("")
                    : Text(suffix).foregroundStyle(.secondary)))
                    .font(.callout.monospaced())
                if !active {
                    Text("· unchanged")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(note)
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Swift port of the sanitize pipeline the shell command applies —
    /// keeps the preview honest. Steps: 1) replace anything outside
    /// `[A-Za-z0-9-]` with `-`; 2) collapse runs of `-` to a single one;
    /// 3) trim leading/trailing `-`.
    private static func sanitizeForBSDHostname(_ raw: String) -> String {
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: action.icon)
                    .font(.title3)
                    .foregroundStyle(action.isDestructive ? Color.orange : Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.label).font(.headline)
                    Text("on \(targetName)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let help = action.help, !help.isEmpty {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder
    private var form: some View {
        if action.fields.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: action.isDestructive
                                  ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(action.isDestructive ? .orange : .secondary)
                Text(action.isDestructive
                     ? "This is a destructive command — confirm before running."
                     : "No parameters needed. Click Run to execute on the host.")
                    .font(.callout)
            }
            .padding(16)
        } else {
            Form {
                ForEach(action.fields) { field in
                    fieldRow(field)
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: QuickAction.Field) -> some View {
        let binding = Binding<String>(
            get: { values[field.id] ?? "" },
            set: { values[field.id] = $0 }
        )
        switch field.kind {
        case .text:
            LabeledContent(field.label) {
                // Empty title + explicit `prompt:` so the placeholder
                // renders INSIDE the field, not as a trailing label
                // outside the rounded box (which is what TextField's
                // first-arg overload does in a macOS Form).
                TextField("", text: binding,
                          prompt: Text(verbatim: field.placeholder))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
            }
        case .secure:
            LabeledContent(field.label) {
                SecureField("", text: binding,
                            prompt: Text(verbatim: field.placeholder))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
            }
        case .picker(let options):
            Picker(field.label, selection: binding) {
                ForEach(options) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Will run on \(targetName):")
                .font(.caption).foregroundStyle(.secondary)
            Text(previewCommand)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                .lineLimit(4).truncationMode(.middle)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// The actual command, but with secure fields masked so the operator
    /// can sanity-check the shape without leaking the password into the
    /// preview pane (or the screenshot they're about to send me).
    private var previewCommand: String {
        var masked = values
        for f in action.fields where f.kind == .secure {
            if !(masked[f.id] ?? "").isEmpty { masked[f.id] = "••••••••" }
        }
        return action.buildCommand(masked)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Run", role: action.isDestructive ? .destructive : nil) {
                onRun(action.buildCommand(values))
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!hasRequiredValues)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// Block Run while any non-secure required text/picker field is
    /// blank. Secure fields are allowed empty (matching how some sudo
    /// flows accept empty admin passwords on test rigs).
    private var hasRequiredValues: Bool {
        for f in action.fields {
            if case .secure = f.kind { continue }
            if (values[f.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
        }
        return true
    }

    private func primeDefaults() {
        for f in action.fields where values[f.id] == nil {
            values[f.id] = f.defaultValue
        }
    }
}
