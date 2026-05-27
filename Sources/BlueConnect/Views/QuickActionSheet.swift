import SwiftUI
import AppKit

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
    /// BSC host context — non-nil for the host-row right-click path,
    /// nil for the local-network sidebar path. Used to power dynamic
    /// pickers that need the host's serial (e.g. `.mrLocalUsers`).
    let hostContext: BlueSkyHost?

    /// Convenience init used by the existing BSC-host call sites.
    init(host: BlueSkyHost, action: QuickAction, onRun: @escaping (String) -> Void) {
        self.targetName = host.displayName
        self.action = action
        self.onRun = onRun
        self.hostContext = host
    }

    /// Init used by the local-network sidebar's Quick Actions submenu.
    init(targetName: String, action: QuickAction, onRun: @escaping (String) -> Void) {
        self.targetName = targetName
        self.action = action
        self.onRun = onRun
        self.hostContext = nil
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @State private var values: [String: String] = [:]
    /// Flips true for ~1.5s after the user clicks-to-copy so the icon
    /// can briefly swap to a checkmark — the only feedback the user
    /// gets that the clipboard actually changed.
    @State private var justCopied: Bool = false
    /// MunkiReport local_users for the target host, fetched lazily when
    /// any field declares `.mrLocalUsers` as its data source. Stays nil
    /// until the fetch completes — gates the picker rendering.
    @State private var mrUsers: [MRUser]?
    @State private var mrUsersLoading: Bool = false
    /// True when the operator clicked "Other (type name)…" in the MR
    /// user picker. Sticks until they pick a real user again — gates
    /// the inline custom-text-field's render so it doesn't disappear
    /// the instant the binding goes empty.
    @State private var mrUsersUseCustom: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            if action.id == "setHostname" {
                Divider()
                HostnamePreview(raw: values["name"] ?? "",
                                scope: values["scope"] ?? "all")
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
            // Collapsed-by-default helper-install reminder for Large
            // Type / Notify User. Slotted below the form (so the
            // parameter inputs stay above the fold) and above the
            // command preview.
            helperHintDisclosure
            Divider()
            preview
            Divider()
            footer
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            primeDefaults()
            loadDynamicSources()
        }
    }

    /// Kicks off async fetches for any field that declares a runtime
    /// data source. Currently just `.mrLocalUsers`. Silent failure —
    /// the field renders as a regular text input when nothing comes back.
    private func loadDynamicSources() {
        guard action.fields.contains(where: { $0.dataSource == .mrLocalUsers }),
              let host = hostContext,
              let serial = host.serialnum?.trimmingCharacters(in: .whitespaces),
              !serial.isEmpty,
              settings.isMunkiReportAPIConfigured
        else { return }
        mrUsersLoading = true
        Task {
            defer { mrUsersLoading = false }
            do {
                let inv = try await MunkiReportClient().fetchHost(serial: serial, settings: settings)
                await MainActor.run { mrUsers = inv.users ?? [] }
            } catch {
                // Silent — falls back to text input. The picker only
                // appears if we got a non-empty list.
                await MainActor.run { mrUsers = [] }
            }
        }
    }

    /// Live preview of what each of macOS's three hostname slots will
    /// resolve to as the user types. The ComputerName slot accepts the
    /// raw input as-is; LocalHostName and HostName get the same sanitize
    /// pipeline the remote shell command applies — `tr -c 'A-Za-z0-9-'
    /// '-' | tr -s '-' | sed 's/^-*//;s/-*$//'` — replicated in Swift so
    /// the operator can confirm the final names before running.
    // hostname preview is now `HostnamePreview` (Views/QuickActions/
    // HostnamePreview.swift) — shared with the browser window so both
    // surfaces show the same live preview.

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
                // Markdown rendering: bare URLs become clickable, **bold**
                // and `inline code` render the way the catalog author
                // typed them, and bullet lists align without depending on
                // monospaced-space tricks (which broke when SwiftUI's
                // proportional caption font collapsed the alignment).
                Text(.init(help))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let cmd = action.copyableCommand, !cmd.isEmpty {
                copyableCommandBlock(cmd)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// Tucked under a collapsed DisclosureGroup below the parameter
    /// form. Used by Large Type / Notify User to surface the helper
    /// install paths without taking up sheet real estate by default.
    /// Closed-by-default because the operator usually has the helper
    /// installed already and doesn't need to read it every time.
    @ViewBuilder
    private var helperHintDisclosure: some View {
        if Self.needsGuiHelperHint(actionID: action.id) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "wand.and.rays")
                            .foregroundStyle(.orange)
                        Text(.init("**Requires either:**\n\n1. **Quick Action** — \"Setup: Install GUI Helper\"\n2. **Package Install** — [BlueConnectHelper.pkg](https://github.com/echoparkbaby/BlueConnect-Admin/releases/latest/download/BlueConnectHelper.pkg)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } label: {
                Label("Helper install details", systemImage: "wand.and.rays")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    /// Set of action IDs whose runtime dispatch goes through the GUI
    /// Helper inbox. Add new GUI-only actions here so the warning
    /// banner picks them up automatically.
    private static let guiHelperActionIDs: Set<String> = [
        "largeTypeShow", "notifyUser"
    ]

    private static func needsGuiHelperHint(actionID: String) -> Bool {
        guiHelperActionIDs.contains(actionID)
    }

    /// Bordered monospaced block showing `cmd` with a Copy button in
    /// the top-right corner. Used for long-form one-liners (uninstall
    /// recipes etc.) that the catalog author wants the operator to
    /// paste into a terminal — not run via this sheet. Visually
    /// distinct from the "Will run on" preview at the bottom so the
    /// operator can't confuse "click Run on this" with "copy this and
    /// paste it elsewhere."
    @ViewBuilder
    private func copyableCommandBlock(_ cmd: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(cmd)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.3))
            )
        }
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
        // Dynamic-data-source field: render as a picker when the fetch
        // returned a usable list, otherwise fall through to the kind's
        // normal rendering. `.mrLocalUsersWithAuto` adds a "Console
        // user (auto)" sentinel option at the top.
        switch field.dataSource {
        case .mrLocalUsers, .mrLocalUsersWithAuto:
            if let users = mrUsers, !users.isEmpty {
                mrUsersPicker(field: field, binding: binding, users: users,
                              includeAutoSentinel: field.dataSource == .mrLocalUsersWithAuto)
            } else {
                staticField(field: field, binding: binding)
            }
        case .none:
            staticField(field: field, binding: binding)
        }
    }

    @ViewBuilder
    private func mrUsersPicker(field: QuickAction.Field,
                               binding: Binding<String>,
                               users: [MRUser],
                               includeAutoSentinel: Bool = false) -> some View {
        // Admin accounts first (helps `ladmin` jump to the top), then
        // by UID. Adds an "Other…" sentinel so the operator can still
        // type a name MR doesn't know about.
        let sorted = users.sorted { a, b in
            let aAdm = a.admin?.isOn ?? false
            let bAdm = b.admin?.isOn ?? false
            if aAdm != bAdm { return aAdm && !bAdm }
            return (a.uid ?? Int.max) < (b.uid ?? Int.max)
        }
        let otherSentinel = "__other__"
        let autoSentinel  = QuickAction.autoConsoleUserSentinel
        let isOther = mrUsersUseCustom
                   || (!binding.wrappedValue.isEmpty
                       && binding.wrappedValue != autoSentinel
                       && !sorted.contains { $0.shortName == binding.wrappedValue })
        let pickerBinding = Binding<String>(
            get: {
                if isOther { return otherSentinel }
                if includeAutoSentinel, binding.wrappedValue == autoSentinel {
                    return autoSentinel
                }
                if binding.wrappedValue.isEmpty { return "" }
                if sorted.contains(where: { $0.shortName == binding.wrappedValue }) {
                    return binding.wrappedValue
                }
                return otherSentinel
            },
            set: { newVal in
                if newVal == otherSentinel {
                    mrUsersUseCustom = true
                    if sorted.contains(where: { $0.shortName == binding.wrappedValue })
                        || binding.wrappedValue == autoSentinel {
                        binding.wrappedValue = ""
                    }
                } else {
                    mrUsersUseCustom = false
                    binding.wrappedValue = newVal
                }
            }
        )
        LabeledContent(field.label) {
            HStack(spacing: 6) {
                Picker("", selection: pickerBinding) {
                    if includeAutoSentinel {
                        Text("Current console user (auto)").tag(autoSentinel)
                        Divider()
                    } else {
                        Text("Select user…").tag("")
                    }
                    ForEach(sorted) { u in
                        let suffix: String = {
                            var parts: [String] = []
                            if let r = u.realname, !r.isEmpty, r != u.shortName { parts.append(r) }
                            if u.admin?.isOn ?? false { parts.append("admin") }
                            return parts.isEmpty ? "" : " — \(parts.joined(separator: ", "))"
                        }()
                        Text("\(u.shortName)\(suffix)").tag(u.shortName)
                    }
                    Divider()
                    Text("Other (type name)…").tag(otherSentinel)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 320, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
        if isOther {
            LabeledContent("Custom short name") {
                HStack(spacing: 6) {
                    TextField("", text: binding,
                              prompt: Text(verbatim: field.placeholder))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func staticField(field: QuickAction.Field,
                             binding: Binding<String>) -> some View {
        switch field.kind {
        case .text:
            LabeledContent(field.label) {
                HStack(spacing: 6) {
                    // Empty title + explicit `prompt:` so the placeholder
                    // renders INSIDE the field, not as a trailing label
                    // outside the rounded box.
                    TextField("", text: binding,
                              prompt: Text(verbatim: field.placeholder))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    if field.dataSource == .mrLocalUsers, mrUsersLoading {
                        ProgressView().controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
            }
        case .secure:
            LabeledContent(field.label) {
                HStack(spacing: 6) {
                    SecureField("", text: binding,
                                prompt: Text(verbatim: field.placeholder))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    Spacer(minLength: 0)
                }
            }
        case .picker(let options):
            // Wrap in LabeledContent (same shape as the text + secure
            // rows above) so the label column stays consistent and the
            // picker control can be capped without stretching.
            LabeledContent(field.label) {
                HStack(spacing: 6) {
                    Picker("", selection: binding) {
                        ForEach(options) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320, alignment: .leading)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Will run on \(targetName):")
                .font(.caption).foregroundStyle(.secondary)
            // Scrollable preview box. Long install commands (GUI Helper +
            // chat client) span 30+ lines once the embedded payloads are
            // elided, so a fixed-height ScrollView avoids the sheet
            // ballooning while still letting the operator read every
            // line. Click anywhere on the box to copy; drag-select also
            // works because `.textSelection(.enabled)` claims drags
            // before the tap gesture fires.
            ScrollView([.vertical, .horizontal]) {
                Text(previewCommand)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .padding(.trailing, 22) // breathing room for the overlay icon
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 80, maxHeight: 220)
            .background(Color(NSColor.textBackgroundColor))
            .overlay(alignment: .topTrailing) {
                Button {
                    copyCommandToPasteboard()
                } label: {
                    Image(systemName: justCopied
                          ? "checkmark.circle.fill"
                          : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(justCopied ? .green : .secondary)
                        .padding(5)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help(justCopied ? "Copied" : "Copy command to clipboard")
                .padding(4)
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            .contentShape(Rectangle())
            .onTapGesture { copyCommandToPasteboard() }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// Writes a human-readable form of the command to the clipboard
    /// (long base64 blobs elided) and flashes the checkmark feedback.
    /// Some install actions embed a 300KB+ binary inline as base64 —
    /// pasting that into a terminal works, but it's unreadable and
    /// pollutes the clipboard. The full command goes through SSH at
    /// Run time; this is just the operator's-eyes copy.
    private func copyCommandToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Self.sanitizeForDisplay(action.buildCommand(values)), forType: .string)
        justCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { justCopied = false }
        }
    }

    /// The actual command, but with secure fields masked AND any
    /// embedded base64 blobs elided, so the operator can sanity-check
    /// the shape without scrolling through 5,000 lines of binary data
    /// (or leaking the password into the preview pane / a screenshot).
    private var previewCommand: String {
        var masked = values
        for f in action.fields where f.kind == .secure {
            if !(masked[f.id] ?? "").isEmpty { masked[f.id] = "••••••••" }
        }
        return Self.sanitizeForDisplay(action.buildCommand(masked))
    }

    /// Replace long base64 runs with a placeholder so the install
    /// commands that embed binary payloads inline (GUI Helper + chat
    /// client) stay readable. Real Run path uses the un-sanitized
    /// command; this is display + copy only.
    ///
    /// Heuristic: any run of 200+ base64 characters (A-Z, a-z, 0-9,
    /// +, /) optionally followed by `=` padding. The threshold is
    /// well above any legitimately-pasted base64 token (e.g. a
    /// 32-byte API key encodes to 44 chars).
    private static let base64BlobRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "[A-Za-z0-9+/]{200,}={0,2}")
    }()

    static func sanitizeForDisplay(_ command: String) -> String {
        let nsCommand = command as NSString
        let range = NSRange(location: 0, length: nsCommand.length)
        let matches = base64BlobRegex.matches(in: command, range: range)
        guard !matches.isEmpty else { return command }
        var out = command
        // Apply from last to first so earlier ranges stay valid.
        for match in matches.reversed() {
            guard let r = Range(match.range, in: out) else { continue }
            let lenBytes = out.distance(from: r.lowerBound, to: r.upperBound)
            let kb = max(1, lenBytes / 1024)
            out.replaceSubrange(r, with: "<\(kb)KB base64 binary payload elided — full content is sent over SSH at Run time>")
        }
        return out
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Run", role: action.isDestructive ? .destructive : nil) {
                QuickActionDefaults.save(actionID: action.id,
                                         values: values,
                                         fields: action.fields)
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
        // Memorised last-used values win over the action's static
        // defaults — so a user who customised the Large Type colour
        // doesn't re-pick the same colour every time. Secure fields
        // are intentionally NOT persisted (see QuickActionDefaults).
        let remembered = QuickActionDefaults.load(actionID: action.id)
        for f in action.fields where values[f.id] == nil {
            if let saved = remembered[f.id], !saved.isEmpty {
                values[f.id] = saved
            } else {
                values[f.id] = f.defaultValue
            }
        }
    }
}
