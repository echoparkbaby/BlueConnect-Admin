import Foundation
import Network
import Observation

/// Active TCP-probe scanner for Macs on the LAN that the Bonjour
/// browser misses — Macs with mDNS turned off, Macs the user just
/// brought online, etc. Reads the operator-configured CIDR list,
/// fans out concurrent `NWConnection` probes on 22 + 5900, builds a
/// `[LocalService]` of every host that answered.
///
/// On-demand only — no background timer. The user picks "Scan" from
/// the sidebar; we burn 1–3 seconds, post results, done. The whole
/// thing renders through `LocalNetworkRow` (just with `source =
/// .scanned`) so visually it lives next to Bonjour discoveries.
@MainActor
@Observable
final class NetworkScanner {
    /// Currently-scanning state for UI gating (disables the button,
    /// shows a spinner).
    var isScanning: Bool = false
    /// Latest scan results. Cleared at the start of each scan so the
    /// UI shows the new run, not a merge.
    var results: [LocalService] = []
    /// Soft progress for the spinner — `done / total` IPs probed.
    var progress: Int = 0
    var total: Int = 0
    /// Last error surfaced from `scan(cidrs:)`, e.g. a bad CIDR. nil
    /// once a clean scan completes.
    var lastError: String?
    /// Per-IP UniFi client data the table can render alongside the
    /// probed services. Populated by `scan(...)` when UniFi is
    /// configured; empty otherwise. Keyed by IPv4.
    var unifiByIP: [String: UniFiClient.ClientInfo] = [:]

    /// Per-IP TCP-connect timeout. 600ms keeps a /24 scan to ~1–2s
    /// even when every IP is dark; bumping past 1s drags the UX.
    private let probeTimeout: TimeInterval = 0.6

    /// Optionally pass a list of Bonjour-discovered services from
    /// `LocalRendezvousBrowser`. Each one's `.local` hostname is
    /// resolved to its IPv4 via `getaddrinfo()` (which DOES tap mDNS
    /// for `.local` forward lookups, unlike its reverse-PTR cousin),
    /// and any matching IP in the scan results inherits the
    /// Bonjour service's friendly name. This is how we populate the
    /// DNS Name column with "Brandon's MacBook" instead of just an
    /// IP — without per-IP shell-outs or hangy reverse-PTR queries.
    func scan(cidrs: [String],
              bonjourCandidates: [LocalService] = [],
              unifi: (baseURL: String, apiKey: String, site: String)? = nil) async {
        guard !isScanning else { return }
        isScanning = true
        results = []
        unifiByIP = [:]
        progress = 0
        lastError = nil

        // Expand the comma/whitespace list of CIDRs into a flat list
        // of IPs. Invalid entries are reported via `lastError` but
        // don't abort the whole scan — other CIDRs still run.
        var ips: [String] = []
        var parseErrors: [String] = []
        for raw in cidrs.flatMap({ $0.split(whereSeparator: { ",\n ".contains($0) }) }) {
            let cidr = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if cidr.isEmpty { continue }
            do {
                ips.append(contentsOf: try expand(cidr: cidr))
            } catch {
                parseErrors.append("\(cidr) (\(error.localizedDescription))")
            }
        }
        total = ips.count

        if !parseErrors.isEmpty {
            lastError = "Couldn't parse: " + parseErrors.joined(separator: ", ")
        }
        if ips.isEmpty {
            isScanning = false
            return
        }

        // Probe IPs concurrently. The TaskGroup batches all probes
        // and yields results as they complete. We collect into a
        // dict so [22, 5900] for the same IP merge into one entry.
        var byIP: [String: LocalService] = [:]
        await withTaskGroup(of: ProbeResult?.self) { group in
            for ip in ips {
                group.addTask { [probeTimeout] in
                    await Self.probeHost(ip: ip, timeout: probeTimeout)
                }
            }
            for await result in group {
                progress += 1
                guard let result = result, result.hasSSH || result.hasVNC else { continue }
                let existing = byIP[result.ip]
                let merged = LocalService(
                    name: existing?.name ?? result.displayName ?? result.ip,
                    hostname: result.ip,
                    sshPort: result.hasSSH ? 22 : (existing?.sshPort),
                    vncPort: result.hasVNC ? 5900 : (existing?.vncPort),
                    source: .scanned
                )
                byIP[result.ip] = merged
            }
        }

        // Plan C: cross-reference Bonjour-discovered services with
        // scan results. For every Bonjour `.local` hostname, resolve
        // it to an IPv4 via getaddrinfo (.local forward lookups DO
        // tap mDNS reliably on macOS). Build [IP: friendly name],
        // then overlay onto the scanner's IP-keyed results.
        let bonjourMap: [String: String]
        if bonjourCandidates.isEmpty {
            bonjourMap = [:]
        } else {
            bonjourMap = await Self.resolveBonjourToIPs(bonjourCandidates)
        }
        // Optional UniFi enrichment — fetches the controller's
        // active-client list (one HTTP call) and indexes by IP. The
        // scan-results table later renders MAC, link speed, and
        // wired/wireless from this map; the LocalService's `name`
        // is also upgraded to UniFi's hostname when Bonjour didn't
        // already provide one.
        if let unifi = unifi, !unifi.baseURL.isEmpty, !unifi.apiKey.isEmpty {
            await fetchUnifiClients(unifi: unifi)
        }
        let enriched = byIP.values.map { svc -> LocalService in
            // Prefer Bonjour name; fall back to UniFi-supplied hostname.
            let bonjourName = bonjourMap[svc.hostname]
            let unifiName = unifiByIP[svc.hostname]?.name
            let chosen = bonjourName ?? unifiName
            if let chosen = chosen, !chosen.isEmpty, chosen != svc.hostname {
                return LocalService(
                    name: chosen,
                    hostname: svc.hostname,
                    sshPort: svc.sshPort,
                    vncPort: svc.vncPort,
                    source: .scanned
                )
            }
            return svc
        }
        // Merge UniFi-known IPs that DIDN'T respond to the TCP probe.
        // The scanner only sees devices answering 22/5900, but UniFi
        // knows every DHCP client — gaming rigs (RDP-only), Hue
        // bridges (HTTP-only), printers, LXCs without SSH, etc. They
        // show up with SSH/VNC ✗ but get full Type/Speed/MAC from
        // UniFi so the table reflects the actual LAN inventory, not
        // just the SSH-able subset.
        var allByIP: [String: LocalService] = [:]
        for svc in enriched { allByIP[svc.hostname] = svc }
        for (ip, unifi) in unifiByIP where allByIP[ip] == nil {
            allByIP[ip] = LocalService(
                name: unifi.name?.isEmpty == false ? unifi.name! : ip,
                hostname: ip,
                sshPort: nil,
                vncPort: nil,
                source: .scanned
            )
        }
        // Sort by IP, dotted-octet numeric, so 10.0.0.2 sorts before
        // 10.0.0.10.
        results = allByIP.values.sorted { Self.ipSortKey($0.hostname) < Self.ipSortKey($1.hostname) }
        isScanning = false
    }

    /// Fetch the active UniFi client list and populate `unifiByIP`.
    /// Best-effort — auth/HTTP failures land in `lastError` but don't
    /// abort the scan (the table still has TCP-probe + Bonjour
    /// data). Picks the configured site by `internalReference`,
    /// falls back to the first site so a typo'd "Default" vs
    /// "default" doesn't silently lose all clients.
    private func fetchUnifiClients(unifi: (baseURL: String, apiKey: String, site: String)) async {
        let client = UniFiClient(baseURL: unifi.baseURL, apiKey: unifi.apiKey)
        // Legacy `/stat/sta` uses the site's short reference
        // (e.g. "default") in the URL — not the integration
        // API's UUID. Defaults to "default" when the operator
        // leaves the Site field empty.
        let siteName = unifi.site.trimmingCharacters(in: .whitespaces).isEmpty
            ? "default"
            : unifi.site
        // Fetch clients (Macs/phones/IoT) and devices (UDM, switches,
        // APs) in parallel — they hit separate endpoints and neither
        // depends on the other. Merge: clients win on IP collision
        // because they have richer data (signal, wireless rates).
        async let clientsRequest = client.clients(siteName: siteName)
        async let devicesRequest = client.devices(siteName: siteName)
        do {
            let (clients, devices) = try await (clientsRequest, devicesRequest)
            var map: [String: UniFiClient.ClientInfo] = [:]
            for c in clients {
                guard let ip = c.ip, !ip.isEmpty else { continue }
                map[ip] = c
            }
            for d in devices {
                guard let ip = d.ip, !ip.isEmpty, map[ip] == nil else { continue }
                map[ip] = d
            }
            unifiByIP = map
        } catch {
            lastError = (lastError.map { $0 + " · " } ?? "")
                + "UniFi: \(error.localizedDescription)"
        }
    }

    /// Concurrently resolve each Bonjour service's `.local` hostname
    /// to an IPv4 string via `getaddrinfo()`. Returns [ipv4: bonjour
    /// service name]. macOS's resolver answers `.local` forward
    /// lookups via mDNS reliably (the reverse-PTR path is what's
    /// missing). Each resolution is wrapped in a 1.5s deadline so a
    /// stale/unreachable service can't stall the whole enrichment.
    private static func resolveBonjourToIPs(_ services: [LocalService]) async -> [String: String] {
        await withTaskGroup(of: (String, String)?.self) { group in
            for svc in services {
                let host = svc.displayHostname  // strips trailing dot
                let name = svc.name.isEmpty ? svc.displayHostname : svc.name
                group.addTask {
                    await Self.resolveIPv4(host: host, deadline: 1.5).map { (ip: String) in (ip, name) }
                }
            }
            var map: [String: String] = [:]
            for await pair in group {
                if let (ip, name) = pair { map[ip] = name }
            }
            return map
        }
    }

    /// Forward `getaddrinfo` for an IPv4 A record, wrapped in a
    /// deadline. Returns the first IPv4 (dotted-quad) the resolver
    /// produces — Macs publishing mDNS expose this immediately.
    private static func resolveIPv4(host: String, deadline: TimeInterval) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var hints = addrinfo(
                    ai_flags: AI_ADDRCONFIG,
                    ai_family: AF_INET,
                    ai_socktype: SOCK_STREAM,
                    ai_protocol: 0,
                    ai_addrlen: 0,
                    ai_canonname: nil,
                    ai_addr: nil,
                    ai_next: nil
                )
                var res: UnsafeMutablePointer<addrinfo>? = nil
                defer { if let r = res { freeaddrinfo(r) } }
                let err = getaddrinfo(host, nil, &hints, &res)
                guard err == 0, let first = res else { return nil }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let nameErr = getnameinfo(
                    first.pointee.ai_addr,
                    first.pointee.ai_addrlen,
                    &buf,
                    socklen_t(buf.count),
                    nil, 0,
                    NI_NUMERICHOST
                )
                guard nameErr == 0 else { return nil }
                return String(cString: buf)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return nil
            }
            // Take whichever task returns first.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    /// Send an mDNS reverse PTR query for `<ip>.in-addr.arpa.` via
    /// `dns-sd`, kill the process after `timeout` seconds, and parse
    /// the first PTR rdata that comes back. dns-sd has no built-in
    /// timeout flag, so we lean on `Process.terminate()` after a
    /// scheduled deadline.
    ///
    /// Sample dns-sd PTR output line:
    ///   `Z:11:09:07.000  Add 2  4 4.0.0.10.in-addr.arpa. PTR foo.local.`
    /// The last token is the answer name; trailing `.` is stripped.
    private static func mdnsReversePTR(ip: String, timeout: TimeInterval) async -> String? {
        let octets = ip.split(separator: ".")
        guard octets.count == 4 else { return nil }
        let reverseName = "\(octets[3]).\(octets[2]).\(octets[1]).\(octets[0]).in-addr.arpa."
        return await Task.detached(priority: .utility) {
            let proc = Process()
            proc.launchPath = "/usr/bin/dns-sd"
            proc.arguments = ["-Q", reverseName, "PTR"]
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = Pipe()
            do { try proc.run() } catch { return nil }
            // Schedule the kill — dns-sd otherwise runs forever
            // waiting for additional answers.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if proc.isRunning { proc.terminate() }
            }
            proc.waitUntilExit()
            let raw = String(
                data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            for line in raw.split(separator: "\n") {
                let s = String(line)
                // Match an answer line — contains both "PTR" and the
                // reverse name (or just "Add" + PTR for v2 dns-sd).
                guard s.contains(" PTR ") || s.contains("\tPTR\t") else { continue }
                let tokens = s.split(separator: " ", omittingEmptySubsequences: true)
                guard let last = tokens.last else { continue }
                let name = String(last).trimmingCharacters(in: .whitespacesAndNewlines)
                let stripped = name.hasSuffix(".") ? String(name.dropLast()) : name
                if !stripped.isEmpty,
                   stripped != reverseName.trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
                    return stripped
                }
            }
            return nil
        }.value
    }

    // MARK: - Probing

    private struct ProbeResult {
        let ip: String
        let hasSSH: Bool
        let hasVNC: Bool
        var displayName: String?
    }

    private static func probeHost(ip: String, timeout: TimeInterval) async -> ProbeResult? {
        // Parallel probes on 22 + 5900. If both fail the host is
        // dark and we drop it. Reverse DNS is best-effort.
        async let ssh = probePort(ip: ip, port: 22, timeout: timeout)
        async let vnc = probePort(ip: ip, port: 5900, timeout: timeout)
        let (hasSSH, hasVNC) = await (ssh, vnc)
        guard hasSSH || hasVNC else { return nil }
        let name = await reverseDNS(ip: ip)
        return ProbeResult(ip: ip, hasSSH: hasSSH, hasVNC: hasVNC, displayName: name)
    }

    private static func probePort(ip: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let conn = NWConnection(
                host: NWEndpoint.Host(ip),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            // Resolve the continuation once — there are three possible
            // race winners (ready / failed / timeout) and we must
            // resume exactly once or Swift traps.
            let resumed = Atomic(false)
            func finish(_ value: Bool) {
                if resumed.swap(true) == false {
                    conn.cancel()
                    continuation.resume(returning: value)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:            finish(true)
                case .failed, .cancelled: finish(false)
                case .waiting:          finish(false)  // host unreachable / refused
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }

    /// Best-effort reverse DNS via `getnameinfo`. Returns nil when
    /// no PTR record exists; the row then renders with just the IP.
    private static func reverseDNS(ip: String) async -> String? {
        await Task.detached(priority: .utility) {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr(ip)
            var host = [CChar](repeating: 0, count: 256)
            let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getnameinfo(sa,
                                socklen_t(MemoryLayout<sockaddr_in>.size),
                                &host,
                                socklen_t(host.count),
                                nil, 0,
                                NI_NAMEREQD)
                }
            }
            guard result == 0 else { return nil }
            let name = String(cString: host)
            return name.isEmpty ? nil : name
        }.value
    }

    // MARK: - CIDR

    enum CIDRError: LocalizedError {
        case malformed
        case unsupportedPrefix
        var errorDescription: String? {
            switch self {
            case .malformed: return "not a CIDR"
            case .unsupportedPrefix: return "only /24 or larger (smaller subnets) supported"
            }
        }
    }

    /// Expand a /N CIDR into all host IPs. Supports /16 through /32
    /// for IPv4. /24 yields 254 IPs (.1–.254, skipping network +
    /// broadcast). Smaller prefixes (larger ranges) than /16 are
    /// rejected to keep scan time bounded.
    private func expand(cidr: String) throws -> [String] {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              prefix >= 16, prefix <= 32
        else { throw CIDRError.malformed }
        let octets = parts[0].split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 < 256 }) else {
            throw CIDRError.malformed
        }
        let base = (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
        let mask: UInt32 = prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix))
        let network = base & mask
        let broadcast = network | ~mask
        guard broadcast >= network else { return [] }
        var out: [String] = []
        // For /32 there's exactly one host. For /31 RFC 3021 allows
        // 2 hosts. For everything else, skip network + broadcast.
        let lo: UInt32 = (prefix >= 31) ? network : network &+ 1
        let hi: UInt32 = (prefix >= 31) ? broadcast : broadcast &- 1
        for v in lo...hi {
            out.append("\((v >> 24) & 0xFF).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)")
        }
        return out
    }

    /// Stable numeric sort key for an IPv4 string so `10.0.0.2`
    /// sorts before `10.0.0.10`. String sort puts "10" before "2".
    private static func ipSortKey(_ ip: String) -> UInt32 {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return 0 }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }
}

/// Tiny atomic flag — used inside `probePort` to make sure the
/// continuation resumes exactly once across the {ready, failed,
/// timeout} race. NSLock + an Int is heavier than this needs, and
/// the Swift Atomics package is out of scope.
private final class Atomic<T> {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { self.value = v }
    func swap(_ new: T) -> T {
        lock.lock(); defer { lock.unlock() }
        let old = value
        value = new
        return old
    }
}
