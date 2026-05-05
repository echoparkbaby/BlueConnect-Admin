import SwiftUI

/// Right half of the transfer sheet: destination on the remote BSC host.
struct SCPDestinationPane: View {
    @Bindable var transfer: SCPTransfer
    let host: BlueSkyHost

    private struct QuickPath: Hashable, Identifiable {
        let label: String
        let path: String
        var id: String { path }
    }

    private let quickPaths: [QuickPath] = [
        .init(label: "Desktop",   path: "~/Desktop/"),
        .init(label: "Downloads", path: "~/Downloads/"),
        .init(label: "Documents", path: "~/Documents/"),
        .init(label: "Home",      path: "~/"),
        .init(label: "/tmp",      path: "/tmp/"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "display").font(.title3).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Destination").font(.caption).foregroundStyle(.secondary)
                    Text(host.displayName).font(.headline).lineLimit(1)
                    Text("#\(host.blueskyid)").font(.caption2).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Path on remote Mac").font(.caption).foregroundStyle(.secondary)
                TextField("~/Desktop/", text: $transfer.destinationPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .autocorrectionDisabled()
                    .disabled(transfer.isRunning)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Quick paths").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(quickPaths) { qp in
                        Button(qp.label) {
                            transfer.destinationPath = qp.path
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(transfer.isRunning)
                    }
                }
            }

            Spacer(minLength: 0)

            Text("File will be written as \(host.displayName):\(transfer.destinationPath)\(transfer.sourceURL?.lastPathComponent ?? "<file>")")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
