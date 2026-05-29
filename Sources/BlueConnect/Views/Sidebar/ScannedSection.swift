import SwiftUI

/// Sidebar section that renders on-demand network scan results.
/// Bonjour misses Macs that don't advertise; the scanner fans out
/// TCP probes on 22 + 5900 across configured CIDRs and reports
/// whoever answers. Results render through the same
/// `LocalNetworkRow` as Bonjour entries (just with `source =
/// .scanned`), so right-click → SSH/VNC/Install/Quick Actions all
/// work identically.
struct ScannedSection: View {
    @Environment(NetworkScanner.self) private var scanner
    @Environment(LocalRendezvousBrowser.self) private var rendezvous
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("sidebarScannedCollapsed") private var collapsed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if !collapsed {
                body_
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) { collapsed.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 10)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption).foregroundStyle(.tint)
                Text("Scanned").font(.caption).bold().foregroundStyle(.secondary)
                Spacer()
                if scanner.isScanning {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                    Text("\(scanner.progress)/\(scanner.total)")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                } else if !scanner.results.isEmpty {
                    Text("\(scanner.results.count)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button {
                    let cidrs = settings.scanSubnets
                        .split(whereSeparator: { ",\n ".contains($0) })
                        .map(String.init)
                    let candidates = rendezvous.services
                    let unifi = settings.activeUnifiCredentials
                    Task { await scanner.scan(cidrs: cidrs, bonjourCandidates: candidates, unifi: unifi) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(scanner.isScanning)
                .help("Scan subnets listed in Settings → General")
                Button {
                    openWindow(id: "scanned-table")
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Open full scan results in a tabular window")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var body_: some View {
        if let err = scanner.lastError, scanner.results.isEmpty, !scanner.isScanning {
            Text(err)
                .font(.caption2).foregroundStyle(.orange)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .fixedSize(horizontal: false, vertical: true)
        } else if scanner.results.isEmpty && !scanner.isScanning {
            Text("Click ↻ to probe \(settings.scanSubnets) for SSH (22) + VNC (5900).")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(scanner.results) { svc in
                LocalNetworkRow(service: svc)
            }
        }
    }
}
