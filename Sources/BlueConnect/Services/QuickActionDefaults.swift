import Foundation

/// Per-action field-value memory. When the user runs a Quick Action the
/// values they picked (color, font, hide-after, free-form text) are
/// saved here keyed by action + field; next time the sheet opens for
/// the same action the saved values pre-populate before the action's
/// own `defaultValue` would apply.
///
/// Secure fields are never persisted — those exist exactly to keep
/// passwords out of the disk.
///
/// Storage shape: a single JSON dictionary in `UserDefaults` under
/// `quickActionsLastValues`, of the form `[actionID: [fieldID: value]]`.
/// One blob keeps migrations cheap and avoids littering Defaults with
/// per-key noise.
@MainActor
enum QuickActionDefaults {
    private static let storeKey = "quickActionsLastValues"

    /// Last-used non-secure field values for `actionID`, or empty if
    /// nothing's been saved yet.
    static func load(actionID: String) -> [String: String] {
        guard let data = UserDefaults.standard.string(forKey: storeKey)?.data(using: .utf8),
              let all  = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return all[actionID] ?? [:]
    }

    /// Save the non-secure field values for `actionID`. Skips fields
    /// whose `kind` is `.secure`. No-ops if the action has no fields.
    static func save(actionID: String, values: [String: String], fields: [QuickAction.Field]) {
        var safe: [String: String] = [:]
        let secureIDs = Set(fields.compactMap { f -> String? in
            if case .secure = f.kind { return f.id } else { return nil }
        })
        for (k, v) in values where !secureIDs.contains(k) {
            safe[k] = v
        }
        // Read-modify-write the outer dictionary so other actions'
        // saved values aren't dropped on each save.
        var all: [String: [String: String]] = [:]
        if let data = UserDefaults.standard.string(forKey: storeKey)?.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            all = decoded
        }
        all[actionID] = safe
        if let data = try? JSONEncoder().encode(all),
           let s    = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: storeKey)
        }
    }
}
