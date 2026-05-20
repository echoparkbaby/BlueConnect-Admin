import AppKit
import SwiftUI

/// Window-scene content for an ad-hoc package install. Compact in the
/// idle/running state, expands when the user discloses the Log pane.
struct InstallProgressWindow: View {
    private static let minContentWidth: CGFloat = 420
    private static let expandedMinContentHeight: CGFloat = 360
    private static let expandedDefaultContentHeight: CGFloat = 520

    @Environment(InstallController.self) private var controller
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    /// Tab cycles password → cancel → install. macOS's full-keyboard-access
    /// default (text fields only) skips buttons; @FocusState + explicit
    /// .focused() puts them on equal footing.
    private enum Field: Hashable { case password, cancel, install }
    @FocusState private var focus: Field?
    /// Disclosure state for the raw-log pane at the bottom of the window.
    @State private var logExpanded: Bool = false
    /// Backing NSWindow — captured via WindowAccessor so we can actively
    /// resize when the log expands/collapses (.windowResizability alone
    /// only fires at scene construction, not on state change).
    @State private var window: NSWindow?
    /// Remember the user's last expanded content size so re-expanding
    /// restores a readable window instead of always resetting to 520pt.
    @State private var lastExpandedContentSize = NSSize(
        width: minContentWidth,
        height: expandedDefaultContentHeight
    )

    var body: some View {
        VStack(spacing: 0) {
            body_
            if logExpanded {
                Divider()
                logPane
            }
            Divider()
            footer
        }
        .frame(minWidth: Self.minContentWidth, idealWidth: Self.minContentWidth, maxWidth: .infinity,
               minHeight: logExpanded ? Self.expandedMinContentHeight : nil,
               idealHeight: logExpanded ? Self.expandedDefaultContentHeight : nil,
               maxHeight: logExpanded ? .infinity : nil,
               alignment: .top)
        .background(InstallWindowAccessor(window: $window))
        .onAppear {
            if controller.phase == .idle { focus = .password }
            scheduleApplyWindowSize(forExpanded: logExpanded)
        }
        .onChange(of: window) { _, _ in
            scheduleApplyWindowSize(forExpanded: logExpanded)
        }
        .onChange(of: controller.phase) { _, new in
            if new == .idle { focus = .password }
        }
        // Note: no `.onChange(of: logExpanded)` — `toggleLog()` performs
        // the resize and the state flip in the right order itself, so
        // observing logExpanded would only fire a redundant follow-up.
    }

    /// Deferred variant — runs on the next runloop tick so SwiftUI has a
    /// chance to render any pending view-tree updates first (matters for
    /// the collapse direction where `contentView.fittingSize` needs to
    /// reflect the post-collapse layout to compute the correct compact
    /// window height). Used from `.onAppear` and the window-binding hook.
    private func scheduleApplyWindowSize(forExpanded expanded: Bool) {
        Task { @MainActor in
            applyWindowSize(forExpanded: expanded)
        }
    }

    /// Resize the install window to match the log state. When collapsed,
    /// the window snaps back to its compact content height so there's no
    /// gutter above or below the password field; when expanded, the
    /// window grows to 520pt tall (or stays larger if the user has
    /// already dragged it past that) so the log pane is readable.
    ///
    /// Synchronous: caller chooses ordering. `toggleLog` runs this BEFORE
    /// the `logExpanded` state change on expand so the window is already
    /// tall enough when SwiftUI renders the new view tree — otherwise the
    /// expanded-layout content tries to fit into a still-collapsed window
    /// for one render pass and the file info / password / log all overlap.
    private func applyWindowSize(forExpanded expanded: Bool) {
        guard let window, let contentView = window.contentView else { return }

        if !expanded {
            let current = window.contentRect(forFrameRect: window.frame).size
            lastExpandedContentSize = NSSize(
                width: max(current.width, Self.minContentWidth),
                height: max(current.height, Self.expandedDefaultContentHeight)
            )
        }

        // Force SwiftUI to flush any pending view-tree work into AppKit
        // before we ask the contentView for its fitting size.
        contentView.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        if expanded {
            window.styleMask.insert(.resizable)
            window.contentMinSize = NSSize(
                width: Self.minContentWidth,
                height: Self.expandedMinContentHeight
            )
            window.contentMaxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )

            let current = window.contentRect(forFrameRect: window.frame).size
            let target = NSSize(
                width: max(current.width, lastExpandedContentSize.width),
                height: max(current.height, lastExpandedContentSize.height)
            )
            setWindowContentSize(window, target)
        } else {
            // Match `.contentSize` behavior while collapsed: compute the
            // real fitted height, then clamp min/max to that exact size.
            window.contentMinSize = .zero
            window.contentMaxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            contentView.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()

            let fitted = contentView.fittingSize
            let target = NSSize(
                width: max(fitted.width, Self.minContentWidth),
                height: fitted.height
            )

            window.contentMinSize = target
            window.contentMaxSize = target
            setWindowContentSize(window, target)
            window.styleMask.remove(.resizable)
        }
    }

    /// Resize around the top edge so disclosure growth behaves like a
    /// native macOS utility window: the title bar stays put and the body
    /// grows/shrinks downward.
    ///
    /// Snaps instead of animating: SwiftUI updates its view tree the
    /// moment `logExpanded` flips, so an animated NSWindow resize leaves
    /// the content rendering at its expanded layout inside a still-
    /// collapsed window (and vice versa) for the duration of the
    /// animation — file info, password field, and log overlap. Instant
    /// resize keeps view geometry and window geometry in lockstep.
    private func setWindowContentSize(_ window: NSWindow, _ targetContentSize: NSSize) {
        let currentFrame = window.frame
        let targetFrame = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: targetContentSize)
        )

        var nextFrame = currentFrame
        nextFrame.origin.y += currentFrame.height - targetFrame.height
        nextFrame.size = targetFrame.size
        window.setFrame(nextFrame, display: true, animate: false)
    }

    /// Raw stdout+stderr feed from the controller — exposed via a chevron
    /// toggle in the footer. Auto-scrolls to the bottom as new lines land.
    private var logPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(controller.log.isEmpty
                     ? "(no output yet — waiting for the process to emit something)"
                     : controller.log)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("log-tail")
            }
            .frame(minHeight: 180, idealHeight: 240, maxHeight: .infinity)
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: controller.log) {
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo("log-tail", anchor: .bottom)
                }
            }
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
                            prompt: Text("Remote sudo password"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .password)
                    .onSubmit {
                        if !controller.sudoPassword.isEmpty {
                            controller.start(settings: settings)
                        }
                    }
            // .downloading is a running phase now — the user already
            // entered their password and clicked Install; the step list's
            // .download row is active. Falls through to the default branch.
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
        if let file = controller.localFile {
            return file.lastPathComponent
        }
        // Munki pending: localFile not set until download finishes —
        // surface the expected filename so the header isn't blank.
        if !controller.pendingFileName.isEmpty {
            return controller.pendingFileName
        }
        return "—"
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
            logToggle
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
                // Require a non-empty sudo password — most fleet Macs need
                // it for `installer`, and a blank attempt fails silently
                // after the upload finishes. Passwordless setups are rare;
                // if it ever becomes a real need we'll add a per-host
                // "passwordless sudo" toggle.
                .disabled(!controller.canStart || controller.sudoPassword.isEmpty)
            } else if controller.phase.isRunning || controller.phase == .downloading {
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

    /// Native disclosure triangle + "Log" label, matching Finder/Inspector
    /// disclosure controls. Lives on the left side of the footer so it
    /// doesn't shift as the right-side action buttons swap between phases.
    private var logToggle: some View {
        Button { toggleLog() } label: {
            HStack(spacing: 4) {
                Image(systemName: logExpanded ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                Text("Log")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(logExpanded ? "Hide log" : "Show install log")
    }

    /// Sequence the window resize and view-tree update to eliminate the
    /// "content squashed in the wrong-size window" distortion frame:
    ///
    /// - Expanding: grow the NSWindow first, *then* flip `logExpanded`.
    ///   That way when SwiftUI inserts the logPane into the view tree it
    ///   has a window already tall enough to host it.
    /// - Collapsing: flip `logExpanded` first (SwiftUI re-renders without
    ///   logPane, content drops to its intrinsic compact size), *then*
    ///   shrink the window. Otherwise the window shrinks past the still-
    ///   tall content and squashes everything mid-render.
    ///
    /// `.onChange(of: logExpanded)` still fires after the second step, but
    /// at that point window and content are already in agreement and the
    /// follow-up call is a no-op.
    private func toggleLog() {
        if logExpanded {
            // Collapse: view tree first, then defer the window shrink so
            // SwiftUI has finished removing the log pane (otherwise
            // contentView.fittingSize still reflects the expanded layout
            // and the window shrinks to the wrong height).
            logExpanded = false
            scheduleApplyWindowSize(forExpanded: false)
        } else {
            // Expand: grow the window synchronously FIRST so the view tree
            // update sees a window already tall enough — no squashing.
            applyWindowSize(forExpanded: true)
            logExpanded = true
        }
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

/// Captures the NSWindow hosting the install-progress view so the SwiftUI
/// side can actively resize it as the log pane expands/collapses. Same
/// pattern as `WindowAccessor` in BlueConnectApp.swift for the main window.
private struct InstallWindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Task { @MainActor in window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor in window = nsView.window }
    }
}
