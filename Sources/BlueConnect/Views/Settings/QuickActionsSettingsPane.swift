import SwiftUI

/// Settings → Quick Actions. Two responsibilities:
///   1. Show every built-in Quick Action with a toggle so the user can
///      hide ones they never use (clears them out of both the right-
///      click menu and the top-level Quick Actions menu).
///   2. Manage user-defined custom actions — Add… opens a sheet with a
///      label / category / icon / shell command form; Delete removes
///      the row from the persisted JSON.
struct QuickActionsSettingsPane: View {
    @EnvironmentObject private var quickActions: QuickActionStore
    @State private var showingAddSheet = false

    var body: some View {
        Form {
            recentsSection
            builtInsSection
            customSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAddSheet) {
            CustomQuickActionEditor { draft in
                quickActions.addCustom(draft)
            }
        }
    }

    // MARK: - Recents

    @ViewBuilder
    private var recentsSection: some View {
        Section {
            Stepper(
                "Show \(quickActions.recentLimit) recent action\(quickActions.recentLimit == 1 ? "" : "s") at the top of Quick Actions menus",
                value: Binding(
                    get: { quickActions.recentLimit },
                    set: { quickActions.recentLimit = max(0, min(20, $0)) }
                ),
                in: 0...20
            )
            HStack {
                Text("0 hides the Recent section entirely.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear recents") {
                    quickActions.recentIDs = []
                }
                .disabled(quickActions.recentIDs.isEmpty)
            }
        } header: {
            Text("Recents")
        }
    }

    // MARK: - Built-ins

    @ViewBuilder
    private var builtInsSection: some View {
        Text("Built-in actions")
            .font(.subheadline).bold().foregroundStyle(.secondary)
        Text("Toggle off any action you don't want to see in the right-click menu or the Quick Actions menu in the menu bar. Settings persist per-Mac.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(Array(builtInGroups.enumerated()), id: \.offset) { entry in
            DisclosureGroup(entry.element.0) {
                ForEach(entry.element.1) { action in
                    builtInRow(action)
                }
            }
        }
    }

    private var builtInGroups: [(String, [QuickAction])] {
        var byCat: [String: [QuickAction]] = [:]
        for a in QuickAction.all {
            byCat[a.category.rawValue, default: []].append(a)
        }
        // Categories alphabetized for findability — the original
        // declaration order (in QuickAction.all) tracked code
        // history, not user intent, and made specific actions
        // hard to locate when the toggle list grew long. Actions
        // within each category stay in declaration order so e.g.
        // FileVault: status-y reads / rotate-key / remove-user
        // keep their logical-severity ordering.
        return byCat.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { ($0, byCat[$0] ?? []) }
    }

    private func builtInRow(_ action: QuickAction) -> some View {
        HStack(spacing: 8) {
            Image(systemName: action.icon)
                .foregroundStyle(action.isDestructive ? Color.orange : Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.label).font(.callout)
                if action.isDestructive {
                    Text("Destructive")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { quickActions.isEnabled(action.id) },
                set: { _ in quickActions.toggleEnabled(action.id) }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Custom

    @ViewBuilder
    private var customSection: some View {
        HStack {
            Text("Custom actions")
                .font(.subheadline).bold().foregroundStyle(.secondary)
            Spacer()
            Button {
                showingAddSheet = true
            } label: {
                Label("Add Custom Action…", systemImage: "plus.circle")
            }
        }
        Text("User-defined shell commands that run on the targeted host via SSH. The command is sent as-is — quote your own arguments and add `sudo` if you need it.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if quickActions.customActions.isEmpty {
            Text("No custom actions yet.")
                .font(.caption).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            ForEach(quickActions.customActions) { custom in
                customRow(custom)
            }
        }
    }

    private func customRow(_ custom: CustomQuickAction) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: custom.icon.isEmpty ? "terminal" : custom.icon)
                .foregroundStyle(custom.isDestructive ? Color.orange : Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(custom.label).font(.callout)
                    Text(custom.category)
                        .font(.caption2)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                    if custom.isDestructive {
                        Text("Destructive")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                Text(custom.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                quickActions.removeCustom(id: custom.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Delete this custom action")
        }
        .padding(.vertical, 2)
    }
}

/// Modal form for creating a custom Quick Action. Intentionally simpler
/// than the built-in shape — no parameter fields, just a static shell
/// command. Users who need a parameter dialog should propose adding a
/// new built-in via a PR.
struct CustomQuickActionEditor: View {
    let onAdd: (CustomQuickAction) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var label: String = ""
    @State private var category: String = "Custom"
    @State private var icon: String = "wand.and.stars"
    @State private var command: String = ""
    @State private var isDestructive: Bool = false
    @State private var help: String = ""

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty
            && !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 520, height: 440)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("New Custom Quick Action").font(.headline)
                Text("Runs the shell command on the targeted host via SSH")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var form: some View {
        Form {
            TextField("Label", text: $label,
                      prompt: Text(verbatim: "Reset DNS cache"))
                .help("Shown in the menu. Keep it short.")
            TextField("Category", text: $category,
                      prompt: Text(verbatim: "Custom"))
                .help("Menus group actions by category. Use \"Custom\" or invent your own — \"Audits\", \"One-offs\", etc.")
            TextField("SF Symbol icon", text: $icon,
                      prompt: Text(verbatim: "wand.and.stars"))
                .help("Any SF Symbol name. Examples: terminal, wand.and.stars, hammer, sparkles, bolt.fill")
            TextField("Help text (optional)", text: $help,
                      prompt: Text(verbatim: "Flushes mDNSResponder cache"))
            Toggle("Destructive — show confirmation banner in the sheet",
                   isOn: $isDestructive)
            VStack(alignment: .leading, spacing: 4) {
                Text("Shell command")
                    .font(.callout)
                TextEditor(text: $command)
                    .font(.callout.monospaced())
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3)))
                Text("Runs on the host as the configured Default remote user. Include `sudo` if you need it. Quote your own arguments — the command is sent unmodified.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add") {
                let draft = CustomQuickAction(
                    label: label.trimmingCharacters(in: .whitespaces),
                    category: category.trimmingCharacters(in: .whitespaces),
                    icon: icon.trimmingCharacters(in: .whitespaces),
                    command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                    isDestructive: isDestructive,
                    help: help.isEmpty ? nil : help
                )
                onAdd(draft)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
