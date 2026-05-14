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
