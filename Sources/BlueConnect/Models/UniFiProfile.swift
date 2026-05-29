import Foundation

/// A saved UniFi controller configuration. An MSP-style admin who
/// hops between client networks via VPN keeps one profile per
/// controller (home UDM, customer A's UDM, customer B's Cloud Key,
/// etc.) and switches in the Network Scan window's header.
///
/// Persisted as a JSON array under `@AppStorage("unifiProfiles")`.
/// The API key never lives in JSON — it sits in the Keychain under
/// account `BlueConnectAdmin.unifiAPIKey.<uuid>` so it round-trips
/// alongside the profile but never leaks into a defaults plist.
struct UniFiProfile: Codable, Hashable, Identifiable {
    var id: UUID
    /// Human-readable name shown in the switcher menu and Settings
    /// list. Free-form: "Home UDM", "Client – ACME", etc.
    var label: String
    /// Same shape as the legacy `unifiBaseURL` field —
    /// `https://10.0.0.1` or `https://unifi.example.com`.
    var baseURL: String
    /// UniFi site short name. Empty string is treated as `"default"`
    /// at call time (matches the legacy field's behavior).
    var site: String

    init(id: UUID = UUID(),
         label: String,
         baseURL: String = "",
         site: String = "default") {
        self.id = id
        self.label = label
        self.baseURL = baseURL
        self.site = site
    }

    var resolvedSite: String {
        let trimmed = site.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "default" : trimmed
    }

    /// True once both URL and (separately-stored) API key are
    /// present. The key is in the Keychain so this struct can't
    /// answer that on its own — callers go through
    /// `SettingsStore.isConfigured(_:)`.
    var hasURL: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
