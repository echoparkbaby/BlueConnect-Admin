#!/bin/bash
# Builds "BlueConnect Admin.app" — a real double-clickable macOS app bundle
# wrapping the SwiftPM executable. Run from the project root.
#
# Optional signing config: create a gitignored `.env-sign` file in the
# project root with any of: SIGN_ID, BUNDLE_ID, VERSION, BUILD_NUMBER,
# NOTARY_PROFILE, GITHUB_REPO. Without it, the build falls back to ad-hoc
# signing — fine for local-only use, but the app won't be trusted off
# your machine.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load signing config if present
if [[ -f "$PROJECT_ROOT/.env-sign" ]]; then
    set -a; source "$PROJECT_ROOT/.env-sign"; set +a
fi

# Defaults — override in `.env-sign` or via env to publish under your own
# identity / different version.
APP_NAME="${APP_NAME:-BlueConnect Admin}"
EXEC_NAME="${EXEC_NAME:-BlueConnectAdmin}"
BUNDLE_ID="${BUNDLE_ID:-com.example.BlueConnectAdmin}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_ID="${SIGN_ID:-}"   # empty → ad-hoc signature
APP_BUNDLE="$PROJECT_ROOT/$APP_NAME.app"

cd "$PROJECT_ROOT"
echo "▶ swift build -c release"
swift build -c release

echo "▶ build .app bundle at: $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp ".build/release/$EXEC_NAME" "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"

# App icon
if [[ -f "$PROJECT_ROOT/Resources/AppIcon.icns" ]]; then
    cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>          <string>en</string>
    <key>CFBundleExecutable</key>                 <string>$EXEC_NAME</string>
    <key>CFBundleIdentifier</key>                 <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>      <string>6.0</string>
    <key>CFBundleName</key>                       <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>                <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>                   <string>AppIcon</string>
    <key>CFBundlePackageType</key>                <string>APPL</string>
    <key>CFBundleShortVersionString</key>         <string>$VERSION</string>
    <key>CFBundleVersion</key>                    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>             <string>13.0</string>
    <key>LSApplicationCategoryType</key>          <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>            <true/>
    <key>NSPrincipalClass</key>                   <string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key>      <string>BlueConnect Admin uses Apple Events to launch Terminal for SSH/VNC/SCP sessions.</string>
    <key>NSLocalNetworkUsageDescription</key>     <string>BlueConnect Admin discovers SSH and VNC servers on your local network so you can connect to them directly without going through the BlueSky tunnel.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_ssh._tcp</string>
        <string>_rfb._tcp</string>
    </array>
</dict>
</plist>
PLIST

if [[ -n "$SIGN_ID" ]]; then
    echo "▶ codesign with: $SIGN_ID"
    codesign --force --deep --options runtime --timestamp \
        --sign "$SIGN_ID" "$APP_BUNDLE"
else
    echo "▶ codesign ad-hoc (no SIGN_ID set in .env-sign)"
    codesign --force --deep -s - "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

echo "▶ verify signature"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/  /'

echo "✅ built: $APP_BUNDLE"
echo "   double-click it, or:  open \"$APP_BUNDLE\""
