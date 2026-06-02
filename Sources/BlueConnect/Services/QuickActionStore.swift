import SwiftUI

/// User-controllable layer on top of the built-in `QuickAction.all` list.
/// Provides two knobs to the user:
///   1. **Disable** any built-in action so it doesn't clutter menus.
///   2. **Add** custom actions with a free-form shell command + category.
///
/// Custom actions intentionally simpler than built-ins — single static
/// shell command, no field-substitution dialog. Users who need a field
/// dialog should pick one of the built-ins to model from, then file a
/// PR. The custom flow is for the "set screensaver password to my office
/// wifi" / "run my homemade audit script" use case.
@MainActor
final class QuickActionStore: ObservableObject {
    @AppStorage("quickActionsDisabledIDs")  private var disabledIDsJSON: String = "[]"
    @AppStorage("quickActionsCustomJSON")   private var customJSON: String = "[]"
    @AppStorage("quickActionsFavoriteIDs") private var favoriteIDsJSON: String = "[]"
    /// Most-recently-run action IDs, newest first. Persisted as a JSON
    /// string array so the menu's "Recent" section survives relaunch.
    @AppStorage("quickActionsRecentIDs")   private var recentIDsJSON: String = "[]"
    /// How many entries the menu's "Recent" section shows. Settable from
    /// Settings → Quick Actions; 0 hides the section entirely.
    @AppStorage("quickActionsRecentLimit") var recentLimit: Int = 3

    /// Convenience setter for the IDs of built-in actions the user has
    /// chosen to hide from menus. Persisted as a JSON string array.
    var disabledIDs: Set<String> {
        get {
            guard let data = disabledIDsJSON.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return Set(arr)
        }
        set {
            if let data = try? JSONEncoder().encode(Array(newValue).sorted()),
               let s = String(data: data, encoding: .utf8) {
                disabledIDsJSON = s
                objectWillChange.send()
            }
        }
    }

    /// IDs of actions the user has starred. They surface in a dedicated
    /// "Favorites" group at the top of the menubar Quick Actions menu and
    /// the browser-window sidebar, in user-pin order.
    var favoriteIDs: Set<String> {
        get {
            guard let data = favoriteIDsJSON.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return Set(arr)
        }
        set {
            if let data = try? JSONEncoder().encode(Array(newValue).sorted()),
               let s = String(data: data, encoding: .utf8) {
                favoriteIDsJSON = s
                objectWillChange.send()
            }
        }
    }

    func isFavorite(_ id: String) -> Bool { favoriteIDs.contains(id) }

    /// Ordered list of recently-run action IDs, newest first. Cap at 50
    /// so we never grow without bound; the menu reads only the top
    /// `recentLimit`.
    var recentIDs: [String] {
        get {
            guard let data = recentIDsJSON.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return arr
        }
        set {
            let capped = Array(newValue.prefix(50))
            if let data = try? JSONEncoder().encode(capped),
               let s = String(data: data, encoding: .utf8) {
                recentIDsJSON = s
                objectWillChange.send()
            }
        }
    }

    /// Record that the user just ran this action. Moves the ID to the
    /// front of the recents list (dedup if already present). Call from
    /// every entry point that fires a Quick Action — the right-click
    /// menu, the row-icon menu, and the Browse window.
    func noteUsed(_ id: String) {
        var ids = recentIDs.filter { $0 != id }
        ids.insert(id, at: 0)
        recentIDs = ids
    }

    func toggleFavorite(_ id: String) {
        var ids = favoriteIDs
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        favoriteIDs = ids
    }

    /// User-defined custom actions, persisted as JSON.
    var customActions: [CustomQuickAction] {
        get {
            guard let data = customJSON.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([CustomQuickAction].self, from: data)
            else { return [] }
            return arr
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let s = String(data: data, encoding: .utf8) {
                customJSON = s
                objectWillChange.send()
            }
        }
    }

    /// All actions (built-in minus disabled, plus custom) — ordered so
    /// built-ins come first in their original category order, then
    /// custom actions under their declared category.
    var allEnabled: ActionList {
        let builtins = QuickAction.all
            .filter { !disabledIDs.contains($0.id) }
        let customAsQA = customActions.map { $0.asQuickAction() }
        return ActionList(actions: builtins + customAsQA,
                          favoriteIDs: favoriteIDs,
                          recentIDs: Array(recentIDs.prefix(recentLimit)))
    }

    /// Add a new custom action. Generates a UUID-based ID so users can
    /// safely add multiples with the same label.
    func addCustom(_ draft: CustomQuickAction) {
        var arr = customActions
        var copy = draft
        if copy.id.isEmpty { copy.id = "custom-\(UUID().uuidString.prefix(8))" }
        arr.append(copy)
        customActions = arr
    }

    /// Overwrite an existing custom action with new values. Matches on
    /// `id` so favorites / recents that referenced the action keep
    /// working. If the id doesn't resolve to an existing entry the call
    /// is a no-op (callers should use `addCustom` for that case).
    func updateCustom(_ updated: CustomQuickAction) {
        var arr = customActions
        guard let idx = arr.firstIndex(where: { $0.id == updated.id }) else { return }
        arr[idx] = updated
        customActions = arr
    }

    func removeCustom(id: String) {
        customActions = customActions.filter { $0.id != id }
    }

    func toggleEnabled(_ id: String) {
        var ids = disabledIDs
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        disabledIDs = ids
    }

    func isEnabled(_ id: String) -> Bool { !disabledIDs.contains(id) }
}

/// Codable wrapper around the menu-displayable form of QuickAction. Used
/// by both built-in and custom paths through `allEnabled`.
struct ActionList {
    let actions: [QuickAction]
    let favoriteIDs: Set<String>
    /// IDs of recently-run actions, newest first, already truncated to
    /// the user's recentLimit by the store. The menu surfaces these
    /// above Favorites; entries are *in addition to* Favorites, not
    /// overlapping (a recent that's also a favorite shows in both).
    let recentIDs: [String]

    init(actions: [QuickAction],
         favoriteIDs: Set<String> = [],
         recentIDs: [String] = []) {
        self.actions = actions
        self.favoriteIDs = favoriteIDs
        self.recentIDs = recentIDs
    }

    var isEmpty: Bool { actions.isEmpty }

    /// Actions the user has starred, alphabetized by label.
    var favorites: [QuickAction] {
        actions
            .filter { favoriteIDs.contains($0.id) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Recently-used actions in MRU order (preserves the order of
    /// `recentIDs`). Skips IDs that no longer resolve to an enabled
    /// action — e.g. the user disabled it after running it.
    var recents: [QuickAction] {
        let byID = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
        return recentIDs.compactMap { byID[$0] }
    }

    /// `[(category-label, [actions])]` — categories alphabetized
    /// case-insensitively, AND each category's actions alphabetized
    /// case-insensitively by label. Used to render the menubar submenus
    /// and the browser-window sidebar consistently, so the catalog's
    /// declaration order doesn't bleed into the UI.
    var grouped: [(String, [QuickAction])] {
        var byCat: [String: [QuickAction]] = [:]
        for a in actions {
            byCat[a.category.rawValue, default: []].append(a)
        }
        return byCat.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { key in
                let sorted = (byCat[key] ?? []).sorted {
                    $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
                }
                return (key, sorted)
            }
    }
}

/// User-defined Quick Action. Subset of `QuickAction`'s capabilities —
/// no parameter sheet (no fields), one static command. The command is
/// run on the remote host as-is via the same SSH path the built-ins use.
struct CustomQuickAction: Codable, Hashable, Identifiable {
    var id: String = ""
    var label: String
    /// Free-form category name — appears as its own section in menus.
    /// "Custom" is a good default; users can split into "Audits",
    /// "One-offs", etc. if they end up with many actions.
    var category: String
    /// SF Symbol name (e.g. "wand.and.stars"). Falls back to "terminal"
    /// when invalid at render time.
    var icon: String = "terminal"
    /// The shell command, sent to the host via SSH as-is. The user is
    /// responsible for quoting and any sudo prefix they need.
    var command: String
    var isDestructive: Bool = false
    var help: String?

    /// Project this onto a `QuickAction` for menu display. The category
    /// goes through a synthetic enum-shaped case backed by the user's
    /// string.
    func asQuickAction() -> QuickAction {
        QuickAction(
            id: id,
            label: label,
            category: .custom(name: category),
            icon: icon.isEmpty ? "terminal" : icon,
            fields: [],
            tabLabel: id,
            isDestructive: isDestructive,
            help: help,
            buildCommand: { _ in command }
        )
    }
}
