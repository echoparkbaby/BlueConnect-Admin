import AppKit

/// Import / export of terminal themes. Only reads what it imports from:
/// - Apple Terminal profiles: com.apple.Terminal "Window Settings" (never written)
/// - .terminal files (same keys as a Terminal profile, archived NSColor / NSFont)
/// - iTerm2 .itermcolors (colors only; font and cursor come from the current theme)
/// Export writes a .terminal file Apple Terminal can import, or an .itermcolors file.
enum TerminalThemeIO {
    static let ansiKeys = ["ANSIBlackColor", "ANSIRedColor", "ANSIGreenColor", "ANSIYellowColor",
                           "ANSIBlueColor", "ANSIMagentaColor", "ANSICyanColor", "ANSIWhiteColor",
                           "ANSIBrightBlackColor", "ANSIBrightRedColor", "ANSIBrightGreenColor", "ANSIBrightYellowColor",
                           "ANSIBrightBlueColor", "ANSIBrightMagentaColor", "ANSIBrightCyanColor", "ANSIBrightWhiteColor"]

    enum ImportError: LocalizedError {
        case notATheme(String)
        var errorDescription: String? {
            switch self { case .notATheme(let file): "\(file) isn't a Terminal or iTerm2 theme file." }
        }
    }

    // MARK: Apple Terminal

    /// The profiles in Apple Terminal's settings, sorted by name.
    static func appleTerminalProfiles() -> [(name: String, settings: [String: Any])] {
        let settings = UserDefaults(suiteName: "com.apple.Terminal")?.dictionary(forKey: "Window Settings") ?? [:]
        return settings.compactMap { key, value in (value as? [String: Any]).map { (key, $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func unarchiveColor(_ value: Any?) -> NSColor? {
        guard let data = value as? Data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }

    private static func unarchiveFont(_ value: Any?) -> NSFont? {
        guard let data = value as? Data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: data)
    }

    /// A Terminal profile dictionary → theme. Missing keys take Apple
    /// Terminal's defaults ("Basic").
    static func theme(fromTerminal profile: [String: Any], name: String) -> TerminalTheme {
        func color(_ key: String, _ fallback: String, alpha: Bool = false) -> String {
            unarchiveColor(profile[key]).map { TerminalTheme.hex($0, keepAlpha: alpha) } ?? fallback
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool { (profile[key] as? NSNumber)?.boolValue ?? fallback }
        let font = unarchiveFont(profile["Font"])
        let text = color("TextColor", "#000000")
        let shape: TerminalTheme.Cursor = switch (profile["CursorType"] as? NSNumber)?.intValue ?? 0 {
        case 1: .underline
        case 2: .bar
        default: .block
        }
        let background = unarchiveColor(profile["BackgroundColor"])
        return TerminalTheme(
            id: "custom-\(UUID().uuidString)", name: name,
            background: TerminalTheme.hex(background ?? .white),
            text: text, boldText: color("TextBoldColor", text), cursor: color("CursorColor", "#929292"),
            selection: color("SelectionColor", "#A4CDFF", alpha: true),
            ansi: ansiKeys.enumerated().map { i, key in color(key, TerminalTheme.appleTerminalANSI[i]) },
            fontName: font?.fontName ?? "", fontSize: Double(font?.pointSize ?? 11),
            cursorShape: shape, cursorBlink: flag("CursorBlink", false),
            useBoldFonts: flag("UseBoldFonts", true), antialias: flag("FontAntialias", true),
            backgroundOpacity: opacity(of: background))
    }

    /// Background alpha → opacity, rounded to whole percent, 50–100 %;
    /// nil when fully opaque.
    static func opacity(of color: NSColor?) -> Double? {
        guard let alpha = (color?.usingColorSpace(.sRGB) ?? color)?.alphaComponent, alpha < 0.995 else { return nil }
        return max(0.5, (Double(alpha) * 100).rounded() / 100)
    }

    /// Reads a .terminal or .itermcolors file.
    static func importFile(_ url: URL, current: TerminalTheme) throws -> TerminalTheme {
        let data = try Data(contentsOf: url)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ImportError.notATheme(url.lastPathComponent)
        }
        let name = url.deletingPathExtension().lastPathComponent
        if url.pathExtension.lowercased() == "itermcolors" {
            guard plist.keys.contains(where: { $0.hasSuffix("Color") }) else { throw ImportError.notATheme(url.lastPathComponent) }
            return fromITerm(plist, name: name, current: current)
        }
        guard plist["BackgroundColor"] != nil || plist["TextColor"] != nil || plist["Font"] != nil
                || plist["type"] as? String == "Window Settings" else {
            throw ImportError.notATheme(url.lastPathComponent)
        }
        return theme(fromTerminal: plist, name: (plist["name"] as? String) ?? name)
    }

    // MARK: iTerm2

    private static func itermColor(_ value: Any?) -> NSColor? {
        guard let dict = value as? [String: Any],
              let r = (dict["Red Component"] as? NSNumber)?.doubleValue,
              let g = (dict["Green Component"] as? NSNumber)?.doubleValue,
              let b = (dict["Blue Component"] as? NSNumber)?.doubleValue else { return nil }
        let a = (dict["Alpha Component"] as? NSNumber)?.doubleValue ?? 1
        switch dict["Color Space"] as? String {
        case "Calibrated": return NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
        case "P3": return NSColor(displayP3Red: r, green: g, blue: b, alpha: a)
        default: return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
    }

    static func fromITerm(_ plist: [String: Any], name: String, current: TerminalTheme) -> TerminalTheme {
        var theme = current
        theme.id = "custom-\(UUID().uuidString)"
        theme.name = name
        func color(_ key: String, _ fallback: String, alpha: Bool = false) -> String {
            itermColor(plist[key]).map { TerminalTheme.hex($0, keepAlpha: alpha) } ?? fallback
        }
        let background = itermColor(plist["Background Color"])
        theme.background = background.map { TerminalTheme.hex($0) } ?? theme.background
        if background != nil { theme.backgroundOpacity = opacity(of: background) }
        theme.text = color("Foreground Color", theme.text)
        theme.boldText = color("Bold Color", theme.text)
        theme.cursor = color("Cursor Color", theme.cursor)
        theme.selection = color("Selection Color", theme.selection, alpha: true)
        theme.ansi = (0..<16).map { color("Ansi \($0) Color", TerminalTheme.appleTerminalANSI[$0]) }
        return theme
    }

    // MARK: Export

    static func exportTerminal(_ theme: TerminalTheme, to url: URL) throws {
        try terminalData(theme).write(to: url, options: .atomic)
    }

    static func terminalData(_ t: TerminalTheme) throws -> Data {
        func archive(_ object: NSObject) throws -> Data {
            try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: true)
        }
        var profile: [String: Any] = [
            "name": t.name, "type": "Window Settings", "ProfileCurrentVersion": 2.07,
            "BackgroundColor": try archive(t.ns(t.background, .black).withAlphaComponent(t.opacity)),
            "TextColor": try archive(t.ns(t.text)),
            "TextBoldColor": try archive(t.ns(t.boldText)),
            "CursorColor": try archive(t.ns(t.cursor)),
            "SelectionColor": try archive(t.ns(t.selection, .selectedTextBackgroundColor)),
            "Font": try archive(t.nsFont),
            "CursorType": t.cursorShape == .block ? 0 : t.cursorShape == .underline ? 1 : 2,
            "CursorBlink": t.cursorBlink ? 1 : 0,
            "UseBoldFonts": t.useBoldFonts ? 1 : 0,
            "FontAntialias": t.antialias ? 1 : 0,
        ]
        for (i, key) in ansiKeys.enumerated() where i < t.ansi.count {
            profile[key] = try archive(t.ns(t.ansi[i]))
        }
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    static func exportITerm(_ theme: TerminalTheme, to url: URL) throws {
        try itermData(theme).write(to: url, options: .atomic)
    }

    static func itermData(_ t: TerminalTheme) throws -> Data {
        func entry(_ hex: String, alpha: Double? = nil) -> [String: Any] {
            let c = t.ns(hex).usingColorSpace(.sRGB) ?? t.ns(hex)
            return ["Red Component": Double(c.redComponent), "Green Component": Double(c.greenComponent),
                    "Blue Component": Double(c.blueComponent), "Alpha Component": alpha ?? Double(c.alphaComponent),
                    "Color Space": "sRGB"]
        }
        var plist: [String: Any] = [
            "Background Color": entry(t.background, alpha: t.opacity),
            "Foreground Color": entry(t.text),
            "Bold Color": entry(t.boldText),
            "Cursor Color": entry(t.cursor),
            "Selection Color": entry(t.selection),
        ]
        for i in 0..<min(16, t.ansi.count) { plist["Ansi \(i) Color"] = entry(t.ansi[i]) }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
