import Foundation

/// One pre-baked admin command we can run on a remote host with a small
/// parameter sheet. Mirrors the Typinator snippets BSC admins type after
/// SSHing — but now exposed in the right-click menu and routed through
/// the existing `openRemoteCommand` SSH path so output lands in a terminal
/// tab.
struct QuickAction: Identifiable, Hashable {
    let id: String
    let label: String
    let category: Category
    let icon: String
    let fields: [Field]
    let tabLabel: String
    let isDestructive: Bool
    /// Multi-line description shown under the action title in the sheet.
    /// Use it to explain WHAT the toggle does in user-facing terms.
    var help: String? = nil
    let buildCommand: (_ values: [String: String]) -> String

    /// Top-level grouping shown as a Section header in the right-click menu.
    /// Order is deliberate for built-ins — Secure Tokens first because
    /// that's the highest-stakes action; Fix Annoyances last because
    /// those are cosmetic. Refactored from a simple enum to a struct so
    /// custom (user-defined) actions can declare arbitrary category
    /// names while keeping the type-safe `.secureTokens` accessors.
    struct Category: Hashable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }

        static let secureTokens  = Category(rawValue: "Secure Tokens")
        static let userAccounts  = Category(rawValue: "User Accounts")
        static let fileVault     = Category(rawValue: "FileVault")
        static let security      = Category(rawValue: "Security & MDM")
        static let fleet         = Category(rawValue: "BlueConnect Fleet")
        static let munki         = Category(rawValue: "Munki")
        static let munkiReport   = Category(rawValue: "MunkiReport")
        static let packages      = Category(rawValue: "Packages")
        static let software      = Category(rawValue: "Software")
        static let system        = Category(rawValue: "System")
        static let diagnostics   = Category(rawValue: "Diagnostics")
        static let disk          = Category(rawValue: "Disk & Spotlight")
        static let timeMachine   = Category(rawValue: "Time Machine")
        static let email         = Category(rawValue: "Email")
        static let privacy       = Category(rawValue: "Privacy & TCC")
        static let processApp    = Category(rawValue: "Process & App")
        static let networking    = Category(rawValue: "Networking")
        static let logs          = Category(rawValue: "Logs")
        static let miscellaneous = Category(rawValue: "Miscellaneous")
        static let fixAnnoyances = Category(rawValue: "UI Tweaks")

        /// Free-form category for user-defined Quick Actions.
        static func custom(name: String) -> Category {
            Category(rawValue: name.isEmpty ? "Custom" : name)
        }

        /// Built-in categories, in display order. Used by the context-
        /// menu grouped iterator. Custom categories thread through
        /// QuickActionStore's separate grouping path.
        static let allCases: [Category] = [
            .secureTokens, .userAccounts, .fileVault, .security,
            .fleet,
            .munki, .munkiReport, .packages, .software,
            .system, .diagnostics,
            .disk, .timeMachine,
            .email,
            .privacy,
            .processApp,
            .networking, .logs,
            .miscellaneous,
            .fixAnnoyances,
        ]
    }

    static func == (lhs: QuickAction, rhs: QuickAction) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    struct Field: Identifiable, Hashable {
        let id: String
        let label: String
        let placeholder: String
        let kind: Kind
        var defaultValue: String = ""
        /// Optional dynamic data source — the sheet fetches options at
        /// open time using the target host's identity. When the data
        /// source is set the field renders as a picker; if the fetch
        /// fails or returns nothing the field degrades to the kind's
        /// normal rendering (text / secure).
        var dataSource: DataSource? = nil

        enum Kind: Hashable {
            case text
            case secure
            case picker([Option])
        }
        struct Option: Hashable, Identifiable {
            var id: String { value }
            let label: String
            let value: String
        }
        /// Where a field gets its picker options at runtime.
        /// `mrLocalUsers` fetches accounts from MunkiReport's
        /// `local_users` table for the target host. `mrLocalUsersWithAuto`
        /// is the same list but prepends a sentinel option that means
        /// "use the currently-logged-in console user" — the field's
        /// buildCommand recognises the magic value `__auto__` and runs
        /// `stat -f%Su /dev/console` to resolve it at command time.
        enum DataSource: Hashable {
            case mrLocalUsers
            case mrLocalUsersWithAuto
        }
    }

    /// Sentinel value emitted by the auto-detect option in
    /// `.mrLocalUsersWithAuto` pickers. Action buildCommands match on
    /// this to switch to runtime console-user detection.
    static let autoConsoleUserSentinel = "__auto__"

}
