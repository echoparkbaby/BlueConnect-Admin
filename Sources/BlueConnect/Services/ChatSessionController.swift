import Foundation
import Observation

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

    /// Present a new chat session, replacing any in-flight one.
    func present(_ session: ChatService) {
        currentSession?.stop()
        currentSession = session
        openCounter &+= 1
    }
}
