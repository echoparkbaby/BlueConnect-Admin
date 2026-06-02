import Foundation
import Observation
import AppKit

/// Shared bridge between the main window's "Open Chat…" action and the
/// standalone Chat window scene. Holds the active `ChatService` so the
/// window can be a normal SwiftUI `Window` scene (one at a time, not a
/// blocking sheet) and still receive the per-session state.
///
/// One active chat at a time is the deliberate scope cut — if you need
/// to triage two hosts at once you can SSH-and-message via another
/// admin Mac, and we save the complexity of managing N independent
/// chat windows + their polling tasks.
@MainActor
@Observable
final class ChatSessionController {
    /// Currently-active chat session. Set by ContentView's "Open Chat"
    /// handler, cleared when the user closes the chat window.
    var currentSession: ChatService? = nil

    /// Bumped each time a session is presented so the Chat window's
    /// `.task` re-fires when the user opens a new chat without closing
    /// the previous window first.
    var openCounter: Int = 0

    /// Present a new chat session, replacing any in-flight one. Direct
    /// callers bypass the same-host / different-host guards below -
    /// reserved for code paths that have already done that check.
    func present(_ session: ChatService) {
        currentSession?.stop()
        currentSession = session
        openCounter &+= 1
    }

    /// Entry point for the chat-icon click handlers in ContentView.
    /// Picks one of three behaviours:
    ///
    /// 1. **No current chat** - present the new session, open the
    ///    window.
    /// 2. **Same host + same target user** - keep the current session,
    ///    just bring the window forward. Re-tapping the chat icon on a
    ///    host you're already chatting with no longer wipes the
    ///    conversation and forces re-init.
    /// 3. **Different host (or different target user)** - run a modal
    ///    NSAlert asking the operator to confirm the switch. The
    ///    transcript is on disk regardless, so they can reopen the
    ///    previous chat from that host's chat icon later. Cancel keeps
    ///    the current chat and is a no-op.
    ///
    /// `openWindow` is the SwiftUI `openWindow(id:)` callback the
    /// caller has from `@Environment(\.openWindow)`. We invoke it in
    /// cases (1) and (2), and only in case (3) if the operator
    /// confirms.
    func present(_ session: ChatService, openWindow: () -> Void) {
        guard let current = currentSession else {
            present(session)
            openWindow()
            return
        }
        if current.host.blueskyid == session.host.blueskyid
            && current.targetUser == session.targetUser {
            // Same target - just front the existing window. The
            // session in-flight is the right one.
            openWindow()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Switch active chat?"
        alert.informativeText = """
        You're already chatting with \(current.host.displayName).

        Switching closes the current conversation in this window. The transcript stays on disk - re-open this host's chat icon to come back to it.
        """
        alert.addButton(withTitle: "Switch to \(session.host.displayName)")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            present(session)
            openWindow()
        }
    }
}
