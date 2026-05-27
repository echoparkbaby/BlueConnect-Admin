import AppKit

/// Tiny hex ↔ NSColor bridge. The Terminal preferences store colors as
/// `#RRGGBB` strings in `@AppStorage` (which only supports primitives);
/// this is the only place that conversion lives, so the SwiftUI color
/// well and the SwiftTerm `LocalProcessTerminalView.nativeBackgroundColor`
/// setter both go through the same canonical form.
extension NSColor {
    /// Returns `#RRGGBB`, lowercased, in the device RGB colorspace.
    /// Alpha is ignored — the terminal's background/foreground/cursor
    /// don't model transparency.
    var hexString: String {
        let rgb = usingColorSpace(.deviceRGB) ?? self
        let r = Int(round(rgb.redComponent   * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent  * 255))
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    /// Parse `#RRGGBB` / `RRGGBB` (case-insensitive). Returns nil on
    /// any malformed input; callers fall back to a sensible default
    /// rather than crashing on a corrupt AppStorage value.
    static func fromHex(_ hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(
            srgbRed:  CGFloat((v >> 16) & 0xff) / 255,
            green:    CGFloat((v >>  8) & 0xff) / 255,
            blue:     CGFloat( v        & 0xff) / 255,
            alpha: 1
        )
    }
}
