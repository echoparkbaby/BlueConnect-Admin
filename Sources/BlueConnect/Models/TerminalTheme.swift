import AppKit
import SwiftTerm

/// One terminal look: colors, the 16 ANSI colors, font, cursor and text
/// options. The built-in presets plus the operator's own saved themes.
///
/// Stored in UserDefaults:
///   terminalTheme        = the theme in use (JSON)
///   terminalCustomThemes = the operator's saved themes (JSON array)
/// Colors are "#RRGGBB" or "#RRGGBBAA" (the selection keeps its
/// transparency, like Apple Terminal).
struct TerminalTheme: Codable, Equatable, Identifiable, Hashable {
    enum Cursor: String, Codable, CaseIterable {
        case block, underline, bar
        var label: String {
            switch self {
            case .block: "Block"
            case .underline: "Underline"
            case .bar: "Vertical Bar"
            }
        }
    }

    var id: String
    var name: String
    var background: String
    var text: String
    var boldText: String
    var cursor: String
    var selection: String
    /// 16 colors: normal 0–7, bright 8–15.
    var ansi: [String]
    /// PostScript name; "" = system monospaced font.
    var fontName: String
    var fontSize: Double
    var cursorShape: Cursor = .block
    var cursorBlink: Bool = false
    var useBoldFonts: Bool = true
    var antialias: Bool = true
    /// Background opacity 0.5–1 (Apple Terminal → Color & Effects →
    /// Opacity). nil = fully opaque. Only the background is see-through;
    /// text stays solid.
    var backgroundOpacity: Double? = nil

    var opacity: Double { min(1, max(0.5, backgroundOpacity ?? 1)) }
    var isBuiltIn: Bool { Self.presets.contains { $0.id == id } }

    /// Same look, ignoring id and name — used to highlight the matching card
    /// and to tell whether there are unsaved changes.
    func looksLike(_ other: TerminalTheme) -> Bool {
        var a = self, b = other
        a.id = ""; a.name = ""; b.id = ""; b.name = ""
        return a == b
    }

    // MARK: - Colors

    static func color(_ hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let rgb = s.count == 8 ? v >> 8 : v
        let alpha = s.count == 8 ? CGFloat(v & 0xff) / 255 : 1
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
                       green: CGFloat((rgb >> 8) & 0xff) / 255,
                       blue: CGFloat(rgb & 0xff) / 255,
                       alpha: alpha)
    }

    static func hex(_ color: NSColor, keepAlpha: Bool = false) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) ?? color
        let rgb = String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)),
                         Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
        return keepAlpha && c.alphaComponent < 0.999 ? rgb + String(format: "%02X", Int(round(c.alphaComponent * 255))) : rgb
    }

    func ns(_ hex: String, _ fallback: NSColor = .white) -> NSColor { Self.color(hex) ?? fallback }

    var nsFont: NSFont {
        if !fontName.isEmpty, let font = NSFont(name: fontName, size: CGFloat(fontSize)) { return font }
        return NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
    }

    var fontLabel: String {
        let font = nsFont
        return (fontName.isEmpty ? "System Monospaced" : (font.displayName ?? font.fontName)) + " \(Int(fontSize))"
    }

    var swiftTermANSI: [SwiftTerm.Color] {
        (0..<16).map { i in
            let c = (Self.color(i < ansi.count ? ansi[i] : Self.appleTerminalANSI[i]) ?? .white).usingColorSpace(.sRGB) ?? .white
            return SwiftTerm.Color(red: UInt16(c.redComponent * 65535),
                                   green: UInt16(c.greenComponent * 65535),
                                   blue: UInt16(c.blueComponent * 65535))
        }
    }

    var swiftTermCursor: CursorStyle {
        switch (cursorShape, cursorBlink) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        }
    }

    // MARK: - Palettes

    /// Apple Terminal's own ANSI colors, which its profiles without custom
    /// ANSI colors (like Homebrew) use.
    static let appleTerminalANSI = ["#000000", "#C23621", "#25BC24", "#ADAD27", "#492EE1", "#D338D3", "#33BBC8", "#CBCCCD",
                                    "#818383", "#FC391F", "#31E722", "#EAEC23", "#5833FF", "#F935F8", "#14F0F0", "#E9EBEB"]
    /// The palette of BlueConnect's original presets. Two intentional
    /// differences from xterm: blue / bright blue (4, 12) are near-white so
    /// prompts that paint the hostname blue stay readable on dark
    /// backgrounds, and red / bright red (1, 9) are gold so prompts that
    /// paint the username red stay readable on Red Dead.
    static let blueConnectANSI = ["#000000", "#FFD700", "#00C200", "#C7C400", "#EBEBEB", "#C930C7", "#00C5C7", "#C7C7C7",
                                  "#686868", "#FFD700", "#5FFA68", "#FFFC67", "#FFFFFF", "#FF77FF", "#60FDFF", "#FFFFFF"]
    static let solarizedANSI = ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
                                "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]

    private static func preset(_ id: String, _ name: String, bg: String, fg: String, bold: String? = nil, cursor: String,
                               sel: String, ansi: [String], font: String = "", size: Double = 14, antialias: Bool = true,
                               opacity: Double? = nil) -> TerminalTheme {
        TerminalTheme(id: id, name: name, background: bg, text: fg, boldText: bold ?? fg, cursor: cursor, selection: sel,
                      ansi: ansi, fontName: font, fontSize: size, antialias: antialias, backgroundOpacity: opacity)
    }

    /// Apple Terminal's "Homebrew" profile: green on black at 90 % opacity,
    /// Andale Mono without antialiasing. Size 14 instead of 12, and no
    /// blinking cursor (no built-in preset blinks).
    static let homebrew = preset("homebrew", "Homebrew", bg: "#000000", fg: "#28FE14", bold: "#00F900", cursor: "#38FE27",
                                 sel: "#0C2EEEA6", ansi: appleTerminalANSI, font: "AndaleMono", antialias: false, opacity: 0.9)

    static let presets: [TerminalTheme] = [
        homebrew,
        preset("dracula", "Dracula", bg: "#282A36", fg: "#F8F8F2", cursor: "#F8F8F2", sel: "#44475A",
               ansi: ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
                      "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"]),
        preset("solarized-dark", "Solarized Dark", bg: "#002B36", fg: "#839496", bold: "#93A1A1", cursor: "#93A1A1",
               sel: "#073642", ansi: solarizedANSI),
        preset("solarized-light", "Solarized Light", bg: "#FDF6E3", fg: "#657B83", bold: "#586E75", cursor: "#586E75",
               sel: "#EEE8D5", ansi: solarizedANSI),
        preset("one-dark", "One Dark", bg: "#282C34", fg: "#ABB2BF", cursor: "#528BFF", sel: "#3E4451",
               ansi: ["#282C34", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF",
                      "#5C6370", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#FFFFFF"]),
        preset("monokai", "Monokai", bg: "#272822", fg: "#F8F8F2", cursor: "#F8F8F0", sel: "#49483E",
               ansi: ["#272822", "#F92672", "#A6E22E", "#F4BF75", "#66D9EF", "#AE81FF", "#A1EFE4", "#F8F8F2",
                      "#75715E", "#F92672", "#A6E22E", "#F4BF75", "#66D9EF", "#AE81FF", "#A1EFE4", "#F9F8F5"]),
        preset("nord", "Nord", bg: "#2E3440", fg: "#D8DEE9", cursor: "#D8DEE9", sel: "#434C5E",
               ansi: ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
                      "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"]),
        preset("gruvbox-dark", "Gruvbox Dark", bg: "#282828", fg: "#EBDBB2", cursor: "#EBDBB2", sel: "#504945",
               ansi: ["#282828", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#A89984",
                      "#928374", "#FB4934", "#B8BB26", "#FABD2F", "#83A598", "#D3869B", "#8EC07C", "#EBDBB2"]),
        preset("tokyo-night", "Tokyo Night", bg: "#1A1B26", fg: "#C0CAF5", cursor: "#C0CAF5", sel: "#33467C",
               ansi: ["#15161E", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6",
                      "#414868", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5"]),
        preset("catppuccin-mocha", "Catppuccin Mocha", bg: "#1E1E2E", fg: "#CDD6F4", cursor: "#F5E0DC", sel: "#585B70",
               ansi: ["#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
                      "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8"]),
        // BlueConnect's original presets, unchanged
        preset("red-dead", "Red Dead", bg: "#8A0C0F", fg: "#50FA7B", cursor: "#FFFFFF", sel: "#B5D5FF",
               ansi: blueConnectANSI, font: "Inconsolata-Regular"),
        preset("open-water", "Open Water", bg: "#2F32FF", fg: "#50FA7B", cursor: "#FFFFFF", sel: "#B5D5FF",
               ansi: blueConnectANSI, font: "Inconsolata-Regular"),
        preset("deep-sea", "Deep Sea", bg: "#121172", fg: "#50FA7B", cursor: "#FFFFFF", sel: "#B5D5FF",
               ansi: blueConnectANSI, font: "Inconsolata-Regular"),
        preset("peppermint", "Peppermint", bg: "#0F0F0F", fg: "#50FA7B", cursor: "#FF2734", sel: "#B5D5FF",
               ansi: blueConnectANSI, font: "Inconsolata-Regular"),
        preset("high-contrast", "High Contrast", bg: "#000000", fg: "#FFFFFF", cursor: "#FFEB3B", sel: "#B5D5FF",
               ansi: blueConnectANSI),
    ]

    static var defaultTheme: TerminalTheme { homebrew }

    /// A preset's font may not be installed (Inconsolata): fall back to the
    /// system monospaced font so the theme still applies.
    var resolvedForThisMac: TerminalTheme {
        var theme = self
        if !theme.fontName.isEmpty, NSFont(name: theme.fontName, size: 12) == nil { theme.fontName = "" }
        return theme
    }
}

// MARK: - Storage

enum TerminalThemeStore {
    static let activeKey = "terminalTheme"
    static let customKey = "terminalCustomThemes"
    static let changed = Notification.Name("BlueConnectTerminalThemeChanged")

    static var defaults: UserDefaults = .standard

    /// The theme in use, with any unsaved edits. Open terminals follow it.
    static var active: TerminalTheme {
        get {
            if let data = defaults.data(forKey: activeKey),
               let theme = try? JSONDecoder().decode(TerminalTheme.self, from: data) { return theme }
            return TerminalTheme.defaultTheme.resolvedForThisMac
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: activeKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// The operator's saved themes.
    static var custom: [TerminalTheme] {
        get {
            guard let data = defaults.data(forKey: customKey) else { return [] }
            return (try? JSONDecoder().decode([TerminalTheme].self, from: data)) ?? []
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: customKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    // MARK: Save / unsaved changes
    // Edits change the active theme right away, but a saved theme only
    // changes on Save. There is no silent autosave.

    /// What the active theme was last saved as: the operator's own copy, or the built-in preset.
    static func baseline(of theme: TerminalTheme, custom: [TerminalTheme]) -> TerminalTheme? {
        custom.first { $0.id == theme.id } ?? TerminalTheme.presets.first { $0.id == theme.id }?.resolvedForThisMac
    }

    static func isDirty(_ theme: TerminalTheme, custom: [TerminalTheme]) -> Bool {
        guard let base = baseline(of: theme, custom: custom) else { return true }
        return !theme.looksLike(base)
    }

    static var activeIsDirty: Bool { isDirty(active, custom: custom) }

    /// Save: an own theme is overwritten; a built-in one is stored as
    /// "<name> (mine)", which the next Save overwrites.
    @discardableResult
    static func save(_ theme: TerminalTheme) -> TerminalTheme {
        var list = custom
        var theme = theme
        if let index = list.firstIndex(where: { $0.id == theme.id }) {
            list[index] = theme
        } else {
            if let preset = TerminalTheme.presets.first(where: { $0.id == theme.id }) {
                theme.name = uniqueName("\(preset.name) (mine)", custom: list)
            }
            theme.id = "custom-\(UUID().uuidString)"
            list.append(theme)
        }
        custom = list
        active = theme
        return theme
    }

    static func uniqueName(_ base: String, custom: [TerminalTheme]) -> String {
        let taken = Set(TerminalTheme.presets.map(\.name) + custom.map(\.name))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Before switching themes or leaving the Terminal settings with unsaved
    /// changes: Save / Discard (/ Cancel). Returns false only on Cancel.
    @MainActor
    static func confirmUnsaved(allowCancel: Bool) -> Bool {
        let current = active, list = custom
        guard isDirty(current, custom: list) else { return true }
        let builtIn = TerminalTheme.presets.contains { $0.id == current.id } && !list.contains { $0.id == current.id }
        let alert = NSAlert()
        alert.messageText = "Save changes to the “\(current.name)” terminal theme?"
        alert.informativeText = builtIn
            ? "Save keeps them as your own copy, “\(uniqueName("\(current.name) (mine)", custom: list))”. Discard goes back to \(current.name)."
            : "Discard goes back to the last saved “\(current.name)”."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        if allowCancel { alert.addButton(withTitle: "Cancel") }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save(current)
            return true
        case .alertSecondButtonReturn:
            if let base = baseline(of: current, custom: list) { active = base }
            return true
        default:
            return false
        }
    }

    /// The five terminal settings used before themes.
    static let legacyKeys = ["terminalFontName", "terminalFontSize", "terminalForegroundHex",
                             "terminalBackgroundHex", "terminalCursorHex"]

    /// Once, at launch: move the old five terminal settings into a theme.
    /// Never set, or still the old default (Peppermint colors) → Homebrew.
    /// One of the old presets → that preset. Anything else → kept as the
    /// operator's own theme "My Terminal".
    static func migrateLegacySettings() {
        guard defaults.data(forKey: activeKey) == nil else { return }
        let stored = legacyKeys.reduce(into: [String: Any]()) { dict, key in
            if let value = defaults.object(forKey: key) { dict[key] = value }
        }
        guard !stored.isEmpty else { return }
        let bg = (stored["terminalBackgroundHex"] as? String)?.uppercased() ?? "#0F0F0F"
        let fg = (stored["terminalForegroundHex"] as? String)?.uppercased() ?? "#50FA7B"
        let cursor = (stored["terminalCursorHex"] as? String)?.uppercased() ?? "#FF2734"
        let font = stored["terminalFontName"] as? String ?? "Inconsolata-Regular"
        let size = stored["terminalFontSize"] as? Double ?? 14
        let oldDefault = bg == "#0F0F0F" && fg == "#50FA7B" && cursor == "#FF2734"
            && ["Inconsolata-Regular", ""].contains(font) && size == 14
        if oldDefault {
            active = TerminalTheme.defaultTheme.resolvedForThisMac
        } else if let preset = TerminalTheme.presets.first(where: {
            $0.background == bg && $0.text == fg && $0.cursor == cursor && $0.fontName == font && $0.fontSize == size
        }) {
            active = preset.resolvedForThisMac
        } else {
            let mine = TerminalTheme(id: "custom-\(UUID().uuidString)", name: uniqueName("My Terminal", custom: custom),
                                     background: bg, text: fg, boldText: fg, cursor: cursor, selection: "#B5D5FF",
                                     ansi: TerminalTheme.blueConnectANSI, fontName: font, fontSize: size)
            custom = custom + [mine]
            active = mine.resolvedForThisMac
        }
        for key in legacyKeys { defaults.removeObject(forKey: key) }
    }
}
