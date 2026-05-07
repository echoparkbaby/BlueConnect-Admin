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

    // Sidebar status-filter order (comma-separated keys, local per-Mac).
    @AppStorage("statusOrder") var statusOrderRaw: String = "all,favorites,recent,active,inactive,uncat"

    var expandedKeyPath: String {
        NSString(string: adminKeyPath).expandingTildeInPath
    }
}
