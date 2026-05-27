import Foundation
import AppKit

/// Admin-side counterpart of `/usr/local/bin/blueconnect-chat`. Manages
/// one chat session against one BSC host: starts the remote window by
/// dropping a job in the GUI Helper inbox, then exchanges messages via
/// timestamp-named text files in the session directory.
///
/// Wire format (mirrors the remote chat client):
///   /Library/Application Support/BlueConnect/chat/sessions/<uuid>/admin/<unix-ms>.txt
///       — admin → user, we write
///   /Library/Application Support/BlueConnect/chat/sessions/<uuid>/user/<unix-ms>.txt
///       — user → admin, we poll
///
/// Transport for both directions is the same one-shot SSH path the rest
/// of BlueConnect uses (ConnectionService), so we inherit the BSC
/// ProxyCommand chain + the admin auth key automatically.
@MainActor
final class ChatService: ObservableObject, Identifiable {
    /// `Identifiable` conformance so `.sheet(item: $activeChat)` can
    /// drive the chat window's presentation. The session UUID is
    /// stable for the lifetime of this service.
    nonisolated var id: String { sessionID }

    struct Message: Identifiable, Hashable {
        enum Author { case admin, user, system }
        let id: String
        let author: Author
        let text: String
        let timestamp: Date
    }

    let sessionID: String
    let host: BlueSkyHost
    private let settings: SettingsStore
    /// Stable title shown in both windows. Defaults to "Tech Support";
    /// override at session creation time if the admin wants something
    /// less stuffy ("Quick Question", their own name, etc.).
    let title: String
    /// Target Mac user the chat is addressed to. Empty string means
    /// "the current console user at job-pickup time" (whoever's at the
    /// screen). When non-empty, only that user's helper picks up the
    /// chat-start job (filename suffix routing).
    let targetUser: String

    @Published var messages: [Message] = []
    @Published var inputDraft: String = ""
    @Published var statusText: String = "Starting chat…"
    @Published var isStarted: Bool = false

    private var pollTask: Task<Void, Never>?
    private var seenUserFilenames: Set<String> = []
    /// Live SSH subprocesses spawned by `captureShell`. We terminate
    /// these on `stop()` so closing the chat doesn't leave stray ssh
    /// processes blocking on a slow/dead host for the full timeout.
    private var liveProcesses: [Process] = []
    /// True for the first send of a session. Triggers a chat-start
    /// job alongside the message write so the remote window
    /// (re-)opens if the user closed it. Cleared after the first send.
    private var needsChatStartOnSend: Bool = true

    /// Persisted across launches so reopening a chat with the same
    /// host (and target user, if any) reuses the same session UUID —
    /// the message history then loads from disk on the chat client
    /// side instead of opening empty. Keyed by `host.blueskyid|user`.
    @MainActor
    private static func persistedSessionID(for blueskyid: Int, targetUser: String) -> String? {
        let key = "chatSessionsByHost"
        let raw = UserDefaults.standard.string(forKey: key) ?? "{}"
        let map = (try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8))) ?? [:]
        return map["\(blueskyid)|\(targetUser)"]
    }

    @MainActor
    private static func recordSessionID(_ id: String, for blueskyid: Int, targetUser: String) {
        let key = "chatSessionsByHost"
        let raw = UserDefaults.standard.string(forKey: key) ?? "{}"
        var map = (try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8))) ?? [:]
        map["\(blueskyid)|\(targetUser)"] = id
        if let data = try? JSONEncoder().encode(map),
           let s = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: key)
        }
    }

    init(host: BlueSkyHost, settings: SettingsStore, title: String? = nil, targetUser: String = "") {
        self.host = host
        self.settings = settings
        self.targetUser = targetUser
        // Reuse the stored session UUID if any — that's what makes
        // closing the chat and reopening show the previous transcript
        // instead of an empty window. New conversation only when no
        // session exists yet for this (host, user) tuple.
        if let existing = Self.persistedSessionID(for: host.blueskyid, targetUser: targetUser) {
            self.sessionID = existing
        } else {
            self.sessionID = UUID().uuidString
            Self.recordSessionID(self.sessionID, for: host.blueskyid, targetUser: targetUser)
        }
        // Title precedence: caller-provided > settings.chatWindowTitle
        // > "Tech Support" fallback. The settings path is what the
        // "Open Chat…" host menu uses; per-session override stays open
        // for future "Open Chat as 'Brandon'…" flows.
        let stored = settings.chatWindowTitle.trimmingCharacters(in: .whitespaces)
        self.title = title ?? (stored.isEmpty ? "Tech Support" : stored)
    }

    // MARK: - Lifecycle

    /// Asks the host's GUI Helper to launch the chat client, then starts
    /// the poll loop. Failure to launch the remote window surfaces in
    /// `statusText` — usually means the helper isn't installed.
    func start() async {
        appendSystem("Connecting to \(host.displayName)…")
        // Up-front capability check: the parent /chat dir must exist
        // with world-writable perms (the GUI Helper install creates it
        // mode 0777). If it's missing or not writable, the mkdir below
        // would fail with a cryptic permission-denied; explain instead
        // so the operator knows the fix is to re-run helper setup.
        let probeCmd = #"""
        if [ ! -d "/Library/Application Support/BlueConnect/inbox" ]; then \
          echo "MISSING_HELPER"; exit 1; \
        fi; \
        if [ ! -w "/Library/Application Support/BlueConnect/chat" ]; then \
          echo "MISSING_CHAT_DIR"; exit 1; \
        fi; \
        if [ ! -x "/usr/local/bin/blueconnect-chat" ]; then \
          echo "MISSING_CHAT_BINARY"; exit 1; \
        fi; \
        echo "OK"
        """#
        let probe = await runShellCaptured(probeCmd)
        guard probe.status == 0 else {
            let out = probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let msg: String
            switch out {
            case "MISSING_HELPER":
                msg = "GUI Helper not installed on \(host.displayName). Right-click the host → Quick Actions → Miscellaneous → \"Setup: Install GUI Helper (one-time)\" and try again."
            case "MISSING_CHAT_DIR":
                msg = "The chat directory hasn't been set up on \(host.displayName) (likely installed before the chat feature shipped). Re-run \"Setup: Install GUI Helper (one-time)\" on this Mac — it's idempotent and will add the missing /chat folder."
            case "MISSING_CHAT_BINARY":
                msg = "/usr/local/bin/blueconnect-chat is missing on \(host.displayName). The chat binary install is currently a separate step from the GUI Helper setup (in-app installer is a TODO). For now, push it manually from a terminal on your admin Mac:\n\nscp -P <port> -o ProxyCommand=\"ssh -p 3122 -i ~/.ssh/bluesky_admin admin@bluesky.macfaqulty.com /bin/nc %h %p\" \"$(path-to)/BlueConnect Admin.app/Contents/Resources/blueconnect-chat\" ladmin@localhost:/tmp/\n\nthen ssh in and: sudo install -m 755 -o root -g wheel /tmp/blueconnect-chat /usr/local/bin/blueconnect-chat"
            default:
                msg = "Unable to prepare \(host.displayName) for chat (\(probe.stderr.prefix(200))). Re-run \"Setup: Install GUI Helper (one-time)\"."
            }
            appendSystem(msg)
            statusText = "Setup needed"
            return
        }
        // Job filename: when `targetUser` is set we tag the job with a
        // `.for-<user>.job` suffix so only that user's helper picks it
        // up (other users' helpers see the suffix and skip without
        // deleting). Empty targetUser → unsuffixed filename → whichever
        // helper grabs it first wins (legacy behavior).
        let suffix = targetUser.isEmpty ? "" : ".for-\(targetUser)"
        let cmd = #"""
        set -e; \
        INBOX="/Library/Application Support/BlueConnect/inbox"; \
        BASE="/Library/Application Support/BlueConnect/chat/sessions/\#(sessionID)"; \
        mkdir -p "$BASE/admin" "$BASE/user"; \
        chmod 0777 "$BASE" "$BASE/admin" "$BASE/user" 2>/dev/null || true; \
        echo '/usr/local/bin/blueconnect-chat "\#(sessionID)" "\#(escapeTitle(title))"' > "$INBOX/chat-start-\#(sessionID)\#(suffix).job"
        """#
        let ok = await runShell(cmd)
        if ok {
            // Pull the full prior transcript from both sides of the
            // session dir so reopening a chat shows the conversation
            // intact, not just future replies. Previously poll() only
            // walked /user/ — admin's own past messages and any user
            // replies from before this app launch never made it into
            // the UI on reopen.
            await loadHistoryFromRemote()
            isStarted = true
            statusText = "Connected"
            let who = targetUser.isEmpty ? "console user" : targetUser
            appendSystem("Chat window opened for \(who) on \(host.displayName).")
            startPolling()
        } else {
            statusText = "Failed to start chat"
        }
    }

    /// Wipe the session's transcript on both sides (admin/ and user/),
    /// clear the local message buffer, and inform the user. Same
    /// `sessionID` survives — the remote chat window stays open
    /// (the directories are recreated by send()/start() on demand).
    /// Public so the ChatWindow header's Clear button can call it.
    func clearTranscript() async {
        let dir = "/Library/Application Support/BlueConnect/chat/sessions/\(sessionID)"
        let cmd = "rm -rf \(shellQuote(dir))/admin/*.txt \(shellQuote(dir))/user/*.txt 2>/dev/null; mkdir -p \(shellQuote(dir))/admin \(shellQuote(dir))/user; chmod 0777 \(shellQuote(dir))/admin \(shellQuote(dir))/user 2>/dev/null || true"
        _ = await runShell(cmd)
        messages.removeAll()
        seenUserFilenames.removeAll()
        appendSystem("Chat history cleared.")
    }

    // MARK: - History loading

    /// One-shot list-and-read of both `admin/` and `user/` dirs for
    /// the session, populating `messages` in chronological order
    /// (filename = unix-ms timestamp, so a string sort is correct).
    /// Files already seen on disk go into `seenUserFilenames` so the
    /// poller doesn't double-add them.
    private func loadHistoryFromRemote() async {
        let base = "/Library/Application Support/BlueConnect/chat/sessions/\(sessionID)"
        let adminNames = await listMessageFiles(in: "\(base)/admin")
        let userNames  = await listMessageFiles(in: "\(base)/user")

        // Bulk-read each side. The shell `for ... cat ... echo ===` trick
        // returns all files in a single SSH round-trip instead of N.
        let adminMsgs = await readMessages(filenames: adminNames, dir: "\(base)/admin", author: .admin)
        let userMsgs  = await readMessages(filenames: userNames,  dir: "\(base)/user",  author: .user)

        // Merge + chronological sort. Filenames are <unix-ms>.txt; string
        // sort works because all are equal-width within a session's
        // lifetime (no leading-zero pad needed up to year ~33658).
        var combined = adminMsgs + userMsgs
        combined.sort { $0.id < $1.id }
        // Replace any pre-existing system "Connecting..." line at the
        // front; everything else gets injected before it.
        let leading = messages.filter { $0.author == .system }
        messages = combined + leading
        for name in userNames { seenUserFilenames.insert(name) }
    }

    private func listMessageFiles(in dir: String) async -> [String] {
        let cmd = "ls -1 \(shellQuote(dir))/ 2>/dev/null | sort"
        guard let out = await captureShell(cmd) else { return [] }
        return out.split(separator: "\n")
            .map(String.init)
            .filter { $0.hasSuffix(".txt") }
    }

    /// Read every named file from `dir` in one SSH round-trip by
    /// concatenating with a unique sentinel between payloads. base64
    /// each one so binary-ish content (newlines, quotes, unicode)
    /// survives both the shell layer and the parse.
    private func readMessages(filenames: [String], dir: String, author: Message.Author) async -> [Message] {
        guard !filenames.isEmpty else { return [] }
        // Sentinel: a UUID we generate — astronomically unlikely to
        // appear inside any real base64 payload.
        let sentinel = "BCMSGSEP-\(UUID().uuidString)"
        let pieces = filenames.map {
            #"printf '%s\n%s\n' \#(shellQuote(sentinel)) \#(shellQuote($0)); base64 < \#(shellQuote("\(dir)/\($0)"))"#
        }
        let cmd = pieces.joined(separator: "; ") + "; printf '%s\\n' \(shellQuote(sentinel))"
        guard let out = await captureShell(cmd) else { return [] }

        // Parse: split on the sentinel, each chunk after a sentinel
        // is "<filename>\n<base64 lines>".
        var out_msgs: [Message] = []
        let chunks = out.components(separatedBy: sentinel)
        for chunk in chunks {
            let lines = chunk.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let first = lines.first, first.hasSuffix(".txt") else { continue }
            let name = first
            let b64 = lines.dropFirst().joined()
            guard let data = Data(base64Encoded: b64),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let stem = (name as NSString).deletingPathExtension
            let ts = Double(stem).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            out_msgs.append(Message(
                id: "\(author == .admin ? "admin" : "user")/\(name)",
                author: author,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                timestamp: ts
            ))
        }
        return out_msgs
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        isStarted = false
        // Kill any in-flight ssh processes — otherwise closing the chat
        // window while a host is slow/dead leaves stray ssh subprocesses
        // blocking on the connect timeout (~8s each).
        for proc in liveProcesses where proc.isRunning {
            proc.terminate()
        }
        liveProcesses.removeAll()
    }

    // MARK: - Sending

    /// Write the draft to a `<unix-ms>.txt` file in the session's
    /// admin/ dir over SSH; on success append to local transcript and
    /// clear the draft. Also re-submits a chat-start job so that if
    /// the remote user closed their chat window, the new message
    /// reopens it (with prior transcript loaded from disk).
    func send() async {
        let text = inputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "\(ms).txt"
        let path = "/Library/Application Support/BlueConnect/chat/sessions/\(sessionID)/admin/\(filename)"
        let suffix = targetUser.isEmpty ? "" : ".for-\(targetUser)"
        // Use base64 so we don't have to fight shell escaping for
        // multi-line messages, embedded quotes, etc.
        let b64 = Data(text.utf8).base64EncodedString()
        // Also drop a fresh chat-start job alongside the message — if
        // the remote chat window is already open, the chat client's
        // flock guard makes the second instance exit cleanly. If it
        // was closed, the new instance opens, loadExisting() pulls in
        // every message file from /admin/ + /user/, and the user sees
        // the full transcript including the new message.
        let escapedTitle = escapeTitle(title)
        let cmd = """
        echo '\(b64)' | base64 -D > \(shellQuote(path)); \
        echo '/usr/local/bin/blueconnect-chat "\(sessionID)" "\(escapedTitle)"' > "/Library/Application Support/BlueConnect/inbox/chat-start-\(sessionID)\(suffix).job"
        """
        let ok = await runShell(cmd)
        if ok {
            messages.append(Message(
                id: "admin/\(filename)",
                author: .admin,
                text: text,
                timestamp: Date()
            ))
            inputDraft = ""
        } else {
            appendSystem("Failed to send.")
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    /// Lists the user/ dir and reads any files we haven't seen yet.
    /// One round-trip per filename — small messages, low frequency,
    /// not worth the complexity of streaming over a persistent SSH.
    private func pollOnce() async {
        let listCmd = #"ls -1 "/Library/Application Support/BlueConnect/chat/sessions/\#(sessionID)/user/" 2>/dev/null | sort"#
        guard let listing = await captureShell(listCmd) else { return }
        let names = listing
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasSuffix(".txt") }

        var newCount = 0
        for name in names where !seenUserFilenames.contains(name) {
            seenUserFilenames.insert(name)
            let readCmd = #"base64 < "/Library/Application Support/BlueConnect/chat/sessions/\#(sessionID)/user/\#(name)""#
            guard let b64 = await captureShell(readCmd),
                  let data = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            let stem = (name as NSString).deletingPathExtension
            let ts = Double(stem).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            messages.append(Message(
                id: "user/\(name)",
                author: .user,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                timestamp: ts
            ))
            newCount += 1
        }
        // Audible cue on new user messages, but not on the initial
        // batch loaded from disk on start (those are already-seen
        // history, not "ping! they replied"). Suppress if the chat
        // window isn't even the key window — we'd otherwise sound
        // off every time the user mounts the session.
        if newCount > 0, isStarted {
            NSSound(named: NSSound.Name("Submarine"))?.play()
        }
    }

    // MARK: - Helpers

    private func appendSystem(_ text: String) {
        messages.append(Message(
            id: "sys/\(Date().timeIntervalSince1970)",
            author: .system,
            text: text,
            timestamp: Date()
        ))
    }

    /// Fire-and-forget SSH command. Returns true if exit code was 0.
    private func runShell(_ command: String) async -> Bool {
        await captureShell(command) != nil
    }

    /// Result of a one-shot SSH invocation. We propagate stderr +
    /// status so the chat panel can surface real errors instead of
    /// silently showing "Failed to start chat" with no diagnostics.
    private struct ShellResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Run an SSH command, return stdout if exit was 0. Uses the same
    /// ProxyCommand chain as `ConnectionService` but as a one-shot
    /// pipe-only ssh (no TTY, no Terminal tab) so we can capture
    /// output cleanly. Forces `-T` (no TTY) so we can't accidentally
    /// inherit one from the spawning context and block on input.
    private func captureShell(_ command: String) async -> String? {
        let result = await runShellCaptured(command)
        if result.status != 0 {
            let trimmed = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                appendSystem("SSH error (exit \(result.status)): \(trimmed.prefix(300))")
            } else {
                appendSystem("SSH exited \(result.status) with no error message.")
            }
            return nil
        }
        return result.stdout
    }

    private func runShellCaptured(_ command: String) async -> ShellResult {
        guard host.active else {
            return ShellResult(status: -1, stdout: "", stderr: "host not active")
        }
        let port = host.sshPort
        let server = settings.serverFqdn
        let adminKey = settings.expandedKeyPath
        let serverPort = settings.sshTunnelPort
        let user = settings.defaultRemoteUser

        let proxy = "ssh -o WarnWeakCrypto=no -p \(serverPort) -i \(shellQuote(adminKey)) admin@\(server) /bin/nc %h %p"
        let args = [
            "-T",
            "-o", "StrictHostKeyChecking=no",
            "-o", "WarnWeakCrypto=no",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ProxyCommand=\(proxy)",
            "-p", "\(port)",
            "\(user)@localhost",
            command
        ]

        let proc = Process()
        proc.launchPath = "/usr/bin/ssh"
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        liveProcesses.append(proc)
        defer { liveProcesses.removeAll { $0 === proc } }

        return await Task.detached(priority: .userInitiated) {
            do { try proc.run() } catch {
                return ShellResult(status: -2, stdout: "", stderr: "\(error)")
            }
            proc.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            return ShellResult(
                status: proc.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        }.value
    }

    private func escapeTitle(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
