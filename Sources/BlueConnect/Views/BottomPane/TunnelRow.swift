import SwiftUI

struct TunnelRow: View {
    var tunnel: TrackedTunnel
    let onKill: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "display").foregroundStyle(.blue)
                    Text("\(tunnel.kind) — \(tunnel.displayName)").bold()
                    Text("#\(tunnel.blueskyid)").foregroundStyle(.secondary).font(.caption)
                }
                Text("localhost:\(tunnel.localPort) → client port \(tunnel.remotePort) · pid \(tunnel.process.processIdentifier) · started \(tunnel.startedAt, style: .time)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive, action: onKill) { Label("Kill", systemImage: "xmark.circle") }
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }
}
