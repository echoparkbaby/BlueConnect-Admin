import Foundation
import Observation

/// Talks to `blueconnect_api.php` on the MR server (see
/// `server/munkireport-module/blueconnect_api.php`). Bearer-token auth,
/// plain HTTPS, JSON in / JSON out. Each instance keeps the last fetch's
/// status so the UI can render error states without an extra wrapper.
@Observable
@MainActor
final class MunkiReportClient {
    var isFetching: Bool = false
    var lastError: String?

    /// Ping the endpoint — verifies URL + token without hitting any DB
    /// tables. Used by Settings → Test Connection.
    func ping(settings: SettingsStore) async throws {
        let url = try Self.buildURL(action: "ping", serial: nil, settings: settings)
        let (data, response) = try await Self.send(url: url, token: settings.munkiReportAPIToken)
        try Self.assertOK(response, data: data)
        // Shape: {"ok": true, "driver": "mysql"} — accept any 200.
    }

    /// Pull per-host inventory by serial. Empty / missing modules come
    /// back as nil sections in `MRHostInventory`.
    func fetchHost(serial: String, settings: SettingsStore) async throws -> MRHostInventory {
        guard !serial.isEmpty else {
            throw MunkiReportError.invalidInput("Serial number is empty — can't query MunkiReport.")
        }
        let url = try Self.buildURL(action: "host", serial: serial, settings: settings)
        let (data, response) = try await Self.send(url: url, token: settings.munkiReportAPIToken)
        try Self.assertOK(response, data: data)
        return try JSONDecoder().decode(MRHostInventory.self, from: data)
    }

    // MARK: - URL + transport helpers

    private static func buildURL(action: String, serial: String?, settings: SettingsStore) throws -> URL {
        var base = settings.munkiReportURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if base.isEmpty {
            throw MunkiReportError.notConfigured("Settings → MunkiReport → server URL is empty.")
        }
        if !base.hasPrefix("http://") && !base.hasPrefix("https://") {
            base = "https://" + base
        }
        // API path is configurable to handle bind-mount layouts that
        // surface the PHP file at a non-root URL (e.g. /custom/...).
        let path = settings.munkiReportAPIPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let effectivePath = path.isEmpty ? "blueconnect_api.php" : path
        var components = URLComponents(string: "\(base)/\(effectivePath)")
            ?? URLComponents()
        var items: [URLQueryItem] = [URLQueryItem(name: "action", value: action)]
        if let serial = serial { items.append(URLQueryItem(name: "serial", value: serial)) }
        components.queryItems = items
        guard let url = components.url else {
            throw MunkiReportError.notConfigured("Malformed MunkiReport URL: \(settings.munkiReportURL)")
        }
        return url
    }

    private static func send(url: URL, token: String) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        return try await URLSession.shared.data(for: req)
    }

    /// Map HTTP error codes into the same `MunkiReportError` shape the
    /// PHP endpoint emits so the UI doesn't have to special-case 4xx vs.
    /// transport errors.
    private static func assertOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MunkiReportError.transport("Non-HTTP response")
        }
        if http.statusCode == 200 { return }
        // The PHP side sends JSON `{"error": "..."}` for every non-200.
        let msg: String
        if let body = try? JSONDecoder().decode([String: String].self, from: data),
           let err = body["error"] {
            msg = err
        } else {
            msg = String(data: data, encoding: .utf8) ?? "(no body)"
        }
        throw MunkiReportError.transport("HTTP \(http.statusCode) — \(msg)")
    }
}

enum MunkiReportError: LocalizedError {
    case notConfigured(String)
    case invalidInput(String)
    case transport(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured(let s): return "Not configured: \(s)"
        case .invalidInput(let s):  return "Invalid input: \(s)"
        case .transport(let s):     return s
        }
    }
}

// MARK: - Decoded shapes

/// Top-level reply from `?action=host&serial=…`. Optional sections are
/// `nil` when the corresponding MR module isn't installed — the UI just
/// hides that section, so this Mac app stays forward-compatible with
/// whatever MR module set the user has enabled.
struct MRHostInventory: Codable, Hashable {
    let serial: String
    let machine: MRMachine?
    let reportdata: MRReportdata?
    let munkireport: MRMunkireport?
    let filevault: MRFilevault?
    let disk_report: MRDiskReport?
    let power: MRPower?
    let comment: MRComment?
    let managed_installs: [MRManagedInstall]?
    let pending_installs: [MRManagedInstall]?
    let users: [MRUser]?
    let network: [MRNetworkInterface]?
    let wifi: MRWifi?
    let software_updates: MRSoftwareUpdateStatus?
    let profiles: [MRProfile]?
    let timemachine: MRTimeMachine?
}

/// `machine` table — the core inventory facts MR always has. Column
/// names match MR-php 5.x exactly. `os_version` is a packed integer
/// (MMmmpp, e.g. 120706 → "12.7.6"); `physical_memory` is GB.
struct MRMachine: Codable, Hashable {
    let serial_number: String?
    let computer_name: String?
    let hostname: String?
    let machine_model: String?
    let machine_desc: String?
    let cpu: String?
    let cpu_arch: String?
    let current_processor_speed: String?
    let number_processors: Int?
    let os_version: Int?
    let physical_memory: Int?
    let machine_name: String?
    let buildversion: String?

    /// Render the packed os_version int as "12.7.6".
    var osVersionString: String? {
        guard let v = os_version, v > 0 else { return nil }
        let major = v / 10000
        let minor = (v % 10000) / 100
        let patch = v % 100
        return "\(major).\(minor).\(patch)"
    }
    var memoryString: String? {
        physical_memory.map { "\($0) GB" }
    }
}

/// `reportdata` — last-check-in timestamp + a few status flags.
struct MRReportdata: Codable, Hashable {
    let timestamp: Int?
    let console_user: String?
    let long_username: String?
    let remote_ip: String?
    let uptime: Int?
    let machine_group: Int?
    let reg_timestamp: Int?
    let uid: Int?
    var lastCheckInDate: Date? {
        timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

/// `munkireport` table — most recent Munki run details.
struct MRMunkireport: Codable, Hashable {
    let version: String?
    let runtype: String?
    let starttime: String?
    let endtime: String?
    let errors: Int?
    let warnings: Int?
    let manifestname: String?
}

/// `filevault_status` from the filevault_status module.
struct MRFilevault: Codable, Hashable {
    let filevault_status: String?
    let filevault_users: String?
    let has_personal_recovery_key: Int?
    let has_institutional_recovery_key: Int?
    let conversion_percent: Int?
    let conversion_state: String?

    var recoveryKeyStatus: String {
        let p = (has_personal_recovery_key ?? 0) == 1
        let i = (has_institutional_recovery_key ?? 0) == 1
        switch (p, i) {
        case (true, true):   return "Personal + Institutional escrowed"
        case (true, false):  return "Personal key escrowed"
        case (false, true):  return "Institutional key escrowed"
        case (false, false): return "No recovery key escrowed"
        }
    }
}

/// `diskreport` table (note: no underscore in MR's actual table name —
/// the JSON key is still `disk_report` for cleanliness, the PHP file
/// queries `diskreport`). Sizes are bytes.
struct MRDiskReport: Codable, Hashable {
    let totalsize: Int?
    let freespace: Int?
    let percentage: Int?
    let smartstatus: String?
    let volumetype: String?
    let media_type: String?
    let volumename: String?
    let encrypted: Int?

    var totalString: String? {
        totalsize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }
    var freeString: String? {
        freespace.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }
}

/// `power` table — actual column names: `max_percent` not
/// `max_capacity_percent`, `current_percent` not `charge_percent`,
/// `externalconnected` + `ischarging` are varchar in MR (values like
/// "Yes" / "No" or "TRUE" / "FALSE"), not int.
struct MRPower: Codable, Hashable {
    let cycle_count: Int?
    let condition: String?
    let max_percent: Int?
    let current_percent: Int?
    let externalconnected: String?
    let ischarging: String?
    let manufacturer: String?
    let temperature: Int?
}

/// `comment` table — `text` is the comment body, `html` is the rendered
/// version, `user` is who left it.
struct MRComment: Codable, Hashable {
    let text: String?
    let user: String?
    let timestamp: Int?
}

/// `managedinstalls` table. `installed` is `int(11)` in MR (0 / 1);
/// custom decoder accepts either Int or Bool so an MR upgrade that
/// changes the column type doesn't break us.
struct MRManagedInstall: Codable, Hashable, Identifiable {
    var id: String { "\(name ?? "")|\(version ?? "")|\(installed)" }
    let name: String?
    let display_name: String?
    let version: String?
    let size: Int?      // KB per MR's conventions
    let installed: Bool
    let status: String?
    let type: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.display_name = try c.decodeIfPresent(String.self, forKey: .display_name)
        self.version = try c.decodeIfPresent(String.self, forKey: .version)
        self.size = try c.decodeIfPresent(Int.self, forKey: .size)
        self.status = try c.decodeIfPresent(String.self, forKey: .status)
        self.type = try c.decodeIfPresent(String.self, forKey: .type)
        if let i = try? c.decodeIfPresent(Int.self, forKey: .installed) {
            self.installed = (i != 0)
        } else if let b = try? c.decodeIfPresent(Bool.self, forKey: .installed) {
            self.installed = b
        } else {
            self.installed = false
        }
    }
    enum CodingKeys: String, CodingKey {
        case name, display_name, version, size, installed, status, type
    }
}

/// `network` table from the network module — one row per interface.
/// PHP aliases MR's actual columns (`service`, `order`, `ethernet`,
/// `ipv4dns`, `searchdomain`) into the snake_case names below.
struct MRNetworkInterface: Codable, Hashable, Identifiable {
    var id: String {
        "\(service_name ?? "?")|\(service_order ?? 0)|\(ipv4ip ?? "")"
    }
    let service_name: String?
    let service_order: Int?
    let ipv4ip: String?
    let ipv4mask: String?
    let ipv4router: String?
    let ipv4dnsservers: String?
    let ipv4searchdomains: String?
    let ipv6ip: String?
    let ethernet_macaddress: String?

    /// True when the interface has any kind of IP assigned — used to
    /// dim "down" / unconfigured interfaces in the UI.
    var hasAddress: Bool {
        (ipv4ip ?? "").isEmpty == false || (ipv6ip ?? "").isEmpty == false
    }
}

/// `local_users` table — one row per local account on the Mac. PHP
/// aliases MR's actual columns (`record_name`/`real_name`/`unique_id`/
/// `home_directory`/`user_shell`/`administrator`) into the names below
/// and filters to `unique_id >= 500` so this only contains real humans
/// + local admins, not Apple's `_*` daemons. `last_login_ts` is MR's
/// `last_login_timestamp` (Unix epoch as bigint, often null).
struct MRUser: Codable, Hashable, Identifiable {
    var id: String { "\(uidValue ?? 0)|\(name ?? username ?? "")" }
    // MR stores `unique_id` / `primary_group_id` as varchar, so the
    // PHP endpoint returns them as JSON strings ("501"). MRFlexInt
    // accepts either int or string and exposes the parsed Int via .value.
    let uid: MRFlexInt?
    let gid: MRFlexInt?
    let name: String?
    let username: String?
    let realname: String?
    let home: String?
    let shell: String?
    let admin: MRFlexBool?
    let ssh_access: MRFlexBool?
    let last_login_ts: Int?

    var uidValue: Int? { uid?.value }
    var gidValue: Int? { gid?.value }

    var shortName: String {
        if let n = name, !n.isEmpty { return n }
        if let u = username, !u.isEmpty { return u }
        return "uid \(uidValue ?? 0)"
    }

    var lastLoginDate: Date? {
        guard let ts = last_login_ts, ts > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }
}

/// `wifi` (or `wifi_signal` / `airport`) table — one row per host with
/// the currently-associated Wi-Fi network details. All optional because
/// the column set differs sharply between MR's wifi-module variants.
struct MRWifi: Codable, Hashable {
    let service: String?
    let ssid: String?
    let bssid: String?
    let channel: MRFlexInt?
    let security: String?
    let rssi: MRFlexInt?
    let noise: MRFlexInt?
    let transmit_rate: String?
    let country_code: String?

    /// True only when at least one user-facing Wi-Fi field is populated.
    var hasAnyField: Bool {
        (ssid?.isEmpty == false)
        || (security?.isEmpty == false)
        || channel != nil
        || rssi != nil
        || (bssid?.isEmpty == false)
    }

    /// Best-effort label for signal strength (RSSI is negative dBm; >-50
    /// is excellent, <-80 is poor). Returns nil when rssi isn't set.
    var rssiLabel: String? {
        guard let r = rssi?.value else { return nil }
        let level: String
        switch r {
        case _ where r >= -50: level = "Excellent"
        case _ where r >= -60: level = "Good"
        case _ where r >= -70: level = "Fair"
        default:               level = "Weak"
        }
        return "\(r) dBm · \(level)"
    }
}

/// `softwareupdate` table — one aggregated status row per host (NOT a
/// per-update list). Fields are best-effort — different MR versions vary
/// the column set, hence everything Optional. The accessors below
/// normalise counts that might come back as int or string.
struct MRSoftwareUpdateStatus: Codable, Hashable {
    let recommendedupdates: MRFlexInt?
    let lastupdatesavailable: MRFlexInt?
    let lastsuccessfuldate: String?
    let lastfullsuccessfuldate: String?
    let auto_update: MRFlexBool?
    let auto_update_restart_required: MRFlexBool?
}

/// Codable bridge for fields MR encodes as int OR string (or absent).
/// Reused for softwareupdate counts + the time-machine `auto_backup` bit.
enum MRFlexInt: Codable, Hashable {
    case int(Int), string(String)
    var value: Int? {
        switch self {
        case .int(let i): return i
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self)    { self = .int(i); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        self = .int(0)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i):    try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

enum MRFlexBool: Codable, Hashable {
    case bool(Bool), int(Int), string(String)
    var isOn: Bool {
        switch self {
        case .bool(let b): return b
        case .int(let i):  return i != 0
        case .string(let s):
            let v = s.trimmingCharacters(in: .whitespaces).lowercased()
            return v == "1" || v == "yes" || v == "true" || v == "on"
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self)   { self = .bool(b); return }
        if let i = try? c.decode(Int.self)    { self = .int(i);  return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        self = .bool(false)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b):   try c.encode(b)
        case .int(let i):    try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

/// `profile` table — installed configuration profiles. PHP aliases
/// `profile_name`/`profile_uuid`/`profile_removal_allowed` into the
/// shorter names below. `payload_name` is the originating service
/// (e.g. com.apple.mdm) and `payload_display` is the friendly label.
/// MR's `payload_data` is deliberately not selected.
struct MRProfile: Codable, Hashable, Identifiable {
    var id: String { identifier ?? name ?? UUID().uuidString }
    let name: String?
    let identifier: String?
    let removaldisallowed: MRFlexBool?
    let payload_name: String?
    let payload_display: String?
}

/// `timemachine` table — single row per host. Column names match MR's
/// snake_case DB schema directly (auto_backup, last_success,
/// last_destination_id, snapshot_dates, alias_volume_name, network_url,
/// server_display_name, apfs_snapshots).
struct MRTimeMachine: Codable, Hashable {
    let auto_backup: MRFlexBool?
    let last_success: String?
    let last_destination_id: String?
    let snapshot_dates: String?
    let alias_volume_name: String?
    let network_url: String?
    let server_display_name: String?
    let apfs_snapshots: String?

    /// True only when at least one user-facing field is populated.
    /// Lets the UI hide the section when MR returned a row of all
    /// nulls (the row exists but the host hasn't reported TM data).
    var hasAnyField: Bool {
        auto_backup != nil
        || (last_success?.isEmpty == false)
        || (last_destination_id?.isEmpty == false)
        || (alias_volume_name?.isEmpty == false)
        || (server_display_name?.isEmpty == false)
    }
}
