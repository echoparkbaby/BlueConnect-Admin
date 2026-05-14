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
    /// Order is deliberate — Secure Tokens first because that's the
    /// highest-stakes action; Desktop tweaks last because they're cosmetic.
    enum Category: String, CaseIterable {
        case secureTokens   = "Secure Tokens"
        case userAccounts   = "User Accounts"
        case fileVault      = "FileVault"
        case software       = "Software"
        case system         = "System"
        case fixAnnoyances  = "Fix Annoyances"
    }

    static func == (lhs: QuickAction, rhs: QuickAction) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    struct Field: Identifiable, Hashable {
        let id: String
        let label: String
        let placeholder: String
        let kind: Kind
        var defaultValue: String = ""

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
    }

    // POSIX single-quote escape — safe for embedding user input in a
    // single-arg sudo/ssh command string. `it'd` → `'it'\''d'`.
    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Actions grouped by category, in `Category.allCases` declaration
    /// order. Categories with no matching action are skipped — useful
    /// later if some actions get gated on a feature flag.
    static var grouped: [(Category, [QuickAction])] {
        Category.allCases.compactMap { cat in
            let items = all.filter { $0.category == cat }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    static let all: [QuickAction] = [

        // 1. Grant Secure Token
        QuickAction(
            id: "grantSecureToken",
            label: "Grant Secure Token…",
            category: .secureTokens,
            icon: "key.fill",
            fields: [
                .init(id: "adminUser", label: "Admin user (already has token)",
                      placeholder: "ladmin", kind: .text, defaultValue: "ladmin"),
                .init(id: "adminPw", label: "Admin password",
                      placeholder: "", kind: .secure),
                .init(id: "targetUser", label: "User to grant token",
                      placeholder: "newuser", kind: .text),
                .init(id: "targetPw", label: "That user's password",
                      placeholder: "", kind: .secure),
            ],
            tabLabel: "grant-token",
            isDestructive: false,
            buildCommand: { v in
                "sudo sysadminctl"
                + " -adminUser \(shq(v["adminUser"] ?? ""))"
                + " -adminPassword \(shq(v["adminPw"] ?? ""))"
                + " -secureTokenOn \(shq(v["targetUser"] ?? ""))"
                + " -password \(shq(v["targetPw"] ?? ""))"
            }
        ),

        // 2. Install Homebrew (user-shell, not sudo — installer prompts itself)
        QuickAction(
            id: "installHomebrew", label: "Install Homebrew",
            category: .software,
            icon: "mug.fill", fields: [],
            tabLabel: "brew-install", isDestructive: false,
            buildCommand: { _ in
                "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            }
        ),

        // 3. FileVault Authenticated Restart
        QuickAction(
            id: "fvAuthRestart",
            label: "FileVault Authenticated Restart",
            category: .fileVault,
            icon: "arrow.clockwise.circle.fill", fields: [],
            tabLabel: "fv-restart", isDestructive: true,
            buildCommand: { _ in "sudo fdesetup authrestart" }
        ),

        // 4. Hide User
        QuickAction(
            id: "hideUser", label: "Hide User from Login Window…",
            category: .userAccounts,
            icon: "eye.slash",
            fields: [.init(id: "user", label: "Short name", placeholder: "ladmin", kind: .text)],
            tabLabel: "hide-user", isDestructive: false,
            buildCommand: { v in
                "sudo dscl . create /Users/\(shq(v["user"] ?? "")) IsHidden 1"
            }
        ),

        // 4b. Unhide User (companion to #4)
        QuickAction(
            id: "unhideUser", label: "Unhide User…",
            category: .userAccounts,
            icon: "eye",
            fields: [.init(id: "user", label: "Short name", placeholder: "ladmin", kind: .text)],
            tabLabel: "unhide-user", isDestructive: false,
            buildCommand: { v in
                "sudo dscl . create /Users/\(shq(v["user"] ?? "")) IsHidden 0"
            }
        ),

        // 5. Logout User
        QuickAction(
            id: "logoutUser", label: "Logout User…",
            category: .userAccounts,
            icon: "rectangle.portrait.and.arrow.right",
            fields: [
                .init(id: "user", label: "Short name", placeholder: "ladmin", kind: .text),
                .init(id: "scope", label: "Scope",
                      placeholder: "", kind: .picker([
                        .init(label: "GUI session", value: "gui"),
                        .init(label: "User session", value: "user"),
                      ]), defaultValue: "gui"),
            ],
            tabLabel: "logout-user", isDestructive: false,
            buildCommand: { v in
                let scope = v["scope"] ?? "gui"
                let user = v["user"] ?? ""
                return "sudo launchctl bootout \(scope)/$(id -u \(shq(user)))"
            }
        ),

        // 6. Remove User
        QuickAction(
            id: "deleteUser", label: "Delete User…",
            category: .userAccounts,
            icon: "person.fill.xmark",
            fields: [.init(id: "user", label: "Short name", placeholder: "ladmin", kind: .text)],
            tabLabel: "delete-user", isDestructive: true,
            buildCommand: { v in
                "sudo sysadminctl -deleteUser \(shq(v["user"] ?? ""))"
            }
        ),

        // 7. Secure Token Status (read-only)
        QuickAction(
            id: "secureTokenStatus",
            label: "Secure Token Status…",
            category: .secureTokens,
            icon: "key",
            fields: [.init(id: "user", label: "Short name", placeholder: "ladmin", kind: .text)],
            tabLabel: "token-status", isDestructive: false,
            buildCommand: { v in
                let u = shq(v["user"] ?? "")
                return "dscl . -read /Users/\(u) AuthenticationAuthority ; echo ;"
                     + " sysadminctl -secureTokenStatus \(u)"
            }
        ),

        // Click-wallpaper-to-show-desktop OFF (Sonoma+ behaviour that
        // surprises users by sweeping their windows off-screen)
        QuickAction(
            id: "showDesktopClickOff",
            label: "Click wallpaper to show desktop — OFF",
            category: .fixAnnoyances,
            icon: "rectangle.fill.on.rectangle.fill.slash.fill", fields: [],
            tabLabel: "click-desktop-off", isDestructive: false,
            help: "Click wallpaper to show desktop\n\nClick wallpaper to move windows out of the way, revealing your desktop items and widgets.\n\nThis turns the behaviour off — the wallpaper becomes click-through to whatever's underneath.",
            buildCommand: { _ in
                "/usr/bin/defaults write com.apple.WindowManager EnableStandardClickToShowDesktop -bool false"
            }
        ),

        // Click-wallpaper-to-show-desktop ON
        QuickAction(
            id: "showDesktopClickOn",
            label: "Click wallpaper to show desktop — ON",
            category: .fixAnnoyances,
            icon: "rectangle.fill.on.rectangle.fill", fields: [],
            tabLabel: "click-desktop-on", isDestructive: false,
            help: "Restores the Sonoma+ default where clicking the wallpaper moves your windows out of the way to reveal the desktop and widgets.",
            buildCommand: { _ in
                "/usr/bin/defaults write com.apple.WindowManager EnableStandardClickToShowDesktop -bool true"
            }
        ),

        // Set Computer / Local / Host name — covers all three macOS
        // identity slots. Picker controls which slot(s) get touched.
        QuickAction(
            id: "setHostname",
            label: "Set Computer Name…",
            category: .system,
            icon: "tag.square",
            fields: [
                .init(id: "name", label: "New name",
                      placeholder: "Brandon's MacBook Pro", kind: .text),
                .init(id: "scope", label: "Apply to",
                      placeholder: "", kind: .picker([
                        .init(label: "All three names (recommended)", value: "all"),
                        .init(label: "ComputerName only (friendly name)", value: "computer"),
                        .init(label: "LocalHostName only (Bonjour .local)", value: "local"),
                        .init(label: "HostName only (terminal / BSD)", value: "host"),
                      ]), defaultValue: "all"),
            ],
            tabLabel: "set-hostname",
            isDestructive: false,
            help: "Renames the Mac across macOS's three hostname slots. ComputerName accepts spaces and special chars; LocalHostName and HostName are auto-sanitized to letters/digits/hyphens for Bonjour and DNS compatibility. \"All three\" is the right choice for a real rename.",
            buildCommand: { v in
                let name = v["name"] ?? ""
                let scope = v["scope"] ?? "all"
                let nameQ = shq(name)
                // Sanitize to alphanumerics + hyphens for the .local /
                // BSD slots. The transform stays visible to the admin
                // (echo | tr | sed) so it's auditable in the terminal.
                let safe = "\"$(echo \(nameQ) | tr -c 'A-Za-z0-9-' '-' | tr -s '-' | sed 's/^-*//;s/-*$//')\""
                switch scope {
                case "computer":
                    return "sudo scutil --set ComputerName \(nameQ)"
                case "local":
                    return "sudo scutil --set LocalHostName \(safe)"
                case "host":
                    return "sudo scutil --set HostName \(safe)"
                default:
                    return [
                        "sudo scutil --set ComputerName \(nameQ)",
                        "sudo scutil --set LocalHostName \(safe)",
                        "sudo scutil --set HostName \(safe)",
                        "sudo dscacheutil -flushcache",
                        "echo 'Done. New names:'",
                        "scutil --get ComputerName ; scutil --get LocalHostName ; scutil --get HostName"
                    ].joined(separator: " && ")
                }
            }
        ),

        // Scrollbars — Always visible
        QuickAction(
            id: "scrollbarsAlways",
            label: "Scrollbars — Always",
            category: .fixAnnoyances,
            icon: "scroll", fields: [],
            tabLabel: "scrollbars-always", isDestructive: false,
            help: "Force scrollbars to remain visible in every app, not just when scrolling. Requires the user to log out and back in (or restart affected apps) to take effect.",
            buildCommand: { _ in
                "defaults write NSGlobalDomain AppleShowScrollBars -string Always"
            }
        ),
    ]
}
