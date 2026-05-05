import AppKit
import Foundation

/// Discovers SSH and VNC services on the local network via Bonjour/mDNS,
/// resolves them to hostname:port, and aggregates per host.
///
/// Requires `NSLocalNetworkUsageDescription` and `NSBonjourServices` in
/// Info.plist on macOS 14+. macOS prompts the user the first time the
/// app browses; if denied, this class silently reports an empty list.
@MainActor
@Observable
final class LocalRendezvousBrowser {
    /// Aggregated list, sorted by name. Body re-renders when this changes.
    private(set) var services: [LocalService] = []
    /// Set when the browser hits a permission/runtime error.
    private(set) var lastError: String?

    @ObservationIgnored private let sshBrowser = NetServiceBrowser()
    @ObservationIgnored private let vncBrowser = NetServiceBrowser()
    @ObservationIgnored private var sshDelegate: BrowserDelegateProxy?
    @ObservationIgnored private var vncDelegate: BrowserDelegateProxy?

    /// SSH/VNC ports keyed by lowercased hostname.
    @ObservationIgnored private var sshPorts: [String: Int] = [:]
    @ObservationIgnored private var vncPorts: [String: Int] = [:]
    /// Service-name → resolved hostname, latest wins. Used to surface a
    /// nicer label than the raw hostname.
    @ObservationIgnored private var nameForHost: [String: String] = [:]
    /// Hold strong references to in-flight resolver delegates — NetService
    /// keeps its delegate weakly so we'd lose them mid-resolution.
    @ObservationIgnored private var resolvers: [String: ResolverDelegate] = [:]

    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        sshDelegate = BrowserDelegateProxy(parent: self, kind: .ssh)
        vncDelegate = BrowserDelegateProxy(parent: self, kind: .vnc)
        sshBrowser.delegate = sshDelegate
        vncBrowser.delegate = vncDelegate
        sshBrowser.searchForServices(ofType: "_ssh._tcp.", inDomain: "local.")
        vncBrowser.searchForServices(ofType: "_rfb._tcp.", inDomain: "local.")
        Log.info("Bonjour", "started browsing _ssh._tcp + _rfb._tcp on local.")
    }

    func stop() {
        sshBrowser.stop()
        vncBrowser.stop()
        sshPorts.removeAll()
        vncPorts.removeAll()
        nameForHost.removeAll()
        resolvers.removeAll()
        services = []
        lastError = nil
        started = false
        Log.info("Bonjour", "stopped")
    }

    fileprivate func handleFound(_ service: NetService, kind: ServiceKind) {
        Log.info("Bonjour", "found \(kind.rawValue) '\(service.name)' in \(service.domain)")
        let key = resolverKey(for: service, kind: kind)
        if resolvers[key] != nil { return }
        // Resolver retains the service — NetServiceBrowser only keeps it
        // alive while didFind is on the stack, so without our retain the
        // service deallocates mid-resolution and the delegate never fires.
        let resolver = ResolverDelegate(parent: self, service: service, kind: kind, key: key)
        resolvers[key] = resolver
        service.delegate = resolver
        service.resolve(withTimeout: 5)
    }

    fileprivate func handleRemoved(_ service: NetService, kind: ServiceKind) {
        guard let host = service.hostName?.lowercased() else { return }
        switch kind {
        case .ssh: sshPorts.removeValue(forKey: host)
        case .vnc: vncPorts.removeValue(forKey: host)
        }
        rebuild()
    }

    fileprivate func handleResolveFinished(_ service: NetService, kind: ServiceKind, key: String, success: Bool) {
        if success, let host = service.hostName?.lowercased() {
            switch kind {
            case .ssh: sshPorts[host] = service.port
            case .vnc: vncPorts[host] = service.port
            }
            nameForHost[host] = service.name
            Log.info("Bonjour", "resolved \(kind.rawValue) '\(service.name)' → \(host):\(service.port)")
            excludeOwnHost()
            rebuild()
        } else if !success {
            Log.warn("Bonjour", "failed to resolve \(kind.rawValue) '\(service.name)'")
        }
        resolvers[key] = nil
    }

    fileprivate func report(_ message: String) {
        lastError = message
        Log.error("Bonjour", message)
    }

    private func resolverKey(for service: NetService, kind: ServiceKind) -> String {
        "\(kind)|\(service.type)|\(service.name)|\(service.domain)"
    }

    private func rebuild() {
        var byHost: [String: LocalService] = [:]
        for (host, port) in sshPorts {
            let display = nameForHost[host] ?? host
            var entry = byHost[host] ?? LocalService(name: display, hostname: host)
            entry.sshPort = port
            byHost[host] = entry
        }
        for (host, port) in vncPorts {
            let display = nameForHost[host] ?? host
            var entry = byHost[host] ?? LocalService(name: display, hostname: host)
            entry.vncPort = port
            byHost[host] = entry
        }
        services = byHost.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Strip ".local." / ".local" / trailing "." so two hostnames can be
    /// compared regardless of how the lookup formatted them.
    private func canonicalHost(_ s: String) -> String {
        var v = s.lowercased()
        if v.hasSuffix(".") { v.removeLast() }
        if v.hasSuffix(".local") { v.removeLast(".local".count) }
        return v
    }

    /// Drop "this Mac" from the list — own hostname is just noise.
    private func excludeOwnHost() {
        let me = canonicalHost(Host.current().localizedName ?? "")
        let myHost = canonicalHost(Host.current().name ?? "")
        let mine: Set<String> = [me, myHost].filter { !$0.isEmpty }.reduce(into: []) { $0.insert($1) }
        for key in Array(sshPorts.keys) where mine.contains(canonicalHost(key)) {
            sshPorts.removeValue(forKey: key)
        }
        for key in Array(vncPorts.keys) where mine.contains(canonicalHost(key)) {
            vncPorts.removeValue(forKey: key)
        }
    }
}

enum ServiceKind: String { case ssh, vnc }

// MARK: - Delegate proxies (NetService keeps delegates weakly, so we own them)

/// Browser delegate, one per service-type.
private final class BrowserDelegateProxy: NSObject, NetServiceBrowserDelegate, @unchecked Sendable {
    weak var parent: LocalRendezvousBrowser?
    let kind: ServiceKind

    init(parent: LocalRendezvousBrowser, kind: ServiceKind) {
        self.parent = parent
        self.kind = kind
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let kind = self.kind
        Task { @MainActor [weak parent] in parent?.handleFound(service, kind: kind) }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let kind = self.kind
        Task { @MainActor [weak parent] in parent?.handleRemoved(service, kind: kind) }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        let s = "browser \(kind.rawValue) error: \(errorDict)"
        Task { @MainActor [weak parent] in parent?.report(s) }
    }
}

private final class ResolverDelegate: NSObject, NetServiceDelegate, @unchecked Sendable {
    weak var parent: LocalRendezvousBrowser?
    let service: NetService     // strong — keeps it alive until resolve completes
    let kind: ServiceKind
    let key: String

    init(parent: LocalRendezvousBrowser, service: NetService, kind: ServiceKind, key: String) {
        self.parent = parent
        self.service = service
        self.kind = kind
        self.key = key
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let kind = self.kind
        let key = self.key
        Task { @MainActor [weak parent] in
            parent?.handleResolveFinished(sender, kind: kind, key: key, success: true)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let kind = self.kind
        let key = self.key
        Task { @MainActor [weak parent] in
            parent?.handleResolveFinished(sender, kind: kind, key: key, success: false)
        }
    }
}
