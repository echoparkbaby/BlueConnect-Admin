import SwiftUI
import AppKit

/// Pop-out tabular view of the last network scan. Same data as the
/// sidebar's `ScannedSection`, but in a real Table so you can sort,
/// search, customize column visibility and order, and act on entries
/// from a roomier UI.
struct ScannedTableWindow: View {
    @Environment(NetworkScanner.self) private var scanner
    @Environment(LocalRendezvousBrowser.self) private var rendezvous
    @EnvironmentObject private var settings: SettingsStore
    /// Used by the UniFi profile dropdown's "Manage Profiles…" item
    /// to jump straight to Settings → Network. We seed
    /// `settingsSelection` first so the Settings window opens on
    /// the right pane (same trick the Terminal profile picker uses).
    @Environment(\.openSettings) private var openSettings
    @State private var sortOrder: [KeyPathComparator<Row>] = [
        KeyPathComparator(\.dnsName, order: .forward)
    ]
    @State private var selection: Row.ID?
    @State private var searchText: String = ""
    /// Persists column visibility + reorder across launches. The
    /// AppStorage key isolates it from any other Table we add later.
    @AppStorage("scannedTableColumns") private var columnsRaw: String = ""
    @State private var columnCustomization: TableColumnCustomization<Row> = .init()
    /// Global text-size multiplier for the Scanned Table. ⌘+ / ⌘-
    /// nudge it; ⌘0 resets. Persisted so the operator's preferred
    /// zoom survives quit. Clamped to [0.7, 1.6] so the UI can't
    /// shrink past readability or blow the column widths out.
    @AppStorage("scannedTableFontScale") private var fontScale: Double = 1.0
    /// AppKit-level NSEvent monitor that intercepts ⌘= / ⌘+ / ⌘- /
    /// ⌘0 when this window is key. SwiftUI's `.keyboardShortcut`
    /// dispatch turned out unreliable for hidden Buttons in a window
    /// whose content is dominated by an AppKit-backed Table — the
    /// shortcuts never fired even when the buttons were hosted in
    /// the same subtree as a working ⌘R. NSEvent monitors are the
    /// bulletproof fallback the rest of the app already uses for ⌘W
    /// tab-close on the main window.
    @State private var zoomKeyMonitor: Any?
    /// User-picked icons for the Type column (Scan: Wired / Scan:
    /// Wireless slots in the Customize Row Icons sheet). Reads
    /// directly from @AppStorage so the table redraws as soon as the
    /// picker mutates the value.
    @AppStorage("scanWiredIconSymbol")    private var scanWiredIcon: String    = "network"
    @AppStorage("scanWirelessIconSymbol") private var scanWirelessIcon: String = "dot.radiowaves.left.and.right"

    /// Base sizes the scale applies to. The IP column gets a bump
    /// over the other monospace fields because it's the primary
    /// identifier most operators eyeball.
    private var smallSize: CGFloat { CGFloat(11 * fontScale) }
    private var ipSize: CGFloat    { CGFloat(12 * fontScale) }
    private var rowSize: CGFloat   { CGFloat(12 * fontScale) }

    /// Flattened row type combining LocalService probe data + UniFi
    /// integration-API client data. Every field is a sortable
    /// KeyPath off this struct so every column header click works.
    struct Row: Identifiable, Hashable {
        let id: String
        let dnsName: String
        let ip: String
        let ipSortKey: UInt32
        let hasSSH: Bool
        let hasVNC: Bool
        let sshSort: Int
        let vncSort: Int
        let typeLabel: String
        let isWired: Bool
        let speedMbps: Double
        let mac: String
        let vlan: String
    }

    private var rows: [Row] {
        scanner.results.map { svc in
            let unifi = scanner.unifiByIP[svc.hostname]
            return Row(
                id: svc.id,
                dnsName: svc.name,
                ip: svc.hostname,
                ipSortKey: Self.ipSortKey(svc.hostname),
                hasSSH: svc.hasSSH,
                hasVNC: svc.hasVNC,
                sshSort: svc.hasSSH ? 1 : 0,
                vncSort: svc.hasVNC ? 1 : 0,
                typeLabel: unifi?.type.map { Self.displayType($0) } ?? "",
                isWired: unifi?.isWired ?? false,
                speedMbps: unifi?.txRateMbps ?? unifi?.rxRateMbps ?? 0,
                mac: unifi?.macAddress ?? "",
                vlan: unifi.flatMap { u in
                    if let net = u.network, !net.isEmpty { return net }
                    if let v = u.vlan { return "\(v)" }
                    return ""
                } ?? ""
            )
        }
    }

    /// Apply the search-field filter across all displayable fields.
    /// Case-insensitive substring match — easiest mental model and
    /// matches everywhere the user sees text in the row.
    private var filteredRows: [Row] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { r in
            r.dnsName.lowercased().contains(q)
            || r.ip.contains(q)
            || r.mac.lowercased().contains(q)
            || r.typeLabel.lowercased().contains(q)
            || r.vlan.lowercased().contains(q)
        }
    }

    private var sortedRows: [Row] {
        var out = filteredRows
        out.sort(using: sortOrder)
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if scanner.results.isEmpty && !scanner.isScanning {
                emptyState
            } else {
                table
            }
        }
        .frame(minWidth: 600, idealWidth: 1100, minHeight: 400, idealHeight: 900)
        .task { await runScan() }
        .onAppear { installZoomKeyMonitor() }
        .onDisappear { removeZoomKeyMonitor() }
        .onAppear {
            // Restore persisted column order/visibility on first
            // render. SwiftUI's TableColumnCustomization is Codable —
            // we round-trip it through AppStorage JSON.
            if !columnsRaw.isEmpty,
               let data = columnsRaw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(TableColumnCustomization<Row>.self, from: data) {
                columnCustomization = decoded
            }
        }
        .onChange(of: columnCustomization) { _, new in
            if let data = try? JSONEncoder().encode(new),
               let s = String(data: data, encoding: .utf8) {
                columnsRaw = s
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Network Scan").font(.headline)
                Text(headerSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Compact search field — anchored next to Scan so it's
            // out of the way but always reachable. ⌘F focuses it.
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary).font(.caption)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            unifiProfilePicker
            if scanner.isScanning {
                ProgressView().controlSize(.small)
                Text("\(scanner.progress)/\(scanner.total)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Button {
                Task { await runScan() }
            } label: {
                Label("Scan", systemImage: "arrow.clockwise")
            }
            // ⌘R refreshes when the scan window is key. Scoped to
            // the button so it doesn't steal the shortcut from
            // other windows (no global cross-window collision).
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(scanner.isScanning)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// UniFi profile switcher next to the search field. Always
    /// visible: with zero profiles it's an entry-point to Settings
    /// (label "Not configured"); with one it's a status tile that
    /// also offers Manage; with two or more it's a real switcher.
    /// "Manage Profiles…" writes the `settingsSelection` AppStorage
    /// key BEFORE calling `openSettings()` so the Settings window
    /// opens directly on the Network pane (the same dance the
    /// Terminal profile picker's Customize button does).
    private var unifiProfilePicker: some View {
        let profiles = settings.unifiProfiles
        let active = settings.activeUnifiProfile
        let label: String = active?.label ?? (profiles.isEmpty ? "Not configured" : "UniFi")
        return Menu {
            if profiles.isEmpty {
                Text("No UniFi profiles configured")
            } else {
                ForEach(profiles) { p in
                    Button {
                        settings.activeUnifiProfileID = p.id
                    } label: {
                        Label(p.label, systemImage: active?.id == p.id
                              ? "checkmark"
                              : "")
                    }
                }
                Divider()
            }
            Button("Manage Profiles…") {
                UserDefaults.standard.set("unifi", forKey: "settingsSelection")
                openSettings()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "network")
                    .foregroundStyle(active == nil ? .secondary : .primary)
                Text(label)
                    .lineLimit(1)
                    .foregroundStyle(active == nil ? .secondary : .primary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(profiles.isEmpty
              ? "Add a UniFi controller profile to enrich scan results"
              : "Switch UniFi controller profile")
    }

    private var headerSubtitle: String {
        if let err = scanner.lastError, !err.isEmpty { return err }
        if scanner.isScanning { return "Probing \(settings.scanSubnets)…" }
        if scanner.results.isEmpty { return "No results — click Scan to probe." }
        let total = scanner.results.count
        let tcp = scanner.results.filter { $0.hasSSH || $0.hasVNC }.count
        let unifiOnly = total - tcp
        let shown = filteredRows.count
        let filterNote = (shown != total) ? " · showing \(shown)" : ""
        if unifiOnly == 0 {
            return "\(total) host\(total == 1 ? "" : "s") responded on TCP 22 or 5900\(filterNote)"
        }
        return "\(total) device\(total == 1 ? "" : "s") · \(tcp) SSH/VNC-reachable · \(unifiOnly) UniFi-only\(filterNote)"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No scan results yet")
                .font(.headline)
            Text("Click Scan above to probe the configured subnets.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Every column carries a `customizationID(...)` so SwiftUI's
    /// Table grants the user header-bar reordering, hide/show via
    /// right-click on the header, and `.tableColumnCustomization`
    /// state for persistence.
    private var table: some View {
        Table(sortedRows,
              selection: $selection,
              sortOrder: $sortOrder,
              columnCustomization: $columnCustomization) {
            TableColumn("DNS Name", value: \.dnsName) { r in
                HStack(spacing: 6) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(.tint)
                    Text(r.dnsName)
                        .font(.system(size: rowSize))
                        .help(r.dnsName == r.ip ? "" : "Resolved from \(r.ip)")
                        .lineLimit(1)
                }
            }
            .width(min: 130, ideal: 200)
            .customizationID("dnsName")
            TableColumn("IP", value: \.ipSortKey) { (r: Row) in
                // IP gets a slightly bigger monospace face — it's the
                // primary identifier most operators read across the
                // row, and the previous .caption made it cramped.
                Text(r.ip).font(.system(size: ipSize, design: .monospaced))
            }
            // 110pt ideal fits a 15-char IPv4 ("192.168.100.200") at
            // 12pt monospaced with a little breathing room. The min
            // is set low so operators can drag-shrink the column for
            // 10.0.0.x setups where the IPs are shorter.
            .width(min: 70, ideal: 110, max: 140)
            .customizationID("ip")
            TableColumn("SSH", value: \.sshSort) { (r: Row) in
                Image(systemName: r.hasSSH ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(r.hasSSH ? .green : .secondary.opacity(0.4))
            }
            .width(40)
            .customizationID("ssh")
            TableColumn("VNC", value: \.vncSort) { (r: Row) in
                Image(systemName: r.hasVNC ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(r.hasVNC ? .blue : .secondary.opacity(0.4))
            }
            .width(40)
            .customizationID("vnc")
            TableColumn("Type", value: \.typeLabel) { (r: Row) in
                if !r.typeLabel.isEmpty {
                    // .firstTextBaseline anchors the SF Symbol's baseline
                    // to the Text's first-line baseline. Default HStack
                    // alignment (.center) centered the Image's *bounds*
                    // against the Text's bounds, which made SF Symbols
                    // sit slightly above the text optical centerline
                    // (their intrinsic padding doesn't match a glyph's
                    // x-height). Baseline alignment is the canonical
                    // SwiftUI pattern for icon+text rows.
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        // Icon comes from the user's picks in View →
                        // Customize Row Icons → Scan: Wired / Wireless.
                        // Defaults: "network" (wired), "dot.radiowaves
                        // .left.and.right" (wireless). Live updates
                        // because @AppStorage on this view triggers a
                        // body re-evaluation when the picker writes.
                        Image(systemName: r.isWired ? scanWiredIcon : scanWirelessIcon)
                            .font(.system(size: smallSize))
                            .foregroundStyle(r.isWired ? .green : .blue)
                        Text(r.typeLabel).font(.system(size: smallSize))
                    }
                } else {
                    Text("—").foregroundStyle(.tertiary).font(.system(size: smallSize))
                }
            }
            .width(min: 70, ideal: 80, max: 110)
            .customizationID("type")
            TableColumn("Speed", value: \.speedMbps) { (r: Row) in
                if let display = scanner.unifiByIP[r.ip]?.displaySpeed {
                    Text(display).font(.system(size: smallSize, design: .monospaced))
                } else {
                    Text("—").foregroundStyle(.tertiary).font(.system(size: smallSize))
                }
            }
            .width(min: 60, ideal: 70, max: 90)
            .customizationID("speed")
            TableColumn("VLAN", value: \.vlan) { (r: Row) in
                if !r.vlan.isEmpty {
                    Text(r.vlan).font(.system(size: smallSize))
                } else {
                    Text("—").foregroundStyle(.tertiary).font(.system(size: smallSize))
                }
            }
            // Tightened: most VLAN labels are 1–3 chars (numeric tag)
            // or a short SSID name. The previous 60–120 reserved more
            // horizontal real estate than the data ever needed.
            .width(min: 40, ideal: 52, max: 80)
            .customizationID("vlan")
            TableColumn("MAC", value: \.mac) { (r: Row) in
                if !r.mac.isEmpty {
                    Text(r.mac)
                        .font(.system(size: smallSize, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.tertiary).font(.system(size: smallSize))
                }
            }
            .width(min: 110, ideal: 125, max: 145)
            .customizationID("mac")
        }
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button("Copy IP") { copy(row.ip) }
                Button("Copy DNS Name") { copy(row.dnsName) }
                if !row.mac.isEmpty {
                    Button("Copy MAC") { copy(row.mac) }
                }
            }
        }
        // Force SwiftUI to rebuild the entire Table identity whenever
        // the font scale OR the Type-column icon picks change.
        // Without this, the AppKit-backed NSTableView reuses
        // already-rendered cells and new sizing / new SF Symbols
        // don't take effect until the user scrolls and the cells
        // get recycled.
        .id("scan-table-\(Int(fontScale * 100))-\(scanWiredIcon)-\(scanWirelessIcon)")
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @MainActor
    private func runScan() async {
        let cidrs = settings.scanSubnets
            .split(whereSeparator: { ",\n ".contains($0) })
            .map(String.init)
        let candidates = rendezvous.services
        let unifi = settings.activeUnifiCredentials
        await scanner.scan(cidrs: cidrs, bonjourCandidates: candidates, unifi: unifi)
    }

    /// Nudge the font scale and clamp it. The clamp matters because
    /// AppStorage will happily store -0.4 if we let it, which would
    /// render every row as a black sliver with no recoverable UI to
    /// reset from.
    private func bumpScale(by delta: Double) {
        let next = (fontScale + delta).rounded(toPlaces: 2)
        fontScale = min(max(next, 0.7), 1.6)
    }

    /// Install the AppKit-level key monitor when the scan window
    /// appears. Filters by `event.window?.title == "Network Scan"`
    /// so other windows aren't affected even though local monitors
    /// are app-wide.
    private func installZoomKeyMonitor() {
        guard zoomKeyMonitor == nil else { return }
        zoomKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.title == "Network Scan" else { return event }
            guard event.modifierFlags.contains(.command) else { return event }
            let chars = event.charactersIgnoringModifiers ?? ""
            switch chars {
            case "=", "+":
                Task { @MainActor in bumpScale(by: 0.1) }
                return nil
            case "-":
                Task { @MainActor in bumpScale(by: -0.1) }
                return nil
            case "0":
                Task { @MainActor in fontScale = 1.0 }
                return nil
            default:
                return event
            }
        }
    }

    private func removeZoomKeyMonitor() {
        if let m = zoomKeyMonitor {
            NSEvent.removeMonitor(m)
            zoomKeyMonitor = nil
        }
    }

    private static func ipSortKey(_ ip: String) -> UInt32 {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return 0 }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    /// UniFi `type` field renderer. Short all-letter codes (`uap`,
    /// `udm`, `usw`, `ugw`, …) are device-class acronyms that read
    /// best in ALL CAPS — UniFi's own UI shows them that way. Longer
    /// values like "wired" / "wireless" / "user" are common English
    /// words; first-letter capitalization is right for them. The
    /// length cutoff (≤4) is a pragmatic line between the two cases.
    private static func displayType(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.count <= 4 && t.allSatisfy({ $0.isLetter }) {
            return t.uppercased()
        }
        return t.capitalized
    }
}

private extension Double {
    /// Two-decimal rounding so AppStorage doesn't accumulate
    /// floating-point lint after a dozen ⌘+ presses (1.0 + 0.1 * n
    /// drifts to 1.2999999… without this).
    func rounded(toPlaces n: Int) -> Double {
        let m = pow(10.0, Double(n))
        return (self * m).rounded() / m
    }
}
