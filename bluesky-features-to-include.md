# BlueSky / BlueConnect — features to include

Living to-do list for the BlueConnect Admin Mac app and the BlueSky
server it talks to. Ordered by attack priority. Last updated 2026-05-03.

## 


---

## Tier 2 — distribution / hygiene

### 2. Developer ID sign + notarize the .app
**Problem:** `BlueConnect Admin.app` is ad-hoc signed. Anyone but you
gets a Gatekeeper "unidentified developer" warning.

**Fix:** Replace the `codesign --force --deep -s -` step in
`build-app.sh` with a real Developer ID cert, then run `xcrun notarytool
submit ... --wait` and `xcrun stapler staple`.

**Effort:** ~30 min once you have an Apple Developer membership and
the cert in your Keychain. One-time setup; subsequent builds just
re-sign.

### 3. Persist column widths
**Problem:** `TableColumnCustomization` already persists visibility and
order via `@SceneStorage("hostsTableColumns")`, but column widths reset
on relaunch.

**Fix:** Investigate whether `TableColumnCustomization` actually carries
widths in macOS 14 (Apple's docs are vague). If not, store widths in a
separate `@AppStorage` dict keyed by `customizationID`, and apply them
via `.width(min:ideal:max:)` per column on first appear.

**Effort:** Medium (1–2 hours of poking).

---

##

### 5. Server-side `last_observed_user` column
**Problem:** The "Last User" column was removed because it was tracked
client-side and only updated when *you* clicked something — useless.
The right place is the server.

**Fix:** Add a `last_observed_user VARCHAR(64)` column to `computers`.
Have the BlueSky server's existing check-in endpoints stamp it from the
SSH session's username on each tunnel handshake. Surface in
`bs_hosts.json.php` and re-add the column in the Mac app.

**Effort:** Medium. Server-side hook is the unknown; the Mac app side is
trivial because the column code is in git history.

### 6. Revisit `sphen/bluesky:dev2xx` upgrade
**Problem:** The 2026-05-02 attempt rolled back. dev2xx (v2.5.0) runs on
Ubuntu 20.04 with OpenSSH 8.2, which deprecates `ssh-rsa` host-key and
pubkey-accepted algorithms. None of the 310 Mac clients reconnected.
`pageHome.php` was also broken because the image lacks `php-xml`.

**Fix path:**
1. Push `HostkeyAlgorithms +ssh-rsa,PubkeyAcceptedAlgorithms +ssh-rsa`
   to every Mac client's `~/.ssh/config` for the bluesky tunnel host
   *first*, via your existing fleet tooling. Verify a sample
   reconnects against a dev2xx test stack.
2. Once the fleet has the override, swap the image, rebuild
   `pageHome.php` workarounds for missing `php-xml`, monitor reconnects.

**Effort:** Large. Coordinated rollout. Defer until you actually want a
dev2xx feature.

---

## Tier 4 — nice-to-haves

### 7. Per-host SSH option overrides
Currently SSH/VNC/SCP all use the global `serverFqdn`, `sshTunnelPort`,
`adminKeyPath`, `defaultRemoteUser`. A handful of weird hosts may need
per-host overrides (different identity file, custom port). Store as
JSON in the existing `notes` column or add a `host_options` column.

### 8. Connection history per host
The `ConnectPanel` shows "Recently Connected" as a single timestamp. A
collapsible "Last 10 sessions" list (kind+timestamp+user) would help
auditing. Local-only, stored in `RecentConnectStore` extended.

### 9. Bulk SSH command runner
Right-click selection → "Run command…" → opens a sheet with a
single-line input → spawns N parallel SSH sessions in the embedded
terminal pane, each in its own tab. Useful for fleet-wide one-liners.
Requires careful UX around output collation.

### 10. Apple Remote Desktop (ARD) integration

**Idea:** offer a third connect path next to SSH/VNC for hosts where
ARD is available. ARD adds observe-only mode, send-Unix-command without
PTY, install-package, lock-screen-with-message.

**Catch:** macOS doesn't expose a clean URL scheme that opens
`Apple Remote Desktop.app` with a target host pre-selected (the way
`vnc://` opens Screen Sharing.app). Two viable paths:

1. **AppleScript** automation — `tell application "Remote Desktop"` to
   open a saved task list / pre-configured "All Computers" entry. Works
   only if the host is already in ARD's database; otherwise scripted
   add-then-connect.
2. **Just open `vnc://`** — ARD-enrolled Macs respond to plain VNC the
   same way Screen Sharing does. Lose the ARD-only features but no app
   integration to write.

**Effort:** small if option 2 (already covered by current VNC button).
Medium if option 1 — needs OSA scripting + per-host ARD database
seeding. Worth doing only if you actually use the ARD-only features.

---

## Skip / defer

- **Drag preview during host drags.** `TableRow.draggable` doesn't
  accept a preview builder; restoring it would mean reverting to
  cell-level drag and breaking row-wide grab. Not worth it.
- **"Last User" via PTY scraping.** Brittle. Server-side column (#5)
  is the right way.
- **`ContentView.swift` refactor.** ~800 lines, long but works.
  Defer until something there is actually painful to change.
- **Test suite.** Zero coverage today. Most of the app is SwiftUI which
  is hard to unit-test. Smoke tests for `BlueSkyAPI` (mocked
  URLProtocol) would be the highest-value first cut, but only if you
  start hitting regressions.

---

## Recently completed

- 2026-05-03: Auto-lock-on-idle (Settings → Security picker, gated on
  Touch ID requirement)
- 2026-05-03: Drag-to-category fixed (plain-string Transferable, row-
  level drag)
- 2026-05-03: Window jumping fixed (NSWindow accessor + content min size)
- 2026-05-03: Login flow refactor (LoginView + Keychain + LockView)
- 2026-05-03: Hostname column click target restored
- 2026-05-03: Delete-key chooser dialog (plain / ⌘Del / ⌘⇧Del)
- 2026-05-03: All `onChange(of:perform:)` deprecations resolved
- 2026-05-03: Old DigitalOcean droplets decommissioned post-migration
