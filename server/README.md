# BlueSky Server Endpoints

These PHP endpoints and SQL migrations support the BlueConnect Admin macOS app.
Deploy them to the web root used by your BlueSky/BlueConnect server and make
sure the PHP process can read the environment variables the scripts expect.

## Layout

```text
server/
├── README.md
├── bs_auth.php
├── bs_health.json.php
├── bs_hosts.json.php
├── bs_host_action.json.php
├── bs_host_update.json.php
├── bs_categories.json.php
└── migrations/
    ├── 2026-05-03-categories-sort-order.sql
    ├── 2026-05-14-computers-blueconnect-columns.sql
    └── 2026-05-27-blocked-serials.sql
```

## Endpoints

- `bs_health.json.php` — unauthenticated health probe
- `bs_hosts.json.php` — authenticated host inventory
- `bs_host_action.json.php` — authenticated host actions
- `bs_host_update.json.php` — authenticated host field updates
- `bs_categories.json.php` — authenticated category CRUD + reorder

## Required environment

These scripts expect the following environment variables to be available to PHP:

- `WEBADMINPASS` — shared password for the Basic-auth protected endpoints (default
  auth mode)
- `WEBADMIN_AUTH` — optional auth mode selector; set to `db` to authenticate against
  the live web-admin password in the database instead of `WEBADMINPASS` (see
  _Authentication_)
- `MYSQLROOTPASS` — MySQL root password
- `MYSQLSERVER` — optional database host override; defaults to `db`
- `SERVERFQDN` — optional server hostname reported back to the app
- `BLUESKY_VERSION` — optional version fallback when no version file is present

## Deployment Notes

- Place the `.php` files where your web server can execute them.
- Place the `migrations/` directory somewhere your database deployment process
  can access it.
- If your web server strips environment variables, provide them through your
  process manager, container runtime, or another server-side mechanism before
  exposing these endpoints.
- After deployment, verify that unauthenticated and authenticated routes return
  the expected JSON responses.

## Schema Migration

`bs_categories.json.php` includes an idempotent migration that creates the
`bs_categories` table when needed and adds `sort_order` if it is missing.

The other migrations under `migrations/` add BlueConnect-specific columns
on the stock BSC `computers` table, and the `blocked_serials` table +
`bc_block_rogue_insert` trigger that `bs_host_action.json.php`'s "block"
action relies on. Apply each in date order:

```text
migrations/2026-05-03-categories-sort-order.sql
migrations/2026-05-14-computers-blueconnect-columns.sql
migrations/2026-05-27-blocked-serials.sql
```

using your normal MySQL administration workflow. `bs_host_action.json.php`
no longer auto-creates the `blocked_serials` table inline — it will return
a 500 with a clear error message if the migration hasn't been applied.

## Authentication

The authenticated endpoints share `bs_auth.php`, which supports two modes selected
by the `WEBADMIN_AUTH` environment variable:

- **`WEBADMINPASS` (default).** The supplied password is compared against the
  `WEBADMINPASS` env var; the username is ignored. This is the original behavior and
  remains the default.
- **`WEBADMIN_AUTH=db`.** The supplied username/password are verified against the
  live web-admin account in the database — `md5(password)` vs
  `membership_users.passMD5`, matching the web admin's own login, restricted to
  approved, non-banned accounts. Use this when the web-admin password can be changed
  from the UI: `WEBADMINPASS` is only a snapshot taken at container start, so it goes
  stale once the password is rotated, whereas DB auth always honors the current
  password. This mode reuses the `MYSQLROOTPASS` / `MYSQLSERVER` env the endpoints
  already use for their data queries.

If `WEBADMIN_AUTH` is unset and `WEBADMINPASS` is empty, the endpoints fall back to
`db` mode so a server that only configures the database still authenticates.

`bs_health.json.php` is intentionally unauthenticated and does not include
`bs_auth.php`.

## PHP Constraints

- PHP 7.1+
- `mbstring` is not required
- Invalid UTF-8 is scrubbed before JSON encoding
- Some deployments may require falling back to `/proc/1/environ` if standard
  process environment lookup is unavailable
