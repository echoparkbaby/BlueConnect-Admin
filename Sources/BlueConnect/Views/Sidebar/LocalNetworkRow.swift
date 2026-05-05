import AppKit
import SwiftUI

struct LocalNetworkRow: View {
    let service: LocalService
    @EnvironmentObject private var settings: SettingsStore
    @Environment(TerminalSessionsManager.self) private var terminals
    @State private var hovered = false

    var body: some View {
        // The row is a passive label — only the trailing SSH / VNC icons
        // (or the right-click menu) trigger a connection. This avoids the
        // accidental-SSH-on-row-click problem the user hit.
        HStack(spacing: 6) {
            Image(systemName: "macbook").foregroundStyle(.tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name).lineLimit(1)
                Text(service.hostname).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if service.hasSSH {
                Button("SSH (Remote Shell)", systemImage: "terminal", action: connectSSH)
                    .labelStyle(.iconOnly)
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .buttonStyle(.plain)
                    .help("SSH on port \(service.sshPort ?? 22)")
            }
            if service.hasVNC {
                Button("VNC (Screen Share)", systemImage: "display", action: connectVNC)
                    .labelStyle(.iconOnly)
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .buttonStyle(.plain)
                    .help("VNC on port \(service.vncPort ?? 5900)")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(hovered ? Color.accentColor.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            if service.hasSSH {
                Button("SSH (Remote Shell)") { connectSSH() }
            }
            if service.hasVNC {
                Button("VNC (Screen Share)") { connectVNC() }
            }
            Divider()
            Button("Copy hostname") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(service.hostname, forType: .string)
            }
            if service.source == .tailscale {
                Divider()
                Button("Hide from sidebar") { hideFromSidebar() }
            }
        }
    }

    private func hideFromSidebar() {
        var current = settings.hiddenTailscalePeers
        current.insert(service.name)
        settings.hiddenTailscalePeers = current
    }

    private func connectSSH() {
        guard let port = service.sshPort else {
            if service.hasVNC { connectVNC() }
            return
        }
        let svc = ConnectionService(
            server: settings.serverFqdn,
            adminKeyPath: settings.expandedKeyPath,
            serverSshPort: settings.sshTunnelPort,
            terminals: terminals
        )
        svc.openDirectSSH(hostname: service.hostname,
                          port: port,
                          remoteUser: settings.defaultRemoteUser)
    }

    private func connectVNC() {
        guard let port = service.vncPort else { return }
        let svc = ConnectionService(
            server: settings.serverFqdn,
            adminKeyPath: settings.expandedKeyPath,
            serverSshPort: settings.sshTunnelPort,
            terminals: terminals
        )
        svc.openDirectVNC(hostname: service.hostname,
                          port: port,
                          remoteUser: settings.defaultRemoteUser)
    }
}
