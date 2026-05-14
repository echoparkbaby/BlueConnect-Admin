import Foundation
import SwiftUI

@MainActor
final class SettingsStore: ObservableObject {
    /// Full URL for the JSON host-list endpoint's *base*. The app appends
    /// `/bs_hosts.json.php` to this. Examples:
    ///   https://bluesky.example.com
    ///   http://10.0.0.10:8095
    /// Empty by default — user fills it in via the LoginView on first launch.
    @AppStorage("apiURL") var apiURL: String = ""
    @AppStorage("apiUsername") var apiUsername: String = "admin"
    /// Loaded from Keychain at runtime; not persisted in UserDefaults.
    @Published var webAdminPass: String = ""

    func loadPasswordFromKeychain() {
        guard !apiUsername.isEmpty else { webAdminPass = ""; return }
        webAdminPass = KeychainHelper.read(account: keychainAccount) ?? ""
    }

    func savePasswordToKeychain() {
        guard !apiUsername.isEmpty else { return }
        KeychainHelper.save(webAdminPass, account: keychainAccount)
    }

    func clearCredentials() {
        KeychainHelper.delete(account: keychainAccount)
        webAdminPass = ""
    }

    private var keychainAccount: String {
        // Per (apiURL + username) so multiple servers can coexist.
        "\(apiURL)|\(apiUsername)"
    }

    /// Host for the SSH ProxyCommand. Often the same machine the API points to.
    @AppStorage("serverFqdn") var serverFqdn: String = ""
    @AppStorage("sshTunnelPort") var sshTunnelPort: Int = 3122
    @AppStorage("adminKeyPath") var adminKeyPath: String = "~/.ssh/bluesky_admin"
    @AppStorage("defaultRemoteUser") var defaultRemoteUser: String = "ladmin"
    @AppStorage("hideInactive") var hideInactive: Bool = false  // "Active only" filter
    @AppStorage("showOnlyInactive") var showOnlyInactive: Bool = false  // "Inactive only" filter

    // Column visibility
    @AppStorage("colShowFavorite") var colShowFavorite: Bool = true
    @AppStorage("colShowActive") var colShowActive: Bool = true
    @AppStorage("colShowID") var colShowID: Bool = true
    @AppStorage("colShowConnect") var colShowConnect: Bool = true
    @AppStorage("colShowUser") var colShowUser: Bool = true
    @AppStorage("colShowRecent") var colShowRecent: Bool = true
    @AppStorage("colShowStatus") var colShowStatus: Bool = true
    @AppStorage("colShowLastSeen") var colShowLastSeen: Bool = true
    @AppStorage("colShowNotes") var colShowNotes: Bool = true

    // Notifications
    @AppStorage("notifyOnStateChange") var notifyOnStateChange: Bool = false

    /// Auto-lock idle timeout in minutes. 0 disables auto-lock.
    /// Only applies when Touch ID is required (otherwise nothing to lock).
    @AppStorage("idleLockMinutes") var idleLockMinutes: Int = 0

    /// Show the Local Network section and run the Bonjour browser. On by
    /// default — turn it off if you don't want the app to discover machines
    /// on your LAN (silences the macOS Local Network privacy prompt too).
    @AppStorage("localNetworkEnabled") var localNetworkEnabled: Bool = true

    /// Show the Tailscale section in the sidebar and poll `tailscale status`.
    /// Off by default — opt in if you actually use the tailnet.
    @AppStorage("tailscaleEnabled") var tailscaleEnabled: Bool = false

    /// JSON-encoded `[String]` of Tailscale peer names that the user has
    /// hidden from the sidebar (machines without the BSC client, iOS,
    /// Windows, Linux peers they don't want to see, etc).
    @AppStorage("hiddenTailscalePeersJSON") var hiddenTailscalePeersJSON: String = "[]"

    var hiddenTailscalePeers: Set<String> {
        get {
            guard let data = hiddenTailscalePeersJSON.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return Set(arr)
        }
        set {
            let arr = Array(newValue).sorted()
            if let data = try? JSONEncoder().encode(arr),
               let s = String(data: data, encoding: .utf8) {
                hiddenTailscalePeersJSON = s
            }
        }
    }

    /// Global default ports used for every Tailscale peer. Per-peer
    /// overrides (below) take precedence. Defaults match macOS Remote
    /// Login (22) and Screen Sharing (5900); set these once if you've
    /// moved sshd / VNC across your fleet uniformly.
    @AppStorage("tailscaleSSHPort") var tailscaleSSHPort: Int = 22
    @AppStorage("tailscaleVNCPort") var tailscaleVNCPort: Int = 5900

    /// Global default remote user for every Tailscale peer. Empty falls
    /// back to `defaultRemoteUser`. Per-peer overrides take precedence.
    @AppStorage("tailscaleDefaultUser") var tailscaleDefaultUser: String = ""

    /// JSON-encoded per-peer port overrides, keyed by Tailscale peer name.
    /// Shape: `{"mahogany": {"ssh": 2222}, "beachwood": {"vnc": 5901}}`.
    /// Missing keys / nil fields fall back to the global defaults above.
    @AppStorage("tailscalePortOverridesJSON") var tailscalePortOverridesJSON: String = "{}"

    var tailscalePortOverrides: [String: PortOverride] {
        get {
            guard let data = tailscalePortOverridesJSON.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: PortOverride].self, from: data)
            else { return [:] }
            return dict
        }
        set {
            // Drop entries that don't actually override anything.
            let pruned = newValue.filter { _, v in v.ssh != nil || v.vnc != nil }
            if let data = try? JSONEncoder().encode(pruned),
               let s = String(data: data, encoding: .utf8) {
                tailscalePortOverridesJSON = s
            }
        }
    }

    /// Resolved SSH port for a given Tailscale peer name (override → global default).
    func tailscaleSSHPort(for peerName: String) -> Int {
        tailscalePortOverrides[peerName]?.ssh ?? tailscaleSSHPort
    }

    /// Resolved VNC port for a given Tailscale peer name (override → global default).
    func tailscaleVNCPort(for peerName: String) -> Int {
        tailscalePortOverrides[peerName]?.vnc ?? tailscaleVNCPort
    }

    /// Resolved remote user for a given Tailscale peer name. Order:
    /// per-peer override → tailscaleDefaultUser → defaultRemoteUser.
    func tailscaleUser(for peerName: String) -> String {
        if let u = tailscalePortOverrides[peerName]?.user, !u.isEmpty {
            return u
        }
        if !tailscaleDefaultUser.isEmpty {
            return tailscaleDefaultUser
        }
        return defaultRemoteUser
    }

    /// HTTPS URL to a package-catalog JSON that powers the Install Package
    /// menu on host rows. See `Models/Package.swift` for the schema.
    /// Empty disables the feature.
    @AppStorage("packageCatalogURL") var packageCatalogURL: String = ""

    /// Picks the protocol used to upload installers to your Package Repo.
    /// One service active at a time. Determines which structured fields
    /// in Settings are read when building the upload target URL.
    @AppStorage("packageRepoService") var packageRepoService: String = "ssh"

    // MARK: SSH / SFTP fields
    /// Raw SCP/SFTP target — `user@host:/path/` or `sftp://user@host:port/path/`.
    @AppStorage("packageUploadSCPPath") var packageUploadSCPPath: String = ""
    /// SSH private key path. Tilde-expanded by `expandedPackageUploadKeyPath`.
    @AppStorage("packageUploadKeyPath") var packageUploadKeyPath: String = "~/.ssh/id_rsa"

    // MARK: FTP / FTPS fields
    @AppStorage("packageRepoFTPHost")   var packageRepoFTPHost: String = ""
    @AppStorage("packageRepoFTPPort")   var packageRepoFTPPort: Int = 21
    @AppStorage("packageRepoFTPUser")   var packageRepoFTPUser: String = ""
    @AppStorage("packageRepoFTPPath")   var packageRepoFTPPath: String = "/"
    @AppStorage("packageRepoFTPSecure") var packageRepoFTPSecure: Bool = false
    /// FTP password loaded from Keychain at runtime; not persisted in UserDefaults.
    @Published var ftpPassword: String = ""

    // MARK: Nextcloud (WebDAV) fields
    @AppStorage("packageRepoNextcloudServer") var packageRepoNextcloudServer: String = ""
    @AppStorage("packageRepoNextcloudUser")   var packageRepoNextcloudUser: String = ""
    @AppStorage("packageRepoNextcloudPath")   var packageRepoNextcloudPath: String = "/"
    /// Nextcloud app password loaded from Keychain at runtime.
    @Published var nextcloudPassword: String = ""

    var expandedPackageUploadKeyPath: String {
        NSString(string: packageUploadKeyPath).expandingTildeInPath
    }

    /// True when the currently-selected service has enough configuration
    /// to attempt an upload. Picker UI dims the Refresh / drop affordances
    /// when this is false.
    var isPackageRepoConfigured: Bool {
        switch packageRepoService {
        case "ftp":
            return !packageRepoFTPHost.isEmpty && !packageRepoFTPUser.isEmpty && !ftpPassword.isEmpty
        case "nextcloud":
            return !packageRepoNextcloudServer.isEmpty
                && !packageRepoNextcloudUser.isEmpty
                && !nextcloudPassword.isEmpty
        default:
            return !packageUploadSCPPath.isEmpty
        }
    }

    /// Resolved upload URL for the active service. Built from the
    /// structured fields (FTP/Nextcloud) or returned verbatim (SSH).
    var packageRepoUploadURL: String {
        switch packageRepoService {
        case "ftp":
            return ftpUploadURL
        case "nextcloud":
            return nextcloudUploadURL
        default:
            return packageUploadSCPPath
        }
    }

    private var ftpUploadURL: String {
        let scheme = packageRepoFTPSecure ? "ftps" : "ftp"
        let portPart = (packageRepoFTPPort > 0 && packageRepoFTPPort != 21)
            ? ":\(packageRepoFTPPort)" : ""
        let user = packageRepoFTPUser
            .addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? packageRepoFTPUser
        let pw = ftpPassword
            .addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? ftpPassword
        var path = packageRepoFTPPath
        if !path.hasPrefix("/") { path = "/" + path }
        if !path.hasSuffix("/") { path += "/" }
        return "\(scheme)://\(user):\(pw)@\(packageRepoFTPHost)\(portPart)\(path)"
    }

    private var nextcloudUploadURL: String {
        var server = packageRepoNextcloudServer
        var scheme = "https"
        if let r = server.range(of: "https://") { server.removeSubrange(r) }
        else if let r = server.range(of: "http://") { scheme = "http"; server.removeSubrange(r) }
        server = server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let user = packageRepoNextcloudUser
            .addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? packageRepoNextcloudUser
        let pw = nextcloudPassword
            .addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? nextcloudPassword
        let userInPath = packageRepoNextcloudUser
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? packageRepoNextcloudUser

        var path = packageRepoNextcloudPath
        if !path.hasPrefix("/") { path = "/" + path }
        if !path.hasSuffix("/") { path += "/" }

        return "\(scheme)://\(user):\(pw)@\(server)/remote.php/dav/files/\(userInPath)\(path)"
    }

    // MARK: Keychain — FTP / Nextcloud passwords

    private static let ftpPasswordAccount = "BlueConnectAdmin.packageRepoFTPPassword"
    private static let nextcloudPasswordAccount = "BlueConnectAdmin.packageRepoNextcloudPassword"

    func loadRepoPasswordsFromKeychain() {
        ftpPassword = KeychainHelper.read(account: Self.ftpPasswordAccount) ?? ""
        nextcloudPassword = KeychainHelper.read(account: Self.nextcloudPasswordAccount) ?? ""
    }

    func saveFTPPassword() {
        KeychainHelper.save(ftpPassword, account: Self.ftpPasswordAccount)
    }

    func saveNextcloudPassword() {
        KeychainHelper.save(nextcloudPassword, account: Self.nextcloudPasswordAccount)
    }

    // MARK: erase-install (Graham Pugh)
    /// Path on the *remote* host to `erase-install.sh`. Default matches
    /// Graham Pugh's standard pkg install location.
    @AppStorage("eraseInstallPath") var eraseInstallPath: String =
        "/Library/Management/erase-install/erase-install.sh"
    /// Flags appended to every erase-install invocation, in addition to
    /// the mode-specific flags chosen in the run sheet.
    @AppStorage("eraseInstallDefaultFlags") var eraseInstallDefaultFlags: String =
        "--min-drive-space=50 --cleanup-after-use --check-power --power-wait-limit 180"

    /// JSON-encoded last-10 erase-install run specs, newest first.
    /// Stored verbatim — the sheet reads + applies, and pushes a new
    /// entry onto the front whenever Run is clicked.
    @AppStorage("eraseInstallRecentRunsJSON") var eraseInstallRecentRunsJSON: String = "[]"

    // MARK: MunkiReport
    /// Root URL of your MunkiReport server (no trailing slash). Used to
    /// build per-host links like `<root>/clients/show/<serial>` when the
    /// user picks "Open in MunkiReport" from the host context menu, and
    /// as the base for the BlueConnect JSON API endpoint.
    @AppStorage("munkiReportURL") var munkiReportURL: String = ""

    /// Bearer token for the standalone blueconnect_api.php JSON endpoint
    /// (server/munkireport-module/blueconnect_api.php). Loaded from
    /// Keychain at runtime; the matching `BLUECONNECT_API_TOKEN` env var
    /// lives on the MR container.
    @Published var munkiReportAPIToken: String = ""

    /// Path appended to `munkiReportURL` to reach the BlueConnect API.
    /// Default works when the PHP file sits at MR's webroot. For setups
    /// where the file is bind-mounted under a subpath (e.g. MR's
    /// `/var/munkireport/public/custom/`), use `custom/blueconnect_api.php`.
    @AppStorage("munkiReportAPIPath") var munkiReportAPIPath: String = "blueconnect_api.php"

    private static let munkiReportTokenAccount = "BlueConnectAdmin.munkiReportAPIToken"

    func loadMunkiReportTokenFromKeychain() {
        munkiReportAPIToken = KeychainHelper.read(account: Self.munkiReportTokenAccount) ?? ""
    }

    func saveMunkiReportTokenToKeychain() {
        KeychainHelper.save(munkiReportAPIToken, account: Self.munkiReportTokenAccount)
    }

    /// True when we have both a URL and a token configured to call the
    /// blueconnect_api.php endpoint. Inventory UI gates on this.
    var isMunkiReportAPIConfigured: Bool {
        !munkiReportURL.isEmpty && !munkiReportAPIToken.isEmpty
    }

    // MARK: Munki repo (Wasabi / S3-compatible / proxy-fronted)
    /// Hostname-style endpoint for the Munki repo, e.g.
    /// `munki.macfaqulty.com` or `s3.us-east-1.wasabisys.com`. No scheme.
    @AppStorage("munkiRepoEndpoint") var munkiRepoEndpoint: String = ""
    /// Bucket name. Often empty if the endpoint already IS the bucket
    /// (virtual-hosted style with a CNAME, or a Worker that has the bucket baked in).
    @AppStorage("munkiRepoBucket") var munkiRepoBucket: String = ""
    /// Path inside the bucket that the Munki repo lives under. Common
    /// values: `munki_repo`, `repo`, or empty if the repo is at the bucket
    /// root. The fetcher inserts this between bucket and key, so the
    /// catalogs/all URL ends up `…/<bucket>/<prefix>/catalogs/all`.
    @AppStorage("munkiRepoPrefix") var munkiRepoPrefix: String = ""
    /// Wasabi region, used in the SigV4 credential scope. Ignored in
    /// `.basic` auth mode (the proxy talks to Wasabi on our behalf).
    @AppStorage("munkiRepoRegion") var munkiRepoRegion: String = "us-east-1"

    /// Auth flavour. `.s3` = SigV4 directly to Wasabi/S3. `.basic` = the
    /// repo is fronted by a proxy that wants HTTP Basic Auth (very common
    /// for Cloudflare-Worker-fronted Munki repos — the Worker handles
    /// SigV4 itself). `.both` = passthrough proxy that requires Basic
    /// Auth AND forwards our SigV4 to Wasabi.
    @AppStorage("munkiRepoAuthMode") var munkiRepoAuthMode: String = "s3"

    @AppStorage("munkiRepoAccessKey") var munkiRepoAccessKey: String = ""
    /// Secret key loaded from Keychain at runtime; never written to UserDefaults.
    @Published var munkiRepoSecretKey: String = ""

    @AppStorage("munkiRepoBasicUser") var munkiRepoBasicUser: String = ""
    /// Basic Auth password loaded from Keychain at runtime.
    @Published var munkiRepoBasicPassword: String = ""

    private static let munkiSecretAccount = "BlueConnectAdmin.munkiRepoSecretKey"
    private static let munkiBasicAccount  = "BlueConnectAdmin.munkiRepoBasicPassword"

    func loadMunkiSecretFromKeychain() {
        munkiRepoSecretKey = KeychainHelper.read(account: Self.munkiSecretAccount) ?? ""
        munkiRepoBasicPassword = KeychainHelper.read(account: Self.munkiBasicAccount) ?? ""
    }

    func saveMunkiSecretToKeychain() {
        KeychainHelper.save(munkiRepoSecretKey, account: Self.munkiSecretAccount)
    }

    func saveMunkiBasicPasswordToKeychain() {
        KeychainHelper.save(munkiRepoBasicPassword, account: Self.munkiBasicAccount)
    }

    /// True when we have enough config to attempt a fetch under the
    /// currently-selected auth mode.
    var isMunkiRepoConfigured: Bool {
        guard !munkiRepoEndpoint.isEmpty else { return false }
        switch munkiRepoAuthMode {
        case "none":
            return true  // plain HTTPS, public/firewalled — endpoint is enough
        case "basic":
            return !munkiRepoBasicUser.isEmpty && !munkiRepoBasicPassword.isEmpty
        case "both":
            return !munkiRepoAccessKey.isEmpty && !munkiRepoSecretKey.isEmpty
                && !munkiRepoBasicUser.isEmpty && !munkiRepoBasicPassword.isEmpty
        default: // "s3"
            return !munkiRepoAccessKey.isEmpty && !munkiRepoSecretKey.isEmpty
        }
    }

    // Sidebar status-filter order (comma-separated keys, local per-Mac).
    @AppStorage("statusOrder") var statusOrderRaw: String = "all,favorites,recent,active,inactive,uncat"

    // Sidebar group collapse state — persisted per-Mac.
    @AppStorage("sidebarCategoriesCollapsed")    var sidebarCategoriesCollapsed: Bool = false
    @AppStorage("sidebarLocalNetworkCollapsed")  var sidebarLocalNetworkCollapsed: Bool = false
    @AppStorage("sidebarTailscaleCollapsed")     var sidebarTailscaleCollapsed: Bool = false
    @AppStorage("sidebarMunkiCollapsed")         var sidebarMunkiCollapsed: Bool = false
    /// When true, the Munki Repo group is removed from the sidebar
    /// entirely (independent of the collapsed/expanded state). Useful
    /// for admins who run the Munki picker but don't want the sidebar
    /// real estate. The repo browser and Install Package's Munki tab
    /// still work regardless — this is sidebar visibility only.
    @AppStorage("sidebarMunkiHidden")            var sidebarMunkiHidden: Bool = false

    var expandedKeyPath: String {
        NSString(string: adminKeyPath).expandingTildeInPath
    }
}
