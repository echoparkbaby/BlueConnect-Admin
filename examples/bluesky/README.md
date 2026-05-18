# BlueSkyConnect — Docker reference deployment

Working `docker-compose.yml` for running [BlueSkyConnect](https://github.com/BlueSkyTools/BlueSkyConnect) + the BlueConnect Admin server endpoints. Pulls the official `ghcr.io/blueskytools/blueskyconnect:latest` image (BSC v2.5.1 and later — the legacy `sphen/bluesky` Docker Hub repo is no longer updated) and layers the BlueConnect PHP endpoints + (optional) custom fail2ban action via individual file mounts.

## Files in this directory

| File | Purpose |
|---|---|
| `compose.yml` | The compose stack — `db` (MySQL 5.7) + `bluesky` (BSC). |
| `.env.example` | Required env vars with comments. Copy to `.env`, fill in. |

## What gets created when you run it

After `docker compose up -d` and a successful first request:

```
./bluesky/
├── compose.yml
├── .env                  ← your secrets (gitignored)
├── db/                   ← MySQL data (the `bluesky` schema lives here)
├── certs/                ← TLS certs BSC presents to clients
├── admin.ssh/            ← /home/admin/.ssh — keys for SSHing INTO the LXC
├── bluesky.ssh/          ← /home/bluesky/.ssh — your Mac fleet's pubkeys
├── bs_*.json.php (×5)    ← BlueConnect endpoints (deploy from this repo)
├── migrations/           ← SQL migrations (also deployed by deploy-server.sh)
└── sendEmail-whois-lines.local  ← optional fail2ban override (see below)
```

## Setup, end-to-end

```bash
# 1. Land here and grab the template
git clone https://github.com/echoparkbaby/BlueConnect-Admin.git
cd BlueConnect-Admin/examples/bluesky
cp .env.example .env
$EDITOR .env                           # fill in passwords, FQDN, SMTP

# 2. Create the bind-mount dirs the compose expects
mkdir -p db certs admin.ssh bluesky.ssh

# 3. Drop your TLS certs into ./certs/ — BSC expects:
#      ./certs/bluesky.crt  (full chain)
#      ./certs/bluesky.key  (private key)
#    Get them from Let's Encrypt / your CA. If you're fronting with
#    nginx-proxy-manager or Caddy, the proxy can terminate TLS instead
#    and you can leave ./certs/ minimal.

# 4. Deploy the BlueConnect PHP endpoints + the SQL migrations from
#    the BlueConnect repo root (one directory up from here):
cd ../..
./deploy-server.sh <user>@<host> <ssh-port> ~/path/to/this/bluesky-dir

# 5. Start the stack
cd examples/bluesky
docker compose up -d

# 6. Smoke test — also triggers the idempotent schema migration that
#    bs_hosts.json.php auto-applies on first hit (adds category,
#    favorite, notes, serialnum, notify, alert, email + index on
#    a stock BSC `computers` table). Safe to re-run.
curl -i http://localhost:8095/bs_health.json.php
# expected: HTTP 200, JSON body with `bs_health_ok`
```

The SQL files under `migrations/` ship for reference and for ops who
want to apply them manually before first request (e.g. provisioning
automation). The endpoints heal themselves regardless.

## Why so many file-level bind mounts?

The `bluesky` service mounts each of the five `bs_*.json.php` endpoint files **individually** rather than mounting the whole `./` directory at `/usr/local/bin/BlueSkyConnect/Server/html/`. That's intentional — a directory mount would shadow the rest of the stock BSC frontend that ships in the image (index.php, the auth handlers, assets, etc.). File-level mounts overlay just the five endpoints we add.

If you find yourself adding a new BlueConnect endpoint, the steps are:

1. Add the new `.php` file to your bind-mount directory.
2. Add one more file-level volume to compose.yml.
3. `docker compose up -d --force-recreate bluesky` to pick up the new mount.

## Ports

| Port | Direction | Purpose |
|---|---|---|
| `3122` | **PUBLIC** | Mac client reverse-tunnel SSH. Every BSC client phones home here. Open through your firewall. |
| `8095` | LAN only | BSC web admin / JSON endpoints. Front with NPM / Caddy / Traefik for HTTPS. Or expose on `:443` directly if you set up TLS in BSC itself instead of `USE_HTTP=1`. |

## Reverse-proxy setup (recommended)

The compose sets `USE_HTTP=1` so BSC serves plain HTTP on `:80` (mapped to host `:8095`). Front it with a reverse proxy for HTTPS:

- **nginx-proxy-manager**: add a proxy host pointing at `bluesky:8095` (or `<docker-host-ip>:8095` if cross-host), let NPM handle Let's Encrypt.
- **Caddy**: `bluesky.example.com { reverse_proxy bluesky:8095 }` — Caddy gets the cert automatically.
- **Traefik / Cloudflare Tunnel**: same idea, configure per their docs.

Whichever proxy you pick, BSC needs to receive `X-Forwarded-Proto: https` and `X-Forwarded-For` headers correctly — NPM and Caddy do this by default.

## Optional: fail2ban WHOIS lines

`sendEmail-whois-lines.local` is a custom fail2ban action that adds WHOIS info to brute-force alert emails. If you don't care about that, omit the bind mount — the upstream fail2ban actions ship in the image and work fine without it.

## Optional: Tailscale sidecar

If you want the BSC LXC reachable on your tailnet (e.g. so the BlueConnect Mac app can connect via Tailscale rather than over public Internet), add a sidecar service to the same compose. The official docs are at <https://tailscale.com/kb/1282/docker>. Minimal shape:

```yaml
  tailscale:
    image: tailscale/tailscale:latest
    container_name: tailscale-bluesky
    hostname: bluesky      # how the LXC appears in your tailnet
    environment:
      TS_AUTHKEY: ${TS_AUTHKEY}        # one-time tailnet enrollment key
      TS_STATE_DIR: /var/lib/tailscale
      TS_USERSPACE: "false"
      TS_EXTRA_ARGS: "--ssh"           # optional: enable Tailscale SSH
    volumes:
      - ./tailscale-state:/var/lib/tailscale
    cap_add: [NET_ADMIN, NET_RAW]
    devices: [/dev/net/tun]
    restart: unless-stopped
```

Add `TS_AUTHKEY=tskey-auth-…` to your `.env` (generate at <https://login.tailscale.com/admin/settings/keys>). The key is one-time-use — after the LXC joins the tailnet, the daemon stores its own credentials in `./tailscale-state/`.

## Troubleshooting

See the [main README troubleshooting section](../../README.md#troubleshooting) for the common errors (HTTP 404 on sign-in, `Unknown column 'category'`, missing env vars, etc.).
