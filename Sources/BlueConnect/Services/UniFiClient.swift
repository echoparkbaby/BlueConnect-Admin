import Foundation

/// Tiny client for the UniFi Network Application **integration**
/// REST API (the modern token-key variant, not the legacy cookie
/// path). Auth is `X-API-KEY: <token>`; endpoints live under
/// `/proxy/network/integrations/v1/...` on the controller.
///
/// We only need two read-only calls for scan enrichment: list
/// sites (so we can validate the configured site name) and list
/// active clients per site (so each scanned IP gets a hostname,
/// MAC, link speed, and wired/wireless flag).
///
/// Trusts self-signed certs via a custom URLSessionDelegate — most
/// home UniFis use the default-installed self-signed cert and
/// strict TLS would block every request. The cert is still
/// verified for hostname + chain via the system trust evaluation;
/// only the "trusted root" check is relaxed.
struct UniFiClient {
    let baseURL: String
    let apiKey: String

    /// Wire shape returned by the controller's clients endpoint.
    /// UniFi has shipped at least three different field-name styles
    /// over the years (snake_case, camelCase, integration-API
    /// renames), so the custom `init(from:)` below tries each known
    /// alias per field.
    struct ClientInfo: Sendable {
        let id: String?
        let name: String?
        let ip: String?
        let macAddress: String?
        let type: String?
        let txRateMbps: Double?
        let rxRateMbps: Double?
        let signal: Int?
        let connectedAt: String?
        /// UniFi VLAN ID (Int) or human network label. `network`
        /// shows up as e.g. "LAN", "IoT", "Guest" — what the
        /// operator sees in UniFi's UI. `vlan` is the numeric tag
        /// (1, 100, etc.). The scan-table column prefers `network`
        /// when present, falls back to `vlan` as a string.
        let vlan: Int?
        let network: String?

        /// Display-friendly link rate, e.g. "1 Gbps" / "866 Mbps".
        var displaySpeed: String? {
            // Prefer tx (uplink to AP / switch) — it's what shows
            // in the UniFi UI as "Tx Rate". Fall back to rx.
            let value = txRateMbps ?? rxRateMbps
            guard let v = value, v > 0 else { return nil }
            if v >= 1000 {
                return String(format: "%.1f Gbps", v / 1000)
                    .replacingOccurrences(of: ".0 ", with: " ")
            }
            return String(format: "%.0f Mbps", v)
        }

        var isWired: Bool { type?.uppercased() == "WIRED" }
    }

    struct SiteInfo: Codable, Sendable {
        let id: String
        let internalReference: String?
        let name: String?
    }

    /// Wrapper the controller wraps every list endpoint in. Only
    /// `data` is structurally meaningful here.
    private struct ListEnvelope<Item: Decodable>: Decodable {
        let data: [Item]
    }

    enum UniFiError: LocalizedError {
        case badBaseURL
        case http(Int, String)
        case decode(Error)
        case network(Error)
        var errorDescription: String? {
            switch self {
            case .badBaseURL:        return "Bad UniFi base URL"
            case .http(let code, let body):
                return "UniFi HTTP \(code): \(body.prefix(160))"
            case .decode(let e):     return "UniFi decode: \(e.localizedDescription)"
            case .network(let e):    return "UniFi network: \(e.localizedDescription)"
            }
        }
    }

    /// List configured sites. Used by the Settings pane's "Test"
    /// button so the operator sees right away whether the URL +
    /// key combination is valid.
    func sites() async throws -> [SiteInfo] {
        let env: ListEnvelope<SiteInfo> = try await get("/proxy/network/integrations/v1/sites")
        return env.data
    }

    /// List currently-connected clients for the given site, using
    /// the **legacy** non-integration endpoint
    /// `/proxy/network/api/s/<site>/stat/sta`. The shiny new
    /// "Integration API" at `/integrations/v1/...` returns a six-
    /// field summary per client (no speed, no signal, no port). The
    /// legacy endpoint accepts the same `X-API-KEY` header on
    /// current UniFi versions and returns 80+ fields per client
    /// including `wired_rate_mbps`, `tx_rate`, `signal`, `sw_port`,
    /// `last_uplink_name` — everything we want to surface in the
    /// scan table. Single call, no pagination (returns all clients).
    /// `siteName` is the short reference from settings (defaults to
    /// "default"), not the UUID — legacy uses short names in URLs.
    func clients(siteName: String) async throws -> [ClientInfo] {
        let env: LegacyEnvelope = try await get(
            "/proxy/network/api/s/\(siteName)/stat/sta"
        )
        return env.data
    }

    /// List UniFi devices (the gear itself: gateway, switches, APs).
    /// `/stat/sta` returns CLIENTS — Macs, phones, IoT — but the
    /// UDM/switches/APs only appear in `/stat/device`. Decoding
    /// reuses `ClientInfo` so the scanner can merge them into the
    /// same `unifiByIP` map and the scan table renders them in the
    /// same Type/Speed/MAC columns.
    func devices(siteName: String) async throws -> [ClientInfo] {
        let env: LegacyEnvelope = try await get(
            "/proxy/network/api/s/\(siteName)/stat/device"
        )
        return env.data
    }

    /// Legacy endpoint envelope. Wraps `data` next to a `meta`
    /// status object; we don't need `meta` here because non-200
    /// statuses already bubble up as `UniFiError.http` from `get`.
    private struct LegacyEnvelope: Decodable {
        let data: [ClientInfo]
    }

    // MARK: - Internal request plumbing

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard var components = URLComponents(string: baseURL) else {
            throw UniFiError.badBaseURL
        }
        components.path = (components.path.hasSuffix("/")
                           ? String(components.path.dropLast())
                           : components.path) + path
        guard let url = components.url else { throw UniFiError.badBaseURL }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        // Trim invisibles — a leading/trailing newline from a paste
        // is a classic 401 cause. Then send both header forms; some
        // UniFi versions check Authorization:Bearer, others check
        // X-API-KEY. Both being present is harmless because the
        // controller only validates whichever it recognizes.
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        req.setValue(cleanKey, forHTTPHeaderField: "X-API-KEY")
        req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 5

        let session = URLSession(
            configuration: .ephemeral,
            delegate: SelfSignedTrustingDelegate(),
            delegateQueue: nil
        )
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw UniFiError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UniFiError.http(0, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UniFiError.http(http.statusCode,
                                  String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw UniFiError.decode(error)
        }
    }
}

/// Custom decoder for `UniFiClient.ClientInfo`. The UniFi Network
/// API has shipped at least three field-name conventions over its
/// lifetime — `ip` vs `ipAddress` vs `clientIp`, etc. — and the
/// "Integration API" docs lag the actual server response. Rather
/// than guess wrong and silently drop data, we try every alias we
/// know for each field. First non-nil wins.
extension UniFiClient.ClientInfo: Decodable {
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    /// Nested `uplink` object on `/stat/device` responses. Only
    /// `speed` (Mbps integer) is relevant for our table; the rest of
    /// the uplink fields (mac, name, port, full_duplex, etc.) are
    /// ignored because optional decoding skips missing keys.
    fileprivate struct UplinkInfo: Decodable {
        let speed: Double?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func str(_ keys: String...) -> String? {
            for k in keys {
                if let v = try? c.decodeIfPresent(String.self, forKey: AnyKey(stringValue: k)),
                   !v.isEmpty { return v }
            }
            return nil
        }
        func dbl(_ keys: String...) -> Double? {
            for k in keys {
                if let v = try? c.decodeIfPresent(Double.self, forKey: AnyKey(stringValue: k)) { return v }
                if let v = try? c.decodeIfPresent(Int.self, forKey: AnyKey(stringValue: k))    { return Double(v) }
            }
            return nil
        }
        func int(_ keys: String...) -> Int? {
            for k in keys {
                if let v = try? c.decodeIfPresent(Int.self, forKey: AnyKey(stringValue: k))    { return v }
                if let v = try? c.decodeIfPresent(Double.self, forKey: AnyKey(stringValue: k)) { return Int(v) }
            }
            return nil
        }
        self.id           = str("id", "_id")
        // Hostname-style name. Try the high-signal sources first:
        //   - `name`         — user-edited UniFi alias (set via
        //                      Clients → Edit) → best
        //   - `hostname`     — DHCP-sent client hostname
        //   - `device_name`  — OS-reported name (Bonjour/SMB)
        //   - `displayName` / `host` — integration-API variants
        // Then degrade to identity hints when no name was set:
        //   - `dev_vendor`   — fingerprinted vendor name
        //   - `product_model` — UniFi's own model for its gear
        //   - `oui`          — manufacturer of the MAC prefix
        // The fallbacks aren't great names but they beat the bare
        // IP for "what is this thing" at a glance.
        self.name         = str(
            "name", "hostname", "device_name", "displayName", "host",
            "dev_vendor", "product_model", "oui"
        )
        // IP — `ip` is the current active IP (legacy), `last_ip` is
        // its DHCP-leased counterpart, `fixed_ip` for reservations,
        // `ipAddress` for the integration API.
        self.ip           = str("ip", "last_ip", "fixed_ip", "ipAddress", "lastIp")
        self.macAddress   = str("mac", "macAddress", "clientMac", "client_mac")
        // Type. Legacy uses `is_wired: true/false`; integration API
        // uses `type: "WIRED"/"WIRELESS"`.
        if let wired = try? c.decodeIfPresent(Bool.self, forKey: AnyKey(stringValue: "is_wired")) {
            self.type = wired ? "WIRED" : "WIRELESS"
        } else if let s = str("type") {
            self.type = s
        } else {
            self.type = nil
        }
        // Per-client link speed:
        //   - Wired: `wired_rate_mbps` (legacy, direct Mbps int —
        //     e.g. 1000, 2500, 10000). This is THE field; no port
        //     lookup needed.
        //   - Wireless: `tx_rate` / `rx_rate` (Kbps in current
        //     firmware — 866000 = 866 Mbps Wi-Fi).
        //   - Integration API: `txRateMbps` (rare).
        // Auto-detect unit from magnitude for the wireless paths.
        func mbpsFromRate(_ keys: String...) -> Double? {
            for k in keys {
                if let v = dbl(k) {
                    if v >= 100_000_000 { return v / 1_000_000 }
                    if v >= 100_000     { return v / 1000 }
                    return v
                }
            }
            return nil
        }
        // Wired path takes priority — if `wired_rate_mbps` exists,
        // it's authoritative and already in the right unit.
        if let wired = dbl("wired_rate_mbps") {
            self.txRateMbps = wired
            self.rxRateMbps = wired   // wired is symmetric — same rate both ways
        } else if let uplinkSpeed = try? c.decodeIfPresent(UplinkInfo.self,
                                                          forKey: AnyKey(stringValue: "uplink"))?.speed {
            // `/stat/device` exposes uplink speed at `uplink.speed`
            // (Mbps integer — 1000 = 1Gbps, 2500, 10000, etc.).
            // No client-side `wired_rate_mbps` for the device itself,
            // so this is where switches/APs get their link rate.
            self.txRateMbps = uplinkSpeed
            self.rxRateMbps = uplinkSpeed
        } else {
            if let mbps = dbl("txRateMbps", "tx_rate_mbps") {
                self.txRateMbps = mbps
            } else if let speed = mbpsFromRate("tx_rate", "txRate", "wifi_tx_rate") {
                self.txRateMbps = speed
            } else {
                self.txRateMbps = nil
            }
            if let mbps = dbl("rxRateMbps", "rx_rate_mbps") {
                self.rxRateMbps = mbps
            } else if let speed = mbpsFromRate("rx_rate", "rxRate", "wifi_rx_rate") {
                self.rxRateMbps = speed
            } else {
                self.rxRateMbps = nil
            }
        }
        self.signal       = int("signal", "rssi")
        self.connectedAt  = str("connectedAt", "first_seen", "lastSeenAt")
        self.vlan         = int("vlan", "gw_vlan", "vlan_id")
        self.network      = str("network", "last_connection_network_name", "essid")
    }
}

/// Allows self-signed certs on the UniFi controller. Skipping cert
/// chain trust is acceptable because the operator has explicitly
/// configured this URL + a sensitive API key for it — we're not
/// silently trusting random servers. Hostname is still validated
/// to thwart accidental cross-host MITM.
private final class SelfSignedTrustingDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let cred = URLCredential(trust: trust)
        completionHandler(.useCredential, cred)
    }
}
