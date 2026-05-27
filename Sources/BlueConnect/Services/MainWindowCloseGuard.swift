import AppKit
import SwiftUI

/// Intercepts ⌘W on the main "BlueConnect Admin" window so the keystroke
/// closes the active terminal tab (or no-ops) instead of closing the
/// whole window and losing the session.
///
/// Why an `NSEvent` local monitor instead of a SwiftUI `CommandGroup`
/// button: a SwiftUI Button with `.keyboardShortcut("w", modifiers:
/// [.command])` competes with the auto-injected File → Close Window
/// command and loses the race on macOS 26 — the keystroke still closes
/// the window. A local key-down monitor runs BEFORE NSMenu's
/// key-equivalent matching for the front window, so we can swallow it
/// cleanly. The class-swap path that BCMainWindow used previously
/// crashed AppKit's _NSTouchBarFinderObservation KVO bookkeeping when a
/// second Window scene opened, so we don't use that anymore.
@MainActor
final class MainWindowCloseGuard {
    static let shared = MainWindowCloseGuard()

    private var monitor: Any?
    private weak var terminals: TerminalSessionsManager?

    /// Identifies the main BlueConnect Admin window by title. The class-
    /// swap-free design means we can't use a custom NSWindow subclass.
    private let mainWindowTitle = "BlueConnect Admin"

    func install(terminals: TerminalSessionsManager) {
        self.terminals = terminals
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

    /// Returns true if we consumed the event.
    private func handle(_ event: NSEvent) -> Bool {
        // Match ⌘W exactly — no shift/option/control so ⌘⇧W and friends
        // pass through to whatever bindings own them.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command,
              event.charactersIgnoringModifiers?.lowercased() == "w"
        else { return false }
        // Only intercept when the main window is key — other windows
        // (Browse Quick Actions, Settings, SCP, etc.) should close
        // normally on ⌘W.
        guard let keyWindow = NSApp.keyWindow,
              keyWindow.title == mainWindowTitle
        else { return false }
        if let id = terminals?.activeSessionID {
            terminals?.close(id)
        }
        // Swallow either way: no tab + no swallow would close the main
        // window via the auto File→Close binding, which is the
        // regression we're guarding against.
        return true
    }
}
