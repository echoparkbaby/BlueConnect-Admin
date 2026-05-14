import SwiftUI

/// Field-driven sheet for the canned admin actions in `QuickAction.all`.
/// Renders one row per declared field (text / secure / picker), shows a
/// live command preview, runs on confirm.
struct QuickActionSheet: View {
    let host: BlueSkyHost
    let action: QuickAction
    let onRun: (String) -> Void  // receives the fully-built shell command

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            preview
            Divider()
            footer
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { primeDefaults() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: action.icon)
                    .font(.title3)
                    .foregroundStyle(action.isDestructive ? Color.orange : Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.label).font(.headline)
                    Text("on \(host.displayName)").font(.caption).foregroundStyle(.secondary)
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
                TextField(field.placeholder, text: binding)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
            }
        case .secure:
            LabeledContent(field.label) {
                SecureField(field.placeholder, text: binding)
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
            Text("Will run on \(host.displayName):")
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
