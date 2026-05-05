#!/bin/bash
# Builds the .app via build-app.sh and packages it into a distributable .dmg.
# Reads signing config from .env-sign — see build-app.sh for details.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$PROJECT_ROOT/.env-sign" ]]; then
    set -a; source "$PROJECT_ROOT/.env-sign"; set +a
fi
APP_NAME="${APP_NAME:-BlueConnect Admin}"
DMG_NAME="${DMG_NAME:-BlueConnect-Admin.dmg}"
SIGN_ID="${SIGN_ID:-}"

bash "$PROJECT_ROOT/build-app.sh"

APP="$PROJECT_ROOT/$APP_NAME.app"
DMG="$PROJECT_ROOT/$DMG_NAME"
STAGE="$(mktemp -d)/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
echo "▶ building $DMG_NAME"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null

if [[ -n "$SIGN_ID" ]]; then
    echo "▶ codesign dmg with: $SIGN_ID"
    codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
fi

echo "✅ $DMG"
