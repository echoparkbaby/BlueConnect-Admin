import AppKit
import SwiftUI
import SwiftTerm

struct TerminalPaneView: View {
    var manager: TerminalSessionsManager
    @Environment(\.openWindow) private var openWindow

    private var attachedSessions: [TerminalSession] {
        manager.sessions.filter { !$0.isDetached }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch manager.activeSelection {
        case .session(let id):
            if let s = manager.sessions.first(where: { $0.id == id }) {
                if s.isDetached {
                    detachedPlaceholder(for: s)
                } else {
                    TerminalContainer(terminal: s.view).id(s.id)
                }
            } else { emptyState("Session ended") }
        case .connections:
            ConnectionsListView(manager: manager)
        case .log:
            LogPaneView()
        case .none:
            emptyState("No active sessions")
        }
    }

    private func detachedPlaceholder(for session: TerminalSession) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("\(session.title) is in its own window")
                .font(.headline)
            Button("Bring it back") { manager.reattach(session.id) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(_ msg: String) -> some View {
        Text(msg).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(attachedSessions) { s in
                        TerminalTab(session: s,
                                    isActive: manager.activeSelection == .session(s.id),
                                    onSelect: { manager.activeSelection = .session(s.id) },
                                    onClose: { manager.close(s.id) },
                                    onDetach: {
                                        manager.detach(s.id)
                                        openWindow(id: "detached-terminal", value: s.id)
                                    },
                                    onCloseAll: { manager.closeAll() })
                    }
                    if !manager.tunnels.isEmpty || manager.activeSelection == .connections {
                        ConnectionsTab(count: manager.tunnels.count,
                                       isActive: manager.activeSelection == .connections,
                                       onSelect: { manager.activeSelection = .connections })
                    }
                    LogTab(isActive: manager.activeSelection == .log,
                           onSelect: { manager.activeSelection = .log })
                }
            }
            Spacer(minLength: 0)
            Button { manager.closeAll() } label: { Image(systemName: "xmark.square").help("Close all terminal tabs") }
            .buttonStyle(.plain).padding(.horizontal, 8)
        }
        .frame(height: 28)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

