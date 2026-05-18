import SwiftUI

/// Wraps a sidebar/connect-panel so it can be collapsed via a chevron at
/// its outer edge.
///
/// CRITICAL: every render must return the same view structure. HSplitView
/// (NSSplitView-backed) crashes in `NSPerformVisuallyAtomicChange` if the
/// inner view *identity* changes — that includes returning different
/// `some View` branches from `body`. So both states (visible / collapsed)
/// share one ZStack; we toggle opacity, hit-testing, and chevron position
/// rather than swapping containers.
struct PaneCollapser<Content: View>: View {
    enum Side { case leading, trailing }

    let side: Side
    @Binding var visible: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: chevronAlignment) {
            // Background — only visible when collapsed (provides the rail
            // look) but always in the hierarchy.
            Color(NSColor.windowBackgroundColor)
                .opacity(visible ? 0 : 1)

            // Real pane content — always in the hierarchy, just dimmed
            // and hit-blocked when collapsed.
            content()
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(visible)
                .clipped()

            // Chevron — single button, repositioned via the ZStack's
            // alignment (recomputed every render but doesn't change
            // identity, so NSSplitView stays happy).
            Button { visible.toggle() } label: {
                Image(systemName: chevronSymbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.secondary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .padding(visible ? 4 : 8)
            .help(visible ? "Collapse pane" : "Expand pane")
        }
    }

    /// When visible: chevron sits at the inner corner of the pane.
    /// When collapsed: chevron sits at the top center of the rail.
    private var chevronAlignment: Alignment {
        if !visible { return .top }
        return side == .leading ? .topTrailing : .topLeading
    }

    /// Chevron direction:
    /// - leading pane, visible    → ‹  (collapse it leftward)
    /// - leading pane, collapsed  → ›  (expand it rightward)
    /// - trailing pane, visible   → ›  (collapse it rightward)
    /// - trailing pane, collapsed → ‹  (expand it leftward)
    private var chevronSymbol: String {
        let leftward: Bool
        switch (side, visible) {
        case (.leading, true), (.trailing, false):  leftward = true
        case (.leading, false), (.trailing, true):  leftward = false
        }
        return leftward ? "chevron.left" : "chevron.right"
    }
}
