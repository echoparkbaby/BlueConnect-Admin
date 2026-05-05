#!/bin/bash
# End-to-end release: build → sign → dmg → notarize → staple → GitHub Release.
# Requires .env-sign with SIGN_ID, NOTARY_PROFILE, GITHUB_REPO populated.
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

# Derive Info.plist VERSION from the tag (strip leading 'v') and BUILD_NUMBER
# from the count of git tags + 1 (monotonic without manual bumping). Both are
# exported so build-app.sh + make-dmg.sh pick them up.
export VERSION="${TAG#v}"
export BUILD_NUMBER="$(($(git tag --list | wc -l | tr -d ' ') + 1))"
echo "▶ release VERSION=$VERSION  BUILD_NUMBER=$BUILD_NUMBER (tag=$TAG)"

bash "$PROJECT_ROOT/make-dmg.sh"

echo "▶ notarize (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▶ staple"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "▶ git tag $TAG"
git tag "$TAG" 2>/dev/null || echo "  (tag already exists, skipping)"
# Push the tag to the GitHub remote (default name: 'github'). If you only
# have one remote, change to: git push --tags
git push github "$TAG" 2>/dev/null || git push --tags

echo "▶ gh release create"
NOTES="${RELEASE_NOTES_FILE:-$PROJECT_ROOT/RELEASE_NOTES.md}"
if [[ -f "$NOTES" ]]; then
    gh release create "$TAG" "$DMG" \
        --repo "$GITHUB_REPO" \
        --title "$TAG" \
        --notes-file "$NOTES"
else
    gh release create "$TAG" "$DMG" \
        --repo "$GITHUB_REPO" \
        --title "$TAG" \
        --generate-notes
fi

echo "✅ released $TAG → https://github.com/$GITHUB_REPO/releases/tag/$TAG"
