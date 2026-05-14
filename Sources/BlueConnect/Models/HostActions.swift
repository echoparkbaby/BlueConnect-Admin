import SwiftUI

/// Bridge between ContentView's selection-aware actions and global
/// keyboard shortcuts in the App's `Commands` block. ContentView writes
/// this each render via `.focusedSceneValue`; the menu reads it via
/// `@FocusedValue`.
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
    let showLog: () -> Void
    /// Triggered from the top-level Quick Actions menu. Caller fires the
    /// existing QuickAction sheet flow against the current target host.
    let runQuickAction: (QuickAction) -> Void
    /// True when a package catalog is loaded — gates ⌘4 / Install Package menu.
    let hasPackages: Bool
    /// True when Munki Repo creds are present — gates the Browse Munki Repo menu.
    let hasMunkiRepo: Bool

    static let none = HostActions(
        hasTarget: false,
        ssh: {}, vnc: {}, scp: {}, installPackage: {}, uploadToRepo: {},
        eraseInstall: {}, browseMunkiRepo: {},
        refresh: {}, focusSearch: {}, toggleFavorite: {}, showLog: {},
        runQuickAction: { _ in },
        hasPackages: false,
        hasMunkiRepo: false
    )
}

/// Tab-management bridge for the Connect menu's tail section. Lives here
/// alongside HostActions because it's the same focused-value pattern.
struct TerminalCommands {
    let previousTab: () -> Void
    let nextTab: () -> Void
    let closeActiveTab: () -> Void
    let closeAllTabs: () -> Void
    let hasMultiple: Bool
    let hasAny: Bool

    static let none = TerminalCommands(
        previousTab: {}, nextTab: {}, closeActiveTab: {}, closeAllTabs: {},
        hasMultiple: false, hasAny: false
    )
}

extension FocusedValues {
    @Entry var hostActions: HostActions? = nil
    @Entry var terminalCommands: TerminalCommands? = nil
}
