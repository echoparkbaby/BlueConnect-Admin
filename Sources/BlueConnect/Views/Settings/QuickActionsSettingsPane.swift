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
    /// When non-nil, the editor sheet appears in Edit mode pre-filled
    /// from this action; saving routes through `updateCustom`. Separate
    /// from `showingAddSheet` so we can't accidentally end up in both
    /// states at once.
    @State private var editingAction: CustomQuickAction?

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                recentsSection
                builtInsSection
                customSection
                    .id("customActionsAnchor")
            }
            .formStyle(.grouped)
            .onReceive(NotificationCenter.default.publisher(for: .bcScrollSettingsToCustomActions)) { _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("customActionsAnchor", anchor: .top)
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            CustomQuickActionEditor(existing: nil) { draft in
                quickActions.addCustom(draft)
            }
        }
        .sheet(item: $editingAction) { existing in
            CustomQuickActionEditor(existing: existing) { updated in
                quickActions.updateCustom(updated)
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
                editingAction = custom
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Edit this custom action")
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

/// Modal form for creating or editing a custom Quick Action. Intentionally
/// simpler than the built-in shape — no parameter fields, just a static
/// shell command. Users who need a parameter dialog should propose adding
/// a new built-in via a PR.
///
/// Pass `existing: nil` to add a new action; pass an existing
/// `CustomQuickAction` to edit it in place. The editor's id stays stable
/// across edits so favorites and recents that reference the action keep
/// working.
struct CustomQuickActionEditor: View {
    let existing: CustomQuickAction?
    let onSubmit: (CustomQuickAction) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var label: String = ""
    @State private var category: String = "Custom"
    @State private var icon: String = "wand.and.stars"
    @State private var command: String = ""
    @State private var isDestructive: Bool = false
    @State private var help: String = ""
    @State private var showingIconPicker: Bool = false

    private var isEditing: Bool { existing != nil }

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
        .onAppear {
            // Seed the form from the existing action on first appear so
            // the @State holds the edit-mode initial values. Skipped on
            // add (existing == nil) so the new-action defaults stand.
            guard let e = existing else { return }
            label = e.label
            category = e.category
            icon = e.icon
            command = e.command
            isDestructive = e.isDestructive
            help = e.help ?? ""
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(isEditing ? "Edit Custom Quick Action" : "New Custom Quick Action")
                    .font(.headline)
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
            HStack {
                Text("Icon")
                Spacer()
                Button {
                    showingIconPicker.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon.isEmpty ? "questionmark.square" : icon)
                            .frame(width: 18)
                        Text(icon.isEmpty ? "Pick icon…" : icon)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showingIconPicker, arrowEdge: .bottom) {
                    SFSymbolGridPicker(selected: $icon) {
                        showingIconPicker = false
                    }
                }
            }
            .help("Click to pick from a curated SF Symbol grid.")
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
            Button(isEditing ? "Save" : "Add") {
                // Preserve the existing id on edit so favorites/recents
                // that reference it keep resolving. addCustom assigns a
                // fresh UUID-based id when this is empty.
                let draft = CustomQuickAction(
                    id: existing?.id ?? "",
                    label: label.trimmingCharacters(in: .whitespaces),
                    category: category.trimmingCharacters(in: .whitespaces),
                    icon: icon.trimmingCharacters(in: .whitespaces),
                    command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                    isDestructive: isDestructive,
                    help: help.isEmpty ? nil : help
                )
                onSubmit(draft)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// Popover grid for picking an SF Symbol for a custom Quick Action.
/// Curated list of admin-relevant symbols — about 80 entries grouped
/// loosely by purpose. A typed search field at the top filters live.
/// Picking a cell writes the symbol name to the bound state and calls
/// `onPick` (which closes the popover).
struct SFSymbolGridPicker: View {
    @Binding var selected: String
    let onPick: () -> Void
    @State private var query: String = ""

    private let symbols: [String] = [
        // Generic / "do something special"
        "wand.and.stars", "wand.and.rays", "sparkles", "bolt.fill", "bolt.circle.fill",
        "hammer", "hammer.fill", "wrench", "wrench.and.screwdriver", "screwdriver",
        // Terminal / shell
        "terminal", "terminal.fill", "chevron.left.forwardslash.chevron.right",
        "curlybraces", "command", "keyboard",
        // System
        "gear", "gearshape", "gearshape.fill", "gearshape.2", "switch.2",
        "power", "power.circle.fill", "arrow.clockwise", "arrow.clockwise.circle.fill",
        "arrow.triangle.2.circlepath",
        // Identity / users
        "person", "person.fill", "person.crop.circle", "person.crop.circle.badge.checkmark",
        "person.2", "person.2.fill", "person.badge.minus", "person.badge.plus",
        // Security
        "lock", "lock.fill", "lock.shield", "lock.shield.fill", "key", "key.fill",
        "checkmark.shield", "checkmark.shield.fill", "exclamationmark.shield",
        // Disk
        "internaldrive", "externaldrive", "externaldrive.fill",
        "opticaldiscdrive", "memorychip",
        // CPU / system load
        "cpu", "cpu.fill", "gauge", "speedometer", "thermometer",
        // Network
        "network", "wifi", "wifi.slash", "antenna.radiowaves.left.and.right",
        "globe", "globe.americas",
        // Communication
        "bell", "bell.fill", "envelope", "envelope.fill", "message",
        // Status
        "checkmark.circle", "checkmark.circle.fill", "xmark.circle", "xmark.circle.fill",
        "exclamationmark.triangle", "exclamationmark.triangle.fill",
        "info.circle", "info.circle.fill", "questionmark.circle",
        // Cleanup / data
        "trash", "trash.fill", "doc", "doc.text", "doc.text.fill",
        "doc.text.below.ecg", "list.bullet.rectangle", "tray",
        // Apps / packages
        "app.fill", "shippingbox", "shippingbox.fill", "cube.box", "cube.box.fill",
        // Time
        "clock", "clock.fill", "clock.arrow.circlepath", "calendar",
        // UI
        "eye", "eye.slash", "magnifyingglass", "scroll", "dock.rectangle",
    ]

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return symbols }
        return symbols.filter { $0.lowercased().contains(q) }
    }

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 4), count: 8)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary).font(.caption)
                TextField("Filter", text: $query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(filtered, id: \.self) { name in
                        Button {
                            selected = name
                            onPick()
                        } label: {
                            Image(systemName: name)
                                .font(.system(size: 18))
                                .frame(width: 34, height: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(name == selected
                                              ? Color.accentColor.opacity(0.25)
                                              : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(name == selected
                                                ? Color.accentColor
                                                : Color.clear, lineWidth: 1.5)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
                .padding(8)
            }
            .frame(height: 220)
        }
        .frame(width: 320)
    }
}
