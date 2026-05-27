import AppKit
import SwiftTerm

/// Custom 16-color ANSI palette installed on every SwiftTerm view.
/// Two intentional divergences from xterm defaults:
///   - **ANSI 4 + 12 (blue / bright blue)** remapped to near-white so
///     shell prompts that paint the hostname blue stay readable on
///     the dark backgrounds we ship (Peppermint / Deep Sea etc.).
///   - **ANSI 1 + 9 (red / bright red)** remapped to gold/amber so
///     shell prompts that paint the username red stay readable on the
///     Red Dead background (#8a0c0f) AND keep solid contrast on the
///     blue/navy/black presets. Side effect: vim error lines, git
///     delete diffs, and `ls` symlink dangles will also render gold;
///     trade-off accepted because operators stare at the prompt 100×
///     more than they hit a vim error.
/// The remaining 12 colors mirror xterm so vim, git, ls --color, etc.
/// look the way the operator expects everywhere else.
enum BlueConnectAnsiPalette {
    static let colors: [SwiftTerm.Color] = [
        // Standard 0–7
        st("#000000"),   // 0 black
        st("#ffd700"),   // 1 red → gold (username remap)
        st("#00c200"),   // 2 green
        st("#c7c400"),   // 3 yellow
        st("#ebebeb"),   // 4 blue → white-ish (hostname remap)
        st("#c930c7"),   // 5 magenta
        st("#00c5c7"),   // 6 cyan
        st("#c7c7c7"),   // 7 white (light gray, xterm default)
        // Bright 8–15
        st("#686868"),   // 8  bright black (gray)
        st("#ffd700"),   // 9  bright red → gold (matches ANSI 1)
        st("#5ffa68"),   // 10 bright green
        st("#fffc67"),   // 11 bright yellow
        st("#ffffff"),   // 12 bright blue → pure white
        st("#ff77ff"),   // 13 bright magenta
        st("#60fdff"),   // 14 bright cyan
        st("#ffffff"),   // 15 bright white
    ]

    /// SwiftTerm's `Color` takes 16-bit channels (0…65535). NSColor's
    /// hex parser produces 8-bit values in `[0…1]` floats; scale into
    /// SwiftTerm's range with a single multiply.
    private static func st(_ hex: String) -> SwiftTerm.Color {
        let ns = NSColor.fromHex(hex) ?? .white
        let rgb = ns.usingColorSpace(.deviceRGB) ?? ns
        return SwiftTerm.Color(
            red:   UInt16(rgb.redComponent   * 65535),
            green: UInt16(rgb.greenComponent * 65535),
            blue:  UInt16(rgb.blueComponent  * 65535)
        )
    }
}
