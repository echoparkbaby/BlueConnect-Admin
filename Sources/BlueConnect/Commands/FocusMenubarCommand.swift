import SwiftUI
import AppKit

/// ⌘⇧F — pop open the BlueConnect MenuBarExtra dropdown so the user can
/// quick-search hosts from anywhere in the app.
///
/// SwiftUI's `MenuBarExtra` doesn't expose its underlying `NSStatusItem`
/// via any public API. We walk `NSStatusBar.system`'s private `_items`
/// array — fragile, but the only path that works without rewriting the
/// menubar in raw AppKit. Best-effort: if the introspection ever breaks
/// in a future macOS, the menu item still serves as a discoverability
/// hint and the user can click the globe icon directly.
struct FocusMenubarCommand: Commands {
    var body: some Commands {
        CommandGroup(after: .windowList) {
            Button("Focus Menubar Search") { Self.openMenubar() }
                // ⌘⇧F was reassigned to "Detach + Full Screen" for the
                // terminal; menubar focus moved to ⌃⌘F. Same letter,
                // different modifier — same discoverability via menu.
                .keyboardShortcut("f", modifiers: [.command, .control])
        }
    }

    private static func openMenubar() {
        let statusBar = NSStatusBar.system
        guard let items = statusBar.value(forKey: "_items") as? [NSStatusItem] else {
            NSLog("FocusMenubarCommand: NSStatusBar._items unavailable")
            return
        }
        // The BlueConnect status item is the one whose button's target is
        // owned by this process. Multiple status items can coexist (e.g.
        // Tailscale, Dropbox), so filter on PID equivalence — our button's
        // target chain lives in this process.
        for item in items {
            guard let button = item.button else { continue }
            // SwiftUI's status item button has its target set to a SwiftUI
            // internal controller in this process. Other-process items get
            // marshaled differently and `target` reads as nil.
            if button.target != nil {
                button.performClick(nil)
                return
            }
        }
    }
}
