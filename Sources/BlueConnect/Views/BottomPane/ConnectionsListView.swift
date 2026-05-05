import SwiftUI

struct ConnectionsListView: View {
    var manager: TerminalSessionsManager

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Active background tunnels").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !manager.tunnels.isEmpty {
                    Button(role: .destructive) { manager.killAllTunnels() } label: {
                        Label("Kill all", systemImage: "xmark.circle").font(.caption)
                    }.buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if manager.tunnels.isEmpty {
                ContentUnavailableView(
                    "No background tunnels running",
                    systemImage: "checkmark.shield",
                    description: Text("VNC connections register here while open.")
                )
            } else {
                List {
                    ForEach(manager.tunnels) { t in
                        TunnelRow(tunnel: t) { manager.killTunnel(t.id) }
                    }
                }.listStyle(.plain)
            }
        }
    }
}
