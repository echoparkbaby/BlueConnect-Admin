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
    let refresh: () -> Void
    let focusSearch: () -> Void
    let toggleFavorite: () -> Void
    let showLog: () -> Void

    static let none = HostActions(
        hasTarget: false,
        ssh: {}, vnc: {}, scp: {},
        refresh: {}, focusSearch: {}, toggleFavorite: {}, showLog: {}
    )
}

extension FocusedValues {
    @Entry var hostActions: HostActions? = nil
}
