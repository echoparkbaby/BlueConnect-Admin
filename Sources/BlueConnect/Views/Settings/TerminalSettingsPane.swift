import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings → Terminal (issue #12: "hard to read the terminal"). Themes in an
/// even grid (Homebrew first, popular coder themes, BlueConnect's originals,
/// then the operator's own), a live preview, and a Customize section laid out
/// like Apple Terminal's Settings → Profiles → Text.
///
/// Edits apply to open terminals right away, but a saved theme only changes
/// on Save (⌘S). Saving a changed built-in theme keeps it as "<name> (mine)".
/// Switching themes or leaving the pane with unsaved changes asks
/// Save / Discard. Import from Apple Terminal, .terminal or .itermcolors;
/// export .terminal or .itermcolors.
struct TerminalSettingsPane: View {
    @State private var theme: TerminalTheme = TerminalThemeStore.active
    @State private var custom: [TerminalTheme] = TerminalThemeStore.custom
    @State private var includeProportional = false
    @State private var fonts: [FontOption] = []
    @State private var message: String?
    @State private var savedFlash = false

    private struct FontOption: Hashable, Identifiable {
        let post: String   // PostScript name; "" means System Monospaced
        let label: String
        var id: String { post }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    private var isCustom: Bool { custom.contains { $0.id == theme.id } }
    private var dirty: Bool { TerminalThemeStore.isDirty(theme, custom: custom) }
    private var title: String { dirty ? "\(theme.name) (modified)" : theme.name }

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(TerminalTheme.presets) { card($0) }
                }
                if !custom.isEmpty {
                    Text("My Themes").font(.headline).padding(.top, 4)
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(custom) { card($0) }
                    }
                }
                actions
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Themes")
            } footer: {
                Text("Click a theme to use it; open terminals change right away. Right-click your own themes to rename, duplicate, export or delete them.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TerminalThemePreview(theme: theme)
            } header: {
                Text("Preview — \(title)")
            }

            Section {
                customize
            } header: {
                HStack {
                    Text("Customize — \(title)")
                    Spacer()
                    if savedFlash {
                        Label("Saved", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    } else if dirty {
                        Text(isCustom ? "Unsaved changes — Save (⌘S) keeps them"
                                      : "Unsaved changes — Save (⌘S) keeps them as “\(theme.name) (mine)”")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            } footer: {
                Text("Antialias off draws crisp, pixel-sharp text like Apple Terminal's Homebrew profile.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear {
            // Leaving the Terminal pane or closing Settings with unsaved changes → Save / Discard.
            _ = TerminalThemeStore.confirmUnsaved(allowCancel: false)
        }
        .task(id: includeProportional) { fonts = Self.loadFonts(includeProportional: includeProportional) }
        .onReceive(NotificationCenter.default.publisher(for: TerminalThemeStore.changed)) { _ in
            theme = TerminalThemeStore.active
            custom = TerminalThemeStore.custom
        }
    }

    // MARK: - Themes

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Save") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!dirty)
                .help(isCustom ? "Save changes to “\(theme.name)” (⌘S)" : "Save as your own copy, “\(theme.name) (mine)” (⌘S)")
            Button("Save As…") { saveAs() }
            Menu("Import") {
                Menu("From Apple Terminal") {
                    let profiles = TerminalThemeIO.appleTerminalProfiles()
                    if profiles.isEmpty { Text("No Terminal profiles found") }
                    ForEach(profiles, id: \.name) { profile in
                        Button(profile.name) {
                            add(TerminalThemeIO.theme(fromTerminal: profile.settings, name: profile.name),
                                note: "Imported “\(profile.name)” from Apple Terminal.")
                        }
                    }
                }
                Button("Terminal or iTerm2 File (.terminal, .itermcolors)…") { importFile() }
            }
            .fixedSize()
            Button("Export…") { export(theme) }
            Spacer()
            Button("Reset to Default") { switchTo(TerminalTheme.defaultTheme) }
                .help("Homebrew — the default look")
        }
    }

    private func card(_ t: TerminalTheme) -> some View {
        let isActive = theme.id == t.id
        return Button { switchTo(t) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 0) {
                    Text("% ls").foregroundStyle(Color(nsColor: t.ns(t.text)))
                    Rectangle().fill(Color(nsColor: t.ns(t.cursor))).frame(width: 6, height: 12).padding(.leading, 2)
                }
                .font(.system(size: 11, design: .monospaced))
                HStack(spacing: 3) {
                    ForEach(1..<7) { i in
                        Circle().fill(Color(nsColor: t.ns(t.ansi[i]))).frame(width: 7, height: 7)
                    }
                }
                Text(t.name).font(.caption.weight(.semibold)).foregroundStyle(Color(nsColor: t.ns(t.text)))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background(Color(nsColor: t.ns(t.background, .black)))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(isActive ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isActive ? 3 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t.isBuiltIn ? "\(t.name) · \(t.fontLabel)" : "\(t.name) (yours) · \(t.fontLabel)")
        .contextMenu {
            if !t.isBuiltIn { Button("Rename…") { rename(t) } }
            Button("Duplicate") {
                var copy = t
                copy.id = "custom-\(UUID().uuidString)"
                copy.name = uniqueName("\(t.name) copy")
                add(copy, note: nil)
            }
            Button("Export…") { export(t) }
            if !t.isBuiltIn {
                Divider()
                Button("Delete…", role: .destructive) { delete(t) }
            }
        }
    }

    // MARK: - Customize (like Apple Terminal → Profiles → Text)

    private static let ansiNames = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]

    private var customize: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text("Font").gridColumnAlignment(.trailing)
                HStack(spacing: 10) {
                    Picker("", selection: bind(\.fontName)) {
                        ForEach(fonts) { Text($0.label).tag($0.post) }
                        if !fonts.contains(where: { $0.post == theme.fontName }) {
                            Text(theme.fontLabel).tag(theme.fontName)
                        }
                    }
                    .labelsHidden().fixedSize()
                    Text("\(Int(theme.fontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    Stepper("", value: bind(\.fontSize), in: 9...36, step: 1).labelsHidden()
                    Spacer(minLength: 0)
                }
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Toggle("Show fonts that aren't monospaced", isOn: $includeProportional).toggleStyle(.checkbox)
                    .help("Fonts that aren't monospaced misalign terminal columns")
            }
            GridRow {
                Text("Text")
                HStack(spacing: 18) {
                    Toggle("Use bold fonts", isOn: bind(\.useBoldFonts)).toggleStyle(.checkbox)
                    Toggle("Antialias text", isOn: bind(\.antialias)).toggleStyle(.checkbox)
                    Spacer(minLength: 0)
                }
            }
            GridRow {
                Text("Cursor")
                HStack(spacing: 18) {
                    Picker("", selection: bind(\.cursorShape)) {
                        ForEach(TerminalTheme.Cursor.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Toggle("Blink cursor", isOn: bind(\.cursorBlink)).toggleStyle(.checkbox)
                    Spacer(minLength: 0)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            GridRow {
                Text("Colors")
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow { well("Background", \.background); well("Text", \.text); well("Bold Text", \.boldText) }
                    GridRow {
                        well("Cursor", \.cursor)
                        well("Selection", \.selection, opacity: true)
                        Color.clear.frame(width: 1, height: 1)
                    }
                }
            }
            GridRow {
                Text("Opacity")
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { theme.opacity },
                                          set: { v in edit { $0.backgroundOpacity = v >= 0.995 ? nil : (v * 100).rounded() / 100 } }),
                           in: 0.5...1)
                        .labelsHidden().frame(width: 220)
                    Text("\(Int((theme.opacity * 100).rounded())) %").monospacedDigit().frame(width: 48, alignment: .trailing)
                    Text("background only — text stays solid").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            GridRow {
                Text("ANSI Colors").gridCellAnchor(.topTrailing)
                Grid(alignment: .center, horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        ForEach(0..<8) { i in
                            Text(Self.ansiNames[i]).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        }
                    }
                    ForEach(0..<2) { row in
                        GridRow {
                            Text(row == 0 ? "Normal" : "Bright").font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).fixedSize().gridColumnAlignment(.leading)
                            ForEach(0..<8) { i in
                                ColorPicker("", selection: ansiBinding(row * 8 + i), supportsOpacity: false).labelsHidden()
                                    .help("ANSI \(row * 8 + i): \(theme.ansi[row * 8 + i])")
                            }
                        }
                    }
                }
            }
        }
    }

    private func well(_ label: String, _ keyPath: WritableKeyPath<TerminalTheme, String>, opacity: Bool = false) -> some View {
        HStack(spacing: 6) {
            ColorPicker("", selection: colorBinding(keyPath, opacity: opacity), supportsOpacity: opacity).labelsHidden()
            Text(label).frame(minWidth: 80, alignment: .leading)
        }
        .help("\(label): \(theme[keyPath: keyPath])")
    }

    // MARK: - Bindings → edit the active theme

    private func bind<V>(_ keyPath: WritableKeyPath<TerminalTheme, V>) -> Binding<V> {
        Binding(get: { theme[keyPath: keyPath] }, set: { value in edit { $0[keyPath: keyPath] = value } })
    }

    private func colorBinding(_ keyPath: WritableKeyPath<TerminalTheme, String>, opacity: Bool) -> Binding<Color> {
        Binding(get: { Color(nsColor: theme.ns(theme[keyPath: keyPath])) },
                set: { c in edit { $0[keyPath: keyPath] = TerminalTheme.hex(NSColor(c), keepAlpha: opacity) } })
    }

    private func ansiBinding(_ i: Int) -> Binding<Color> {
        Binding(get: { Color(nsColor: theme.ns(theme.ansi[i])) },
                set: { c in edit { $0.ansi[i] = TerminalTheme.hex(NSColor(c)) } })
    }

    private func edit(_ change: (inout TerminalTheme) -> Void) {
        var t = theme
        change(&t)
        guard t != theme else { return }
        theme = t
        savedFlash = false
        TerminalThemeStore.active = t   // open terminals follow right away; the saved theme changes only on Save
    }

    // MARK: - Actions

    /// Picking another theme with unsaved changes asks Save / Discard / Cancel first.
    private func switchTo(_ t: TerminalTheme) {
        if t.id != theme.id || dirty, !TerminalThemeStore.confirmUnsaved(allowCancel: true) { return }
        custom = TerminalThemeStore.custom
        apply(t)
    }

    private func apply(_ t: TerminalTheme) {
        theme = t.resolvedForThisMac
        TerminalThemeStore.active = theme
        message = nil
    }

    private func save() {
        guard dirty else { return }
        theme = TerminalThemeStore.save(theme)
        custom = TerminalThemeStore.custom
        message = nil
        savedFlash = true
        Task { try? await Task.sleep(for: .seconds(2)); savedFlash = false }
    }

    private func add(_ t: TerminalTheme, note: String?) {
        guard TerminalThemeStore.confirmUnsaved(allowCancel: true) else { return }
        custom = TerminalThemeStore.custom
        var t = t
        t.name = uniqueName(t.name)
        custom.append(t)
        TerminalThemeStore.custom = custom
        apply(t)
        message = note
    }

    private func uniqueName(_ base: String) -> String {
        TerminalThemeStore.uniqueName(base, custom: custom)
    }

    private func saveAs() {
        let suggested = isCustom ? "\(theme.name) copy" : "\(theme.name) (mine)"
        guard let name = ask("Save Theme As", "Name for this theme:", suggested) else { return }
        // The theme being edited keeps its last saved version; the changes go to the new one.
        var t = theme
        t.id = "custom-\(UUID().uuidString)"
        t.name = uniqueName(name)
        custom.append(t)
        TerminalThemeStore.custom = custom
        apply(t)
        message = "Saved “\(t.name)”."
    }

    private func rename(_ t: TerminalTheme) {
        guard let name = ask("Rename Theme", "New name:", t.name),
              let index = custom.firstIndex(where: { $0.id == t.id }) else { return }
        custom[index].name = name
        TerminalThemeStore.custom = custom
        if theme.id == t.id {
            theme.name = name
            TerminalThemeStore.active = theme
        }
    }

    private func delete(_ t: TerminalTheme) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(t.name)”?"
        alert.informativeText = theme.id == t.id ? "Your terminals switch to Homebrew. This can't be undone." : "This can't be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let wasActive = theme.id == t.id
        custom.removeAll { $0.id == t.id }
        TerminalThemeStore.custom = custom
        if wasActive { apply(TerminalTheme.defaultTheme) }
    }

    private func ask(_ title: String, _ text: String, _ value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static let terminalType = UTType(filenameExtension: "terminal") ?? .propertyList
    private static let itermType = UTType(filenameExtension: "itermcolors") ?? .propertyList

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.terminalType, Self.itermType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            add(try TerminalThemeIO.importFile(url, current: theme), note: "Imported \(url.lastPathComponent).")
        } catch {
            message = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func export(_ t: TerminalTheme) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(t.name).terminal"
        panel.allowedContentTypes = [Self.terminalType, Self.itermType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if url.pathExtension.lowercased() == "itermcolors" {
                try TerminalThemeIO.exportITerm(t, to: url)
            } else {
                try TerminalThemeIO.exportTerminal(t, to: url)
            }
            message = "Exported \(url.lastPathComponent)."
        } catch {
            message = "Couldn't export: \(error.localizedDescription)"
        }
    }

    // MARK: - Fonts

    private static let allFonts: [(post: String, label: String, fixed: Bool)] = {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.compactMap { family in
            guard !family.hasPrefix("."), let members = manager.availableMembers(ofFontFamily: family),
                  let regular = members.first(where: { ($0[1] as? String) == "Regular" }) ?? members.first,
                  let post = regular[0] as? String, let font = NSFont(name: post, size: 12) else { return nil }
            return (post, family, font.isFixedPitch)
        }
    }()

    private static func loadFonts(includeProportional: Bool) -> [FontOption] {
        [FontOption(post: "", label: "System Monospaced")]
            + allFonts.filter { includeProportional || $0.fixed }.map { FontOption(post: $0.post, label: $0.label) }
    }
}
