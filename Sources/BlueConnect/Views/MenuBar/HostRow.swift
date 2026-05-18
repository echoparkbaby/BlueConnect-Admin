import SwiftUI

struct HostRow: View {
    let host: BlueSkyHost
    let kbSelected: Bool
    @EnvironmentObject var settings: SettingsStore
    @Environment(RecentConnectStore.self) var recents
    @Environment(TerminalSessionsManager.self) var terminals
    @Environment(SCPController.self) var scp
    @Environment(\.openWindow) private var openWindow
    @State private var hovered = false

    var body: some View {
        Button { connect(.ssh) } label: {
            HStack(spacing: 10) {
                Image(systemName: host.active ? "circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(host.active ? .green : .secondary.opacity(0.5))
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(host.displayName).lineLimit(1)
                            .foregroundStyle(host.active ? .primary : .secondary)
                        if host.isFavorite {
                            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                        }
                    }
                    if let subtitle = subtitleText {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    MiniIconButton(icon: "terminal", color: .green, enabled: host.active, help: "SSH") {
                        connect(.ssh)
                    }
                    MiniIconButton(icon: "display", color: .blue, enabled: host.active, help: "VNC") {
                        connect(.vnc)
                    }
                    MiniIconButton(icon: "doc.badge.arrow.up", color: .orange,
                                   enabled: host.active, help: "Send file (SCP)") {
                        connect(.scp)
                    }
                }
                .opacity(host.active ? (hovered ? 1.0 : 0.6) : 0.3)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(rowBackground)
                    .padding(.horizontal, 6)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var rowBackground: Color {
        if kbSelected { return Color.accentColor.opacity(0.30) }
        if hovered { return Color.accentColor.opacity(0.18) }
        return Color.clear
    }

    private var subtitleText: String? {
        var bits: [String] = []
        if let cat = host.category, !cat.isEmpty { bits.append(cat) }
        if let recent = recents.date(for: host.blueskyid) {
            bits.append(recent.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
        } else if let sharing = host.sharingname, !sharing.isEmpty, sharing != host.hostname {
            bits.append(sharing)
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private enum Action { case ssh, vnc, scp }

    private func connect(_ action: Action) {
        guard host.active else { return }
        var svc = ConnectionService(
            server: settings.serverFqdn,
            adminKeyPath: settings.expandedKeyPath,
            serverSshPort: settings.sshTunnelPort,
            terminals: terminals
        )
        svc.onConnect = { h in recents.recordConnect(blueskyid: h.blueskyid) }
        let user = host.effectiveUser(default: settings.defaultRemoteUser)
        switch action {
        case .ssh: svc.openSSH(host: host, remoteUser: user)
        case .vnc: svc.openVNC(host: host, remoteUser: user)
        case .scp:
            scp.begin(with: host)
            openWindow(id: "scp-transfer")
        }
        // VNC + SCP open external windows but the dropdown stays open by
        // default; explicitly dismiss so the user isn't double-handling it.
        _ = user
    }
}
