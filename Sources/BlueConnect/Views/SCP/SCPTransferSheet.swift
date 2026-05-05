import SwiftUI

/// Modal sheet that orchestrates an in-app SCP file transfer to one
/// BSC host. Source on the left (this Mac), destination on the right
/// (remote host), animated footer with progress / done / error.
struct SCPTransferSheet: View {
    let host: BlueSkyHost
    @Bindable var transfer: SCPTransfer
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                SCPSourcePane(transfer: transfer)
                    .frame(maxWidth: .infinity)
                Divider()
                SCPDestinationPane(transfer: transfer, host: host)
                    .frame(maxWidth: .infinity)
            }
            .frame(minHeight: 280)
            Divider()
            footer
        }
        .frame(width: 760, height: 460)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "paperplane.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Send File").font(.title3).bold()
                Text("Securely copies via the BlueSky tunnel").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close", systemImage: "xmark") {
                transfer.cancel()
                dismiss()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Cancel and close")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder
    private var footer: some View {
        Group {
            switch transfer.phase {
            case .idle:        idleFooter
            case .running:     runningFooter
            case .succeeded:   succeededFooter
            case .failed(let m): failedFooter(m)
            case .cancelled:   cancelledFooter
            }
        }
        .padding(16)
        .animation(.easeInOut(duration: 0.2), value: transfer.progressPercent)
    }

    private var idleFooter: some View {
        HStack {
            if transfer.sourceURL == nil {
                Label("Pick a file to enable Start", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Start Transfer", systemImage: "paperplane.fill") {
                transfer.start(host: host, settings: settings)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!transfer.canStart)
        }
    }

    private var runningFooter: some View {
        VStack(spacing: 8) {
            ProgressView(value: Double(transfer.progressPercent), total: 100) {
                HStack(spacing: 8) {
                    Text("\(transfer.progressPercent)%").bold()
                    Text(progressDetail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .progressViewStyle(.linear)
            HStack {
                Spacer()
                Button("Cancel Transfer", role: .destructive) { transfer.cancel() }
            }
        }
    }

    private var succeededFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transfer complete").font(.body).bold()
                    if let url = transfer.sourceURL {
                        Text("\(url.lastPathComponent) → \(host.displayName):\(transfer.destinationPath)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Button("OK") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            // Send-this-link helper: lets the operator paste a clickable
            // file:// URL into iMessage / Mail. When the recipient (the
            // Mac we just transferred to) clicks it, Finder opens.
            HStack(spacing: 8) {
                Text(remoteFileURLString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy file link", systemImage: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(remoteFileURLString, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copies a file:// URL the recipient can click in iMessage or Mail to open the file in Finder.")
                .disabled(transfer.sourceURL == nil)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.tint.opacity(0.05)))
        }
        .transition(.opacity)
    }

    /// Build a `file:///Users/<remoteUser>/...` URL pointing at the
    /// just-transferred file. Expanding `~` to `/Users/<user>` is a
    /// reasonable assumption on macOS — non-default home dirs are rare.
    private var remoteFileURLString: String {
        guard let src = transfer.sourceURL else { return "" }
        let user = host.effectiveUser(default: settings.defaultRemoteUser)
        var dest = transfer.destinationPath
        if dest == "~" {
            dest = "/Users/\(user)/"
        } else if dest.hasPrefix("~/") {
            dest = "/Users/\(user)/" + String(dest.dropFirst(2))
        } else if !dest.hasPrefix("/") {
            dest = "/Users/\(user)/" + dest
        }
        if !dest.hasSuffix("/") { dest += "/" }
        let path = dest + src.lastPathComponent
        return URL(fileURLWithPath: path).absoluteString
    }

    private func failedFooter(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Transfer failed").bold()
            }
            ScrollView {
                Text(msg)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 80)
            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
        }
    }

    private var cancelledFooter: some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("Cancelled").font(.body).bold()
            Spacer()
            Button("Close") { dismiss() }
        }
    }

    private var progressDetail: String {
        var bits: [String] = []
        if !transfer.transferred.isEmpty { bits.append(transfer.transferred) }
        if !transfer.rate.isEmpty { bits.append(transfer.rate) }
        if !transfer.eta.isEmpty { bits.append("ETA \(transfer.eta)") }
        return bits.joined(separator: " · ")
    }
}
