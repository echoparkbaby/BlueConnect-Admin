import Foundation
import Observation
import CryptoKit

/// Fetches and parses a Munki repo's `catalogs/all` from a Wasabi /
/// S3-compatible bucket. We shell out to `curl --aws-sigv4` so we don't
/// have to implement SigV4 by hand — curl 7.75+ supports it natively and
/// every supported macOS version ships a recent-enough curl.
///
/// Catalogs are cached on disk so the sidebar / browser opens instantly
/// on subsequent launches. Refresh runs in the background after the
/// cache is shown; a force-refresh ignores the freshness check.
@Observable
@MainActor
final class MunkiRepoStore {
    var packages: [MunkiPkg] = []
    var isLoading = false
    var lastError: String?
    var lastFetched: Date?

    /// Cached catalog is considered "fresh" within this window. Past the
    /// window we still display the cache but trigger a background refresh.
    private static let cacheMaxAge: TimeInterval = 60 * 60 // 1 hour

    /// Refresh the package list. By default uses cache when fresh; pass
    /// `force: true` to bypass the freshness check (e.g. the user clicked
    /// the refresh button explicitly).
    func refresh(force: Bool = false, settings: SettingsStore) async {
        guard settings.isMunkiRepoConfigured else {
            lastError = "Munki Repo credentials missing — fill them in under Settings → Munki Repo."
            return
        }
        // Hydrate from disk first so the UI has something to show
        // immediately, even if network is slow.
        if packages.isEmpty { loadFromCacheIfPresent(settings: settings) }
        if !force, let when = lastFetched,
           Date().timeIntervalSince(when) < Self.cacheMaxAge {
            return
        }
        isLoading = true
        defer { isLoading = false }
        lastError = nil

        do {
            let data = try await fetchCatalogAll(settings: settings)
            packages = try Self.parse(data: data)
            lastFetched = Date()
            saveToCache(data: data, settings: settings)
        } catch {
            // Soft-fail when we have cached packages already on screen —
            // the user keeps their data, the error surfaces only when
            // there's nothing else to show.
            if packages.isEmpty {
                lastError = error.localizedDescription
            }
        }
    }

    /// Pull packages from disk if a cache for the current settings exists.
    /// Safe to call repeatedly; idempotent and synchronous (cheap plist
    /// parse).
    func loadFromCacheIfPresent(settings: SettingsStore) {
        let url = Self.cacheFileURL(settings: settings)
        guard let data = try? Data(contentsOf: url),
              let parsed = try? Self.parse(data: data)
        else { return }
        packages = parsed
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let mod = attrs[.modificationDate] as? Date {
            lastFetched = mod
        }
    }

    private func saveToCache(data: Data, settings: SettingsStore) {
        let url = Self.cacheFileURL(settings: settings)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Per-(endpoint, bucket, prefix) cache file. Hashed so weird chars in
    /// the endpoint can't escape the cache directory.
    static func cacheFileURL(settings: SettingsStore) -> URL {
        let combo = "\(settings.munkiRepoEndpoint)|\(settings.munkiRepoBucket)|\(settings.munkiRepoPrefix)"
        let digest = SHA256.hash(data: Data(combo.utf8))
        let key = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = support
            .appendingPathComponent("BlueConnectAdmin", isDirectory: true)
            .appendingPathComponent("MunkiCache", isDirectory: true)
        return dir.appendingPathComponent("\(key).plist")
    }

    /// Build the catalog URL, run curl, return the response body. Throws
    /// `MunkiRepoError.transport` on any failure, with curl's stderr and
    /// the HTTP response body included so SigV4 / Basic Auth mismatches
    /// surface clearly (Wasabi returns useful XML; Cloudflare proxies
    /// return useful HTML).
    private func fetchCatalogAll(settings: SettingsStore) async throws -> Data {
        try await fetch(key: "catalogs/all", settings: settings)
    }

    /// Generic GET against the repo with the configured auth mode.
    /// Returns the response body in memory — use for small payloads like
    /// catalogs and pkginfo files. For installers, use the file-direct
    /// variant below to avoid round-tripping hundreds of MB through Data.
    func fetch(key: String, settings: SettingsStore) async throws -> Data {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bcadmin-munki-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await fetch(key: key, to: tmp, settings: settings)
        return try Data(contentsOf: tmp)
    }

    /// Stream a key directly to disk. Critical for installer downloads:
    /// curl writes the bytes to `destination` itself, so we never load
    /// the package into Data and we never block the main actor on a long
    /// `Process.waitUntilExit()`. The blocking call runs in a detached
    /// task; the main actor only resumes when curl exits.
    func fetch(key: String, to destination: URL, settings: SettingsStore) async throws {
        let url = Self.catalogURL(endpoint: settings.munkiRepoEndpoint,
                                  bucket: settings.munkiRepoBucket,
                                  prefix: settings.munkiRepoPrefix,
                                  key: key)
        let args = Self.curlArgs(url: url, destination: destination, settings: settings)

        // Hop off the main actor — Process.waitUntilExit() would otherwise
        // beachball the UI for the full duration of the download.
        let result = try await Task.detached(priority: .userInitiated) {
            try Self.runCurl(args: args)
        }.value

        if result.status != 0 {
            // The response body (if any) was written to `destination`
            // when --fail-with-body fires — for 401/403/404 from Wasabi
            // or Cloudflare this is gold.
            var bodyPreview = ""
            if let body = try? Data(contentsOf: destination),
               let s = String(data: body, encoding: .utf8) {
                bodyPreview = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if bodyPreview.count > 600 {
                    bodyPreview = String(bodyPreview.prefix(600)) + "…"
                }
            }
            // Discard the partial/error body so the caller never mistakes
            // it for a real installer.
            try? FileManager.default.removeItem(at: destination)
            let combined = [
                "URL: \(url)",
                "HTTP \(result.statusCode) · curl exit \(result.status)",
                result.stderrMsg,
                bodyPreview
            ].filter { !$0.isEmpty }.joined(separator: "\n")
            throw MunkiRepoError.transport(combined)
        }
    }

    /// Build the curl argv based on the configured auth mode. Reads
    /// MainActor-isolated SettingsStore fields so it must stay on the
    /// main actor; the resulting `[String]` is Sendable and crosses
    /// the actor boundary into `Task.detached` cleanly.
    private static func curlArgs(
        url: String, destination: URL, settings: SettingsStore
    ) -> [String] {
        var args: [String] = [
            "--silent", "--show-error", "--fail-with-body", "--location",
            "--write-out", "%{http_code}",
            "--output", destination.path,
        ]
        // Auth: SigV4, Basic, both, or none. curl supports stacking `--user`
        // for both kinds: `--aws-sigv4` flips `--user` from Basic Auth to S3
        // signing for this request, so when we need BOTH we have to send
        // Basic Auth in a literal Authorization header AND keep `--user`
        // for SigV4.
        switch settings.munkiRepoAuthMode {
        case "none":
            break // plain HTTPS GET, no auth — public/firewalled web repos
        case "basic":
            args += ["--user", "\(settings.munkiRepoBasicUser):\(settings.munkiRepoBasicPassword)"]
        case "both":
            args += [
                "--aws-sigv4", "aws:amz:\(settings.munkiRepoRegion):s3",
                "--user", "\(settings.munkiRepoAccessKey):\(settings.munkiRepoSecretKey)",
                "--header", "Authorization: Basic " + basicAuthB64(
                    user: settings.munkiRepoBasicUser,
                    password: settings.munkiRepoBasicPassword)
            ]
        default: // "s3"
            args += [
                "--aws-sigv4", "aws:amz:\(settings.munkiRepoRegion):s3",
                "--user", "\(settings.munkiRepoAccessKey):\(settings.munkiRepoSecretKey)",
            ]
        }
        args.append(url)
        return args
    }

    /// Run curl and collect its termination status, --write-out body
    /// (HTTP code), and stderr. Throws Process spawn errors; HTTP-level
    /// errors come through as non-zero `status`.
    nonisolated private static func runCurl(
        args: [String]
    ) throws -> (status: Int32, statusCode: String, stderrMsg: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = args
        let stderr = Pipe()
        let stdout = Pipe()
        proc.standardError = stderr
        proc.standardOutput = stdout
        try proc.run()
        proc.waitUntilExit()
        let statusData = stdout.fileHandleForReading.readDataToEndOfFile()
        let statusCode = String(data: statusData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stderrMsg = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus, statusCode, stderrMsg)
    }

    /// "user:password" → base64, for stamping a literal Authorization
    /// header when --user is already claimed by --aws-sigv4.
    private static func basicAuthB64(user: String, password: String) -> String {
        let combo = "\(user):\(password)"
        return Data(combo.utf8).base64EncodedString()
    }

    /// Build the catalog URL: `https://<endpoint>[/<bucket>][/<prefix>]/<key>`.
    /// Strips schemes and stray slashes from each component so we never
    /// emit `https://host//bucket///prefix/key`.
    static func catalogURL(endpoint: String,
                           bucket: String,
                           prefix: String,
                           key: String) -> String {
        var host = endpoint
        if let r = host.range(of: "https://") { host.removeSubrange(r) }
        if let r = host.range(of: "http://")  { host.removeSubrange(r) }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let trim = CharacterSet(charactersIn: "/ ")
        let bucketPart = bucket.trimmingCharacters(in: .whitespaces).isEmpty
            ? "" : "/\(bucket.trimmingCharacters(in: trim))"
        let prefixPart = prefix.trimmingCharacters(in: .whitespaces).isEmpty
            ? "" : "/\(prefix.trimmingCharacters(in: trim))"
        return "https://\(host)\(bucketPart)\(prefixPart)/\(key)"
    }

    /// Parse `catalogs/all` (binary or XML plist of dicts) into `MunkiPkg`s.
    static func parse(data: Data) throws -> [MunkiPkg] {
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
        guard let arr = plist as? [[String: Any]] else {
            throw MunkiRepoError.parse("catalogs/all is not a plist array of dicts")
        }
        return arr.map(MunkiPkg.init(dict:))
    }
}

enum MunkiRepoError: LocalizedError {
    case transport(String)
    case parse(String)
    var errorDescription: String? {
        switch self {
        case .transport(let msg): return "Repo fetch failed: \(msg)"
        case .parse(let msg):     return "Catalog parse failed: \(msg)"
        }
    }
}

/// Minimal projection of a Munki pkginfo dict — enough to render a useful
/// browser. The repo's authoritative pkginfo has dozens of keys but most
/// aren't needed for the picker.
struct MunkiPkg: Identifiable, Hashable {
    var id: String { "\(name)|\(version)" }
    let name: String
    let displayName: String?
    let version: String
    let description: String?
    let catalogs: [String]
    let installerItemLocation: String?
    let installerItemSize: Int?      // KB (Munki convention)
    let minimumOSVersion: String?
    let supportedArchitectures: [String]
    let category: String?
    let developer: String?

    var resolvedDisplayName: String { displayName?.isEmpty == false ? displayName! : name }

    /// Human-readable file size. Munki stores `installer_item_size` in KB.
    var humanSize: String {
        guard let kb = installerItemSize, kb > 0 else { return "—" }
        let bytes = Int64(kb) * 1024
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var archSummary: String {
        supportedArchitectures.isEmpty ? "Universal?" : supportedArchitectures.joined(separator: " / ")
    }

    init(dict: [String: Any]) {
        self.name = (dict["name"] as? String) ?? "(unnamed)"
        self.displayName = dict["display_name"] as? String
        self.version = (dict["version"] as? String) ?? "?"
        self.description = dict["description"] as? String
        self.catalogs = (dict["catalogs"] as? [String]) ?? []
        self.installerItemLocation = dict["installer_item_location"] as? String
        self.installerItemSize = dict["installer_item_size"] as? Int
        self.minimumOSVersion = dict["minimum_os_version"] as? String
        self.supportedArchitectures = (dict["supported_architectures"] as? [String]) ?? []
        self.category = dict["category"] as? String
        self.developer = dict["developer"] as? String
    }

    /// Used by the picker when collapsing catalog-membership duplicates —
    /// keeps the chosen pkginfo (newest version) but unions the catalogs
    /// list so the UI still shows e.g. "testing, production".
    private init(name: String, displayName: String?, version: String,
                 description: String?, catalogs: [String],
                 installerItemLocation: String?, installerItemSize: Int?,
                 minimumOSVersion: String?, supportedArchitectures: [String],
                 category: String?, developer: String?) {
        self.name = name
        self.displayName = displayName
        self.version = version
        self.description = description
        self.catalogs = catalogs
        self.installerItemLocation = installerItemLocation
        self.installerItemSize = installerItemSize
        self.minimumOSVersion = minimumOSVersion
        self.supportedArchitectures = supportedArchitectures
        self.category = category
        self.developer = developer
    }

    func withMergedCatalogs(_ merged: [String]) -> MunkiPkg {
        MunkiPkg(name: name, displayName: displayName, version: version,
                 description: description, catalogs: merged,
                 installerItemLocation: installerItemLocation,
                 installerItemSize: installerItemSize,
                 minimumOSVersion: minimumOSVersion,
                 supportedArchitectures: supportedArchitectures,
                 category: category, developer: developer)
    }
}
