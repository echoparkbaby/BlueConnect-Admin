import Foundation

extension String {
    /// Unwind double-encoded UTF-8 (a.k.a. "mojibake") that crept in via
    /// the BSC server's latin1 → utf8 round-trip on names like
    /// `ladmin’s MacBook Air`. After the round-trip, the original three
    /// UTF-8 bytes of `’` (0xE2 0x80 0x99) end up rendered as the three
    /// glyphs `â€™` and re-stored as a valid (but wrong) UTF-8 string
    /// of six bytes.
    ///
    /// Strategy:
    ///   1. Look for telltale mojibake glyph pairs.
    ///   2. Encode the string as Windows-1252 — that recovers the
    ///      *original* byte sequence the database probably wanted to hold.
    ///   3. Decode those bytes back as UTF-8.
    ///   4. If both encode + decode round-trip cleanly, the result is the
    ///      original text. If not, return the input unchanged.
    func unmojibake() -> String {
        let markers = ["â€", "Ã©", "Ã¨", "Ã ", "Ã­", "â‚¬", "â„¢", "â„¢", "â", "Ã"]
        guard markers.contains(where: { self.contains($0) }) else { return self }
        guard let win1252 = self.data(using: .windowsCP1252) else { return self }
        guard let fixed = String(data: win1252, encoding: .utf8), !fixed.isEmpty else {
            return self
        }
        return fixed
    }
}
