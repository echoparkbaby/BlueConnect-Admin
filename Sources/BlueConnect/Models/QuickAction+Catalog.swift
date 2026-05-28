import Foundation

/// Built-in catalog of `QuickAction` items + the `shq` POSIX-escape helper
/// the buildCommand closures use. Split out of `QuickAction.swift` so the
/// type definition stays under 130 lines and diffs to the catalog don't
/// drag the type header along for the ride. Both files compile into the
/// same `QuickAction` type — Swift extensions in the same module are free.
extension QuickAction {

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
                      placeholder: "shortname", kind: .text),
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

        // FileVault: inspect (read-only, mode picker covering the
        // common fdesetup / diskutil checks)
        QuickAction(
            id: "fvInspect", label: "FileVault: inspect…",
            category: .fileVault, icon: "lock.shield",
            fields: [
                .init(id: "mode", label: "Inspect",
                      placeholder: "", kind: .picker([
                        .init(label: "Status (on/off, encrypting, …)",  value: "status"),
                        .init(label: "Authorized users (unlock list)",  value: "list"),
                        .init(label: "Has personal recovery key?",      value: "personal"),
                        .init(label: "Has institutional recovery key?", value: "institutional"),
                        .init(label: "Deferred-enable info",            value: "deferral"),
                        .init(label: "APFS CryptoUsers (boot vol)",     value: "crypto"),
                      ]), defaultValue: "status"),
            ],
            tabLabel: "fv-inspect", isDestructive: false,
            help: "Read-only FileVault diagnostics. Run any of these without changing state — useful for confirming who can unlock the disk, whether a recovery key exists, and what APFS itself thinks is enrolled.",
            buildCommand: { v in
                switch v["mode"] ?? "status" {
                case "list":          return "sudo fdesetup list"
                case "personal":      return "sudo fdesetup haspersonalrecoverykey"
                case "institutional": return "sudo fdesetup hasinstitutionalrecoverykey"
                case "deferral":      return "sudo fdesetup showdeferralinfo"
                case "crypto":        return "diskutil apfs listCryptoUsers /"
                default:              return "fdesetup status"
                }
            }
        ),

        // FileVault: rotate personal recovery key (destructive — prints
        // the NEW key once; if the operator misses it, the key is gone)
        QuickAction(
            id: "fvRotatePersonalRecoveryKey",
            label: "FileVault: rotate personal recovery key",
            category: .fileVault, icon: "key.fill", fields: [],
            tabLabel: "fv-rotate-prk", isDestructive: true,
            help: "Generates a brand new personal recovery key, replacing the old one. The new key is printed to the terminal ONCE — copy and store it before closing the tab, or it's lost.\n\nRequires interactive admin authentication on the remote host.",
            buildCommand: { _ in "sudo fdesetup changerecovery -personal" }
        ),

        // FileVault: remove user from unlock list (destructive)
        QuickAction(
            id: "fvRemoveUserFromUnlock",
            label: "FileVault: remove user from unlock list…",
            category: .fileVault, icon: "person.fill.xmark",
            fields: [.init(id: "user", label: "Short name",
                           placeholder: "shortname", kind: .text,
                           // MunkiReport poll: dropdown of users on this
                           // Mac. Falls back to plain text input if MR
                           // isn't configured for the host.
                           dataSource: .mrLocalUsers)],
            tabLabel: "fv-remove-user", isDestructive: true,
            help: "Removes a user from the list of accounts that can unlock the disk at boot. The account itself is not deleted — they just lose the ability to enter their password at the FileVault prompt.",
            buildCommand: { v in
                "sudo fdesetup remove -user \(shq(v["user"] ?? ""))"
            }
        ),

        // 4. Hide or Unhide User (merged: single sheet, mode picker)
        QuickAction(
            id: "hideUnhideUser", label: "Hide or Unhide User…",
            category: .userAccounts,
            icon: "eye.slash",
            fields: [
                .init(id: "user", label: "Short name",
                      placeholder: "shortname", kind: .text,
                      dataSource: .mrLocalUsers),
                .init(id: "mode", label: "Action",
                      placeholder: "", kind: .picker([
                        .init(label: "Hide from login window", value: "hide"),
                        .init(label: "Unhide", value: "unhide"),
                      ]), defaultValue: "hide"),
            ],
            tabLabel: "hide-unhide-user", isDestructive: false,
            buildCommand: { v in
                let flag = (v["mode"] == "unhide") ? "0" : "1"
                return "sudo dscl . create /Users/\(shq(v["user"] ?? "")) IsHidden \(flag)"
            }
        ),

        // 5. Logout User
        QuickAction(
            id: "logoutUser", label: "Logout User…",
            category: .userAccounts,
            icon: "rectangle.portrait.and.arrow.right",
            fields: [
                // dataSource: .mrLocalUsers turns the field into a picker
                // populated from MunkiReport's local_users for this host
                // at sheet-open time. Falls back to a plain text field
                // when MR isn't configured, the host has no serial,
                // or local_users is empty for this Mac.
                .init(id: "user", label: "Short name",
                      placeholder: "shortname", kind: .text,
                      dataSource: .mrLocalUsers),
                .init(id: "scope", label: "Scope",
                      placeholder: "", kind: .picker([
                        .init(label: "GUI session", value: "gui"),
                        .init(label: "User session", value: "user"),
                      ]), defaultValue: "gui"),
            ],
            tabLabel: "logout-user", isDestructive: false,
            help: """
            • GUI session — kills only the Aqua/window-server context. \
            Logs the user out of the desktop; user-level daemons that \
            don't depend on the GUI may keep running. Closest equivalent \
            to the Log Out… item in the Apple menu, and the safer choice \
            when the user might be in the middle of saving something.

            • User session — kills the entire per-user launchd domain \
            (GUI included). A hard logout: everything the user owns is \
            torn down. Use when GUI logout didn't take, or when you \
            need to free per-user resources entirely.

            If the user isn't actually logged in, the command no-ops.
            """,
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
            fields: [.init(id: "user", label: "Short name", placeholder: "shortname", kind: .text,
                           dataSource: .mrLocalUsers)],
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
            fields: [.init(id: "user", label: "Short name", placeholder: "shortname", kind: .text,
                           dataSource: .mrLocalUsers)],
            tabLabel: "token-status", isDestructive: false,
            buildCommand: { v in
                let u = shq(v["user"] ?? "")
                return "dscl . -read /Users/\(u) AuthenticationAuthority ; echo ;"
                     + " sysadminctl -secureTokenStatus \(u)"
            }
        ),

        // Click-wallpaper-to-show-desktop toggle (merged ON/OFF — picker)
        QuickAction(
            id: "showDesktopClick",
            label: "Click wallpaper to show desktop…",
            category: .fixAnnoyances,
            icon: "rectangle.fill.on.rectangle.fill",
            fields: [
                .init(id: "mode", label: "State",
                      placeholder: "", kind: .picker([
                        .init(label: "Disable (recommended — wallpaper click does nothing)", value: "off"),
                        .init(label: "Enable (Sonoma+ default — click sweeps windows off)", value: "on"),
                      ]), defaultValue: "off"),
            ],
            tabLabel: "click-desktop", isDestructive: false,
            help: "Click wallpaper to show desktop\n\nClick wallpaper to move windows out of the way, revealing your desktop items and widgets. Off makes the wallpaper click-through, restoring pre-Sonoma behaviour.",
            buildCommand: { v in
                let value = (v["mode"] == "on") ? "true" : "false"
                return "/usr/bin/defaults write com.apple.WindowManager EnableStandardClickToShowDesktop -bool \(value)"
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
                      placeholder: "e.g. Lab 2 Mini", kind: .text),
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

        // MARK: - Munki

        QuickAction(
            id: "munkiRunNow", label: "Munki: run now",
            category: .munki, icon: "play.circle.fill", fields: [],
            tabLabel: "munki-run", isDestructive: false,
            help: "Touches the trigger file that the Munki launchd job watches. Next agent wake-up (within ~10s) does a full Munki run.",
            buildCommand: { _ in "touch /private/tmp/.com.googlecode.munki.managedinstall.launchd" }
        ),
        QuickAction(
            id: "munkiCheckOnly", label: "Munki: check only",
            category: .munki, icon: "magnifyingglass.circle", fields: [],
            tabLabel: "munki-check", isDestructive: false,
            help: "Asks the Munki server what's available without downloading or installing anything. Good first step when troubleshooting why a host isn't getting an update.",
            buildCommand: { _ in "sudo /usr/local/munki/managedsoftwareupdate --checkonly -v" }
        ),
        QuickAction(
            id: "munkiInstallOnly", label: "Munki: install only",
            category: .munki, icon: "square.and.arrow.down.fill", fields: [],
            tabLabel: "munki-install", isDestructive: false,
            help: "Installs whatever Munki has already cached locally. Skips the network check phase — useful when a prior --checkonly already staged the packages.",
            buildCommand: { _ in "sudo /usr/local/munki/managedsoftwareupdate --installonly -v" }
        ),
        QuickAction(
            id: "munkiAuto", label: "Munki: auto run",
            category: .munki, icon: "arrow.triangle.2.circlepath.circle.fill", fields: [],
            tabLabel: "munki-auto", isDestructive: false,
            help: "Full Munki cycle: check, download, install, post-install. Equivalent to what the scheduled launchd job does on its own.",
            buildCommand: { _ in "sudo /usr/local/munki/managedsoftwareupdate --auto" }
        ),
        QuickAction(
            id: "munkiTailMSULog", label: "Munki: tail ManagedSoftwareUpdate log",
            category: .munki, icon: "doc.text", fields: [],
            tabLabel: "munki-tail-msu", isDestructive: false,
            help: "Follows the high-level Munki log live. ⌃C in the terminal tab to stop.",
            buildCommand: { _ in "tail -n2 -f /Library/Managed\\ Installs/Logs/ManagedSoftwareUpdate.log" }
        ),
        QuickAction(
            id: "munkiTailInstallLog", label: "Munki: tail install log",
            category: .munki, icon: "doc.text.below.ecg", fields: [],
            tabLabel: "munki-tail-install", isDestructive: false,
            help: "Follows the per-package installer output Munki writes during install phase. ⌃C in the terminal tab to stop.",
            buildCommand: { _ in "tail -n2 -f /Library/Managed\\ Installs/Logs/install.log" }
        ),
        QuickAction(
            id: "munkiShowConfig", label: "Munki: show config",
            category: .munki, icon: "gearshape.fill", fields: [],
            tabLabel: "munki-config", isDestructive: false,
            help: "Dumps Munki's effective configuration — repo URL, client identifier, catalogs, manifest, etc.",
            buildCommand: { _ in "sudo /usr/local/munki/managedsoftwareupdate --show-config" }
        ),
        QuickAction(
            id: "munkiReadRepoURL", label: "Munki: read repo URL",
            category: .munki, icon: "link", fields: [],
            tabLabel: "munki-repo-url", isDestructive: false,
            help: "Prints just the SoftwareRepoURL Munki is configured to talk to.",
            buildCommand: { _ in "defaults read /Library/Preferences/ManagedInstalls SoftwareRepoURL" }
        ),

        // MARK: - MunkiReport

        QuickAction(
            id: "mrRunNow", label: "MunkiReport: run now",
            category: .munkiReport, icon: "antenna.radiowaves.left.and.right", fields: [],
            tabLabel: "mr-run", isDestructive: false,
            help: "Forces the MunkiReport agent to gather and push inventory to the server immediately.",
            buildCommand: { _ in "sudo /usr/local/munkireport/munkireport-runner" }
        ),
        QuickAction(
            id: "mrVersion", label: "MunkiReport: version",
            category: .munkiReport, icon: "number.circle", fields: [],
            tabLabel: "mr-version", isDestructive: false,
            help: "Prints the installed MunkiReport client version on the host.",
            buildCommand: { _ in "defaults read /Library/Preferences/MunkiReport.plist Version" }
        ),
        QuickAction(
            id: "mrBaseURL", label: "MunkiReport: read base URL",
            category: .munkiReport, icon: "globe", fields: [],
            tabLabel: "mr-base", isDestructive: false,
            help: "Prints which MunkiReport server URL this host is configured to report to.",
            buildCommand: { _ in "sudo defaults read /Library/Preferences/MunkiReport BaseUrl" }
        ),
        QuickAction(
            id: "mrDetectXRescan", label: "MunkiReport: DetectX rescan",
            category: .munkiReport, icon: "shield.lefthalf.filled.badge.checkmark", fields: [],
            tabLabel: "detectx", isDestructive: false,
            help: "Triggers a full DetectX Swift scan and writes the result into the MunkiReport cache so the next inventory submission picks it up.",
            buildCommand: { _ in
                "sudo /Applications/Utilities/DetectX\\ Swift.app/Contents/MacOS/DetectX\\ Swift search -aj /usr/local/munkireport/scripts/cache/detectx.json"
            }
        ),

        // MARK: - Packages

        QuickAction(
            id: "pkgListReceipts", label: "List installed receipts",
            category: .packages, icon: "list.bullet.rectangle", fields: [],
            tabLabel: "pkg-list", isDestructive: false,
            help: "Lists every package receipt the macOS package database knows about. Useful for finding the exact bundle identifier to feed `pkgutil --forget`.",
            buildCommand: { _ in "pkgutil --pkgs" }
        ),
        QuickAction(
            id: "pkgForget", label: "Forget package receipt…",
            category: .packages, icon: "minus.rectangle",
            fields: [.init(id: "receipt", label: "Receipt ID",
                           placeholder: "com.example.MyPackage", kind: .text)],
            tabLabel: "pkg-forget", isDestructive: false,
            help: "Removes the receipt record without uninstalling the package itself. Lets a re-install run again as if the package had never been installed.\n\nTip: run \"List installed receipts\" first to copy the exact ID.",
            buildCommand: { v in "sudo pkgutil --forget \(shq(v["receipt"] ?? ""))" }
        ),
        QuickAction(
            id: "pkgAppVersion", label: "Check app version…",
            category: .packages, icon: "info.circle",
            fields: [.init(id: "app", label: "App name (without .app)",
                           placeholder: "Firefox", kind: .text)],
            tabLabel: "app-version", isDestructive: false,
            help: "Reads the kMDItemVersion Spotlight metadata for /Applications/<name>.app.",
            buildCommand: { v in
                "mdls -name kMDItemVersion \(shq("/Applications/\(v["app"] ?? "").app"))"
            }
        ),
        QuickAction(
            id: "pkgCodeSign", label: "Check code signature…",
            category: .packages, icon: "checkmark.seal",
            fields: [.init(id: "app", label: "App name (without .app)",
                           placeholder: "Firefox", kind: .text)],
            tabLabel: "code-sign", isDestructive: false,
            help: "Dumps the full code-signing identity for /Applications/<name>.app — useful for verifying Developer ID and timestamp.",
            buildCommand: { v in
                "codesign -dv --verbose=4 \(shq("/Applications/\(v["app"] ?? "").app"))"
            }
        ),
        QuickAction(
            id: "pkgInspectMobileconfig", label: "Inspect mobileconfig…",
            category: .packages, icon: "doc.badge.gearshape",
            fields: [.init(id: "path", label: "Path to .mobileconfig",
                           placeholder: "/path/to/profile.mobileconfig", kind: .text)],
            tabLabel: "mobileconfig", isDestructive: false,
            help: "Extracts the signer certificates from a signed .mobileconfig file so you can verify which authority issued the profile.",
            buildCommand: { v in
                "openssl pkcs7 -inform DER -print_certs -in \(shq(v["path"] ?? ""))"
            }
        ),

        // MARK: - Diagnostics

        QuickAction(
            id: "diagConsoleUser", label: "Logged-in console user",
            category: .diagnostics, icon: "person.crop.circle", fields: [],
            tabLabel: "console-user", isDestructive: false,
            help: "Prints the user currently logged in at the console (the physical display). Empty / `_loginwindow` means no GUI user.",
            buildCommand: { _ in "stat -f %Su /dev/console" }
        ),
        QuickAction(
            id: "diagListUsers", label: "List local users",
            category: .diagnostics, icon: "person.2.fill", fields: [],
            tabLabel: "users", isDestructive: false,
            help: "Lists real local user accounts (system accounts starting with `_` are filtered out).",
            buildCommand: { _ in "dscl . list /Users | grep -v '_'" }
        ),
        QuickAction(
            id: "diagFindIP", label: "Find IP (en0)",
            category: .diagnostics, icon: "network", fields: [],
            tabLabel: "ip-en0", isDestructive: false,
            help: "Prints the IPv4 address bound to the primary Ethernet/Wi-Fi interface (en0).",
            buildCommand: { _ in "ifconfig en0 | grep 'inet ' | awk '{print $2}'" }
        ),
        QuickAction(
            id: "diagDuByFolder", label: "Disk usage by folder",
            category: .diagnostics, icon: "externaldrive.badge.questionmark", fields: [],
            tabLabel: "du-root", isDestructive: false,
            help: "Top 30 largest folders two levels deep from /. Slow on big disks — give it a minute.",
            buildCommand: { _ in "du -hd 2 / 2>/dev/null | sort -hr | head -30" }
        ),
        QuickAction(
            id: "diagTopMemory", label: "Top memory hogs",
            category: .diagnostics, icon: "memorychip", fields: [],
            tabLabel: "top-mem", isDestructive: false,
            help: "One-shot snapshot of the top 20 processes ranked by resident memory.",
            buildCommand: { _ in "top -l 1 -o rsize -n 20" }
        ),

        // MARK: - Time Machine

        QuickAction(
            id: "tmListSnapshots", label: "List local snapshots",
            category: .timeMachine, icon: "clock.arrow.circlepath", fields: [],
            tabLabel: "tm-list", isDestructive: false,
            help: "Lists APFS local snapshots Time Machine has taken on the boot volume — useful when a host is suddenly low on space.",
            buildCommand: { _ in "tmutil listlocalsnapshots /" }
        ),
        QuickAction(
            id: "tmDeleteSnapshots", label: "Delete all local snapshots",
            category: .timeMachine, icon: "trash.fill", fields: [],
            tabLabel: "tm-delete", isDestructive: true,
            help: "Removes every Time Machine local snapshot on the boot volume. Reclaims disk space when local snapshots have grown to consume significant free space. Server-side TM backups are not affected.",
            buildCommand: { _ in
                "for d in $(tmutil listlocalsnapshotdates | grep '-'); do sudo tmutil deletelocalsnapshots \"$d\"; done"
            }
        ),

        // MARK: - BlueConnect Fleet

        QuickAction(
            id: "fleetKickstart", label: "BlueConnect agent: kickstart",
            category: .fleet, icon: "bolt.circle.fill", fields: [],
            tabLabel: "bsc-kick", isDestructive: false,
            help: "Restarts the BlueConnect (BlueSky) launchd agent on the host. Use when a Mac's tunnel is stuck or you've just rotated keys server-side.",
            buildCommand: { _ in "sudo launchctl kickstart -k system/com.solarwindsmsp.bluesky" }
        ),

        // MARK: - Fix Annoyances (additions)

        QuickAction(
            id: "finderShowHidden", label: "Finder: show hidden files",
            category: .fixAnnoyances, icon: "eye", fields: [],
            tabLabel: "finder-hidden", isDestructive: false,
            help: "Toggles Finder's AppleShowAllFiles default to true and restarts Finder so the change takes effect. Dotfiles will be visible until reverted.",
            buildCommand: { _ in
                "defaults write com.apple.Finder AppleShowAllFiles true && killall Finder"
            }
        ),
        QuickAction(
            id: "finderTitleBarIcons", label: "Finder: show window title-bar icons",
            category: .fixAnnoyances, icon: "macwindow", fields: [],
            tabLabel: "finder-titleicons", isDestructive: false,
            help: "Restores the small folder icon Finder windows used to show next to the title — handy for dragging the proxy icon. Restarts Finder.",
            buildCommand: { _ in
                "defaults write com.apple.universalaccess showWindowTitlebarIcons -bool true && killall Finder"
            }
        ),

        // MARK: - System (additions)

        QuickAction(
            id: "sysSwVers", label: "macOS version",
            category: .system, icon: "apple.logo", fields: [],
            tabLabel: "sw-vers", isDestructive: false,
            help: "Prints the macOS product name, version and build number.",
            buildCommand: { _ in "sw_vers" }
        ),
        QuickAction(
            id: "sysHardwareOverview", label: "Hardware overview",
            category: .system, icon: "cpu", fields: [],
            tabLabel: "hw-overview", isDestructive: false,
            help: "system_profiler's hardware data type — model, chip, serial, RAM, etc.",
            buildCommand: { _ in "system_profiler SPHardwareDataType" }
        ),
        QuickAction(
            id: "sysBatteryHealth", label: "Battery health",
            category: .system, icon: "battery.75percent", fields: [],
            tabLabel: "battery", isDestructive: false,
            help: "system_profiler's power data type — battery cycle count, condition, and AC adapter status. Desktops will mostly show AC info only.",
            buildCommand: { _ in "system_profiler SPPowerDataType" }
        ),
        QuickAction(
            id: "sysBootHistory", label: "Boot history",
            category: .system, icon: "power", fields: [],
            tabLabel: "boots", isDestructive: false,
            help: "Last ten boots/reboots from `last reboot`.",
            buildCommand: { _ in "last reboot | head" }
        ),
        QuickAction(
            id: "sysSleepWake", label: "Sleep/wake reasons (recent)",
            category: .system, icon: "moon.zzz", fields: [],
            tabLabel: "sleep-wake", isDestructive: false,
            help: "Last 50 sleep/wake events from pmset's log. Useful for figuring out why a Mac keeps waking up overnight.",
            buildCommand: { _ in
                "pmset -g log | grep -e 'Wake reason' -e ' Sleep ' | tail -50"
            }
        ),
        QuickAction(
            id: "sysAwakeAssertions", label: "What's keeping the Mac awake",
            category: .system, icon: "exclamationmark.bubble", fields: [],
            tabLabel: "assertions", isDestructive: false,
            help: "Active power assertions — apps holding `PreventUserIdleSystemSleep` or similar. Useful when a laptop won't sleep on its own.",
            buildCommand: { _ in "pmset -g assertions" }
        ),
        QuickAction(
            id: "sysHIDIdle", label: "HID idle time (seconds)",
            category: .system, icon: "hand.point.up", fields: [],
            tabLabel: "hid-idle", isDestructive: false,
            help: "Seconds since the last keyboard/mouse input. Zero means someone's actively at the machine right now.",
            buildCommand: { _ in
                "ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'"
            }
        ),

        // MARK: - Security & MDM

        QuickAction(
            id: "secSIPStatus", label: "SIP status",
            category: .security, icon: "lock.fill", fields: [],
            tabLabel: "sip", isDestructive: false,
            help: "Reports whether System Integrity Protection is enabled. Should be \"enabled\" on every production Mac.",
            buildCommand: { _ in "csrutil status" }
        ),
        QuickAction(
            id: "secGatekeeperStatus", label: "Gatekeeper status",
            category: .security, icon: "checkmark.shield", fields: [],
            tabLabel: "gatekeeper", isDestructive: false,
            help: "Reports whether Gatekeeper signature/notarization checking is enabled.",
            buildCommand: { _ in "spctl --status" }
        ),
        QuickAction(
            id: "secMDMEnrollment", label: "MDM enrollment status",
            category: .security, icon: "building.columns", fields: [],
            tabLabel: "mdm", isDestructive: false,
            help: "Shows whether the device is enrolled in an MDM, and whether the enrollment was DEP-driven.",
            buildCommand: { _ in "profiles status -type enrollment" }
        ),
        QuickAction(
            id: "secListProfiles", label: "List installed profiles",
            category: .security, icon: "doc.text.fill", fields: [],
            tabLabel: "profiles", isDestructive: false,
            help: "Every configuration profile installed on the Mac, system + user scope. Includes payloads installed by MDM.",
            buildCommand: { _ in "sudo profiles list" }
        ),

        // MARK: - Disk & Spotlight

        QuickAction(
            id: "diskList", label: "List disks",
            category: .disk, icon: "externaldrive", fields: [],
            tabLabel: "diskutil-list", isDestructive: false,
            help: "All disks, partitions and APFS volumes as seen by diskutil.",
            buildCommand: { _ in "diskutil list" }
        ),
        QuickAction(
            id: "diskAPFSList", label: "APFS containers",
            category: .disk, icon: "internaldrive", fields: [],
            tabLabel: "apfs-list", isDestructive: false,
            help: "APFS containers and volumes including the Sealed System Volume + Data volume role.",
            buildCommand: { _ in "diskutil apfs list" }
        ),
        QuickAction(
            id: "diskBootInfo", label: "Boot volume info",
            category: .disk, icon: "info.bubble", fields: [],
            tabLabel: "boot-info", isDestructive: false,
            help: "diskutil info on `/` — size, free space, encryption state, mount point.",
            buildCommand: { _ in "diskutil info /" }
        ),
        QuickAction(
            id: "spotlightStatus", label: "Spotlight: status (boot vol)",
            category: .disk, icon: "magnifyingglass", fields: [],
            tabLabel: "mdutil-status", isDestructive: false,
            help: "Whether Spotlight indexing is currently enabled on the boot volume, and whether indexing is in progress.",
            buildCommand: { _ in "mdutil -s /" }
        ),
        // Spotlight rebuild (merged Quick + Full Reset — mode picker)
        QuickAction(
            id: "spotlightRebuild",
            label: "Spotlight: rebuild…",
            category: .disk, icon: "arrow.triangle.2.circlepath",
            fields: [
                .init(id: "mode", label: "Mode",
                      placeholder: "", kind: .picker([
                        .init(label: "Quick — erase + reindex (mdutil -E)", value: "quick"),
                        .init(label: "Full reset — off → wipe → on → reindex",  value: "full"),
                      ]), defaultValue: "quick"),
            ],
            tabLabel: "spotlight-rebuild", isDestructive: true,
            help: """
            Quick mode: Apple's documented one-shot — `sudo mdutil -E /` erases and rebuilds the Spotlight index. Try this first.

            Full reset: heavier path when the quick rebuild doesn't clear up a stuck Spotlight. Runs four steps in order:

            1. `sudo mdutil -i off /` — disable indexing
            2. `sudo rm -rf /.Spotlight-V100/Store-V*` — wipe the on-disk index
            3. `sudo mdutil -i on /` — re-enable indexing
            4. `sudo mdutil -E /` — force a full erase + reindex

            Either mode triggers a background reindex that can run for tens of minutes — search results will be incomplete until it finishes.
            """,
            buildCommand: { v in
                if v["mode"] == "full" {
                    return [
                        "sudo mdutil -i off /",
                        "sudo rm -rf /.Spotlight-V100/Store-V*",
                        "sudo mdutil -i on /",
                        "sudo mdutil -E /",
                        "echo 'Spotlight full reset complete. Indexing will run in the background.'",
                    ].joined(separator: " && ")
                }
                return "sudo mdutil -E /"
            }
        ),

        // MARK: - Email

        QuickAction(
            id: "mailRebuildEnvelopeIndex",
            label: "Mail: rebuild envelope index (console user)",
            category: .email, icon: "envelope.badge", fields: [],
            tabLabel: "mail-rebuild", isDestructive: false,
            help: """
            Fixes the classic Mail.app symptoms: spinning beachball on launch, messages missing from a mailbox, search returning nothing. The envelope index is Mail's local SQLite cache of message metadata — Mail rebuilds it from scratch on next launch when it's missing.

            Steps run:

            1. Identify the console (GUI) user.
            2. Quit Mail.app gracefully via osascript (no-op if not running).
            3. Find the user's latest `~/Library/Mail/V*` directory.
            4. Rename every `Envelope Index*` file with a timestamped `.broken-<date>` suffix so the user can recover if needed.

            After this finishes, have the user reopen Mail — it'll rebuild the index automatically (can take a few minutes on a large mailbox). Suggest running "Spotlight: rebuild index (quick)" too if Mail search stays empty after the rebuild.
            """,
            buildCommand: { _ in
                #"""
                CONSOLE_USER=$(stat -f%Su /dev/console); \
                CONSOLE_UID=$(id -u "$CONSOLE_USER"); \
                USER_HOME=$(eval echo ~$CONSOLE_USER); \
                # Quit Mail gracefully — but the osascript MUST run
                # inside the console user's GUI launchd session. The
                # previous script invoked osascript as the SSH user
                # (ladmin), and Apple Events from a non-GUI session
                # can't reach an app owned by another user, so the
                # tell-to-quit silently no-op'd. Mail kept running
                # and the index files got renamed under its open
                # SQLite handles.
                echo "▶ asking Mail.app to quit in $CONSOLE_USER's session…"; \
                sudo -u "$CONSOLE_USER" launchctl asuser "$CONSOLE_UID" osascript -e 'tell application "Mail" to quit' 2>/dev/null || true; \
                # Poll for Mail's PID to disappear (up to 8s). Some
                # mailboxes take a couple seconds to flush state on
                # close. Renaming the index while the handle is open
                # is what corrupted the rebuild last time.
                for i in 1 2 3 4 5 6 7 8; do \
                  pgrep -u "$CONSOLE_USER" -x Mail >/dev/null 2>&1 || break; \
                  sleep 1; \
                done; \
                # Belt and suspenders — force-quit if Mail ignored the
                # graceful request (background sync, modal sheet, etc).
                if pgrep -u "$CONSOLE_USER" -x Mail >/dev/null 2>&1; then \
                  echo "▶ Mail didn't honor the graceful quit; force-killing…"; \
                  pkill -u "$CONSOLE_USER" -x Mail >/dev/null 2>&1 || true; \
                  sleep 1; \
                fi; \
                echo "▶ Mail confirmed exited"; \
                # `~/Library` is mode 700 on the console user's home,
                # so an ssh session as ladmin can't list inside it.
                # sudo -u <consoleUser> for every read into that
                # tree — the previous version silently fell into the
                # "No Mail data found" branch even when V10/ existed,
                # because the host-side `ls` got permission-denied.
                # Walk EVERY V* directory rather than guess "latest" —
                # old V7 dirs can have newer mtimes than the in-use
                # V10/V11 from leftover filesystem operations, so
                # `ls -td | head -1` was picking a stale dir with no
                # Envelope Index in it and reporting "already rebuilt".
                # Iterating every V* is harmless: each gets recursively
                # scanned for "Envelope Index*" files, found ones get
                # the timestamped suffix, missing ones are no-op.
                V_DIRS=$(sudo -u "$CONSOLE_USER" sh -c "ls -1d \"$USER_HOME/Library/Mail/V\"*/ 2>/dev/null"); \
                if [ -n "$V_DIRS" ]; then \
                  TS=$(date +%Y%m%d-%H%M%S); \
                  RENAMED_TOTAL=0; \
                  RENAMED_TOTAL_FILE=$(mktemp); \
                  echo 0 > "$RENAMED_TOTAL_FILE"; \
                  echo "$V_DIRS" | while IFS= read -r v_dir; do \
                    FILES=$(sudo -u "$CONSOLE_USER" find "$v_dir" -type f -name "Envelope Index*" 2>/dev/null); \
                    if [ -n "$FILES" ]; then \
                      echo "$FILES" | while IFS= read -r f; do \
                        sudo -u "$CONSOLE_USER" mv "$f" "${f}.broken-${TS}" && echo "Renamed: $f" && echo $(($(cat "$RENAMED_TOTAL_FILE")+1)) > "$RENAMED_TOTAL_FILE"; \
                      done; \
                    fi; \
                  done; \
                  RENAMED_TOTAL=$(cat "$RENAMED_TOTAL_FILE"); \
                  rm -f "$RENAMED_TOTAL_FILE"; \
                  if [ "$RENAMED_TOTAL" -gt 0 ]; then \
                    echo "Done — renamed $RENAMED_TOTAL Envelope Index file(s). Have $CONSOLE_USER reopen Mail to rebuild."; \
                  else \
                    echo "No Envelope Index files found in any of: $(echo "$V_DIRS" | tr '\n' ' ')"; \
                    echo "Either Mail's index has already been rebuilt, or this Mac stores Mail data in a non-standard location."; \
                  fi; \
                else \
                  echo "No Mail data found for $CONSOLE_USER under $USER_HOME/Library/Mail. Confirm Mail.app has been launched at least once on this Mac."; \
                fi
                """#
            }
        ),

        // MARK: - Privacy & TCC

        // TCC: reset one service (merged Camera/Mic/Screen Recording/A11y)
        QuickAction(
            id: "tccResetService", label: "Reset TCC permissions…",
            category: .privacy, icon: "exclamationmark.shield",
            fields: [
                .init(id: "service", label: "Service",
                      placeholder: "", kind: .picker([
                        .init(label: "Camera",            value: "Camera"),
                        .init(label: "Microphone",        value: "Microphone"),
                        .init(label: "Screen Recording",  value: "ScreenCapture"),
                        .init(label: "Accessibility",     value: "Accessibility"),
                      ]), defaultValue: "Camera"),
            ],
            tabLabel: "tcc-reset", isDestructive: false,
            help: "Clears every app's grant for the chosen TCC service. Apps will re-prompt the next time they request access — Screen Recording specifically needs to be re-approved in System Settings → Privacy & Security.",
            buildCommand: { v in "tccutil reset \(v["service"] ?? "Camera")" }
        ),
        QuickAction(
            id: "tccResetAllForBundle", label: "Reset all permissions for one app…",
            category: .privacy, icon: "exclamationmark.shield",
            fields: [.init(id: "bundle", label: "Bundle identifier",
                           placeholder: "com.zoom.xos", kind: .text)],
            tabLabel: "tcc-reset-bundle", isDestructive: false,
            help: "Clears every TCC permission grant the named bundle has — Camera, Mic, Screen Recording, Accessibility, Files & Folders, etc. Useful when an app has gotten itself wedged in a half-permission state.",
            buildCommand: { v in "tccutil reset All \(shq(v["bundle"] ?? ""))" }
        ),

        // MARK: - Process & App

        QuickAction(
            id: "procRestartFinder", label: "Restart Finder",
            category: .processApp, icon: "macwindow.on.rectangle", fields: [],
            tabLabel: "kill-finder", isDestructive: false,
            help: "Kills the Finder process. launchd restarts it immediately. Use when Finder is unresponsive.",
            buildCommand: { _ in "killall Finder" }
        ),
        QuickAction(
            id: "procRestartDock", label: "Restart Dock",
            category: .processApp, icon: "dock.rectangle", fields: [],
            tabLabel: "kill-dock", isDestructive: false,
            help: "Kills the Dock. launchd restarts it. Also resets Mission Control state. Use when the Dock has gone weird.",
            buildCommand: { _ in "killall Dock" }
        ),
        QuickAction(
            id: "procRestartSystemUI", label: "Restart SystemUIServer (menu bar)",
            category: .processApp, icon: "menubar.rectangle", fields: [],
            tabLabel: "kill-sus", isDestructive: false,
            help: "Restarts the menu bar / status item process. Use when menu bar items are stuck or invisible.",
            buildCommand: { _ in "killall SystemUIServer" }
        ),
        // Large on-screen message via `largetype`. Flag names verified
        // from `largetype --help`:
        //   --font-family <sans-serif|monospace|system|CustomFontName>
        //   --color <rrggbb>
        //   --background-color <rrggbbaa>
        //   --hide-after <seconds>
        //
        // Picker values are the literal strings largetype expects (hex
        // codes for colors, family names for fonts). Each picker has
        // a sentinel "" / "default" option that emits no flag so we
        // stay on largetype's built-in defaults.
        // Native macOS notification banner — `osascript display
        // notification` talks to the system-wide NotificationCenter
        // daemon, which doesn't need session attachment, so this works
        // over SSH-as-ladmin even when the console user is someone
        // different. Doesn't render fullscreen like Large Type, but
        // there's no sudo / no setup / no NOPASSWD requirement.
        QuickAction(
            id: "notifyUser", label: "Notify User…",
            category: .miscellaneous, icon: "bell.badge.fill",
            fields: [
                .init(id: "msg", label: "Message",
                      placeholder: "Tech support is on the way", kind: .text),
                .init(id: "title", label: "Title",
                      placeholder: "BlueConnect", kind: .text,
                      defaultValue: "BlueConnect"),
                .init(id: "sound", label: "Sound",
                      placeholder: "", kind: .picker([
                        .init(label: "Default (silent)", value: ""),
                        .init(label: "Submarine",  value: "Submarine"),
                        .init(label: "Glass",      value: "Glass"),
                        .init(label: "Funk",       value: "Funk"),
                        .init(label: "Hero",       value: "Hero"),
                        .init(label: "Ping",       value: "Ping"),
                        .init(label: "Pop",        value: "Pop"),
                        .init(label: "Tink",       value: "Tink"),
                        .init(label: "Blow",       value: "Blow"),
                        .init(label: "Sosumi",     value: "Sosumi"),
                        .init(label: "Basso",      value: "Basso"),
                      ]), defaultValue: ""),
            ],
            tabLabel: "notify", isDestructive: false,
            help: "Shows a macOS notification banner to whoever's at the screen. Smaller / less attention-grabbing than Large Type. The BlueConnect Helper requirement is covered by the orange notice below.",
            buildCommand: { v in
                // AppleScript string literal: double-quoted, with
                // backslash + double-quote escaped. Single quotes are
                // NOT string delimiters in AppleScript — wrapping
                // values in shell single quotes (via shq) made
                // osascript bark "syntax error: Expected … but found
                // unknown token". The outer shq() then wraps the whole
                // script in shell single quotes for safe pass-through
                // to `osascript -e`.
                func asStr(_ s: String) -> String {
                    let esc = s
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                    return "\"\(esc)\""
                }
                let msg = asStr(v["msg"] ?? "")
                let titleRaw = (v["title"] ?? "").isEmpty
                    ? "BlueConnect"
                    : (v["title"] ?? "BlueConnect")
                let title = asStr(titleRaw)
                let sound = (v["sound"] ?? "").trimmingCharacters(in: .whitespaces)
                var script = "display notification \(msg) with title \(title)"
                if !sound.isEmpty {
                    script += " sound name \(asStr(sound))"
                }
                // Payload is: `osascript -e '<applescript>'`. The
                // AppleScript string literals are double-quoted; the
                // outer shell wrap is single-quoted (via `shq`). When
                // we try to write that into a job file via `echo "…"`,
                // the outer-double-quotes collide with the inner-
                // double-quotes and the shell strips them — producing
                // a broken AppleScript like `display notification
                // today with title BlueConnect` (no quotes around the
                // values). Confirmed by reading a stuck job on the
                // wire. Fix: base64-encode the whole payload locally
                // and decode into the job file on the target. Base64
                // has no shell-special chars, so single-quoting is
                // bulletproof.
                let payload = "osascript -e \(shq(script))"
                let payloadB64 = Data(payload.utf8).base64EncodedString()
                // Cross-user GUI dispatch via the GUI Helper LaunchAgent
                // (installed by the "Setup: Install GUI Helper" Quick
                // Action). Job file lands in the world-writable inbox;
                // the agent — already running in the console user's
                // session — picks it up via WatchPaths and runs the
                // osascript call in that session, so the notification
                // appears in the right NotificationCenter.
                // `set +H` disables zsh history expansion so `!` in
                // messages survives down to osascript.
                return #"""
                set +H; \
                INBOX="/Library/Application Support/BlueConnect/inbox"; \
                if [ ! -d "$INBOX" ]; then \
                  echo "ERROR: GUI Helper is not installed on this Mac."; \
                  echo "Run the 'Setup: Install GUI Helper' Quick Action first."; \
                  exit 1; \
                fi; \
                consoleUser=$(stat -f%Su /dev/console); \
                [ -z "$consoleUser" -o "$consoleUser" = "root" ] && { echo "no console user — nobody to notify"; exit 1; }; \
                JOB="$INBOX/notify-$(uuidgen).job"; \
                echo '\#(payloadB64)' | base64 -D > "$JOB"; \
                echo "Notification queued for '$consoleUser' (job: $(basename "$JOB"))."
                """#
            }
        ),

        // GUI Helper installer — replaces the older NOPASSWD-sudo path.
        //
        // Installs a tiny Aqua-session LaunchAgent that watches an
        // inbox directory and executes job files as the logged-in GUI
        // user. After install, cross-user GUI Quick Actions (Large
        // Type / Notify User) drop a job file into the inbox and the
        // agent (already running in the console user's session) picks
        // it up and runs the GUI app with full WindowServer access.
        //
        // Trade-off vs. NOPASSWD sudo: requires one sudo prompt at
        // install time (to write to /Library and /usr/local/bin), but
        // afterwards NOTHING needs sudo. No standing root privilege is
        // granted to the SSH user — only the LaunchAgent (running as
        // the GUI user, in their own session) has GUI access.
        //
        // Files installed:
        //   /usr/local/bin/blueconnect-gui-helper           (755 root:wheel)
        //   /Library/LaunchAgents/xyz.hellocomputer.blueconnect-helper.plist  (644 root:wheel)
        //   /Library/Application Support/BlueConnect/inbox/ (0777 root:wheel — world-writable drop folder)
        //
        // Idempotent: re-running overwrites helper + plist and reloads
        // the agent. Safe to re-run after macOS upgrades.
        QuickAction(
            id: "setupGuiHelper",
            label: "Setup: Install GUI Helper",
            category: .miscellaneous, icon: "wand.and.rays",
            fields: [],
            tabLabel: "setup-gui-helper", isDestructive: true,
            help: """
            **ONE-TIME per Mac.** Installs a LaunchAgent that lets BlueConnect display chat and fullscreen notifications in the logged-in user's session without granting standing root.

            Note: Fullscreen texts require Largetype — [github.com/abdusco/largetype](https://github.com/abdusco/largetype).

            **TWO ways to install:**

            1. Install [BlueConnectHelper.pkg](https://github.com/echoparkbaby/BlueConnect-Admin/releases/latest/download/BlueConnectHelper.pkg) (signed/notarized).
            2. Run this Quick Action. It prompts once for sudo, installs the files, and loads the agent for the current console user.

            **Files installed:**

            - `/usr/local/bin/blueconnect-gui-helper` — worker script
            - `/usr/local/bin/blueconnect-chat` — chat client (universal binary)
            - `/Library/LaunchAgents/xyz.hellocomputer.blueconnect-helper.plist` — Aqua-session LaunchAgent
            - `/Library/Application Support/BlueConnect/inbox/` — job drop folder (world-writable)

            **Uninstall options:**

            1. Run **Setup: Uninstall GUI Helper** from Miscellaneous.
            2. Paste the command below into Terminal on the target Mac.
            """,
            copyableCommand: "sudo launchctl bootout gui/$(id -u $(stat -f%Su /dev/console)) /Library/LaunchAgents/xyz.hellocomputer.blueconnect-helper.plist && sudo rm /Library/LaunchAgents/xyz.hellocomputer.blueconnect-helper.plist /usr/local/bin/blueconnect-gui-helper /usr/local/bin/blueconnect-chat && sudo rm -rf '/Library/Application Support/BlueConnect'",
            buildCommand: { _ in
                // The helper script + LaunchAgent plist are base64-
                // encoded at build time so we don't have to fight
                // shell heredoc / quoting / indentation when emitting
                // them as part of a single SSH command line.
                let helperScript = """
                #!/bin/bash
                # blueconnect-gui-helper — runs in the Aqua session of
                # the logged-in GUI user (loaded by /Library/Launch-
                # Agents/xyz.hellocomputer.blueconnect-helper.plist).
                # Watches /Library/Application Support/BlueConnect/inbox
                # via WatchPaths in the plist; on each fire, walks every
                # *.job file there, hands its contents to /bin/sh ONLY
                # if it matches the allowlisted prefixes, and deletes
                # the file. Anything else is logged and dropped.
                #
                # Allowlist is the security boundary: even if a local
                # user gets a job file into the sticky-shared inbox,
                # they can only invoke commands BlueConnect already
                # supports. No arbitrary shell.
                INBOX="/Library/Application Support/BlueConnect/inbox"
                LOG="$HOME/Library/Logs/blueconnect-helper.log"
                mkdir -p "$(dirname "$LOG")"
                for job in "$INBOX"/*.job; do
                  [ -e "$job" ] || continue
                  # Filename-based target-user routing. Filenames like
                  # `notify-<uuid>.for-jennifer.job` are only processed
                  # by jennifer's helper; everyone else's helper sees
                  # the suffix, skips the file, leaves it for the
                  # correct user to grab. Unsuffixed filenames are
                  # untargeted (first-helper-wins, legacy behavior).
                  base=$(basename "$job")
                  case "$base" in
                    *.for-*.job)
                      target=$(echo "$base" | sed -n 's/.*\\.for-\\([^.]*\\)\\.job$/\\1/p')
                      if [ -n "$target" ] && [ "$target" != "$USER" ]; then
                        continue
                      fi
                      ;;
                  esac
                  cmd=$(cat "$job")
                  # Owner check: only files dropped by an admin-group
                  # user (or root) are accepted. `stat -f%Su` returns
                  # the owner's short name; `id -Gn <name>` lists the
                  # owner's groups. macOS admin users are in `admin`.
                  owner=$(stat -f%Su "$job" 2>/dev/null)
                  rm -f "$job"
                  if [ -z "$owner" ]; then
                    echo "$(date '+%F %T') [$USER] REJECTED (no owner)" >> "$LOG"
                    continue
                  fi
                  if [ "$owner" != "root" ] && ! id -Gn "$owner" 2>/dev/null | tr ' ' '\\n' | grep -qx admin; then
                    echo "$(date '+%F %T') [$USER] REJECTED non-admin owner '$owner': $cmd" >> "$LOG"
                    continue
                  fi
                  case "$cmd" in
                    /usr/local/bin/largetype\\ *|\\
                    /usr/local/bin/blueconnect-chat\\ *|\\
                    osascript\\ -e\\ *)
                      echo "$(date '+%F %T') [$USER] ALLOW [$owner]: $cmd" >> "$LOG"
                      # Background the GUI command and disown so the
                      # helper can keep processing the queue without
                      # waiting for the user to close a chat window
                      # (which would block largetype/notify jobs
                      # behind it). nohup prevents launchd from
                      # killing the child when this helper exits.
                      nohup /bin/sh -c "$cmd" </dev/null >> "$LOG" 2>&1 &
                      ;;
                    *)
                      echo "$(date '+%F %T') [$USER] REJECTED (not allowlisted) [$owner]: $cmd" >> "$LOG"
                      ;;
                  esac
                done
                """
                let plist = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>Label</key>
                    <string>xyz.hellocomputer.blueconnect-helper</string>
                    <key>ProgramArguments</key>
                    <array>
                        <string>/usr/local/bin/blueconnect-gui-helper</string>
                    </array>
                    <key>WatchPaths</key>
                    <array>
                        <string>/Library/Application Support/BlueConnect/inbox</string>
                    </array>
                    <key>LimitLoadToSessionType</key>
                    <string>Aqua</string>
                    <key>StandardErrorPath</key>
                    <string>/tmp/blueconnect-helper.err.log</string>
                    <!-- Critical for our spawn-and-exit model: by
                         default launchd nukes every process in the
                         job's process group when the job exits. We
                         spawn long-running GUI children (largetype,
                         blueconnect-chat) and need them to outlive
                         the helper's brief inbox-walk. true here
                         tells launchd to leave them alone. -->
                    <key>AbandonProcessGroup</key>
                    <true/>
                </dict>
                </plist>
                """
                let helperB64 = Data(helperScript.utf8).base64EncodedString()
                let plistB64  = Data(plist.utf8).base64EncodedString()
                // Chat client install: ContentView intercepts this
                // Quick Action's run path and SCPs the bundled chat
                // binary to /tmp/blueconnect-chat BEFORE this script
                // executes (inline base64 would push the total SSH
                // command past the BSC-nc-tunnel's truncation point —
                // empirically ~320KB). The shell-script side just
                // moves the staged file into place IF it's there;
                // missing /tmp/blueconnect-chat is non-fatal (the
                // helper + Large Type + Notify User still work).
                let chatInstallBlock = #"""
                if [ -f /tmp/blueconnect-chat ]; then \
                  sudo install -m 755 -o root -g wheel /tmp/blueconnect-chat /usr/local/bin/blueconnect-chat; \
                  rm -f /tmp/blueconnect-chat; \
                  sudo xattr -dr com.apple.quarantine /usr/local/bin/blueconnect-chat 2>/dev/null || true; \
                fi; \

                """#
                let chatStep = #"""
                echo "▶ installing chat client (/usr/local/bin/blueconnect-chat — if /tmp/blueconnect-chat is staged)…"; \

                """#
                return #"""
                set -e; \
                echo "▶ priming sudo (will prompt for password if not cached)…"; \
                sudo -v; \
                echo "▶ creating /Library/Application Support/BlueConnect/{inbox,chat,chat/sessions} (0777)…"; \
                sudo mkdir -p "/Library/Application Support/BlueConnect/inbox"; \
                sudo chmod 0777 "/Library/Application Support/BlueConnect/inbox"; \
                sudo mkdir -p "/Library/Application Support/BlueConnect/chat/sessions"; \
                sudo chmod 0777 "/Library/Application Support/BlueConnect/chat"; \
                sudo chmod 0777 "/Library/Application Support/BlueConnect/chat/sessions"; \
                echo "▶ installing helper script (/usr/local/bin/blueconnect-gui-helper)…"; \
                echo "\#(helperB64)" | base64 -D | sudo tee /usr/local/bin/blueconnect-gui-helper > /dev/null; \
                sudo chmod 0755 /usr/local/bin/blueconnect-gui-helper; \
                sudo chown root:wheel /usr/local/bin/blueconnect-gui-helper; \
                echo "▶ installing LaunchAgent plist (/Library/LaunchAgents/xyz.hellocomputer.blueconnect-helper.plist)…"; \
                echo "\#(plistB64)" | base64 -D | sudo tee /Library/LaunchAgents/xyz.hellocomputer.blueconnect-helper.plist > /dev/null; \
                sudo chmod 0644 /Library/LaunchAgents/xyz.hellocomputer.blueconnect-helper.plist; \
                sudo chown root:wheel /Library/LaunchAgents/xyz.hellocomputer.blueconnect-helper.plist; \
                \#(chatStep)\#(chatInstallBlock)echo "▶ bootstrapping LaunchAgent into every active Aqua session…"; \
                consoleUser=$(stat -f%Su /dev/console); \
                LOADED=""; \
                SKIPPED=""; \
                for u in $(/usr/bin/who | /usr/bin/awk '{print $1}' | /usr/bin/sort -u); do \
                  [ "$u" = "root" ] && continue; \
                  uid=$(id -u "$u" 2>/dev/null) || continue; \
                  [ -z "$uid" ] && continue; \
                  sudo launchctl bootout "gui/$uid" /Library/LaunchAgents/xyz.hellocomputer.blueconnect-helper.plist 2>/dev/null || true; \
                  if sudo launchctl bootstrap "gui/$uid" /Library/LaunchAgents/xyz.hellocomputer.blueconnect-helper.plist 2>/dev/null; then \
                    LOADED="$LOADED $u"; \
                  else \
                    SKIPPED="$SKIPPED $u"; \
                  fi; \
                done; \
                if [ -n "$LOADED" ]; then \
                  echo "✅ GUI helper installed on $(hostname). Loaded for:$LOADED. Console user: $consoleUser."; \
                  [ -n "$SKIPPED" ] && echo "   (no Aqua session for:$SKIPPED — they'll pick it up on next login)"; \
                else \
                  echo "✅ GUI helper installed on $(hostname). No active GUI sessions found — will auto-load on next login."; \
                fi
                """#
            }
        ),

        // Setup: Uninstall — the inverse of setupGuiHelper. Removes
        // the LaunchAgent (booting it out of every active Aqua
        // session first), the helper script, the chat client, and
        // the world-writable inbox + chat session dirs. Idempotent —
        // running it on a Mac that doesn't have the helper just
        // succeeds with no-ops. Pair this with the per-host install
        // path for ad-hoc cleanup; for Munki-deployed installs the
        // uninstall path is "remove from manifest" instead.
        QuickAction(
            id: "uninstallGuiHelper",
            label: "Setup: Uninstall GUI Helper",
            category: .miscellaneous, icon: "trash",
            fields: [],
            tabLabel: "uninstall-gui-helper", isDestructive: true,
            help: """
            Removes the GUI Helper from this Mac — undoes **Setup: Install GUI Helper**. Large Type, Notify User, and Chat will stop working on this Mac until the helper is reinstalled.

            **What gets removed:**

            - `/usr/local/bin/blueconnect-gui-helper` — worker script
            - `/usr/local/bin/blueconnect-chat` — chat client
            - `/Library/LaunchAgents/xyz.hellocomputer.blueconnect-helper.plist` — LaunchAgent (booted out first)
            - `/Library/Application Support/BlueConnect/` — inbox + chat sessions (full directory)

            Safe to run on a Mac that doesn't have the helper installed — every step is idempotent. For Munki-deployed installs, prefer removing the pkg from the manifest so Munki manages the uninstall instead.
            """,
            buildCommand: { _ in
                // Single SSH-friendly line so the BSC tunnel doesn't
                // need to handle multi-line shell. `|| true` on each
                // step so partial installs (only some files present)
                // still complete instead of failing on the first
                // missing path.
                #"""
                set -e; \
                echo "▶ priming sudo (will prompt for password if not cached)…"; \
                sudo -v; \
                PLIST="/Library/LaunchAgents/xyz.hellocomputer.blueconnect-helper.plist"; \
                if [ -f "$PLIST" ]; then \
                  echo "▶ booting LaunchAgent out of every active Aqua session…"; \
                  for u in $(/usr/bin/who | /usr/bin/awk '{print $1}' | /usr/bin/sort -u); do \
                    [ "$u" = "root" ] && continue; \
                    uid=$(id -u "$u" 2>/dev/null) || continue; \
                    [ -z "$uid" ] && continue; \
                    sudo launchctl bootout "gui/$uid" "$PLIST" 2>/dev/null || true; \
                  done; \
                else \
                  echo "▶ no LaunchAgent plist found — skipping bootout"; \
                fi; \
                echo "▶ removing files (/usr/local/bin/blueconnect-{gui-helper,chat}, LaunchAgent plist, app-support dir)…"; \
                sudo rm -f "$PLIST"; \
                sudo rm -f /usr/local/bin/blueconnect-gui-helper; \
                sudo rm -f /usr/local/bin/blueconnect-chat; \
                sudo rm -rf "/Library/Application Support/BlueConnect"; \
                echo "✅ GUI helper uninstalled from $(hostname)."
                """#
            }
        ),

        QuickAction(
            id: "largeTypeShow", label: "Large Type",
            category: .miscellaneous, icon: "textformat.size",
            fields: [
                .init(id: "msg", label: "Message",
                      placeholder: "Tech support is on the way", kind: .text),
                // Target-user picker removed: the GUI Helper LaunchAgent
                // runs in the console user's Aqua session and can only
                // dispatch GUI apps to whoever's at the screen — there's
                // nothing useful for the user to pick. Auto-detection
                // happens shell-side in buildCommand.
                .init(id: "color", label: "Text color",
                      placeholder: "", kind: .picker([
                        .init(label: "White",        value: "ffffff"),
                        .init(label: "Black",        value: "000000"),
                        .init(label: "Red",          value: "ff0000"),
                        .init(label: "Orange",       value: "ff8000"),
                        .init(label: "Yellow",       value: "ffff00"),
                        .init(label: "Green",        value: "00ff00"),
                        .init(label: "Cyan",         value: "00ffff"),
                        .init(label: "Blue",         value: "0000ff"),
                        .init(label: "Purple",       value: "8000ff"),
                        .init(label: "Magenta",      value: "ff00ff"),
                        .init(label: "Pink",         value: "ff80c0"),
                        .init(label: "Gray",         value: "808080"),
                      ]), defaultValue: "ffffff"),
                .init(id: "bgcolor", label: "Background",
                      placeholder: "", kind: .picker([
                        .init(label: "Translucent black (default)",  value: "00000080"),
                        .init(label: "Opaque black",                 value: "000000ff"),
                        .init(label: "Opaque white",                 value: "ffffffff"),
                        .init(label: "Translucent white",            value: "ffffff80"),
                        .init(label: "Solid red",                    value: "ff0000ff"),
                        .init(label: "Solid green",                  value: "00ff00ff"),
                        .init(label: "Solid blue",                   value: "0000ffff"),
                        .init(label: "Solid yellow",                 value: "ffff00ff"),
                      ]), defaultValue: "00000080"),
                .init(id: "font", label: "Font",
                      placeholder: "", kind: .picker([
                        .init(label: "Futura",               value: "Futura"),
                        .init(label: "Sans-serif (default)", value: ""),
                        .init(label: "Monospace",            value: "monospace"),
                        .init(label: "System",               value: "system"),
                        .init(label: "Helvetica Neue",       value: "Helvetica Neue"),
                        .init(label: "Helvetica",            value: "Helvetica"),
                        .init(label: "Arial",                value: "Arial"),
                        .init(label: "Times New Roman",      value: "Times New Roman"),
                        .init(label: "Georgia",              value: "Georgia"),
                        .init(label: "Verdana",              value: "Verdana"),
                        .init(label: "Avenir",               value: "Avenir"),
                        .init(label: "Avenir Next",          value: "Avenir Next"),
                        .init(label: "Impact",               value: "Impact"),
                        .init(label: "American Typewriter",  value: "American Typewriter"),
                        .init(label: "Menlo",                value: "Menlo"),
                        .init(label: "Monaco",               value: "Monaco"),
                        .init(label: "Courier New",          value: "Courier New"),
                        .init(label: "Marker Felt",          value: "Marker Felt"),
                        .init(label: "Chalkboard SE",        value: "Chalkboard SE"),
                        .init(label: "Comic Sans MS",        value: "Comic Sans MS"),
                        .init(label: "Papyrus",              value: "Papyrus"),
                      ]), defaultValue: "Futura"),
                .init(id: "hide", label: "Auto-hide after",
                      placeholder: "", kind: .picker([
                        .init(label: "1 second",    value: "1"),
                        .init(label: "2 seconds",   value: "2"),
                        .init(label: "3 seconds",   value: "3"),
                        .init(label: "5 seconds",   value: "5"),
                        .init(label: "10 seconds",  value: "10"),
                        .init(label: "15 seconds",  value: "15"),
                        .init(label: "30 seconds",  value: "30"),
                        .init(label: "60 seconds",  value: "60"),
                        .init(label: "Don't auto-hide", value: "0"),
                      ]), defaultValue: "5"),
            ],
            tabLabel: "largetype", isDestructive: false,
            help: "Displays a full-screen text message in front of the user via [largetype](https://github.com/abdusco/largetype).",
            buildCommand: { v in
                let msg = shq(v["msg"] ?? "")
                let color   = (v["color"]   ?? "").trimmingCharacters(in: .whitespaces)
                let bg      = (v["bgcolor"] ?? "").trimmingCharacters(in: .whitespaces)
                let font    = (v["font"]    ?? "").trimmingCharacters(in: .whitespaces)
                let hideRaw = (v["hide"]    ?? "").trimmingCharacters(in: .whitespaces)
                let hide    = hideRaw.isEmpty ? "5" : hideRaw

                // largetype syntax: `largetype <text> [options]`
                var flags = ""
                if !font.isEmpty {
                    flags += " --font-family \(shq(font))"
                }
                if !color.isEmpty, color != "ffffff" {
                    flags += " --color \(shq(color))"
                }
                if !bg.isEmpty {
                    flags += " --background-color \(shq(bg))"
                }
                if hide != "0" {
                    flags += " --hide-after \(shq(hide))"
                }

                // Dispatch via the GUI Helper LaunchAgent inbox. The
                // agent runs in the console user's Aqua session so
                // largetype lands there with full WindowServer access
                // — no sudo / launchctl asuser needed at runtime, no
                // target-user picker needed (helper *only* dispatches
                // to whoever's at the screen).
                //
                // `set +H` disables zsh history expansion so messages
                // starting with `!` survive intact.
                return #"""
                set +H; \
                INBOX="/Library/Application Support/BlueConnect/inbox"; \
                if [ ! -d "$INBOX" ]; then \
                  echo "ERROR: GUI Helper is not installed on this Mac."; \
                  echo "Run the 'Setup: Install GUI Helper' Quick Action first."; \
                  exit 1; \
                fi; \
                consoleUser=$(stat -f%Su /dev/console); \
                [ -z "$consoleUser" -o "$consoleUser" = "root" ] && { echo "no console user — nothing to display to"; exit 1; }; \
                # Verify largetype is actually installed on the target.
                # It's third-party (abdusco/largetype) and not bundled
                # by the helper installer, so a missing binary is the
                # #1 reason "queued but nothing displays" — surface
                # the diagnostic up-front instead of silently writing
                # a job file that fires into the void.
                if [ ! -x /usr/local/bin/largetype ]; then \
                  echo "ERROR: /usr/local/bin/largetype is not installed."; \
                  echo "Get it from https://github.com/abdusco/largetype/releases and 'install -m 755 largetype /usr/local/bin/'."; \
                  exit 1; \
                fi; \
                CMD="/usr/local/bin/largetype \#(msg)\#(flags)"; \
                JOB="$INBOX/largetype-$(uuidgen).job"; \
                printf '%s\n' "$CMD" > "$JOB"; \
                echo "Large Type queued for '$consoleUser' (job: $(basename "$JOB"))."; \
                echo "Command: $CMD"; \
                echo "If nothing appears within ~2 seconds, tail the helper log:"; \
                echo "  ssh <host> 'tail -20 /Users/'$consoleUser'/Library/Logs/blueconnect-helper.log'"
                """#
            }
        ),

        QuickAction(
            id: "procForceQuit", label: "Force-quit by name…",
            category: .processApp, icon: "xmark.octagon",
            fields: [.init(id: "appname", label: "Process name (case-insensitive)",
                           placeholder: "Firefox", kind: .text)],
            tabLabel: "pkill", isDestructive: true,
            help: "Sends SIGTERM to every process whose name matches. Case-insensitive substring match — be specific so you don't kill the wrong thing.",
            buildCommand: { v in "pkill -f \(shq(v["appname"] ?? ""))" }
        ),

        // MARK: - Networking

        QuickAction(
            id: "netDNSState", label: "DNS resolver state",
            category: .networking, icon: "globe.americas", fields: [],
            tabLabel: "scutil-dns", isDestructive: false,
            help: "Current DNS resolver configuration as macOS sees it — including per-interface resolvers and search domains.",
            buildCommand: { _ in "scutil --dns | head -40" }
        ),
        QuickAction(
            id: "netDefaultGateway", label: "Default gateway",
            category: .networking, icon: "arrow.up.right.circle", fields: [],
            tabLabel: "route-default", isDestructive: false,
            help: "Which interface and gateway IP is the default route for IPv4 traffic.",
            buildCommand: { _ in "route -n get default" }
        ),
        QuickAction(
            id: "netListeningPorts", label: "Listening ports",
            category: .networking, icon: "ear", fields: [],
            tabLabel: "netstat-listen", isDestructive: false,
            help: "All TCP/UDP sockets currently in LISTEN state.",
            buildCommand: { _ in "netstat -an | grep LISTEN" }
        ),
        QuickAction(
            id: "netWifiSSID", label: "Current Wi-Fi SSID",
            category: .networking, icon: "wifi", fields: [],
            tabLabel: "wifi-ssid", isDestructive: false,
            help: "Name of the Wi-Fi network the host is currently associated with.",
            buildCommand: { _ in "networksetup -getairportnetwork en0" }
        ),
        QuickAction(
            id: "netFlushDNS", label: "Flush DNS cache",
            category: .networking, icon: "arrow.triangle.2.circlepath.icloud", fields: [],
            tabLabel: "flush-dns", isDestructive: false,
            help: "Clears the macOS DNS resolver cache + tells mDNSResponder to forget what it knows. Use when a host is still resolving an old IP after a DNS change.",
            buildCommand: { _ in "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder" }
        ),

        // MARK: - Logs

        QuickAction(
            id: "logsRecentErrors", label: "Recent errors (last 1h)",
            category: .logs, icon: "exclamationmark.triangle", fields: [],
            tabLabel: "log-errors", isDestructive: false,
            help: "Top 100 lines from the unified log over the last hour that mention `error` (case-insensitive). Useful for an at-a-glance \"is this Mac on fire\" check.",
            buildCommand: { _ in
                "log show --last 1h --style syslog | grep -i error | head -100"
            }
        ),
        QuickAction(
            id: "logsSoftwareUpdate", label: "Software Update log (last 1h)",
            category: .logs, icon: "arrow.down.circle.dotted", fields: [],
            tabLabel: "log-su", isDestructive: false,
            help: "Filters the unified log to the SoftwareUpdate subsystem over the last hour. Useful when `softwareupdate` or System Settings → Software Update is misbehaving.",
            buildCommand: { _ in
                "log show --last 1h --predicate 'subsystem == \"com.apple.SoftwareUpdate\"' --style syslog"
            }
        ),
    ]
}
