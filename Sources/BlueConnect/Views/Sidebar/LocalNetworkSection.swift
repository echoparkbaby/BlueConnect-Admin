import SwiftUI

/// Sidebar section showing machines on the *local* network — discovered
/// via Bonjour/mDNS only. Tailscale peers (which mDNS can't see) live in
/// `TailscaleSection`.
struct LocalNetworkSection: View {
    @Environment(LocalRendezvousBrowser.self) private var browser
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.snappy(duration: 0.15)) {
                    settings.sidebarLocalNetworkCollapsed.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: settings.sidebarLocalNetworkCollapsed
                          ? "chevron.right" : "chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: "wifi").font(.caption).foregroundStyle(.tint)
                    Text("Local Network").font(.caption).bold().foregroundStyle(.secondary)
                    Spacer()
                    if !browser.services.isEmpty {
                        Text("\(browser.services.count)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 2)

            if !settings.sidebarLocalNetworkCollapsed {
                if browser.services.isEmpty {
                    Text(browser.lastError == nil ? "Searching…" : "Discovery unavailable")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                } else {
                    ForEach(browser.services) { svc in
                        LocalNetworkRow(service: svc)
                    }
                }
            }
        }
    }
}
