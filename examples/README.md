# BlueConnect server-side examples

Reference Docker deployments for the server-side pieces of a BlueConnect setup. Each subdirectory has a working `compose.yml` + `.env.example` + step-by-step README — sanitized from real homelab deployments, drop into place and tweak.

| Stack | What it runs | When you need it |
|---|---|---|
| [`bluesky/`](bluesky/) | BlueSkyConnect (`sphen/bluesky`) + MySQL 5.7 + the BlueConnect PHP endpoints | **Required.** The BSC server every Mac client phones home to and the BlueConnect Admin app reads from. |
| `munkireport/` (TODO) | MunkiReport-php + MySQL + the `blueconnect_api.php` JSON endpoint | Optional — only if you want host inventory inside the BlueConnect Admin app's Inventory tab. |

The Mac app itself doesn't need any of this if you're using **Skip — explore without a BlueSky server** mode on the login screen. The examples are for the server side.

## Quick start

```bash
git clone https://github.com/echoparkbaby/BlueConnect-Admin.git
cd BlueConnect-Admin/examples/bluesky
cp .env.example .env
$EDITOR .env
mkdir -p db certs admin.ssh bluesky.ssh
docker compose up -d
```

Full walkthrough lives in [`bluesky/README.md`](bluesky/README.md).
