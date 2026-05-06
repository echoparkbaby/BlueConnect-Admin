#!/bin/bash
# One-shot deploy of the BlueConnect Admin server endpoints to a
# BlueSkyConnect host. Copies every PHP file in `server/` plus the
# migrations directory to the BSC web root via scp.
#
# Usage:
#   ./deploy-server.sh <ssh-user>@<host> [ssh-port] [remote-path]
#
# Defaults: ssh-port=22, remote-path=~/docker/stacks/bluesky
#
# Example (typical sphen/bluesky docker setup):
#   ./deploy-server.sh admin@bluesky.example.com 22
#
# After deploying, verify with:
#   curl -i -u admin:$WEBADMINPASS https://<host>/bs_hosts.json.php
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_TARGET="${1:?usage: $0 <ssh-user>@<host> [ssh-port=22] [remote-path=~/docker/stacks/bluesky]}"
SSH_PORT="${2:-22}"
REMOTE_PATH="${3:-~/docker/stacks/bluesky}"

cd "$PROJECT_ROOT/server"

echo "▶ Deploying PHP endpoints to $SSH_TARGET:$REMOTE_PATH (port $SSH_PORT)"
scp -P "$SSH_PORT" -p *.php "$SSH_TARGET:$REMOTE_PATH/"

echo "▶ Deploying migrations"
scp -P "$SSH_PORT" -pr migrations "$SSH_TARGET:$REMOTE_PATH/"

echo "✅ Deployed."
echo "   The bs_categories.json.php endpoint runs the categories migration"
echo "   idempotently on every request, so the schema will update on first use."
echo ""
echo "   Verify with:"
echo "     curl -i -u admin:\$WEBADMINPASS https://<host>/bs_hosts.json.php"
echo "   Expected: HTTP 200 + JSON body."
