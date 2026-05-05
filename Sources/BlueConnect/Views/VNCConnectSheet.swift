import AppKit
import SwiftUI


struct VNCConnectSheet: View {
    @Bindable var controller: VNCConnectController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "display")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("Connecting to \(controller.host.displayName)")
                .font(.title2).bold()
                .multilineTextAlignment(.center)
            Text(controller.localPort > 0
                 ? "#\(controller.host.blueskyid) · \(controller.user)@localhost:\(controller.localPort)"
                 : "#\(controller.host.blueskyid) · \(controller.user)")
                .font(.callout).foregroundStyle(.secondary)

            Group {
                switch controller.phase {
                case .starting:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.regular)
                        Text("Starting…").font(.body).foregroundStyle(.secondary)
                    }
                case .connecting:
                    VStack(spacing: 10) {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 360)
                        Text("Opening tunnel through bluesky…")
                            .font(.body).foregroundStyle(.secondary)
                    }
                case .opening:
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                        Text("Tunnel up — opening Screen Sharing…").font(.body)
                    }
                case .done:
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                        Text("Connected").font(.body).bold()
                    }
                case .failed(let msg):
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange).font(.title3)
                            Text("Connection failed").font(.body).bold()
                        }
                        ScrollView {
                            Text(msg)
                                .font(.body).foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(8)
                        }
                        .background(Color(NSColor.textBackgroundColor))
                        .clipShape(.rect(cornerRadius: 6))
                        .frame(maxHeight: 200)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 80)

            HStack {
                Spacer()
                Button(controller.phase.isTerminal ? "Close" : "Cancel") {
                    controller.cancel()
                    dismiss()
                }
                .keyboardShortcut(controller.phase.isTerminal ? .defaultAction : .cancelAction)
                .controlSize(.large)
            }
        }
        .padding(28)
        .frame(width: 520, height: 420)
        .onAppear { controller.start() }
        .onChange(of: controller.phase) { _, newValue in
            if case .done = newValue {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    dismiss()
                }
            }
        }
    }
}

extension VNCConnectController.Phase: Equatable {
    var isTerminal: Bool {
        switch self {
        case .done, .failed: return true
        default: return false
        }
    }

    static func == (lhs: VNCConnectController.Phase, rhs: VNCConnectController.Phase) -> Bool {
        switch (lhs, rhs) {
        case (.starting, .starting), (.connecting, .connecting),
             (.opening, .opening), (.done, .done):
            return true
        case (.failed(let a), .failed(let b)):
            return a == b
        default: return false
        }
    }
}
