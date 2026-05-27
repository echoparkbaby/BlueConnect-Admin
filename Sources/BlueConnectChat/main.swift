import SwiftUI
import AppKit
import Foundation

// blueconnect-chat — installed on target Macs as
// /usr/local/bin/blueconnect-chat. Spawned by the GUI Helper LaunchAgent
// from a chat-start job file in the console user's Aqua session, so the
// SwiftUI window draws with full WindowServer access without sudo /
// launchctl asuser at runtime.
//
// Invocation:
//   blueconnect-chat <session-uuid> [title]
//
// File transport (filesystem polling — no sockets, no daemons):
//   /Library/Application Support/BlueConnect/chat/sessions/<uuid>/admin/
//       <unix-ms>.txt   — written by BlueConnect Admin on send; we poll
//   /Library/Application Support/BlueConnect/chat/sessions/<uuid>/user/
//       <unix-ms>.txt   — written by us on Send; admin polls
//
// Both dirs are world-writable (the helper's install creates them with
// 1777). Filenames are unix-ms timestamps so chronological sort is just
// `sort -n` and there are no collisions per side. Plain text payload —
// no JSON, no schema to break.

// MARK: - Models

struct ChatMessage: Identifiable, Hashable {
    enum Author { case admin, user }
    let id: String   // filename, also gives sort order
    let author: Author
    let text: String
    let timestamp: Date
}

// MARK: - Session

final class ChatSession: ObservableObject {
    let sessionID: String
    let baseDir: URL
    let adminDir: URL  // we read from here
    let userDir: URL   // we write to here

    @Published var messages: [ChatMessage] = []
    @Published var inputDraft: String = ""

    private var pollTimer: Timer?
    private var seenIDs: Set<String> = []

    init(sessionID: String) {
        self.sessionID = sessionID
        let base = URL(fileURLWithPath: "/Library/Application Support/BlueConnect/chat/sessions/\(sessionID)")
        self.baseDir = base
        self.adminDir = base.appendingPathComponent("admin", isDirectory: true)
        self.userDir = base.appendingPathComponent("user", isDirectory: true)
    }

    func start() {
        // Best-effort dir setup — the helper install creates the parent
        // (world-writable) so we only have to create our own subdirs.
        try? FileManager.default.createDirectory(at: adminDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        loadExisting()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Read any messages that already exist in the admin/user dirs at
    /// startup so the window opens with full history (e.g. user closed
    /// it and admin re-opened — we want context).
    private func loadExisting() {
        let admin = files(in: adminDir).map { (file: $0, author: ChatMessage.Author.admin) }
        let user  = files(in: userDir).map  { (file: $0, author: ChatMessage.Author.user) }
        let all = (admin + user).sorted { $0.file.lastPathComponent < $1.file.lastPathComponent }
        for entry in all {
            if let msg = readMessage(at: entry.file, author: entry.author) {
                messages.append(msg)
                seenIDs.insert(msg.id)
            }
        }
    }

    /// One poll tick — list the admin dir, append any file we haven't
    /// seen yet. User dir is owned by us so doesn't need polling (we
    /// know what we wrote).
    private func poll() {
        let admin = files(in: adminDir)
        for file in admin {
            let id = "admin/\(file.lastPathComponent)"
            if seenIDs.contains(id) { continue }
            if let msg = readMessage(at: file, author: .admin, idOverride: id) {
                messages.append(msg)
                seenIDs.insert(id)
            }
        }
    }

    private func files(in dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            .map { $0.filter { $0.pathExtension == "txt" } } ?? []
    }

    private func readMessage(at url: URL, author: ChatMessage.Author, idOverride: String? = nil) -> ChatMessage? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        let ts = Double(stem).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        return ChatMessage(
            id: idOverride ?? "\(author == .admin ? "admin" : "user")/\(url.lastPathComponent)",
            author: author,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            timestamp: ts
        )
    }

    @Published var sendError: String? = nil

    /// Persist the input draft as a user message file. ONLY clear the
    /// draft and append to the transcript on a successful write —
    /// otherwise surface an error so the user can retry. Silently
    /// swallowing a write failure (full disk, permission drift, broken
    /// helper install) used to show "sent" in the UI while nothing
    /// actually persisted.
    func send() {
        let text = inputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let url = userDir.appendingPathComponent("\(ms).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            sendError = "Couldn't send: \(error.localizedDescription)"
            return
        }
        let id = "user/\(ms).txt"
        messages.append(ChatMessage(id: id, author: .user, text: text, timestamp: Date()))
        seenIDs.insert(id)
        inputDraft = ""
        sendError = nil
    }
}

// MARK: - Views

struct ChatRoot: View {
    @ObservedObject var session: ChatSession
    let title: String
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        // 2/3 of the previous 420pt ideal — matches the admin side
        // and feels more like a real chat client (Messages.app /
        // Slack DM proportions) than a sprawling utility window.
        .frame(minWidth: 240, idealWidth: 280, minHeight: 380, idealHeight: 540)
        .onAppear {
            session.start()
            inputFocused = true
        }
        .onDisappear { session.stop() }
        .navigationTitle(title)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(session.messages) { msg in
                        bubble(msg).id(msg.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: session.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private func bubble(_ msg: ChatMessage) -> some View {
        HStack {
            if msg.author == .user { Spacer(minLength: 40) }
            VStack(alignment: msg.author == .user ? .trailing : .leading, spacing: 2) {
                Text(msg.text)
                    .font(.body)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(
                        msg.author == .admin
                        ? Color(NSColor.controlBackgroundColor)
                        : Color.accentColor
                    )
                    .foregroundStyle(
                        msg.author == .admin
                        ? Color(NSColor.labelColor)
                        : Color.white
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Text(msg.timestamp, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if msg.author == .admin { Spacer(minLength: 40) }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let err = session.sendError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            HStack(spacing: 8) {
                TextField("Type a reply…", text: $session.inputDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .onSubmit { session.send() }
                Button("Send") { session.send() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(session.inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
    }
}

// MARK: - App entry

// Manual NSApplication setup — we read argv before invoking SwiftUI's
// App protocol so we can fail fast on a missing session ID.

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: blueconnect-chat <session-id> [title]\n".utf8))
    exit(2)
}
let sessionID = args[1]
let chatTitle = args.count >= 3 ? args[2] : "Tech Support"

// Single-instance-per-session guard: each chat-start job that lands
// in the inbox spawns this process, but we only want ONE window per
// session. flock() a per-session lock file; if we can't acquire it,
// an existing instance is already running — exit silently.
let lockPath = "/tmp/blueconnect-chat-\(sessionID).lock"
let lockFD = open(lockPath, O_CREAT | O_WRONLY, 0o644)
if lockFD < 0 {
    FileHandle.standardError.write(Data("warn: couldn't open lock \(lockPath): \(String(cString: strerror(errno)))\n".utf8))
} else if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    // Already running for this session — admin re-submitting a chat-
    // start on every send is the design, so this branch is normal.
    exit(0)
}
// fd intentionally left open: closing would release the lock.

let session = ChatSession(sessionID: sessionID)

let app = NSApplication.shared
let delegate = ChatAppDelegate(session: session, title: chatTitle)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()

/// Owns the SwiftUI window for the chat. We use NSApp + NSWindow
/// directly (instead of the `@main App` protocol) because we need to
/// read argv at startup — `@main` swallows the arguments.
///
/// Also acts as NSWindowDelegate so we can intercept the red close
/// button: the user gets an NSAlert asking "are you sure?", and only
/// real Yes proceeds to close. Stops a misplaced click from killing
/// an in-progress conversation.
final class ChatAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let session: ChatSession
    let title: String
    var window: NSWindow?

    init(session: ChatSession, title: String) {
        self.session = session
        self.title = title
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = ChatRoot(session: session, title: title)
        let hosting = NSHostingController(rootView: root)
        let w = NSWindow(contentViewController: hosting)
        w.title = title
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.setContentSize(NSSize(width: 280, height: 540))
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        self.window = w
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Called by AppKit when the red close button is pressed (or
    /// ⌘W is fired). Showing an NSAlert here and returning false
    /// keeps the window open until the user explicitly confirms.
    /// The alert's run mode is .application so it floats above the
    /// chat window like Mail's "discard draft?" prompt.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close \(title)?"
        alert.informativeText = "Your chat history is saved — if Tech sends another message, this window will reopen. Close anyway?"
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Keep Open")
        // Default action (Return) = Keep Open; Escape also = Keep Open.
        // Close button is the second one (less destructive default).
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }
}
