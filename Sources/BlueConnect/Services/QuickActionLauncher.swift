import Foundation
import Observation

/// Relay between the standalone Quick Actions browser window and
/// ContentView's command dispatcher. The browser writes a `pendingRun`;
/// ContentView reacts via `.onChange` and routes through the same
/// `runQuickAction(host:action:command:)` path the inline sheet uses.
@MainActor
@Observable
final class QuickActionLauncher {
    /// One Run intent from the browser window. ContentView clears it after
    /// dispatching so the next click fires `.onChange` cleanly.
    struct PendingRun: Equatable {
        let host: BlueSkyHost
        let action: QuickAction
        let command: String
    }

    /// Set by the browser window when the user clicks Run. ContentView
    /// observes and clears after running.
    var pendingRun: PendingRun? = nil
}
