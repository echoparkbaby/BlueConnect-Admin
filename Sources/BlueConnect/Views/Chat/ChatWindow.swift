import SwiftUI
import AppKit

/// Scene wrapper around `ChatWindow`. Reads the active `ChatService`
/// from `ChatSessionController` so the standalone window can be
/// presented via `openWindow(id: "blueconnect-chat")` from any code
/// path. Renders a placeholder when no chat is in flight (window opened
/// without a session set, e.g. user reopened it from the Window menu).
struct ChatWindowScene: View {
    @Environment(ChatSessionController.self) private var controller
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let session = controller.currentSession {
                ChatWindow(chat: session)
                    .id(controller.openCounter) // re-mount on new session
            } else {
                VStack {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                    Text("No active chat")
                        .font(.headline)
                    Text("Right-click a host → Open Chat… to start one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 320, height: 240)
            }
        }
        .onAppear { pinChatWindowToFloating() }
        .onChange(of: controller.openCounter) { _, _ in
            // Re-pin on every present() in case the host window
            // briefly demoted itself during the session switch.
            pinChatWindowToFloating()
        }
    }

    /// Find the chat window by SwiftUI scene title and raise its level
    /// to `.floating`. Keeps the chat above every other normal window
    /// so the admin never loses sight of an in-flight conversation
    /// when they click into a Terminal tab, the host list, or any
    /// other window. Defer one runloop tick so SwiftUI has actually
    /// mounted the NSWindow.
    private func pinChatWindowToFloating() {
        DispatchQueue.main.async {
            if let w = NSApp.windows.first(where: {
                $0.identifier?.rawValue == "blueconnect-chat" || $0.title == "Chat"
            }) {
                w.level = .floating
                w.collectionBehavior.insert(.canJoinAllSpaces)
            }
        }
    }
}

/// Admin-side mirror of the remote chat client. Bound to a single
/// `ChatService` (one per session); the service handles SSH transport.
/// UI is intentionally close to the remote window (same bubble shape,
/// same composer) so both sides feel like the same conversation.
struct ChatWindow: View {
    @ObservedObject var chat: ChatService
    @FocusState private var inputFocused: Bool
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        // 2/3 of the previous 460pt ideal — bubbles wrap fine at this
        // width and the window stops dominating the desktop.
        .frame(minWidth: 260, idealWidth: 320, minHeight: 420, idealHeight: 580)
        .task(id: chat.sessionID) {
            await chat.start()
            inputFocused = true
        }
        .onDisappear { chat.stop() }
    }

    @State private var showingClearConfirm = false

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Chat with \(chat.host.displayName)")
                    .font(.headline)
                Text(chat.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showingClearConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Clear chat history (both sides)")
            .disabled(chat.messages.isEmpty)
            Button("Close") { dismissWindow(id: "blueconnect-chat") }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .confirmationDialog("Clear chat history?",
                            isPresented: $showingClearConfirm,
                            titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                Task { await chat.clearTranscript() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every message from both ends of this chat on \(chat.host.displayName). The chat window stays open; new messages start a fresh transcript.")
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(chat.messages) { msg in
                        bubble(msg).id(msg.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: chat.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ msg: ChatService.Message) -> some View {
        if msg.author == .system {
            HStack {
                Spacer()
                VStack(spacing: 6) {
                    Text(msg.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if msg.showInstallHelperButton || msg.showRetryButton {
                        HStack(spacing: 8) {
                            if msg.showInstallHelperButton {
                                Button {
                                    chat.installGuiHelper()
                                } label: {
                                    Label("Install GUI Helper", systemImage: "wand.and.rays")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            if msg.showRetryButton {
                                Button {
                                    chat.retryConnection()
                                } label: {
                                    Label("Retry", systemImage: "arrow.clockwise")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                Spacer()
            }
        } else {
            HStack {
                if msg.author == .admin { Spacer(minLength: 40) }
                VStack(alignment: msg.author == .admin ? .trailing : .leading, spacing: 2) {
                    Text(msg.text)
                        .font(.body)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(
                            msg.author == .admin
                            ? Color.accentColor
                            : Color(NSColor.controlBackgroundColor)
                        )
                        .foregroundStyle(
                            msg.author == .admin
                            ? Color.white
                            : Color(NSColor.labelColor)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    Text(msg.timestamp, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if msg.author == .user { Spacer(minLength: 40) }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Type a message…", text: $chat.inputDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { Task { await chat.send() } }
                .disabled(!chat.isStarted)
            Button("Send") { Task { await chat.send() } }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(chat.inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || !chat.isStarted)
        }
        .padding(10)
    }
}
