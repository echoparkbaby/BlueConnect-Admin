import Foundation

/// Metadata pulled from a local installer file. All fields are optional
/// — readers populate what they can; missing values just stay nil.
struct PackageMetadata: Equatable {
    var displayName: String?
    var version: String?
    var buildNumber: String?
    var bundleID: String?
    var minSystem: String?

    var hasContent: Bool {
        displayName != nil || version != nil || bundleID != nil
            || buildNumber != nil || minSystem != nil
    }

    /// Read metadata from a local .pkg / .app / .dmg. `.app` is synchronous
    /// (just an Info.plist read). `.pkg` shells out to `xar` so it's async.
    /// Returns `nil` only if extraction failed entirely.
    static func read(from url: URL) async -> PackageMetadata? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "app":
            return readApp(at: url)
        case "pkg":
            return await Task.detached(priority: .userInitiated) {
                readPkg(at: url)
            }.value
        default:
            return nil
        }
    }

    // MARK: - .app (Info.plist)

    private static func readApp(at appURL: URL) -> PackageMetadata? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = (try? PropertyListSerialization
                .propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else { return nil }
        return PackageMetadata(
            displayName: (plist["CFBundleDisplayName"] as? String)
                ?? (plist["CFBundleName"] as? String),
            version: plist["CFBundleShortVersionString"] as? String,
            buildNumber: plist["CFBundleVersion"] as? String,
            bundleID: plist["CFBundleIdentifier"] as? String,
            minSystem: plist["LSMinimumSystemVersion"] as? String
        )
    }

    // MARK: - .pkg (xar + PackageInfo XML)

    private static func readPkg(at pkgURL: URL) -> PackageMetadata? {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bcadmin-pkg-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let xar = Process()
        xar.executableURL = URL(fileURLWithPath: "/usr/bin/xar")
        xar.arguments = ["-x", "-f", pkgURL.path, "PackageInfo", "Distribution"]
        xar.currentDirectoryURL = temp
        xar.standardError = Pipe()
        xar.standardOutput = Pipe()
        do {
            try xar.run()
            xar.waitUntilExit()
        } catch {
            return nil
        }

        let pkgInfoData = (try? Data(contentsOf: temp.appendingPathComponent("PackageInfo"))) ?? Data()
        let pkgInfoXML = String(data: pkgInfoData, encoding: .utf8) ?? ""
        let distData = (try? Data(contentsOf: temp.appendingPathComponent("Distribution"))) ?? Data()
        let distXML = String(data: distData, encoding: .utf8) ?? ""

        let id = attribute(in: pkgInfoXML, tag: "pkg-info", attr: "identifier")
            ?? attribute(in: distXML, tag: "pkg-ref", attr: "id")
        let version = attribute(in: pkgInfoXML, tag: "pkg-info", attr: "version")
            ?? attribute(in: distXML, tag: "pkg-ref", attr: "version")
        let title = tagText(in: distXML, tag: "title")
        let minSystem = attribute(in: distXML, tag: "options", attr: "hostArchitectures") // not perfect; pkgs vary
            ?? attribute(in: distXML, tag: "allowed-os-versions", attr: "min")

        if id == nil && version == nil && title == nil { return nil }
        return PackageMetadata(
            displayName: title,
            version: version,
            buildNumber: nil,
            bundleID: id,
            minSystem: minSystem
        )
    }

    // MARK: - Tiny XML helpers (avoid full XMLParser ceremony for two attrs)

    /// Pull `attr="value"` from the first `<tag …>` occurrence in `xml`.
    private static func attribute(in xml: String, tag: String, attr: String) -> String? {
        guard let tagRange = xml.range(of: "<\(tag)") else { return nil }
        guard let attrStart = xml.range(of: "\(attr)=\"", range: tagRange.upperBound..<xml.endIndex)
        else { return nil }
        // Stop at the next "
        guard let attrEnd = xml.range(of: "\"", range: attrStart.upperBound..<xml.endIndex)
        else { return nil }
        let value = xml[attrStart.upperBound..<attrEnd.lowerBound]
        return value.isEmpty ? nil : String(value)
    }

    /// Pull `<tag>value</tag>` text content from `xml`.
    private static func tagText(in xml: String, tag: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>") else { return nil }
        guard let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex)
        else { return nil }
        let v = xml[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}
