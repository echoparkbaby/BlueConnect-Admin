import AppKit
import SwiftUI

struct FqdnPill: View {
    let text: String
    let healthy: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: "https://\(text)") {
                openURL(url)
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(healthy ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                    .help(healthy ? "Server reachable" : "Server unreachable / API error")
                Image(systemName: "network")
                    .foregroundStyle(.tint)
                Text(text)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))
            .overlay(Capsule().stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open https://\(text) in your browser")
    }
}
