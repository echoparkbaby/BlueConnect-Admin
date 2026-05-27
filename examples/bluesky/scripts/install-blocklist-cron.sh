#!/bin/bash
# install-blocklist-cron.sh — one-shot installer for the BlueConnect
# blocked-host cron sweeper on the bluesky LXC.
#
# Run this once on the bluesky LXC (10.0.0.184). Idempotent — re-running
# updates the cron line in place. Removes nothing existing.

set -euo pipefail

STACK_DIR="${STACK_DIR:-$HOME/docker/stacks/bluesky}"
SCRIPTS_DIR="$STACK_DIR/scripts"
LOG_DIR="$STACK_DIR/logs"
PURGE_SCRIPT="$SCRIPTS_DIR/purge-blocked.sh"
CRON_LINE="* * * * * STACK_DIR=$STACK_DIR $PURGE_SCRIPT"
CRON_MARKER="# blueconnect-blocklist purge"

if [[ ! -d "$STACK_DIR" ]]; then
    echo "ERR: stack dir not found: $STACK_DIR (override with STACK_DIR=…)"
    exit 1
fi

mkdir -p "$SCRIPTS_DIR" "$LOG_DIR"

# Place / update the purge script.
src_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ ! -f "$src_dir/purge-blocked.sh" ]]; then
    echo "ERR: purge-blocked.sh not next to this installer (expected $src_dir)"
    exit 1
fi
install -m 0755 "$src_dir/purge-blocked.sh" "$PURGE_SCRIPT"
echo "installed: $PURGE_SCRIPT"

# Drop a logrotate-friendly note so the log doesn't grow forever.
cat > "$LOG_DIR/.gitignore" <<'EOG' 2>/dev/null || true
*.log
EOG

# Splice the cron entry. Replace any prior `CRON_MARKER` line + the ONE
# cron entry that follows it. Adds both if missing.
#
# `skip=1` drops the marker line itself (via `next`) plus exactly one
# following line (the next iteration sees skip>0, decrements to 0, also
# `next`s). An earlier `skip=2` here off-by-oned and ate an extra line.
crontab_current=$(crontab -l 2>/dev/null || true)
crontab_new=$(printf '%s\n' "$crontab_current" \
              | awk -v marker="$CRON_MARKER" '
                  $0 == marker { skip=1; next }
                  skip > 0     { skip--; next }
                  { print }
              ')
crontab_new="${crontab_new%$'\n'}"$'\n'"$CRON_MARKER"$'\n'"$CRON_LINE"$'\n'
echo "$crontab_new" | crontab -

echo "cron installed:"
echo "  $CRON_LINE"
echo
echo "verify with:  crontab -l | grep -A1 blueconnect-blocklist"
echo "tail log:     tail -f $LOG_DIR/purge-blocked.log"
echo
echo "to disable:   crontab -e (delete the two lines)"
