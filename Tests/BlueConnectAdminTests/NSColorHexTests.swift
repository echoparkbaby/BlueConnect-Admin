import Testing
import AppKit
@testable import BlueConnectAdmin

/// Tiny hex ↔ NSColor bridge used by the Terminal preferences pane
/// (color pickers stored as `#RRGGBB` strings in @AppStorage) and by
/// the ANSI palette installer. A regression that drops alpha or
/// silently accepts malformed input would produce wrong terminal
/// colors with no visible error, so the round-trip is pinned here.
@Suite("NSColor hex bridge")
@MainActor
struct NSColorHexTests {

    @Test func roundTripIsLossless() {
        let original = "#50fa7b"
        guard let parsed = NSColor.fromHex(original) else {
            Issue.record("Expected fromHex to parse \(original)")
            return
        }
        #expect(parsed.hexString == original)
    }

    @Test func parserAcceptsCaseInsensitive() {
        let upper = NSColor.fromHex("#FFD700")
        let lower = NSColor.fromHex("#ffd700")
        #expect(upper?.hexString == "#ffd700")
        #expect(lower?.hexString == "#ffd700")
    }

    @Test func parserAcceptsMissingHashPrefix() {
        let c = NSColor.fromHex("00ff00")
        #expect(c?.hexString == "#00ff00")
    }

    @Test func parserRejectsMalformed() {
        #expect(NSColor.fromHex("") == nil)
        #expect(NSColor.fromHex("#12345") == nil)        // 5 digits
        #expect(NSColor.fromHex("#GGHHII") == nil)       // non-hex
        #expect(NSColor.fromHex("#12345678") == nil)     // 8 digits (alpha not supported)
    }

    @Test func hexStringFromKnownNSColor() {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        #expect(red.hexString == "#ff0000")
    }

    @Test func hexStringIgnoresAlpha() {
        // alpha is not modeled — translucent inputs round to their
        // RGB triplet only. Same as how the terminal renderer ignores
        // alpha on bg/fg/cursor.
        let semi = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5)
        #expect(semi.hexString == "#0000ff")
    }
}
