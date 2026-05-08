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

    // Sidebar status-filter order (comma-separated keys, local per-Mac).
    @AppStorage("statusOrder") var statusOrderRaw: String = "all,favorites,recent,active,inactive,uncat"

    var expandedKeyPath: String {
        NSString(string: adminKeyPath).expandingTildeInPath
    }
}
