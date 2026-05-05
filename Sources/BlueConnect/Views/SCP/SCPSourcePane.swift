import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Left half of the transfer sheet: source on this Mac.
/// Drop a file, or pick via NSOpenPanel.
struct SCPSourcePane: View {
    @Bindable var transfer: SCPTransfer
    @State private var hovering = false
    @State private var thisMacName: String = Host.current().localizedName ?? "This Mac"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "macbook.and.iphone").font(.title3).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Source").font(.caption).foregroundStyle(.secondary)
                    Text(thisMacName).font(.headline).lineLimit(1)
                }
            }

            if let url = transfer.sourceURL {
                selectedFileCard(url: url)
            } else {
                dropZone
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func selectedFileCard(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName(for: url))
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(url.lastPathComponent).bold().lineLimit(2)
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Label(byteString, systemImage: "scalemass")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if !transfer.isRunning {
                    Button("Choose Different…", systemImage: "doc.badge.arrow.up") {
                        showFilePicker()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.tint.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.tint.opacity(0.3)))
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 44))
                .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
            Text(hovering ? "Release to add file" : "Drop a file here")
                .font(.callout)
                .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
            Text("or").font(.caption2).foregroundStyle(.tertiary)
            Button("Choose File…", systemImage: "doc") { showFilePicker() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill((hovering ? Color.accentColor : Color.gray).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    hovering ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $hovering) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in transfer.setSource(url) }
            }
            return true
        }
    }

    private var byteString: String {
        guard transfer.totalSize > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: transfer.totalSize, countStyle: .file)
    }

    private func iconName(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "zip", "tar", "gz", "tgz", "bz2", "7z": return "archivebox.fill"
        case "dmg", "pkg":                            return "shippingbox.fill"
        case "png", "jpg", "jpeg", "heic", "gif":     return "photo.fill"
        case "mov", "mp4", "m4v":                     return "film.fill"
        case "pdf":                                   return "doc.richtext.fill"
        case "txt", "md", "log":                      return "doc.text.fill"
        default:                                       return "doc.fill"
        }
    }

    private func showFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file to send"
        if panel.runModal() == .OK, let url = panel.url {
            transfer.setSource(url)
        }
    }
}
