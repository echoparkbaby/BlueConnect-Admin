import SwiftUI

/// Sidebar section listing online Tailscale peers (macOS + Linux).
/// Reachable via the Tailscale-assigned 100.x.x.x address; doesn't
/// require MagicDNS to be configured. macOS peers offer SSH+VNC; Linux
/// peers offer SSH only.
struct TailscaleSection: View {
    @Environment(TailscaleBrowser.self) private var browser
    @EnvironmentObject private var settings: SettingsStore
    @State private var showingManager = false

    private var visible: [LocalService] {
        let hidden = settings.hiddenTailscalePeers
        return browser.services.filter { !hidden.contains($0.name) }
    }
    private var hiddenCount: Int {
        let hidden = settings.hiddenTailscalePeers
        return browser.services.filter { hidden.contains($0.name) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.caption).foregroundStyle(.tint)
                Text("Tailscale").font(.caption).bold().foregroundStyle(.secondary)
                Spacer()
                if !browser.services.isEmpty {
                    Button {
                        showingManager = true
                    } label: {
                        Image(systemName: "eye.slash")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Manage visible peers")
                    .popover(isPresented: $showingManager, arrowEdge: .trailing) {
                        TailscalePeerManager()
                            .environmentObject(settings)
                            .environment(browser)
                    }
                }
                if !visible.isEmpty {
                    Text("\(visible.count)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 2)

            if visible.isEmpty {
                Text(browser.lastError == nil
                     ? (browser.services.isEmpty ? "Loading…" : "All peers hidden")
                     : "Tailscale CLI not found")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 6)
            } else {
                ForEach(visible) { svc in
                    LocalNetworkRow(service: svc)
                }
            }

            if hiddenCount > 0 {
                Button("Show \(hiddenCount) hidden peer\(hiddenCount == 1 ? "" : "s")") {
                    settings.hiddenTailscalePeers = []
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
        }
    }
}

/// Popover for bulk-managing which Tailscale peers appear in the sidebar.
/// Per-row toggles plus Hide All / Show All for one-click bulk ops.
private struct TailscalePeerManager: View {
    @Environment(TailscaleBrowser.self) private var browser
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tailscale Peers").font(.headline)
                Spacer()
                Button("Hide All") {
                    settings.hiddenTailscalePeers = Set(browser.services.map(\.name))
                }
                .disabled(browser.services.isEmpty
                          || settings.hiddenTailscalePeers.count == browser.services.count)
                Button("Show All") {
                    settings.hiddenTailscalePeers = []
                }
                .disabled(settings.hiddenTailscalePeers.isEmpty)
            }
            Text("Uncheck a peer to hide it from the sidebar.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(browser.services) { svc in
                        peerToggle(for: svc)
                    }
                }
            }
            .frame(minHeight: 80, maxHeight: 320)
        }
        .padding(12)
        .frame(width: 320)
    }

    private func peerToggle(for svc: LocalService) -> some View {
        let visible = !settings.hiddenTailscalePeers.contains(svc.name)
        return Toggle(isOn: Binding(
            get: { visible },
            set: { newVisible in
                var current = settings.hiddenTailscalePeers
                if newVisible { current.remove(svc.name) } else { current.insert(svc.name) }
                settings.hiddenTailscalePeers = current
            }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(svc.name).lineLimit(1)
                Text(svc.hostname)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .toggleStyle(.checkbox)
    }
}
