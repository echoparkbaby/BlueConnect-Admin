import SwiftUI

/// Window-scene content for an ad-hoc package install. Compact in the
/// idle/running state, expands when the user discloses the Log pane.
struct InstallProgressWindow: View {
    @Environment(InstallController.self) private var controller
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    /// Tab cycles password → cancel → install. macOS's full-keyboard-access
    /// default (text fields only) skips buttons; @FocusState + explicit
    /// .focused() puts them on equal footing.
    private enum Field: Hashable { case password, cancel, install }
    @FocusState private var focus: Field?

    var body: some View {
        VStack(spacing: 0) {
            body_
            Divider()
            footer
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { if controller.phase == .idle { focus = .password } }
        .onChange(of: controller.phase) { _, new in
            if new == .idle { focus = .password }
        }
    }

    @ViewBuilder
    private var body_: some View {
        VStack(alignment: .leading, spacing: 10) {
            fileInfoRow
            switch controller.phase {
            case .idle:
                @Bindable var c = controller
                SecureField("",
                            text: $c.sudoPassword,
                            prompt: Text("Remote sudo password (leave blank if passwordless)"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .password)
                    .onSubmit { controller.start(settings: settings) }
            case .succeeded:
                successView
            case .failed(let msg):
                failedView(msg)
            case .cancelled:
                cancelledView
            default:
                stepList
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12).padding(.bottom, 10)
    }

    private var fileInfoRow: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: controller.localFile))
                .font(.system(size: 24))
                .foregroundStyle(.tint)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                // Prefer the extracted display name when available, else
                // fall back to the filename.
                Text(displayTitle)
                    .font(.callout).bold().lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    if !controller.localFileSize.isEmpty {
                        Text(controller.localFileSize)
                    }
                    if !controller.destinationDescription.isEmpty {
                        Text(controller.destinationDescription)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let meta = controller.fileMetadata, meta.hasContent {
                    metadataLine(meta)
                }
            }
            Spacer()
        }
    }

    private var displayTitle: String {
        if let name = controller.fileMetadata?.displayName, !name.isEmpty {
            return name
        }
        return controller.localFile?.lastPathComponent ?? "—"
    }

    private func metadataLine(_ meta: PackageMetadata) -> some View {
        var bits: [String] = []
        if let v = meta.version {
            bits.append(meta.buildNumber.map { "v\(v) (\($0))" } ?? "v\(v)")
        }
        if let id = meta.bundleID { bits.append(id) }
        if let m = meta.minSystem { bits.append("macOS \(m)+") }
        return Text(bits.joined(separator: " · "))
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
    }

    /// Stepped checklist — one row per phase, with ○ pending / ◐ active /
    /// ✓ done. The active row also shows a small linear bar (with % for
    /// the upload phase, indeterminate otherwise).
    private var stepList: some View {
        VStack(alignment: .leading, spacing: 6) {
            let activeIndex = controller.steps.firstIndex { $0.matchingPhase == controller.phase } ?? -1
            ForEach(Array(controller.steps.enumerated()), id: \.element.id) { idx, step in
                stepRow(step, index: idx, activeIndex: activeIndex)
            }
        }
    }

    private func stepRow(_ step: InstallController.Step, index: Int, activeIndex: Int) -> some View {
        let isDone = index < activeIndex || controller.phase == .succeeded
        let isActive = index == activeIndex
        let isPending = !isDone && !isActive
        return HStack(alignment: .top, spacing: 8) {
            Group {
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if isActive {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary.opacity(0.6))
                }
            }
            .frame(width: 16, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(step.label)
                        .font(.callout)
                        .foregroundStyle(isPending ? .secondary : .primary)
                        .fontWeight(isActive ? .semibold : .regular)
                    Spacer()
                    if isActive, step == .upload, controller.progressPercent > 0 {
                        Text("\(controller.progressPercent)%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if isActive {
                    if step == .upload, controller.progressPercent > 0 {
                        ProgressView(value: Double(controller.progressPercent), total: 100)
                            .progressViewStyle(.linear)
                    }
                    if !controller.trailingLogLine.isEmpty {
                        Text(controller.trailingLogLine)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
    }

    private var successView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.title3)
            Text("Installed successfully.").font(.callout).bold()
        }
    }

    private func failedView(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.title3)
                Text("Install failed").font(.callout).bold()
            }
            ScrollView {
                Text(msg)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 70)
        }
    }

    private var cancelledView: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.orange).font(.title3)
            Text("Cancelled.").font(.callout).bold()
        }
    }

    private var footer: some View {
        HStack {
            if controller.phase == .idle {
                Spacer()
                Button("Cancel", role: .cancel) {
                    controller.reset()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .focused($focus, equals: .cancel)
                Button("Install") {
                    controller.start(settings: settings)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .focused($focus, equals: .install)
                .disabled(!controller.canStart)
            } else if controller.phase.isRunning {
                Spacer()
                Button("Cancel", role: .destructive) {
                    controller.cancel()
                }
            } else {
                Spacer()
                Button("OK") {
                    controller.reset()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func iconName(for url: URL?) -> String {
        guard let url else { return "shippingbox.fill" }
        switch url.pathExtension.lowercased() {
        case "pkg": return "shippingbox.fill"
        case "dmg": return "externaldrive.fill"
        case "app": return "app.fill"
        default:    return "doc.fill"
        }
    }
}
