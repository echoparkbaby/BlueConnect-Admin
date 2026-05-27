import SwiftUI
import AppKit

/// Standalone "Quick Actions Browser" window. Categorized list on the
/// left, detail pane on the right with description, parameter form, live
/// command preview, and a Run button. Polished cousin of the per-host
/// QuickActionSheet — same data model (`QuickAction.all`), different
/// presentation surface so admins can scroll the full catalog instead of
/// hunting through the menu bar.
///
/// Target host is chosen via a picker at the top of the window. Run
/// writes a `PendingRun` into `QuickActionLauncher`; ContentView watches
/// that and dispatches through the existing `runQuickAction(host:action:
/// command:)` path so output lands in a terminal tab.
///
/// **Layout note:** intentionally avoids `.toolbar`, `.searchable
/// (placement: .sidebar)`, `.navigationTitle/Subtitle`, and
/// `.navigationSplitViewColumnWidth`. On macOS 26 with a standalone
/// `Window` scene, those combine into a touch-bar KVO crash inside
/// `_NSTouchBarFinderObservation` during the display cycle. A plain
/// HStack header + a search TextField inside the sidebar List avoid the
/// crash path entirely.
struct QuickActionsBrowserWindow: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var quickActionStore: QuickActionStore
    @Environment(BlueSkyHostListStore.self) private var hostStore
    @Environment(QuickActionLauncher.self) private var launcher
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    @State private var selectedActionID: String?
    @State private var selectedHostID: Int?
    @State private var valuesByActionID: [String: [String: String]] = [:]
    @State private var search: String = ""

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            NavigationSplitView {
                sidebar
            } detail: {
                detail
            }
        }
        .frame(minWidth: 840, minHeight: 540)
        .onAppear { primeDefaultSelection() }
        // Hidden Cancel button binds ESC to close the window. SwiftUI's
        // .keyboardShortcut(.cancelAction) on any Button registers ESC
        // app-wide for whatever window holds it. Zero-size + .hidden()
        // so it doesn't render but the shortcut is live.
        .background {
            Button("") { dismissWindow(id: "quick-actions-browser") }
                .keyboardShortcut(.cancelAction)
                .hidden()
                .frame(width: 0, height: 0)
        }
    }

    // MARK: - Header bar (target picker + search)

    private var headerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("Target:")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("", selection: $selectedHostID) {
                    Text("— Select host —").tag(Int?.none)
                    let online = onlineHosts
                    let offline = offlineHosts
                    if !online.isEmpty {
                        Section("Online (\(online.count))") {
                            ForEach(online) { h in
                                HStack(spacing: 6) {
                                    Circle().fill(Color.green).frame(width: 7, height: 7)
                                    Text(h.displayName)
                                }
                                .tag(Optional(h.blueskyid))
                            }
                        }
                    }
                    if !offline.isEmpty {
                        Section("Offline (\(offline.count))") {
                            ForEach(offline) { h in
                                HStack(spacing: 6) {
                                    Circle().fill(Color.gray).frame(width: 7, height: 7)
                                    Text(h.displayName).foregroundStyle(.secondary)
                                }
                                .tag(Optional(h.blueskyid))
                            }
                        }
                    }
                }
                .labelsHidden()
                .frame(minWidth: 240, maxWidth: 360)
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter actions", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - Sidebar (categorized action list)

    private var sidebar: some View {
        List(selection: $selectedActionID) {
            // Favorites stay visible during search too — filter them by
            // the same query as the category sections so the top of the
            // sidebar isn't blank when a search matches a starred item.
            let favs = filteredFavorites
            if !favs.isEmpty {
                Section {
                    ForEach(favs) { action in
                        ActionRow(action: action,
                                  isFavorite: true).tag(action.id)
                    }
                } header: {
                    Label("Favorites", systemImage: "star.fill")
                        .foregroundStyle(.yellow)
                }
            }
            ForEach(Array(filteredGrouped.enumerated()), id: \.offset) { entry in
                Section(entry.element.0) {
                    ForEach(entry.element.1) { action in
                        ActionRow(action: action,
                                  isFavorite: quickActionStore.isFavorite(action.id))
                            .tag(action.id)
                    }
                }
            }
            if filteredGrouped.isEmpty && favs.isEmpty {
                Text(search.isEmpty
                     ? "All actions disabled — see Settings → Quick Actions"
                     : "No actions match \"\(search)\"")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detail: some View {
        if let action = selectedAction {
            // Match the row/context-menu policy: don't let the operator
            // fire a Quick Action against an inactive host (the SSH
            // tunnel is down so the command can't be delivered). Copy
            // still works — useful for prepping a command to paste
            // into a session later.
            DetailPane(
                action: action,
                values: bindingForValues(actionID: action.id),
                targetName: selectedHost?.displayName,
                canRun: selectedHost?.active == true,
                isFavorite: quickActionStore.isFavorite(action.id),
                onRun: { runSelected() },
                onCopy: { copyCommand() },
                onToggleFavorite: { quickActionStore.toggleFavorite(action.id) }
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("Pick an action from the list")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if selectedHost == nil {
                    Text("Then choose a target host above.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    private var sortedHosts: [BlueSkyHost] {
        hostStore.hosts.sorted { a, b in
            if a.active != b.active { return a.active && !b.active }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    private var onlineHosts: [BlueSkyHost] {
        hostStore.hosts.filter { $0.active }.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var offlineHosts: [BlueSkyHost] {
        hostStore.hosts.filter { !$0.active }.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var selectedHost: BlueSkyHost? {
        guard let id = selectedHostID else { return nil }
        return hostStore.hosts.first { $0.blueskyid == id }
    }

    private var selectedAction: QuickAction? {
        guard let id = selectedActionID else { return nil }
        return quickActionStore.allEnabled.actions.first { $0.id == id }
    }

    private var filteredGrouped: [(String, [QuickAction])] {
        let s = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return quickActionStore.allEnabled.grouped }
        return quickActionStore.allEnabled.grouped.compactMap { (cat, items) in
            let hits = items.filter {
                $0.label.lowercased().contains(s)
                || cat.lowercased().contains(s)
                || ($0.help?.lowercased().contains(s) ?? false)
            }
            return hits.isEmpty ? nil : (cat, hits)
        }
    }

    private var filteredFavorites: [QuickAction] {
        let s = search.trimmingCharacters(in: .whitespaces).lowercased()
        let favs = quickActionStore.allEnabled.favorites
        guard !s.isEmpty else { return favs }
        return favs.filter {
            $0.label.lowercased().contains(s)
            || ($0.help?.lowercased().contains(s) ?? false)
        }
    }

    private func bindingForValues(actionID: String) -> Binding<[String: String]> {
        Binding(
            get: {
                if let v = valuesByActionID[actionID] { return v }
                // First time this action is touched in this session —
                // seed from the persistent last-used values so picker
                // defaults reflect what the user picked last time.
                let remembered = QuickActionDefaults.load(actionID: actionID)
                return remembered
            },
            set: { valuesByActionID[actionID] = $0 }
        )
    }

    private func primeDefaultSelection() {
        if selectedHostID == nil {
            let firstOnline = hostStore.hosts.first { $0.active }
            selectedHostID = firstOnline?.blueskyid ?? hostStore.hosts.first?.blueskyid
        }
        if selectedActionID == nil {
            selectedActionID = quickActionStore.allEnabled.actions.first?.id
        }
    }

    private func runSelected() {
        guard let host = selectedHost, let action = selectedAction else { return }
        // Read through bindingForValues so we pick up the remembered
        // values even when the user hasn't touched a field this
        // session — otherwise persisted picks were silently dropped.
        let v = bindingForValues(actionID: action.id).wrappedValue
        QuickActionDefaults.save(actionID: action.id, values: v, fields: action.fields)
        let command = action.buildCommand(v)
        // Ensure the main window (which consumes pendingRun via
        // .onChange / .task) is open. If it was closed, this also
        // gives ContentView a chance to mount and pick up the
        // pendingRun we're about to set.
        openWindow(id: "main")
        launcher.pendingRun = .init(host: host, action: action, command: command)
    }

    private func copyCommand() {
        guard let action = selectedAction else { return }
        let v = bindingForValues(actionID: action.id).wrappedValue
        let command = action.buildCommand(v)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(command, forType: .string)
    }
}

// MARK: - Sidebar row

private struct ActionRow: View {
    let action: QuickAction
    let isFavorite: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: action.icon)
                .frame(width: 18)
                .foregroundStyle(action.isDestructive ? Color.orange : Color.accentColor)
            Text(action.label).lineLimit(1)
            Spacer(minLength: 0)
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
            if action.isDestructive {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Detail pane

private struct DetailPane: View {
    let action: QuickAction
    @Binding var values: [String: String]
    let targetName: String?
    let canRun: Bool
    let isFavorite: Bool
    let onRun: () -> Void
    let onCopy: () -> Void
    let onToggleFavorite: () -> Void

    /// Flashes the inline copy-icon to a checkmark for ~1.5s after the
    /// user clicks-to-copy.
    @State private var justCopied: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let help = action.help, !help.isEmpty {
                    // Same Markdown rendering pattern as
                    // QuickActionSheet — clickable URLs, bullet
                    // alignment, selectable for copy.
                    Text(.init(help))
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !action.fields.isEmpty {
                    fields
                }
                if action.id == "setHostname" {
                    HostnamePreview(raw: values["name"] ?? "",
                                    scope: values["scope"] ?? "all")
                }
                commandPreview
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .onAppear { primeDefaults() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: action.icon)
                .font(.system(size: 28))
                .foregroundStyle(action.isDestructive ? Color.orange : Color.accentColor)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.label).font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Text(action.category.rawValue)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                    if action.isDestructive {
                        Label("Destructive", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Button {
                onToggleFavorite()
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
    }

    @ViewBuilder
    private var fields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Parameters").font(.caption).foregroundStyle(.secondary)
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
                TextField("", text: binding, prompt: Text(verbatim: field.placeholder))
                    .textFieldStyle(.roundedBorder)
            }
        case .secure:
            LabeledContent(field.label) {
                SecureField("", text: binding, prompt: Text(verbatim: field.placeholder))
                    .textFieldStyle(.roundedBorder)
            }
        case .picker(let options):
            Picker(field.label, selection: binding) {
                ForEach(options) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
        }
    }

    private var commandPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Command")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: true) {
                Text(maskedCommand)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .padding(.trailing, 28) // breathing room for the overlay icon
                    .frame(minWidth: 100, alignment: .leading)
            }
            .background(Color(NSColor.textBackgroundColor))
            .overlay(alignment: .topTrailing) {
                Button {
                    flashAndCopy()
                } label: {
                    Image(systemName: justCopied
                          ? "checkmark.circle.fill"
                          : "doc.on.doc")
                        .font(.callout)
                        .foregroundStyle(justCopied ? .green : .secondary)
                        .padding(6)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help(justCopied ? "Copied" : "Copy command to clipboard")
                .padding(6)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3))
            )
            .frame(maxHeight: 180)
            .contentShape(Rectangle())
            .onTapGesture { flashAndCopy() }
        }
    }

    /// Calls the parent's copy callback AND flips the local feedback
    /// state for the brief checkmark flash. Keeps the click-anywhere
    /// and tiny-icon paths in sync.
    private func flashAndCopy() {
        onCopy()
        justCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { justCopied = false }
        }
    }

    private var maskedCommand: String {
        var masked = values
        for f in action.fields where f.kind == .secure {
            if !(masked[f.id] ?? "").isEmpty { masked[f.id] = "••••••••" }
        }
        return action.buildCommand(masked)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button {
                onCopy()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy the command to the clipboard")

            Button(role: action.isDestructive ? .destructive : nil) {
                onRun()
            } label: {
                if let name = targetName {
                    Text("Run on \(name)")
                } else {
                    Text("Run")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canRun || !hasRequiredValues)
            .help(canRun ? "Run the command on the selected host"
                         : "Pick a target host at the top of the window first")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
    }

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
