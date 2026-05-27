#!/bin/bash
# build-helper-pkg.sh — produces BlueConnectHelper.pkg, a signed flat
# .pkg that installs:
#
#   /usr/local/bin/blueconnect-chat              (SwiftUI chat client)
#   /usr/local/bin/blueconnect-gui-helper        (bash inbox watcher)
#   /Library/LaunchAgents/xyz.hellocomputer.blueconnect-helper.plist
#
# plus a postinstall that creates the world-writable inbox + chat
# session directories under /Library/Application Support/BlueConnect/
# and bootstraps the LaunchAgent into every active Aqua session so the
# helper is live without requiring a logout/login.
#
# The whole point of this packaging path: deploy via Munki to the fleet
# instead of running the "Setup: Install GUI Helper (one-time)" Quick
# Action against each host. One Munki sync rolls the helper to every
# enrolled Mac in the next check-in cycle.
#
# Usage:
#   bash scripts/build-helper-pkg.sh                # builds + signs
#   bash scripts/build-helper-pkg.sh --notarize     # builds + signs + notarizes + staples
#
# Requires .env-sign (already used by build-app.sh / release.sh):
#   SIGN_ID         — Developer ID Application identity (signs chat binary)
#   PKG_SIGN_ID     — Developer ID Installer identity  (signs the pkg itself)
#   NOTARY_PROFILE  — only needed with --notarize
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

if [[ -f .env-sign ]]; then
    set -a; source .env-sign; set +a
fi

NOTARIZE=0
[[ "${1:-}" == "--notarize" ]] && NOTARIZE=1

: "${SIGN_ID:?SIGN_ID required (Developer ID Application identity for the chat binary)}"
: "${PKG_SIGN_ID:?PKG_SIGN_ID required (Developer ID Installer identity for the .pkg). Add it to .env-sign.}"
if [[ "$NOTARIZE" -eq 1 ]]; then
    : "${NOTARY_PROFILE:?NOTARY_PROFILE required with --notarize}"
fi

# Version from the most recent git tag (matches what build-app.sh uses
# for the app bundle), falling back to 1.0.0 on a tagless repo.
VERSION="${PKG_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-1.0.0}"

PKG_IDENTIFIER="xyz.hellocomputer.blueconnect-helper"
PKG_NAME="BlueConnectHelper.pkg"
PKG_OUT="$PROJECT_ROOT/$PKG_NAME"

STAGE="$PROJECT_ROOT/.build/pkg-stage"
ROOT="$STAGE/root"
SCRIPTS="$STAGE/scripts"
rm -rf "$STAGE"
mkdir -p "$ROOT/usr/local/bin"
mkdir -p "$ROOT/Library/LaunchAgents"
mkdir -p "$SCRIPTS"

echo "▶ swift build -c release (BlueConnectChat)"
swift build -c release --product BlueConnectChat

# Stage the three payload files. Permissions get a final pass via
# pkgbuild --analyze/--component-plist, but installing them with the
# right modes up-front keeps the staged tree audit-friendly.
echo "▶ stage payload"
install -m 755 .build/release/BlueConnectChat "$ROOT/usr/local/bin/blueconnect-chat"
install -m 755 scripts/pkg/blueconnect-gui-helper "$ROOT/usr/local/bin/blueconnect-gui-helper"
install -m 644 scripts/pkg/xyz.hellocomputer.blueconnect-helper.plist \
    "$ROOT/Library/LaunchAgents/xyz.hellocomputer.blueconnect-helper.plist"

# Sign the chat binary with hardened runtime + secure timestamp so it
# can pass notarization. The helper script is a plain bash file — no
# need (and no way) to codesign it.
echo "▶ codesign blueconnect-chat with $SIGN_ID"
codesign --force --options runtime --timestamp \
    --sign "$SIGN_ID" \
    "$ROOT/usr/local/bin/blueconnect-chat"

# pkgbuild scripts: preinstall + postinstall live in $SCRIPTS, not in
# the payload. pkgbuild names them by the file name itself; they
# don't need to be in a subdirectory.
echo "▶ stage installer scripts"
install -m 755 scripts/pkg/scripts/preinstall  "$SCRIPTS/preinstall"
install -m 755 scripts/pkg/scripts/postinstall "$SCRIPTS/postinstall"

echo "▶ pkgbuild $PKG_NAME (version $VERSION)"
pkgbuild \
    --root "$ROOT" \
    --scripts "$SCRIPTS" \
    --identifier "$PKG_IDENTIFIER" \
    --version "$VERSION" \
    --install-location "/" \
    --sign "$PKG_SIGN_ID" \
    "$PKG_OUT"

echo "▶ pkgutil --check-signature"
pkgutil --check-signature "$PKG_OUT" | sed 's/^/  /'

if [[ "$NOTARIZE" -eq 1 ]]; then
    echo "▶ notarize $PKG_NAME (this can take a few minutes)"
    xcrun notarytool submit "$PKG_OUT" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    echo "▶ staple"
    xcrun stapler staple "$PKG_OUT"
    xcrun stapler validate "$PKG_OUT"
fi

echo "✅ built: $PKG_OUT"
echo "   identifier: $PKG_IDENTIFIER  version: $VERSION"
echo ""
echo "Next steps for Munki deployment:"
echo "  1. munkiimport $PKG_OUT"
echo "  2. Assign to the relevant manifest(s) — e.g. 'managed_installs' or a new 'blueconnect-helper' category."
echo "  3. makecatalogs"
echo ""
echo "On the target Macs, Munki's next sync will install. Helper is live"
echo "immediately on Macs with an active GUI session; on others it loads"
echo "on next user login."
