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
    @AppStorage("quickActionsDisabledIDs") private var disabledIDsJSON: String = "[]"
    @AppStorage("quickActionsCustomJSON")  private var customJSON: String = "[]"

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
        return ActionList(actions: builtins + customAsQA)
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

    var isEmpty: Bool { actions.isEmpty }

    /// `[(category-label, [actions])]` — keyed by displayable category
    /// string so custom actions (free-form category) merge naturally
    /// with built-in (enum-backed) ones.
    var grouped: [(String, [QuickAction])] {
        var byCat: [String: [QuickAction]] = [:]
        var order: [String] = []
        for a in actions {
            let key = a.category.rawValue
            if byCat[key] == nil { order.append(key) }
            byCat[key, default: []].append(a)
        }
        return order.map { ($0, byCat[$0] ?? []) }
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
