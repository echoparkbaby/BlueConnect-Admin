# BlueSky Server Endpoints

These PHP endpoints and SQL migrations support the BlueConnect Admin macOS app.
Deploy them to the web root used by your BlueSky/BlueConnect server and make
sure the PHP process can read the environment variables the scripts expect.

## Layout

```text
server/
├── README.md
├── bs_health.json.php
├── bs_hosts.json.php
├── bs_host_action.json.php
├── bs_host_update.json.php
├── bs_categories.json.php
└── migrations/
    └── 2026-05-03-categories-sort-order.sql
```

## Endpoints

- `bs_health.json.php` — unauthenticated health probe
- `bs_hosts.json.php` — authenticated host inventory
- `bs_host_action.json.php` — authenticated host actions
- `bs_host_update.json.php` — authenticated host field updates
- `bs_categories.json.php` — authenticated category CRUD + reorder

## Required environment

These scripts expect the following environment variables to be available to PHP:

- `WEBADMINPASS` — shared password for the Basic-auth protected endpoints
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

If you prefer to run the SQL manually instead of letting the endpoint perform
the migration during a request, apply:

```text
migrations/2026-05-03-categories-sort-order.sql
```

using your normal MySQL administration workflow.

## Authentication

The authenticated endpoints use HTTP Basic auth and compare the supplied
password against `WEBADMINPASS`. The username is not used for authorization.

## PHP Constraints

- PHP 7.1+
- `mbstring` is not required
- Invalid UTF-8 is scrubbed before JSON encoding
- Some deployments may require falling back to `/proc/1/environ` if standard
  process environment lookup is unavailable
