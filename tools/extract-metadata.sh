#!/bin/bash
# extract-metadata.sh — walk a pkg directory, read .pkg + .app metadata
# (xar PackageInfo / Info.plist), merge into metadata.json without
# clobbering human-curated fields.
#
# Usage:
#   ./extract-metadata.sh <pkgs-dir>
#
# Reads each .pkg with `xar -xf … PackageInfo Distribution`, pulls
# identifier + version + title. Reads each .app's Contents/Info.plist
# (only meaningful on macOS; Linux servers will skip them since they
# can't recurse into .app bundles). Merges into metadata.json such that:
#
#   * Extracted fields land under filename keys.
#   * Existing manual fields (name, group, description, iconName,
#     destructive, etc.) are NEVER overwritten.
#   * `_catalogName` is preserved.
#
# Drop in any cron / on-upload hook to keep the catalog rich without
# hand-editing.
#
# Run on the server you host packages on (Bluehost, Nextcloud VPS,
# wherever). Requires:
#   * xar   (apt/yum/brew)
#   * jq    (apt/yum/brew)
set -euo pipefail

DIR="${1:?usage: $0 <pkgs-dir>}"
[ -d "$DIR" ] || { echo "✖ not a directory: $DIR" >&2; exit 1; }
command -v xar >/dev/null || { echo "✖ xar required: apt/yum/brew install xar" >&2; exit 1; }
command -v jq  >/dev/null || { echo "✖ jq required: apt/yum/brew install jq"  >&2; exit 1; }

cd "$DIR"

existing="{}"
if [ -f metadata.json ]; then
    existing=$(cat metadata.json)
fi
out="$existing"

extract_attr() {
    # extract_attr <xml-file> <tag> <attr>
    grep -oE "<$2[^>]*\\s$3=\"[^\"]*\"" "$1" 2>/dev/null \
        | head -n1 \
        | sed -E "s/.*$3=\"([^\"]*)\".*/\\1/"
}

extract_tag_text() {
    # extract_tag_text <xml-file> <tag>
    grep -oE "<$2>[^<]*</$2>" "$1" 2>/dev/null \
        | head -n1 \
        | sed -E "s/<$2>(.*)<\\/$2>/\\1/"
}

count=0
for pkg in *.pkg; do
    [ -f "$pkg" ] || continue
    count=$((count + 1))
    tmp=$(mktemp -d)
    if ! xar -x -C "$tmp" -f "$pkg" PackageInfo Distribution 2>/dev/null; then
        rm -rf "$tmp"
        continue
    fi

    identifier=""
    version=""
    title=""

    if [ -f "$tmp/PackageInfo" ]; then
        identifier=$(extract_attr "$tmp/PackageInfo" "pkg-info" "identifier")
        version=$(extract_attr   "$tmp/PackageInfo" "pkg-info" "version")
    fi
    if [ -f "$tmp/Distribution" ]; then
        [ -z "$identifier" ] && identifier=$(extract_attr "$tmp/Distribution" "pkg-ref" "id")
        [ -z "$version" ]    && version=$(extract_attr    "$tmp/Distribution" "pkg-ref" "version")
        title=$(extract_tag_text "$tmp/Distribution" "title")
    fi
    rm -rf "$tmp"

    # Merge into out, preserving any existing manual fields per file.
    out=$(printf '%s' "$out" | jq \
        --arg f "$pkg" \
        --arg id "$identifier" \
        --arg ver "$version" \
        --arg title "$title" '
        . as $orig
        | (($orig[$f]) // {}) as $cur
        | ($cur
            + (if $id    != ""                                  then {bundleID: $id} else {} end)
            + (if $ver   != ""                                  then {version:  $ver} else {} end)
            + (if $title != "" and ($cur.name // "") == ""      then {name:     $title} else {} end)
          ) as $merged
        | $orig + {($f): $merged}')
done

# .app bundles (rare on a Linux server, common on a macOS share)
for app in *.app; do
    [ -d "$app" ] || continue
    plist="$app/Contents/Info.plist"
    [ -f "$plist" ] || continue
    count=$((count + 1))
    bundleID=""
    version=""
    build=""
    minSys=""
    title=""
    if command -v plutil >/dev/null; then
        bundleID=$(plutil -extract CFBundleIdentifier raw "$plist" 2>/dev/null || true)
        version=$( plutil -extract CFBundleShortVersionString raw "$plist" 2>/dev/null || true)
        build=$(   plutil -extract CFBundleVersion raw "$plist" 2>/dev/null || true)
        title=$(   plutil -extract CFBundleDisplayName raw "$plist" 2>/dev/null \
                || plutil -extract CFBundleName raw "$plist" 2>/dev/null || true)
        minSys=$(  plutil -extract LSMinimumSystemVersion raw "$plist" 2>/dev/null || true)
    elif command -v defaults >/dev/null; then
        bundleID=$(defaults read "$(pwd)/$app/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
        version=$(defaults  read "$(pwd)/$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)
    fi

    out=$(printf '%s' "$out" | jq \
        --arg f "$app" \
        --arg id "$bundleID" \
        --arg ver "$version" \
        --arg build "$build" \
        --arg title "$title" \
        --arg minSys "$minSys" '
        . as $orig
        | (($orig[$f]) // {}) as $cur
        | ($cur
            + (if $id    != ""                                   then {bundleID: $id}  else {} end)
            + (if $ver   != ""                                   then {version:  $ver} else {} end)
            + (if $build != ""                                   then {buildNumber: $build} else {} end)
            + (if $title != "" and ($cur.name // "") == ""       then {name:     $title} else {} end)
            + (if $minSys != ""                                  then {minSystem: $minSys} else {} end)
          ) as $merged
        | $orig + {($f): $merged}')
done

if [ "$count" -eq 0 ]; then
    echo "✖ no .pkg or .app files found in $DIR" >&2
    exit 1
fi

printf '%s\n' "$out" | jq . > metadata.json.tmp
mv metadata.json.tmp metadata.json
echo "✓ metadata.json updated ($count installer$([ "$count" = 1 ] || echo s) processed)"
