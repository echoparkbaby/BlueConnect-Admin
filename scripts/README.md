# BlueConnect helper packaging

`build-helper-pkg.sh` produces **`BlueConnectHelper.pkg`** — a signed,
optionally-notarized flat installer that bundles everything the
"Setup: Install GUI Helper (one-time)" Quick Action installs:

| Path | Mode | Source |
|------|------|--------|
| `/usr/local/bin/blueconnect-chat` | 0755 root:wheel | universal binary (arm64 + x86_64) lipo'd from per-arch `swift build` outputs |
| `/usr/local/bin/blueconnect-gui-helper` | 0755 root:wheel | `scripts/pkg/blueconnect-gui-helper` |
| `/Library/LaunchAgents/xyz.hellocomputer.blueconnect-helper.plist` | 0644 root:wheel | `scripts/pkg/xyz.hellocomputer.blueconnect-helper.plist` |
| `/Library/Application Support/BlueConnect/inbox` | 0777 | `postinstall` |
| `/Library/Application Support/BlueConnect/chat/sessions` | 0777 | `postinstall` |

The postinstall also calls `launchctl bootstrap gui/<uid>` for every
active Aqua session so the helper goes live without a logout/login.

## Why this exists

The per-host Setup Quick Action works one Mac at a time and requires
SSH access + a sudo prompt on each box. Munki distributes a `.pkg` to
the whole fleet on its next sync. Use this for any fleet of more than
~3 Macs.

## Architecture

The `blueconnect-chat` binary in the pkg is a **universal** Mach-O
(arm64 + x86_64) — same with the copy embedded in the app bundle by
`build-app.sh`. Verify with `lipo -info /usr/local/bin/blueconnect-chat`.
Works on both Apple Silicon and Intel fleet Macs without Rosetta.

The `blueconnect-gui-helper` is a bash script — arch-independent.

## What's NOT in the pkg

* **`largetype`** — third-party, unsigned, **x86_64 only** on
  Brandon's dev box. On Apple Silicon fleet Macs it runs via
  Rosetta if Rosetta is installed; otherwise the Large Type Quick
  Action will fail. If your fleet needs first-class Large Type,
  either deploy a universal-binary build of largetype separately
  (its repo has the recipe) or ensure Rosetta is installed
  fleet-wide via `softwareupdate --install-rosetta --agree-to-license`.
  Out of scope for redistribution in this pkg either way.
* **BlueConnect Admin.app** itself — the Mac app stays distributed
  via the GitHub Releases + Forgejo Releases path. The pkg only
  contains the on-target-Mac helper bits.

## Prereqs

In `.env-sign` (already gitignored):

```
SIGN_ID=Developer ID Application: <Your Name> (TEAMID)   # signs blueconnect-chat
PKG_SIGN_ID=Developer ID Installer: <Your Name> (TEAMID) # signs the .pkg
NOTARY_PROFILE=<keychain-profile-name>                    # only for --notarize
```

## Build

```sh
bash scripts/build-helper-pkg.sh
```

…produces `BlueConnectHelper.pkg` at the repo root, signed but
NOT notarized. Good for local testing.

```sh
bash scripts/build-helper-pkg.sh --notarize
```

…signs, submits to Apple's notary service, and staples. This is the
artifact that goes into Munki.

Version string is derived from the most recent git tag automatically
(matches what `build-app.sh` uses for the app bundle's
`CFBundleShortVersionString`).

## Deploying via Munki

```sh
munkiimport /path/to/BlueConnectHelper.pkg
# answer the prompts; suggested name: BlueConnect-Helper
# minimum_os_version: 13.0 (matches the app's macOS target)

# Add to relevant manifest(s):
#   munkitools-make manifest blueconnect-helper
#   or edit an existing manifest's managed_installs array
```

On the next Munki sync each enrolled Mac installs the helper.
Bootstraps into any active GUI session immediately; otherwise the
LaunchAgent loads on next login (LimitLoadToSessionType=Aqua handles
that automatically).

## Upgrading the pkg in the field

`pkgbuild --identifier xyz.hellocomputer.blueconnect-helper` ties
every build to the same identifier, so a newer pkg installed on top
replaces the old payload cleanly. The preinstall script `bootout`s
the live LaunchAgent first; postinstall re-bootstraps after the new
plist is in place. No reboot needed.

## Uninstall (in the field)

There's no built-in uninstaller pkg. Manual cleanup if needed:

```sh
sudo launchctl bootout "gui/$(id -u $(stat -f%Su /dev/console))" \
    /Library/LaunchAgents/xyz.hellocomputer.blueconnect-helper.plist
sudo rm /Library/LaunchAgents/xyz.hellocomputer.blueconnect-helper.plist
sudo rm /usr/local/bin/blueconnect-gui-helper /usr/local/bin/blueconnect-chat
sudo rm -rf "/Library/Application Support/BlueConnect"
```
