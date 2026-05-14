#!/bin/bash
# sync-catalog.sh — generate a BlueConnect Admin catalog.json from a
# local directory of .pkg / .dmg files and optionally push everything
# (pkgs + catalog + sidecar metadata) to any rclone-supported backend
# in one shot.
#
# Use this when your storage backend (Dropbox, Nextcloud public share,
# S3/R2/GCS, OneDrive, GDrive, Box, etc.) doesn't run PHP so you can't
# use the dynamic `catalog.php` generator that ships with the app's
# server/ directory.
#
# One-time setup:
#   brew install rclone jq
#   rclone config       # → "n" → name e.g. "dropbox" / "nextcloud" → follow prompts
#
# Daily use:
#   1. Drop new .pkg / .dmg files into your local folder.
#   2. (Optional) Edit metadata.json in that same folder to add friendly
#      names, groups, descriptions, etc. — same shape as the PHP version.
#   3. Run:
#        ./sync-catalog.sh <local-dir> <baseURL> [<rclone-remote:path>] [kind]
#
# Args:
#   <local-dir>          Path to your local pkgs folder.
#   <baseURL>            Public URL prefix the *app* uses to fetch files.
#                          - Dropbox shared folder:  https://www.dropbox.com/scl/fo/<id>/?dl=1
#                          - Nextcloud public share: https://cloud.example.com/s/<token>
#                          - S3/R2/GCS:              https://bucket.example.com/path/
#   <rclone-remote:path> Optional. Omit to generate catalog.json only (no upload).
#                          - dropbox:pkgs
#                          - nextcloud:pkgs   (rclone webdav remote pointing at your share)
#                          - r2:my-bucket/pkgs
#   [kind]               "plain" (default) or "nextcloud". Tells the app how
#                        to build per-file download URLs. Use "nextcloud" for
#                        public-share folders served by Nextcloud.
#
# Examples:
#   ./sync-catalog.sh ~/pkgs https://cdn.example.com/pkgs/ r2:cdn/pkgs
#   ./sync-catalog.sh ~/pkgs https://cloud.example.com/s/abc123 nextcloud:pkgs nextcloud
#   ./sync-catalog.sh ~/pkgs https://www.dropbox.com/scl/fo/<id>/?dl=1   # local only
#
# Optional metadata.json sidecar in <local-dir> (same shape as catalog.php):
# {
#   "_catalogName": "MacFaqulty Standard",
#   "munkitools-6.3.1.4580.pkg": {
#     "name": "Munki tools 6.3x",
#     "group": "Munki",
#     "description": "Full Munki client",
#     "iconName": "shippingbox.fill"
#   },
#   "bluesky-uninstall.pkg": {
#     "name": "BlueSky uninstall",
#     "group": "Uninstall",
#     "destructive": true
#   }
# }

set -euo pipefail

LOCAL_DIR="${1:?usage: $0 <local-dir> <baseURL> [rclone-remote:path] [kind=plain|nextcloud]}"
BASE_URL="${2:?baseURL required (the public URL prefix the app should use)}"
RCLONE_REMOTE="${3:-}"
KIND="${4:-plain}"

command -v jq >/dev/null || { echo "✖ jq required:  brew install jq" >&2; exit 1; }
[ -d "$LOCAL_DIR" ] || { echo "✖ not a directory: $LOCAL_DIR" >&2; exit 1; }
case "$KIND" in plain|nextcloud) ;; *) echo "✖ kind must be 'plain' or 'nextcloud'" >&2; exit 1 ;; esac

cd "$LOCAL_DIR"

META_FILE=""
META_ARG="/dev/null"
if [ -f metadata.json ]; then
    META_FILE="metadata.json"
    META_ARG="metadata.json"
fi

# Enumerate installers (case-insensitive .pkg / .dmg) sorted ASCII.
# macOS `find` doesn't support -printf, so strip the leading "./".
file_list=$(find . -maxdepth 1 -type f \
    \( -iname '*.pkg' -o -iname '*.dmg' \) | sed 's|^\./||' | sort)

if [ -z "$file_list" ]; then
    echo "✖ no .pkg or .dmg files in $LOCAL_DIR" >&2
    exit 1
fi

# Build the JSON array of package entries, merging in metadata sidecar values.
packages_json=$(printf '%s\n' "$file_list" \
    | jq -R -s --slurpfile meta "$META_ARG" '
        ($meta[0] // {}) as $m |
        split("\n")
        | map(select(length > 0))
        | map(. as $f |
              (($m[$f]) // {}) as $entry |
              $entry + { file: $f, name: ($entry.name // ($f | sub("\\.[pP][kK][gG]$"; "") | sub("\\.[dD][mM][gG]$"; ""))) }
              | with_entries(select(.key | IN("name","file","command","group","description","iconName","destructive")))
        )')

catalog_name=$(jq -r '._catalogName // "Auto-Generated"' "$META_ARG" 2>/dev/null || echo "Auto-Generated")

# Write catalog.json
jq -n \
    --arg name "$catalog_name" \
    --arg baseURL "$BASE_URL" \
    --arg kind "$KIND" \
    --argjson packages "$packages_json" \
    '{name: $name, baseURL: $baseURL, kind: $kind, packages: $packages}' \
    > catalog.json

count=$(echo "$packages_json" | jq 'length')
echo "✓ catalog.json — $count package$([ "$count" = 1 ] || echo s) (kind=$KIND, baseURL=$BASE_URL)"

if [ -n "$RCLONE_REMOTE" ]; then
    command -v rclone >/dev/null || { echo "✖ rclone required:  brew install rclone" >&2; exit 1; }
    echo "▶ rclone sync . $RCLONE_REMOTE"
    rclone sync . "$RCLONE_REMOTE" \
        --include "*.pkg" --include "*.dmg" \
        --include "catalog.json" --include "metadata.json" \
        --progress
    echo "✓ synced to $RCLONE_REMOTE"
fi
