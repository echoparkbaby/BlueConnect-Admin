import SwiftUI

/// Adds a "Show BlueConnect Admin" item to the Window menu (⌘0) so the
/// main window can be brought back after the user closes it via the red
/// traffic light. Without this, the only way back is to relaunch the
/// app — since `MainWindowCloseGuard` swallows ⌘W on the main window,
/// a close requires the red light, which gives no obvious path to
/// reopen.
struct WindowMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .windowList) {
            Divider()
            Button("Show BlueConnect Admin") {
                // Pull openWindow off the env at action time — a
                // CommandGroup doesn't have a containing view but the
                // shortcut still fires through the app's command chain.
                MainWindowReopener.shared.reopen()
            }
            .keyboardShortcut("0", modifiers: [.command])
        }
    }
}

/// Helper that grabs the SwiftUI `openWindow` action from the first
/// scene that registers it. The main WindowGroup's content wires this
/// up on `.onAppear`, so by the time the user could close + reopen the
/// window, `reopen` has a usable handle.
@MainActor
final class MainWindowReopener {
    static let shared = MainWindowReopener()
    var open: (() -> Void)?

    func reopen() {
        if let open {
            open()
            return
        }
        // Fallback when openWindow wasn't wired (cold start path where
        // the WindowGroup itself isn't loaded): poke the NSApplication
        // to ask SwiftUI to bring the main scene back. Matches Apple's
        // own Dock-icon-click behaviour.
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.title == "BlueConnect Admin" {
            w.makeKeyAndOrderFront(nil)
            return
        }
    }
}

/// Tiny view-modifier that captures `openWindow` once and hands it to
/// `MainWindowReopener` so the menu command can reach it from outside
/// the view hierarchy.
struct MainWindowReopenerCapture: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear {
            MainWindowReopener.shared.open = {
                openWindow(id: "main")
            }
        }
    }
}
