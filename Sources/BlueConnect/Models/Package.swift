import Foundation

/// One package the user can install on a remote host. Either points to
/// a downloadable installer (`file`) or runs a raw shell command
/// (`command`). At least one of the two must be set.
struct Package: Codable, Hashable, Identifiable {
    /// Display label in the menu.
    var name: String
    /// Filename relative to the catalog's `baseURL`. When set, expands to
    /// `curl -L <baseURL>/<file> -o /tmp/<file> && sudo installer -pkg /tmp/<file> -target /`.
    var file: String?
    /// Raw shell command. Runs as-is over SSH.
    var command: String?
    /// Optional grouping label (e.g. "Munki", "Uninstall").
    var group: String?
    /// Optional one-liner shown under the name in the picker sheet.
    var description: String?
    /// Optional SF Symbol name. Falls back to a sensible default by group
    /// when nil (Uninstall → trash, kind=command → terminal, else → shippingbox).
    var iconName: String?
    /// When true, show a confirmation alert before running. Auto-set true
    /// for anything in the "Uninstall" group too.
    var destructive: Bool?
    /// Pulled from the .pkg's PackageInfo (`version`) or the .app's
    /// `CFBundleShortVersionString`. Surfaces in the picker preview.
    /// Populated by `tools/extract-metadata.sh` (server-side) or the
    /// in-app local-metadata reader.
    var version: String?
    /// Pulled from the .pkg's PackageInfo identifier or the .app's
    /// `CFBundleIdentifier`.
    var bundleID: String?
    /// Pulled from the .app's `CFBundleVersion`.
    var buildNumber: String?
    /// Pulled from the .app's `LSMinimumSystemVersion`.
    var minSystem: String?

    var id: String { "\(group ?? "")|\(name)" }

    /// True if this row triggers a confirmation prompt before executing.
    var isDestructive: Bool {
        if let d = destructive { return d }
        return (group ?? "").localizedCaseInsensitiveContains("uninstall")
    }

    /// SF Symbol shown next to the package name.
    var resolvedIcon: String {
        if let icon = iconName, !icon.isEmpty { return icon }
        if isDestructive { return "trash" }
        if command != nil { return "terminal" }
        return "shippingbox.fill"
    }
}

/// Catalog of packages a remote host can pull. Hosted as a single JSON
/// document at any direct-download HTTPS URL: a personal server,
/// GitHub Releases, S3/R2/GCS, Dropbox shared link, Nextcloud, etc.
struct PackageCatalog: Codable, Hashable {
    /// Catalog kind. Affects how `downloadURL(for:)` builds the per-file URL.
    enum Kind: String, Codable {
        /// `<baseURL>/<file>` — works for personal HTTPS servers, GitHub
        /// Releases, S3/R2/GCS, etc.
        case plain
        /// Nextcloud public-folder share. `baseURL` is the share URL like
        /// `https://cloud.example.com/s/<token>`. Expands to
        /// `<baseURL>/download?path=%2F&files=<file>`.
        case nextcloud
    }

    var name: String?
    var baseURL: String
    var kind: Kind = .plain
    var packages: [Package] = []

    enum CodingKeys: String, CodingKey {
        case name, baseURL, kind, packages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        kind = (try c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .plain
        packages = (try c.decodeIfPresent([Package].self, forKey: .packages)) ?? []
    }

    init(name: String? = nil, baseURL: String, kind: Kind = .plain, packages: [Package] = []) {
        self.name = name; self.baseURL = baseURL; self.kind = kind; self.packages = packages
    }

    /// HTTPS URL the remote host should curl to fetch this package's installer.
    func downloadURL(for filename: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        switch kind {
        case .plain:
            return "\(trimmed)/\(encoded)"
        case .nextcloud:
            // Public share download: /s/<token>/download?path=/&files=<file>
            return "\(trimmed)/download?path=%2F&files=\(encoded)"
        }
    }

    /// Shell command to run on the remote host for this package.
    /// Falls back to `command` if `file` isn't set.
    func remoteCommand(for pkg: Package) -> String? {
        if let cmd = pkg.command, !cmd.isEmpty { return cmd }
        guard let file = pkg.file, !file.isEmpty else { return nil }
        let url = downloadURL(for: file)
        let tmp = "/tmp/\(file)"
        // -L follows redirects (Dropbox, Nextcloud rewrite); -f fails the pipeline
        // on HTTP errors so we don't try to install an HTML 404 page.
        return "curl -fL '\(url)' -o '\(tmp)' && sudo installer -pkg '\(tmp)' -target /"
    }

    /// Packages grouped by their `group` field, preserving JSON order.
    var grouped: [(group: String, items: [Package])] {
        var seen: [String] = []
        var byGroup: [String: [Package]] = [:]
        for p in packages {
            let g = p.group ?? ""
            if byGroup[g] == nil { seen.append(g) }
            byGroup[g, default: []].append(p)
        }
        return seen.map { ($0, byGroup[$0] ?? []) }
    }
}
