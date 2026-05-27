#!/bin/bash
# purge-blocked.sh — runs every minute from cron on the bluesky LXC.
# Walks the BlueSky.blocked_serials table and nukes any matching rows from
# `computers` (plus their key lines from authorized_keys) that snuck back in.
#
# Most blocks are already prevented by the BEFORE INSERT trigger that
# bs_host_action.json.php installs when you mark a host blocked. This script
# is the belt-and-suspenders layer: if a server-side path bypasses the trigger
# (a future BSC upgrade with SUPER-less DB user, a manual INSERT, etc.), the
# cron sweeps the stragglers within 60 seconds.
#
# Install: see ./install-blocklist-cron.sh (sets up the cron entry + logging).
# Run-from-anywhere safe — uses absolute paths derived from STACK_DIR.

set -euo pipefail

STACK_DIR="${STACK_DIR:-$HOME/docker/stacks/bluesky}"
LOG_FILE="${LOG_FILE:-$STACK_DIR/logs/purge-blocked.log}"
COMPOSE_FILE="$STACK_DIR/compose.yaml"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    printf '%s %s\n' "$(date -Iseconds)" "$*" >> "$LOG_FILE"
}

if [[ ! -f "$COMPOSE_FILE" ]]; then
    log "ERR: compose file not found at $COMPOSE_FILE — aborting"
    exit 1
fi

# Run everything inside the bluesky service container so we get the right
# $MYSQLROOTPASS env var, the right DB host, and direct access to
# /home/bluesky/.ssh/authorized_keys without needing host-side credentials.
#
# The container script:
#   1. Selects (blueskyid, serialnum) for any rows whose serial appears in
#      blocked_serials.
#   2. For each match: scrub the matching key line(s) from authorized_keys
#      (last-token match — same approach as bs_host_action.json.php's delete
#      path so we don't accidentally wipe other hosts), then DELETE the row.
#   3. Print a one-line summary per kill so the host-side log captures it.
purge_output=$(docker compose -f "$COMPOSE_FILE" exec -T bluesky bash -s <<'EOF' 2>&1 || true
set -euo pipefail

DB_HOST="${MYSQLSERVER:-db}"
DB_PASS="${MYSQLROOTPASS:-}"
AUTH_KEYS=/home/bluesky/.ssh/authorized_keys
MYSQL_ERR=$(mktemp)
trap 'rm -f "$MYSQL_ERR"' EXIT

if [[ -z "$DB_PASS" ]]; then
    echo "ERR: MYSQLROOTPASS not set in container env"
    exit 1
fi

# Pull pairs as tab-separated for safe parsing of serials with spaces.
# Surface mysql failures (don't fail-open silently) — wrong creds /
# missing blocked_serials table / network glitch should all show up
# in the cron log.
rows=$(mysql -h "$DB_HOST" -uroot -p"$DB_PASS" --batch --skip-column-names \
       -e "SELECT c.blueskyid, c.serialnum
           FROM BlueSky.computers c
           JOIN BlueSky.blocked_serials b ON c.serialnum = b.serial" \
       2>"$MYSQL_ERR")
mysql_rc=$?
if (( mysql_rc != 0 )); then
    # blocked_serials may not exist yet (no host has ever been blocked) —
    # treat ER_NO_SUCH_TABLE (1146) as a clean no-op, anything else as
    # an error.
    if grep -q '1146' "$MYSQL_ERR"; then
        exit 0
    fi
    echo "ERR: mysql SELECT failed (rc=$mysql_rc): $(cat "$MYSQL_ERR" | head -c 400)"
    exit 1
fi

if [[ -z "$rows" ]]; then
    exit 0
fi

# Take an exclusive flock on authorized_keys for the whole purge so we
# can't interleave with BSC's keymaster.sh (which also flocks) and lose
# updates. fd 9 is a conventional aux fd; -n would race, -w 5 caps the
# wait so a stuck keymaster doesn't hang cron forever.
exec 9>>"$AUTH_KEYS"
if ! flock -w 5 -x 9; then
    echo "ERR: couldn't get flock on $AUTH_KEYS within 5s"
    exit 1
fi

while IFS=$'\t' read -r bid serial; do
    [[ -z "$bid" ]] && continue

    # Defense in depth — schema says blueskyid is int(11) so this should
    # already be safe, but reject anything that's not pure digits before
    # interpolating into the DELETE.
    if ! [[ "$bid" =~ ^[0-9]+$ ]]; then
        echo "ERR: non-numeric bid=$bid serial=$serial — skipping"
        continue
    fi
    legacy="BlueSky-${bid}"

    # Scrub key line(s) by trailing-token match on EITHER the modern
    # (serial) or legacy (BlueSky-NN) comment. Holding flock 9 the whole
    # time. Rewrite via temp + mv keeps the rewrite atomic.
    if [[ -w "$AUTH_KEYS" ]]; then
        awk -v s="$serial" -v l="$legacy" '
            {
                line = $0
                gsub(/^[ \t]+|[ \t]+$/, "", line)
                if (line == "" || substr(line, 1, 1) == "#") { print; next }
                n = split(line, parts, /[ \t]+/)
                tok = parts[n]
                if (tok == s || tok == l) next
                print
            }
        ' "$AUTH_KEYS" > "${AUTH_KEYS}.tmp" \
          && mv "${AUTH_KEYS}.tmp" "$AUTH_KEYS"
    fi

    if ! mysql -h "$DB_HOST" -uroot -p"$DB_PASS" \
               -e "DELETE FROM BlueSky.computers WHERE blueskyid=${bid}" \
               2>"$MYSQL_ERR"; then
        echo "ERR: DELETE bid=$bid failed: $(cat "$MYSQL_ERR" | head -c 200)"
        continue
    fi

    echo "purged bid=${bid} serial=${serial}"
done <<< "$rows"

flock -u 9
EOF
)

if [[ -n "$purge_output" ]]; then
    while IFS= read -r line; do
        log "$line"
    done <<< "$purge_output"
fi
