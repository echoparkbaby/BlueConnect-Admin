#!/bin/bash
# End-to-end release: build → sign → dmg → notarize → staple → GitHub
# Release + Forgejo Release. Uploads two assets per release:
#   - BlueConnect-Admin.dmg     (the Mac app, drag-installer)
#   - BlueConnectHelper.pkg     (Munki-deployable chat helper + LaunchAgent;
#                                URL is hard-linked from the in-app
#                                "Setup: Install GUI Helper" Quick Action)
#
# Requires .env-sign with SIGN_ID, PKG_SIGN_ID, NOTARY_PROFILE,
# GITHUB_REPO populated. Forgejo upload is gated on FORGEJO_BASE /
# FORGEJO_TOKEN — script skips it silently if those aren't set.
#
# Requires the `gh` CLI (https://cli.github.com) authenticated with repo scope.
#
# Usage:  bash release.sh v0.2.0
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="${1:?usage: $0 <version>  e.g. v1.0.0}"

if [[ ! -f "$PROJECT_ROOT/.env-sign" ]]; then
    echo "✖ missing .env-sign — see build-app.sh for the variables it expects" >&2
    exit 1
fi
set -a; source "$PROJECT_ROOT/.env-sign"; set +a

: "${SIGN_ID:?SIGN_ID required for a release build}"
: "${NOTARY_PROFILE:?NOTARY_PROFILE required for notarization}"
: "${GITHUB_REPO:?GITHUB_REPO required for upload (format: owner/repo)}"

DMG_NAME="${DMG_NAME:-BlueConnect-Admin.dmg}"
DMG="$PROJECT_ROOT/$DMG_NAME"
HELPER_PKG_NAME="${HELPER_PKG_NAME:-BlueConnectHelper.pkg}"
HELPER_PKG="$PROJECT_ROOT/$HELPER_PKG_NAME"

# Derive Info.plist VERSION from the tag (strip leading 'v') and BUILD_NUMBER
# from the count of git tags + 1 (monotonic without manual bumping). Both are
# exported so build-app.sh + make-dmg.sh pick them up.
export VERSION="${TAG#v}"
export BUILD_NUMBER="$(($(git tag --list | wc -l | tr -d ' ') + 1))"
# Signal to build-app.sh that this BUILD_NUMBER is a release-managed
# counter, not the stale value sourced from .env-sign — so it isn't
# rewritten to a timestamp.
export BUILD_NUMBER_EXPLICIT=1
echo "▶ release VERSION=$VERSION  BUILD_NUMBER=$BUILD_NUMBER (tag=$TAG)"

bash "$PROJECT_ROOT/make-dmg.sh"

echo "▶ notarize (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▶ staple"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "▶ git tag $TAG"
git tag "$TAG" 2>/dev/null || echo "  (tag already exists, skipping)"
# Push the tag to BOTH remotes — github (public mirror) and origin
# (Forgejo home). Older release.sh only pushed to github; the v1.4.0
# cut showed why that's bad. `|| true` per remote so a single-remote
# failure doesn't abort the entire release.
echo "▶ push tag to github + origin"
git push github "$TAG" 2>/dev/null || echo "  (github tag push skipped)"
git push origin "$TAG" 2>/dev/null || echo "  (origin tag push skipped)"

# Build the Munki-deployable helper pkg (chat client + GUI helper +
# LaunchAgent plist) as the second release asset. The in-app
# "Setup: Install GUI Helper" Quick Action links operators at
# https://github.com/<repo>/releases/download/<tag>/BlueConnectHelper.pkg —
# they'd hit a 404 if we forgot to build + upload it here.
# `--notarize` makes the pkg builder do its own notarize + staple
# pass (separate notarytool submission from the DMG above).
# PKG_VERSION is exported so the pkg's CFBundleShortVersionString
# matches $VERSION even before the new tag has propagated to
# `git describe`.
echo "▶ build BlueConnectHelper.pkg (notarized + stapled)"
PKG_VERSION="$VERSION" bash "$PROJECT_ROOT/scripts/build-helper-pkg.sh" --notarize

NOTES="${RELEASE_NOTES_FILE:-$PROJECT_ROOT/RELEASE_NOTES.md}"

echo "▶ gh release create (GitHub)"
if [[ -f "$NOTES" ]]; then
    gh release create "$TAG" "$DMG" "$HELPER_PKG" \
        --repo "$GITHUB_REPO" \
        --title "$TAG" \
        --notes-file "$NOTES"
else
    gh release create "$TAG" "$DMG" "$HELPER_PKG" \
        --repo "$GITHUB_REPO" \
        --title "$TAG" \
        --generate-notes
fi

# Forgejo release — POST a release record + upload the DMG as an
# asset. Config is optional: skip if FORGEJO_BASE / FORGEJO_TOKEN
# aren't set in .env-sign. The Forgejo repo path is derived from
# the `origin` remote URL: parse the path after the host, strip
# trailing `.git`. Token scope needed: `write:repository`.
if [[ -n "${FORGEJO_BASE:-}" && -n "${FORGEJO_TOKEN:-}" ]]; then
    FORGEJO_REPO_PATH="$(git remote get-url origin | sed -E 's#^https?://[^/]+/##; s#\.git$##')"
    echo "▶ Forgejo release: $FORGEJO_BASE/$FORGEJO_REPO_PATH"
    BODY="$(if [[ -f "$NOTES" ]]; then cat "$NOTES"; else echo "$TAG"; fi)"
    REL_JSON=$(jq -n \
        --arg tag "$TAG" \
        --arg name "$TAG" \
        --arg body "$BODY" \
        '{tag_name:$tag,name:$name,body:$body,draft:false,prerelease:false}')
    REL_RESP=$(curl -sS -X POST \
        -H "Authorization: token $FORGEJO_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$REL_JSON" \
        "$FORGEJO_BASE/api/v1/repos/$FORGEJO_REPO_PATH/releases")
    REL_ID=$(echo "$REL_RESP" | jq -r '.id // empty')
    if [[ -z "$REL_ID" ]]; then
        echo "  ⚠ Forgejo release create failed: $REL_RESP"
    else
        echo "  release id: $REL_ID — uploading DMG + helper pkg"
        curl -sS -X POST \
            -H "Authorization: token $FORGEJO_TOKEN" \
            -F "attachment=@$DMG" \
            "$FORGEJO_BASE/api/v1/repos/$FORGEJO_REPO_PATH/releases/$REL_ID/assets?name=$DMG_NAME" \
            > /dev/null
        curl -sS -X POST \
            -H "Authorization: token $FORGEJO_TOKEN" \
            -F "attachment=@$HELPER_PKG" \
            "$FORGEJO_BASE/api/v1/repos/$FORGEJO_REPO_PATH/releases/$REL_ID/assets?name=$HELPER_PKG_NAME" \
            > /dev/null
        echo "  ✅ Forgejo: $FORGEJO_BASE/$FORGEJO_REPO_PATH/releases/tag/$TAG"
    fi
fi

echo "✅ released $TAG → https://github.com/$GITHUB_REPO/releases/tag/$TAG"
