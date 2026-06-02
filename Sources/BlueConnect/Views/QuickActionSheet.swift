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
    /// Receives the fully-built shell command plus the raw `values`
    /// dict the user filled in. Most receivers ignore `values` and
    /// just dispatch the command; the setHostname path uses it to
    /// also push the new name to BSC's `bs_host_update.json.php` so
    /// the server-side record matches what scutil now reports — the
    /// BSC agent only POSTs hostname during initial registration, so
    /// without this side-channel the DB stays stale forever.
    let onRun: (String, [String: String]) -> Void
    /// Optional: when non-nil, the sheet renders a secondary "Run in
    /// existing tab" button alongside the primary Run button. Same
    /// signature as `onRun` — receiver writes the command into the
    /// already-open shell session for the target host instead of
    /// spawning a new SSH tab. nil → button is hidden.
    let onRunInExistingTab: ((String, [String: String]) -> Void)?
    /// Display name for the existing session — shows up in the
    /// secondary button label and a small note above it so the
    /// operator can verify which tab they're about to inject into.
    let existingTabTitle: String?
    /// BSC host context — non-nil for the host-row right-click path,
    /// nil for the local-network sidebar path. Used to power dynamic
    /// pickers that need the host's serial (e.g. `.mrLocalUsers`).
    let hostContext: BlueSkyHost?

    /// Convenience init used by the existing BSC-host call sites.
    init(host: BlueSkyHost,
         action: QuickAction,
         existingTabTitle: String? = nil,
         onRun: @escaping (String, [String: String]) -> Void,
         onRunInExistingTab: ((String, [String: String]) -> Void)? = nil) {
        self.targetName = host.displayName
        self.action = action
        self.onRun = onRun
        self.onRunInExistingTab = onRunInExistingTab
        self.existingTabTitle = existingTabTitle
        self.hostContext = host
    }

    /// Init used by the local-network sidebar's Quick Actions submenu.
    init(targetName: String,
         action: QuickAction,
         onRun: @escaping (String, [String: String]) -> Void) {
        self.targetName = targetName
        self.action = action
        self.onRun = onRun
        self.onRunInExistingTab = nil
        self.existingTabTitle = nil
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
            // Single collapsed-by-default "Details" chevron carrying
            // BOTH the helper-install reminder (when applicable) and
            // the "Will run on …" command preview. Most operators
            // don't need to read either every time they click Run;
            // tucking them behind a chevron keeps the sheet compact
            // while leaving the diagnostics one click away.
            detailsDisclosure
            Divider()
            footer
        }
        .frame(width: 400)
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

    /// Two collapsed-by-default disclosures: helper requirements
    /// (only for actions that need it) and the command preview.
    /// Stacked tightly so they feel like a single inspector area but
    /// labeled distinctly so the operator knows exactly what's
    /// inside each one without expanding.
    @ViewBuilder
    private var detailsDisclosure: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let hint = Self.guiHelperHintMarkdown(actionID: action.id) {
                DisclosureGroup {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "wand.and.rays")
                            .foregroundStyle(.orange)
                        Text(.init(hint))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 4)
                } label: {
                    Label("Helper requirements", systemImage: "wand.and.rays")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            DisclosureGroup {
                preview
                    .padding(.top, 4)
            } label: {
                // Show the first ~70 chars of the command inline so
                // the operator can see WHAT runs without expanding.
                // Truncation keeps the label single-line; the full
                // command is one click away.
                HStack(spacing: 6) {
                    Label("Preview command", systemImage: "terminal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(previewSummary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// First line / first ~70 chars of the command, trimmed of leading
    /// `set -e;`/`set +H;` noise. Used as the inline summary on the
    /// collapsed Preview-command chevron so the operator gets a hint
    /// of what's about to run without expanding the disclosure.
    private var previewSummary: String {
        let raw = previewCommand
            .replacingOccurrences(of: "\\\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        // Drop common leading set-shell noise so the summary starts
        // with the action's actual work.
        var s = raw
        for prefix in ["set +H; ", "set -e; "] {
            if s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        }
        return String(s.prefix(70))
    }

    /// Markdown body for the "Helper requirements" disclosure, or nil
    /// when the action has no GUI-helper dependency. The largetype
    /// action additionally requires the third-party `largetype`
    /// binary (`abdusco/largetype`), so its hint lists both
    /// requirements; notify-user is GUI Helper only.
    private static func guiHelperHintMarkdown(actionID: String) -> String? {
        let guiHelperLine = "**Quick Action** — \"GUI Helper\" or **Package Install** — [BlueConnectHelper.pkg](https://github.com/echoparkbaby/BlueConnect-Admin/releases/latest/download/BlueConnectHelper.pkg)"
        switch actionID {
        case "largeTypeShow":
            return """
            **Requires:**

            1. **Largetype** — [github.com/abdusco/largetype](https://github.com/abdusco/largetype)
            2. \(guiHelperLine)
            """
        case "notifyUser":
            return """
            **Requires:**

            1. \(guiHelperLine)
            """
        default:
            return nil
        }
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
            // Hand-rolled form. SwiftUI's Form{} + .formStyle(.grouped)
            // applied its own row padding around our custom HStack/Grid
            // rendering — leaving giant gaps between labels and their
            // controls, and stacking long-labeled pickers vertically
            // when there wasn't enough width. Building the form
            // ourselves out of plain VStack rows is more predictable
            // and gives us a consistent label column across all field
            // kinds.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(pairedFieldRows.enumerated()), id: \.offset) { idx, row in
                    if idx > 0 {
                        Divider()
                    }
                    if row.count == 2 {
                        // Two cells side by side via Grid. Grid sizes
                        // each row to the max cell height instead of
                        // letting SwiftUI's HStack(.firstTextBaseline)
                        // stretch the cells vertically (which made
                        // every picker row 150pt tall earlier).
                        Grid(alignment: .topLeading,
                             horizontalSpacing: 24,
                             verticalSpacing: 0) {
                            GridRow {
                                pickerCell(field: row[0])
                                pickerCell(field: row[1])
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    } else {
                        fieldRow(row[0])
                            .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.18)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    /// Single picker cell: short label on top, picker below, both at
    /// the same leading edge. The previous LabeledContent+Grid
    /// approach mis-aligned when one row's labels were short and the
    /// next row's labels were long ("Auto-hide after" wrapped, the
    /// picker stacked vertically). Top-label layout makes every
    /// picker cell identical in shape regardless of label length.
    @ViewBuilder
    private func pickerCell(field: QuickAction.Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            inlinePickerControl(field: field)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Just the picker control without the label — pulled out so
    /// `pickerCell` can lay it out under the label instead of inside
    /// a LabeledContent.
    @ViewBuilder
    private func inlinePickerControl(field: QuickAction.Field) -> some View {
        let binding = fieldBinding(for: field)
        switch field.kind {
        case .picker(let options):
            Picker("", selection: binding) {
                ForEach(options) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            // Min width keeps the dropdown chevron + selection text
            // visible — single-word options like "Read" or "List"
            // were collapsing the menu to a tiny invisible chevron
            // without this floor.
            .frame(minWidth: 140)
        default:
            fieldRow(field)
        }
    }

    /// Binding helper extracted so `inlinePickerControl` doesn't need
    /// to duplicate the dictionary-default machinery used by fieldRow.
    private func fieldBinding(for field: QuickAction.Field) -> Binding<String> {
        Binding(
            get: { values[field.id] ?? field.defaultValue },
            set: { values[field.id] = $0 }
        )
    }

    /// Group consecutive `.picker` fields into pairs so the form can
    /// render two-up rows; everything else stays full-width. Text and
    /// secure fields break the pairing — they always render solo.
    private var pairedFieldRows: [[QuickAction.Field]] {
        var rows: [[QuickAction.Field]] = []
        var i = 0
        let fields = action.fields
        while i < fields.count {
            let cur = fields[i]
            if case .picker = cur.kind,
               i + 1 < fields.count,
               case .picker = fields[i + 1].kind {
                rows.append([cur, fields[i + 1]])
                i += 2
            } else {
                rows.append([cur])
                i += 1
            }
        }
        return rows
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
            return (a.uidValue ?? Int.max) < (b.uidValue ?? Int.max)
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
            // Label above, field full-width below. Multi-line messages
            // (Large Type) get room to grow vertically without the
            // baseline-clipping that LabeledContent caused, and short
            // single-line entries still look fine — they just don't
            // expand past one line.
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 6) {
                    TextField("", text: binding,
                              prompt: Text(verbatim: field.placeholder),
                              axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if field.dataSource == .mrLocalUsers, mrUsersLoading {
                        ProgressView().controlSize(.small)
                            .padding(.top, 4)
                    }
                }
            }
        case .secure:
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("", text: binding,
                            prompt: Text(verbatim: field.placeholder))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .picker(let options):
            // Single (unpaired) picker — label above, picker below.
            // minWidth: 140 so single-word selections don't collapse
            // the dropdown to an invisible chevron.
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: binding) {
                    ForEach(options) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 140)
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
        // Outer padding intentionally absent — `preview` is now
        // rendered inside `detailsDisclosure` which provides its own
        // .padding(.horizontal, 16).padding(.vertical, 8).
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
        VStack(spacing: 6) {
            if let title = existingTabTitle, onRunInExistingTab != nil {
                // Small contextual notice — names the tab so the
                // operator can tell whether they're about to dump a
                // command into the right session.
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.stack")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Existing SSH tab open: ")
                        .font(.caption2).foregroundStyle(.secondary)
                    + Text(title)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.primary)
                    Spacer()
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let onExisting = onRunInExistingTab {
                    Button("Run in Existing Tab") {
                        QuickActionDefaults.save(actionID: action.id,
                                                 values: values,
                                                 fields: action.fields)
                        onExisting(action.buildCommand(values), values)
                        dismiss()
                    }
                    .disabled(!hasRequiredValues)
                    .help("Inject this command into the existing SSH tab for this host instead of opening a new one. Heads-up: if a TUI (vim/top/less) is running there, the line gets sent as input to that program.")
                }
                Button("Run", role: action.isDestructive ? .destructive : nil) {
                    QuickActionDefaults.save(actionID: action.id,
                                             values: values,
                                             fields: action.fields)
                    onRun(action.buildCommand(values), values)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!hasRequiredValues)
            }
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
