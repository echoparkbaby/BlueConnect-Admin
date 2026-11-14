import Testing
import AppKit
@testable import BlueConnectAdmin

/// Terminal themes: the presets, saving and the unsaved-changes logic,
/// moving the old five terminal settings into a theme, and Apple Terminal /
/// iTerm2 import and export.
@Suite("Terminal themes", .serialized)
@MainActor
struct TerminalThemeTests {
    /// Runs `body` with TerminalThemeStore writing to a throwaway defaults domain.
    private func withScratchDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "BlueConnectAdminTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let saved = TerminalThemeStore.defaults
        TerminalThemeStore.defaults = defaults
        defer {
            TerminalThemeStore.defaults = saved
            defaults.removePersistentDomain(forName: suite)
        }
        try body(defaults)
    }

    // MARK: Presets

    @Test func presetsAreComplete() {
        #expect(Set(TerminalTheme.presets.map(\.id)).count == TerminalTheme.presets.count)
        #expect(Set(TerminalTheme.presets.map(\.name)).count == TerminalTheme.presets.count)
        for theme in TerminalTheme.presets {
            #expect(theme.ansi.count == 16, "\(theme.name)")
            for hex in [theme.background, theme.text, theme.boldText, theme.cursor, theme.selection] + theme.ansi {
                #expect(TerminalTheme.color(hex) != nil, "\(theme.name): \(hex)")
            }
            #expect(theme.cursorBlink == false, "\(theme.name) should not blink")
        }
    }

    @Test func homebrewIsTheDefault() {
        let homebrew = TerminalTheme.defaultTheme
        #expect(homebrew.id == "homebrew")
        #expect(TerminalTheme.presets.first == homebrew)
        #expect(homebrew.antialias == false)
        #expect(homebrew.opacity == 0.9)
    }

    /// Homebrew matches the profile Apple Terminal ships, apart from the
    /// font size (14 instead of 12) and the cursor not blinking.
    @Test func homebrewMatchesAppleTerminal() throws {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app/Contents/Resources/Initial Settings/Homebrew.terminal")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var shipped = try TerminalThemeIO.importFile(url, current: .defaultTheme)
        #expect(shipped.fontSize == 12)
        #expect(shipped.cursorBlink)
        shipped.id = "homebrew"
        shipped.fontSize = 14
        shipped.cursorBlink = false
        #expect(shipped.looksLike(TerminalTheme.homebrew))
    }

    @Test func colorsRoundTripThroughHex() throws {
        #expect(TerminalTheme.hex(try #require(TerminalTheme.color("#28FE14"))) == "#28FE14")
        #expect(TerminalTheme.hex(try #require(TerminalTheme.color("#0C2EEEA6")), keepAlpha: true) == "#0C2EEEA6")
        #expect(TerminalTheme.color("nope") == nil)
    }

    @Test func themesRoundTripThroughJSON() throws {
        for theme in TerminalTheme.presets {
            let back = try JSONDecoder().decode(TerminalTheme.self, from: try JSONEncoder().encode(theme))
            #expect(back == theme)
        }
    }

    // MARK: Saving

    @Test func savingABuiltInThemeMakesAnOwnCopy() {
        withScratchDefaults { _ in
            var edited = TerminalTheme.presets[1]
            #expect(!TerminalThemeStore.isDirty(edited, custom: []))
            edited.fontSize = 18
            #expect(TerminalThemeStore.isDirty(edited, custom: []))

            let saved = TerminalThemeStore.save(edited)
            #expect(saved.name == "\(TerminalTheme.presets[1].name) (mine)")
            #expect(saved.id.hasPrefix("custom-"))
            #expect(TerminalThemeStore.custom == [saved])
            #expect(TerminalThemeStore.active == saved)
            #expect(!TerminalThemeStore.activeIsDirty)

            // The next Save overwrites the same copy.
            var again = saved
            again.fontSize = 20
            TerminalThemeStore.save(again)
            #expect(TerminalThemeStore.custom.count == 1)
            #expect(TerminalThemeStore.custom[0].fontSize == 20)

            // A second copy of the same preset gets a number.
            #expect(TerminalThemeStore.save(edited).name == "\(TerminalTheme.presets[1].name) (mine) 2")
        }
    }

    // MARK: Moving the old settings

    @Test func freshInstallStartsOnHomebrew() {
        withScratchDefaults { _ in
            TerminalThemeStore.migrateLegacySettings()
            #expect(TerminalThemeStore.active.id == "homebrew")
        }
    }

    @Test func oldDefaultMovesToHomebrew() {
        withScratchDefaults { d in
            d.set("#0F0F0F", forKey: "terminalBackgroundHex")
            d.set("#50FA7B", forKey: "terminalForegroundHex")
            d.set("#FF2734", forKey: "terminalCursorHex")
            d.set("Inconsolata-Regular", forKey: "terminalFontName")
            d.set(14.0, forKey: "terminalFontSize")
            TerminalThemeStore.migrateLegacySettings()
            #expect(TerminalThemeStore.active.id == "homebrew")
            #expect(TerminalThemeStore.custom.isEmpty)
            #expect(d.object(forKey: "terminalBackgroundHex") == nil)
        }
    }

    @Test func oldPresetMovesToThatPreset() {
        withScratchDefaults { d in
            d.set("#8a0c0f", forKey: "terminalBackgroundHex")
            d.set("#50fa7b", forKey: "terminalForegroundHex")
            d.set("#ffffff", forKey: "terminalCursorHex")
            d.set("Inconsolata-Regular", forKey: "terminalFontName")
            d.set(14.0, forKey: "terminalFontSize")
            TerminalThemeStore.migrateLegacySettings()
            #expect(TerminalThemeStore.active.id == "red-dead")
        }
    }

    @Test func ownSettingsBecomeAnOwnTheme() {
        withScratchDefaults { d in
            d.set("#101820", forKey: "terminalBackgroundHex")
            d.set("#FFFFFF", forKey: "terminalForegroundHex")
            d.set("Menlo-Regular", forKey: "terminalFontName")
            d.set(16.0, forKey: "terminalFontSize")
            TerminalThemeStore.migrateLegacySettings()
            let mine = TerminalThemeStore.custom
            #expect(mine.count == 1)
            #expect(mine.first?.name == "My Terminal")
            #expect(mine.first?.background == "#101820")
            #expect(mine.first?.fontSize == 16)
            #expect(TerminalThemeStore.active.id == mine.first?.id)
            // Runs only once.
            TerminalThemeStore.migrateLegacySettings()
            #expect(TerminalThemeStore.custom.count == 1)
        }
    }

    // MARK: Import / export

    @Test func terminalFilesRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for theme in TerminalTheme.presets.map(\.resolvedForThisMac) {
            let url = dir.appendingPathComponent("\(theme.id).terminal")
            try TerminalThemeIO.exportTerminal(theme, to: url)
            var back = try TerminalThemeIO.importFile(url, current: theme)
            back.id = theme.id
            var expected = theme
            if expected.fontName.isEmpty { expected.fontName = back.fontName }   // the system font exports by name
            #expect(back.name == theme.name)
            #expect(back.looksLike(expected), "\(theme.name)")
        }
    }

    @Test func itermFilesRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for theme in TerminalTheme.presets {
            let url = dir.appendingPathComponent("\(theme.id).itermcolors")
            try TerminalThemeIO.exportITerm(theme, to: url)
            var back = try TerminalThemeIO.importFile(url, current: theme)
            back.id = theme.id
            back.name = theme.name
            #expect(back.looksLike(theme), "\(theme.name)")
        }
    }

    @Test func importsAnITermFile() throws {
        let plist: [String: Any] = [
            "Background Color": ["Red Component": 0.1, "Green Component": 0.2, "Blue Component": 0.3, "Color Space": "sRGB"],
            "Ansi 1 Color": ["Red Component": 1.0, "Green Component": 0.0, "Blue Component": 0.0, "Color Space": "sRGB"],
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Sample-\(UUID().uuidString).itermcolors")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let theme = try TerminalThemeIO.importFile(url, current: .homebrew)
        #expect(theme.background == "#1A334D")
        #expect(theme.ansi[1] == "#FF0000")
        #expect(theme.fontName == TerminalTheme.homebrew.fontName)   // fonts come from the current theme
    }

    @Test func rejectsFilesThatAreNotThemes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).terminal")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try TerminalThemeIO.importFile(url, current: .homebrew) }
    }
}
