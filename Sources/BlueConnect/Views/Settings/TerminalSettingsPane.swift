import SwiftUI
import AppKit

/// Settings → Terminal. Lets the operator tune the SwiftTerm view's
/// font face, size, background, foreground, and cursor color. The
/// presets at the bottom mirror profiles the user already keeps in
/// Apple Terminal.app (Red Dead, Open Water, Deep Sea, Peppermint),
/// because the reason this pane exists (issue #12) is "I find it hard
/// to read" — surfacing the same cures one click away.
struct TerminalSettingsPane: View {
    @EnvironmentObject private var settings: SettingsStore

    /// Toggle for showing the full installed-font list. When off (the
    /// default) the picker filters to monospaced families, because
    /// proportional fonts in a terminal misalign every column. The
    /// operator can opt in if they really want, e.g. for a fancy
    /// banner font or display-only terminal use.
    @State private var includeProportional: Bool = false

    /// All installed font families on the system, optionally filtered to
    /// monospaced. Cached via @State so the (slightly expensive)
    /// NSFontManager scan only runs once per pane lifetime instead of
    /// every render.
    @State private var availableFonts: [FontOption] = []

    /// One row in the font picker — the PostScript name we persist
    /// (`""` for the system mono fallback) plus the user-facing label.
    private struct FontOption: Hashable, Identifiable {
        let post: String   // PostScript name; "" means System Monospace
        let label: String  // Family/display name
        var id: String { post }
    }

    var body: some View {
        Form {
            Section {
                Picker("Font", selection: $settings.terminalFontName) {
                    ForEach(availableFonts) { f in
                        Text(f.label).tag(f.post)
                    }
                }
                Toggle("Show non-monospaced fonts", isOn: $includeProportional)
                    .help("Proportional fonts misalign terminal columns. Off by default; turn on if you really want a non-monospaced face.")
                LabeledContent("Font size") {
                    HStack {
                        Slider(value: $settings.terminalFontSize, in: 9...22, step: 1)
                            .frame(maxWidth: 220)
                        Text("\(Int(settings.terminalFontSize)) pt")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                colorRow("Background", hex: $settings.terminalBackgroundHex)
                colorRow("Foreground", hex: $settings.terminalForegroundHex)
                colorRow("Cursor",     hex: $settings.terminalCursorHex)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Changes apply to new terminal sessions immediately. Already-open tabs update on the next render — close and reopen if you don't see the change.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                preview
            } header: {
                Text("Preview")
            }

            Section {
                // Two rows of presets — the user's familiar profiles
                // first, then the generic high-contrast / reset
                // catchalls. Wrapping with `FlowLayout` would be nice
                // but pure HStack works at the 720-wide Settings frame.
                HStack {
                    Button("Red Dead") { applyRedDead() }
                    Button("Open Water") { applyOpenWater() }
                    Button("Deep Sea") { applyDeepSea() }
                    Button("Peppermint") { applyPeppermint() }
                    Spacer()
                }
                HStack {
                    Button("High Contrast") { applyHighContrast() }
                    Button("Reset to Defaults", role: .destructive) { resetToDefaults() }
                    Spacer()
                }
            } header: {
                Text("Presets")
            } footer: {
                Text("Red Dead / Open Water / Deep Sea / Peppermint mirror Apple Terminal profiles. Open Water = Ocean 2 (bright blue), Deep Sea = Ocean 4 (deep navy).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: includeProportional) {
            availableFonts = Self.loadInstalledFonts(includeProportional: includeProportional)
            // If the user just flipped to monospaced-only and the
            // currently-saved font isn't in the filtered list, fall
            // back to the system mono face so the Picker doesn't
            // render a blank/invalid selection.
            if !settings.terminalFontName.isEmpty,
               !availableFonts.contains(where: { $0.post == settings.terminalFontName }) {
                settings.terminalFontName = ""
            }
        }
    }

    /// Cached scan of every installed font family. The NSFontManager
    /// walk + per-family NSFont allocation is O(~800) on a typical
    /// designer Mac; without the cache, every Settings → Terminal open
    /// and every "Show non-monospaced fonts" toggle re-paid the full
    /// cost. The cache is process-lifetime because users don't install
    /// fonts while BlueConnect is running — a "Refresh fonts" button
    /// in Settings is overkill for an edge case nobody has hit.
    private static let allInstalledFontsCache: [(post: String, label: String, fixedPitch: Bool)] = {
        let manager = NSFontManager.shared
        var out: [(post: String, label: String, fixedPitch: Bool)] = []
        for family in manager.availableFontFamilies.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            // Skip the system "." families — these are private faces
            // (SF Symbols etc.) that aren't valid for general text.
            if family.hasPrefix(".") { continue }
            // Each family lists [postScriptName, weight, ...] members.
            // We pick the first member as the representative face.
            guard let members = manager.availableMembers(ofFontFamily: family),
                  let first = members.first,
                  let post = first[0] as? String,
                  let probe = NSFont(name: post, size: 12)
            else { continue }
            out.append((post: post, label: family, fixedPitch: probe.isFixedPitch))
        }
        return out
    }()

    /// Filter the cached scan to what the picker should show now.
    /// "System Monospace" is always pinned to the top so a user with
    /// no custom monospaced fonts still has a valid choice.
    private static func loadInstalledFonts(includeProportional: Bool) -> [FontOption] {
        var out: [FontOption] = [FontOption(post: "", label: "System Monospace")]
        for entry in allInstalledFontsCache {
            if !includeProportional && !entry.fixedPitch { continue }
            out.append(FontOption(post: entry.post, label: entry.label))
        }
        return out
    }

    /// Compact color picker row — swatch on the right, hex code
    /// trailing behind. Matches the macOS Display preferences shape.
    private func colorRow(_ label: String, hex: Binding<String>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 10) {
                ColorPicker("", selection: nsColorBinding(hex), supportsOpacity: false)
                    .labelsHidden()
                Text(hex.wrappedValue.uppercased())
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
            }
        }
    }

    private var preview: some View {
        let bg = NSColor.fromHex(settings.terminalBackgroundHex) ?? .black
        let fg = NSColor.fromHex(settings.terminalForegroundHex) ?? .white
        let cursor = NSColor.fromHex(settings.terminalCursorHex) ?? fg
        let previewFont: Font = {
            if !settings.terminalFontName.isEmpty,
               let ns = NSFont(name: settings.terminalFontName, size: CGFloat(settings.terminalFontSize)) {
                return Font(ns as CTFont)
            }
            return .system(size: settings.terminalFontSize, design: .monospaced)
        }()
        return VStack(alignment: .leading, spacing: 6) {
            Text("admin@bluesky:~$ uptime")
                .font(previewFont)
                .foregroundStyle(Color(nsColor: fg))
            HStack(spacing: 0) {
                Text(" 09:42  up 7 days, 14:08,  2 users,  load average: 0.21")
                    .font(previewFont)
                    .foregroundStyle(Color(nsColor: fg))
                Rectangle()
                    .fill(Color(nsColor: cursor))
                    .frame(width: settings.terminalFontSize * 0.55,
                           height: settings.terminalFontSize * 1.1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: bg))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3))
        )
    }

    /// Bridge between the `@AppStorage` String + SwiftUI `ColorPicker`'s
    /// `Color` binding. The canonical value stays as a hex string so
    /// `TerminalSession.applyAppearance` can read it directly without
    /// re-importing SwiftUI.
    private func nsColorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor.fromHex(hex.wrappedValue) ?? .white) },
            set: { newColor in hex.wrappedValue = NSColor(newColor).hexString }
        )
    }

    // MARK: - Presets

    /// Foreground for all four colored presets — bright green
    /// (Dracula palette). Readable on red, bright blue, navy, and
    /// black backgrounds so the same text color works everywhere
    /// without needing per-profile per-element tuning.
    private static let presetForeground = "#50FA7B"

    private func applyRedDead() {
        settings.terminalBackgroundHex = "#8a0c0f"
        settings.terminalForegroundHex = Self.presetForeground
        settings.terminalCursorHex     = "#ffffff"
        applyInconsolata(size: 14)
    }

    private func applyOpenWater() {
        settings.terminalBackgroundHex = "#2f32ff"
        settings.terminalForegroundHex = Self.presetForeground
        settings.terminalCursorHex     = "#ffffff"
        applyInconsolata(size: 14)
    }

    private func applyDeepSea() {
        settings.terminalBackgroundHex = "#121172"
        settings.terminalForegroundHex = Self.presetForeground
        settings.terminalCursorHex     = "#ffffff"
        applyInconsolata(size: 14)
    }

    private func applyPeppermint() {
        settings.terminalBackgroundHex = "#0f0f0f"
        settings.terminalForegroundHex = Self.presetForeground
        settings.terminalCursorHex     = "#ff2734"
        applyInconsolata(size: 14)
    }

    private func applyHighContrast() {
        settings.terminalBackgroundHex = "#000000"
        settings.terminalForegroundHex = "#ffffff"
        settings.terminalCursorHex     = "#ffeb3b"  // yellow caret, very visible
        settings.terminalFontSize      = 14
    }

    /// "Reset to Defaults" intentionally lands on Peppermint — the
    /// matching SettingsStore default values — rather than the older
    /// plain white-on-black. Operators reading the BSC fleet expect a
    /// readable green-on-near-black terminal, not the macOS factory
    /// blank slate.
    private func resetToDefaults() {
        applyPeppermint()
    }

    /// Set the font to Inconsolata at `size` if installed. Otherwise
    /// pick the system monospace face so the preset still renders
    /// recognizably on machines without Inconsolata.
    private func applyInconsolata(size: Double) {
        if NSFont(name: "Inconsolata-Regular", size: CGFloat(size)) != nil {
            settings.terminalFontName = "Inconsolata-Regular"
        } else {
            settings.terminalFontName = ""
        }
        settings.terminalFontSize = size
    }
}
