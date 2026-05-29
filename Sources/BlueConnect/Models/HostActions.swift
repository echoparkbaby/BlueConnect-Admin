import SwiftUI

/// Bridge between ContentView's selection-aware actions and global
/// keyboard shortcuts in the App's `Commands` block. ContentView writes
/// this each render via `.focusedSceneValue`; the menu reads it via
/// `@FocusedValue`. Presence of this value also gates main-window-only
/// commands (e.g. ⌘W Close Tab) — when nil, the menu item disables and
/// the shortcut falls through to the system's native window close.
struct HostActions {
    /// True when there's at least one host selected (or a default host
    /// available); menu items disable themselves when false.
    let hasTarget: Bool
    let ssh: () -> Void
    let vnc: () -> Void
    let scp: () -> Void
    let installPackage: () -> Void
    let uploadToRepo: () -> Void
    let eraseInstall: () -> Void
    let browseMunkiRepo: () -> Void
    let refresh: () -> Void
    let focusSearch: () -> Void
    let toggleFavorite: () -> Void
    /// Triggered from the top-level Quick Actions menu. Caller fires the
    /// existing QuickAction sheet flow against the current target host.
    let runQuickAction: (QuickAction) -> Void
    /// True when a package catalog is loaded — gates ⌘4 / Install Package menu.
    let hasPackages: Bool
    /// True when Munki Repo creds are present — gates the Browse Munki Repo menu.
    let hasMunkiRepo: Bool

    // MARK: - View menu

    /// Replace the sidebar filter selection. Wired to ⌘⇧1…⌘⇧6.
    let setSidebarFilter: (SidebarFilter) -> Void
    /// Replace the table sort order with a single comparator on the named
    /// column. "name" | "id" | "status" | "last_seen".
    let setSortField: (String) -> Void
    /// Toggle visibility of the left sidebar and the right Connect Panel.
    /// (Bottom-pane visibility is derived from session/tunnel presence;
    /// no manual toggle.)
    let toggleSidebar: () -> Void
    let toggleConnectPanel: () -> Void
    /// Current visibility — drives the checkmark on each menu Toggle.
    let isSidebarVisible: Bool
    let isConnectPanelVisible: Bool

    // MARK: - Connect menu lifecycle

    /// Close the currently-active terminal tab. Wired to ⌘W; presence of
    /// HostActions in the focus chain gates whether ⌘W fires here or
    /// falls through to the system File→Close Window.
    let closeActiveTab: () -> Void
    /// True when there is a tab eligible for ⌘W close (i.e. the bottom
    /// pane has an active session selection).
    let canCloseActiveTab: Bool

    /// Re-spawn the last-closed session using *current* Settings values
    /// (server FQDN, key path, tunnel port, default remote user) — not
    /// whatever was baked into the args at original launch. Local shells
    /// just respawn a fresh login shell.
    let reopenLastClosed: () -> Void
    /// True when there is a last-closed stub to reopen.
    let canReopenLastClosed: Bool
    /// Re-run the active session's connection in a fresh tab. Same
    /// rebuild-from-Settings semantics as reopen.
    let reconnectActive: () -> Void
    /// True when there is an active session whose host still exists in
    /// the current host list.
    let canReconnectActive: Bool

    /// Copy `ssh user@…` (the BSC-wrapped form) for the selected host to
    /// the clipboard. Returns no UI feedback — silent like Finder's Copy.
    let copySSHCommand: () -> Void
    /// Copy just the BSC ProxyCommand fragment (`ssh -p … admin@server
    /// /bin/nc %h %p`) — useful when the caller wants to splice it into a
    /// custom ~/.ssh/config Host stanza.
    let copyProxyCommand: () -> Void

    // MARK: - Former toolbar ⋯ menu items, redistributed across the
    // standard menus (File / View / app).

    /// File → "Export Hosts as CSV…" — opens a Save panel for the
    /// current filtered+sorted host list.
    let exportCSV: () -> Void
    /// File → "Activity Log…" — opens the in-app activity log sheet.
    let showActivityLog: () -> Void
    /// app menu → "Blocked Hosts…" — opens the blocked-serials sheet.
    let showBlockedHosts: () -> Void
    /// View → "Customize Row Icons…" — opens the row-icon picker sheet.
    let showCustomizeRowIcons: () -> Void

    /// Connect → "Chat ▸ With whoever's at the screen" — opens the
    /// chat window addressed to whoever the host's currently logged
    /// in console user is.
    let openChat: () -> Void
    /// Connect → "Chat ▸ With specific user…" — opens the
    /// ChatTargetUserSheet so the operator can pick a specific
    /// local account on the host before the chat window appears.
    let openChatWithSpecificUser: () -> Void

    static let none = HostActions(
        hasTarget: false,
        ssh: {}, vnc: {}, scp: {}, installPackage: {}, uploadToRepo: {},
        eraseInstall: {}, browseMunkiRepo: {},
        refresh: {}, focusSearch: {}, toggleFavorite: {},
        runQuickAction: { _ in },
        hasPackages: false,
        hasMunkiRepo: false,
        setSidebarFilter: { _ in },
        setSortField: { _ in },
        toggleSidebar: {},
        toggleConnectPanel: {},
        isSidebarVisible: true,
        isConnectPanelVisible: true,
        closeActiveTab: {},
        canCloseActiveTab: false,
        reopenLastClosed: {},
        canReopenLastClosed: false,
        reconnectActive: {},
        canReconnectActive: false,
        copySSHCommand: {},
        copyProxyCommand: {},
        exportCSV: {},
        showActivityLog: {},
        showBlockedHosts: {},
        showCustomizeRowIcons: {},
        openChat: {},
        openChatWithSpecificUser: {}
    )
}

extension FocusedValues {
    @Entry var hostActions: HostActions? = nil
}
