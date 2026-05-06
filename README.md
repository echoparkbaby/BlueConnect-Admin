# BlueConnect Admin

A native macOS admin client for [BlueSkyConnect](https://github.com/BlueSkyTools/BlueSkyConnect) — the SSH reverse-tunnel concentrator used to remote-support a Mac fleet. Lists every registered host, shows which ones are currently tunneled, and connects via SSH / Screen Share (VNC) / file upload (SCP) with one click.

![BlueConnect Admin screenshot](Resources/screenshot.png)

## Download

Grab the latest signed and notarized `.dmg` from the [Releases page](../../releases). Open the disk image and drag **BlueConnect Admin** into `/Applications`.

## Requirements

- A running [BlueSkyConnect](https://github.com/BlueSkyTools/BlueSkyConnect) server
- The five BlueConnect Admin PHP endpoints deployed on that server (see [Server setup](#server-setup))
- macOS 14 (Sonoma) or later
- An SSH key authorized on your BlueSkyConnect server
- BlueSky web admin credentials

## Server setup

Stock BlueSkyConnect ships an HTML admin UI but no JSON API. This Mac app needs five small read-mostly PHP endpoints (in `server/`) deployed once to your BSC server's web root. They don't change BSC's behavior — they translate the existing database state into JSON.

The fastest deploy is the included `deploy-server.sh`:

```sh
./deploy-server.sh <ssh-user>@<bsc-host> [ssh-port] [remote-path]
# defaults: ssh-port=22, remote-path=~/docker/stacks/bluesky
```

It scp's `server/*.php` and the `migrations/` directory to your BSC server. The categories migration runs idempotently on first request — no manual SQL needed.

Verify:

```sh
curl -i -u admin:$WEBADMINPASS https://<host>/bs_hosts.json.php
# expected: HTTP 200 with JSON body
```

If the app's login screen shows *"The server responded but doesn't have the BlueConnect Admin endpoints"*, that's the deploy step still missing.

## First launch

The login window asks for:

- **Server URL** — your BlueSky web admin, e.g. `https://bluesky.example.com`
- **Username / Password** — the same credentials you use for the BlueSky web UI (stored in macOS Keychain)
- **Use Touch ID** — optional biometric unlock + auto-lock timer

Then open **Settings** (⌘,) and confirm:

- **SSH host** — the BlueSky server hostname
- **SSH port** — typically `3122`
- **Admin SSH key path** — e.g. `~/.ssh/bluesky_admin`
- **Default remote user** — typically `admin`

That's it — the host list populates from the server.

## Features

- **Built-in terminal** — every SSH connection opens in a tab right inside the app (SwiftTerm). No external Terminal.app, no window juggling.
- **Drag-and-drop file transfer** — drop a file onto any host row in the table and a Send File window pops up with the source pre-filled. One click and it's on the remote Mac.
- **Send File window** — split-pane source/destination, live progress, ETA + transfer rate, quick-path destination buttons (Desktop / Downloads / Documents / Home / `/tmp`). After a successful transfer there's a **Copy file link** button that puts a clickable `file://` URL on your clipboard — paste it into iMessage or Mail and the recipient (the Mac you just sent to) opens straight to that file in Finder.
- **Local Network sidebar** — Bonjour discovers other Macs on your LAN with SSH and Screen Sharing enabled. One-click SSH or VNC, no tunnel needed.
- **Tailscale sidebar** — pulls peers from `tailscale status`, lists every reachable macOS / Linux machine across your tailnet. SSH icon for any peer, VNC for Macs that have Screen Sharing on. Bulk hide/show via the eye-slash button — skip the iPhones, ATVs, and Linux boxes you don't care about.
- **Touch ID lock** — biometric unlock with an auto-lock timer when the app is idle. Enable it in Settings.
- **Menu bar extra** — globe icon up top with quick host shortcuts. Goes red when the server is unreachable.
- **Categories** — drag to reorder, drag hosts between them, sticky favorites and recents.


### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘, | Open Settings |
| ⌘1 | Open SSH session to selected host |
| ⌘2 | Open VNC session to selected host |
| ⌘3 | Send File via SCP to selected host |
| ⌘F | Focus the host search |
| ⌘R | Refresh host list |
| ⌘D | Toggle favorite on selected host |
| ⌘W | Close active terminal tab (never closes the main window) |
| ⌘⇧W | Close all terminal tabs |
| ⌘⇧[ / ⌘⇧] | Previous / next terminal tab |
| ⌘\\ | Show Log |
| ⌘⇧L | Lock now (Touch ID re-required) |

## Building from source

```sh
git clone <this-repo>.git
cd BlueConnect-Admin
./build-app.sh
open "BlueConnect Admin.app"
```

`build-app.sh` runs `swift build -c release` and wraps the executable into a `.app` bundle for local use.

## Support the project

If BlueConnect Admin saves you time, a tip is always appreciated.

[<img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="48" />](https://buymeacoffee.com/echoparkbaby)

## License

[MIT](LICENSE) — © 2026 Brandon Walter.
