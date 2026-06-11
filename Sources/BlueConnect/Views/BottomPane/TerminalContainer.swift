import AppKit
import SwiftUI
import SwiftTerm

struct TerminalContainer: NSViewRepresentable {
    let terminal: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        // Claim first responder so keystrokes go straight to ssh's
        // stdin without the operator needing to click the pane first.
        //
        // Tried as a no-delay call originally — that fired before the
        // view hierarchy was attached to a window when the bottom pane
        // was opening from empty (the common case for a fresh SSH
        // click), so `terminal.window` was nil and makeFirstResponder
        // silently no-op'd. Two-stage hop (one tick + a fallback
        // ~80ms later) covers both the warm-pane and cold-pane paths.
        Task { @MainActor in
            terminal.window?.makeFirstResponder(terminal)
            try? await Task.sleep(for: .milliseconds(80))
            if terminal.window?.firstResponder !== terminal {
                terminal.window?.makeFirstResponder(terminal)
            }
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // SwiftUI reparents the SwiftTerm view between attached and
        // detached layouts; re-take focus if we lost it during the
        // transition. Idempotent when we're already first responder.
        Task { @MainActor in
            if terminal.window?.firstResponder !== terminal {
                terminal.window?.makeFirstResponder(terminal)
            }
        }
    }
}
