# BlueSky server-side files

These PHP endpoints + SQL migrations live alongside the Mac app source.
The actual deployed copies sit at `~/docker/stacks/bluesky/` on the
BlueSkyConnect server, bind-mounted into the `sphen/bluesky:2.3.2`
container at `/usr/local/bin/BlueSky/Server/html/`.

Edit the host file directly; the bind mount means the container picks
up changes without restart. Apache/PHP re-reads on the next request.

## Layout

```
Server/
├── README.md                       (this file)
├── bs_health.json.php              GET unauthenticated health probe
├── bs_hosts.json.php               GET host inventory (Basic auth)
├── bs_host_action.json.php         POST selfdestruct/delete actions
├── bs_host_update.json.php         POST field updates (hostname, notes, …)
├── bs_categories.json.php          GET/POST/PUT/DELETE category CRUD + reorder
└── migrations/
    └── 2026-05-03-categories-sort-order.sql
```

## Schema migrations

`bs_categories.json.php` runs an idempotent migration on every request:

1. `CREATE TABLE IF NOT EXISTS bs_categories (...)` — pre-2026-05-02
   schemas didn't have it.
2. `ALTER TABLE bs_categories ADD COLUMN sort_order …` if missing.
3. Falls back gracefully (no `ORDER BY sort_order`, no sort_order in
   INSERT) if the ALTER hasn't taken effect yet, so partial deploys
   don't 500.
4. PUT (reorder) returns **409** with a clear message if `sort_order`
   is genuinely absent — should never trigger after step 2 lands.

If you'd rather run the migration as a one-shot SQL file (faster than
piggy-backing on a request), the same logic is in
`migrations/2026-05-03-categories-sort-order.sql`. Apply with:

```sh
ssh -p <ssh-port> <user>@<bluesky-host>
cd ~/docker/stacks/bluesky/
docker compose exec -T db mysql -uroot -p"$MYSQL_ROOT_PASSWORD" BlueSky \
  < migrations/2026-05-03-categories-sort-order.sql
```

(The `MYSQL_ROOT_PASSWORD` is in `~/docker/stacks/bluesky/.env`.)

## Pushing changes from this repo to the server

Make sure the server's `.bashrc` doesn't print anything (e.g. fastfetch)
*above* the interactive guard — non-interactive SCP/SSH inherits stdout
and any pre-guard banner breaks the protocol. Then:

```sh
cd Server
scp -P <ssh-port> *.php <user>@<bluesky-host>:~/docker/stacks/bluesky/
scp -P <ssh-port> -r migrations <user>@<bluesky-host>:~/docker/stacks/bluesky/
```

Bind mount means no container restart needed. To test:

```sh
curl -u "admin:$WEBADMINPASS" https://bluesky.example.com/bs_categories.json.php
```

## PHP constraints baked into these files

- PHP 7.1+ (`: void` is used). 7.0-only features removed.
- `mbstring` not installed — UTF-8 sanitization uses `preg_match('//u', $s)` + `iconv`.
- Apache strips env vars — `MYSQLROOTPASS` / `WEBADMINPASS` read from `/proc/1/environ`.
- Latin1 columns may carry UTF-8 bytes — scrub before `json_encode` or it silently returns `false`.
- `JSON_INVALID_UTF8_SUBSTITUTE` constant doesn't exist — don't use it.
