import SwiftUI

/// Sidebar section showing machines on the *local* network — discovered
/// via Bonjour/mDNS only. Tailscale peers (which mDNS can't see) live in
/// `TailscaleSection`.
struct LocalNetworkSection: View {
    @Environment(LocalRendezvousBrowser.self) private var browser

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "wifi").font(.caption).foregroundStyle(.tint)
                Text("Local Network").font(.caption).bold().foregroundStyle(.secondary)
                Spacer()
                if !browser.services.isEmpty {
                    Text("\(browser.services.count)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 2)

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
