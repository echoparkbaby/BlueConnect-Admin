import SwiftUI

/// Floating-window content for a terminal session that's been popped out
/// of the tab bar. Toolbar at top with a re-attach button; the rest is
/// the live `TerminalContainer` wrapping the session's NSView.
struct DetachedTerminalView: View {
    let sessionID: UUID
    @Environment(TerminalSessionsManager.self) private var manager
    @Environment(\.dismissWindow) private var dismissWindow

    private var session: TerminalSession? {
        manager.sessions.first(where: { $0.id == sessionID })
    }

    var body: some View {
        Group {
            if let session, session.isDetached {
                VStack(spacing: 0) {
                    toolbar(session: session)
                    Divider()
                    TerminalContainer(terminal: session.view).id(session.id)
                }
                // Hidden ⌘F shortcut so the same key that detaches
                // from the main window re-attaches from this one.
                // SwiftUI dispatches keyboardShortcut bindings on the
                // key window first, so this button wins over the
                // app-menu's "Detach Tab" when the detached window
                // has focus.
                .background(
                    Button("Re-attach (⌘F)") {
                        manager.reattach(sessionID)
                        dismissWindow(id: "detached-terminal", value: sessionID)
                    }
                    .keyboardShortcut("f", modifiers: [.command])
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                )
            } else {
                // Session ended or was already re-attached — close ourselves.
                Color.clear
                    .onAppear {
                        dismissWindow(id: "detached-terminal", value: sessionID)
                    }
            }
        }
        // If user closes via the red traffic light without hitting Re-attach,
        // pull the terminal NSView back into the manager's tab bar so it
        // doesn't end up orphaned.
        .onDisappear {
            if let s = session, s.isDetached {
                manager.reattach(sessionID)
            }
        }
        .frame(minWidth: 600, minHeight: 320)
    }

    private func toolbar(session: TerminalSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: session.kind == .ssh ? "terminal" : "doc.badge.arrow.up")
                .foregroundStyle(session.kind == .ssh ? .green : .orange)
            Text(session.title).font(.callout).bold()
            Spacer()
            Button {
                manager.reattach(sessionID)
                dismissWindow(id: "detached-terminal", value: sessionID)
            } label: {
                Label("Re-attach to tabs", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            // ⌘⇧W — pairs with ⌘W (close window) so the user has both
            // reattach and dispose at their fingertips without the mouse.
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .help("Move this terminal back into the main window's tab bar (⌘⇧W)")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }
}
