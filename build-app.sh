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
# .env-sign's BUILD_NUMBER is a starting hint, not a pin. If the env-sign
# value is what we just read (no caller override), bump to a fresh
# timestamp so each dev build reports a unique Info.plist version.
# release.sh sets its own monotonic counter and exports it after sourcing
# .env-sign, so that path still takes precedence.
if [[ -z "${BUILD_NUMBER_EXPLICIT:-}" ]]; then
    BUILD_NUMBER="$(date +%Y%m%d.%H%M%S)"
fi
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

# Embed the chat-client binary inside the .app's Resources. The Mac app
# pushes this over SCP on first chat open so the target gets
# /usr/local/bin/blueconnect-chat (a tiny SwiftUI window the GUI Helper
# LaunchAgent launches in the console user's Aqua session).
#
# Single-arch (whatever Swift built for the host) is fine for now since
# all fleet Macs we manage are Apple Silicon. If we later need Intel
# coverage, the right move is two `swift build -c release` runs with
# --arch arm64 and --arch x86_64 then `lipo -create` them.
if [[ -f ".build/release/BlueConnectChat" ]]; then
    cp ".build/release/BlueConnectChat" "$APP_BUNDLE/Contents/Resources/blueconnect-chat"
    chmod +x "$APP_BUNDLE/Contents/Resources/blueconnect-chat"
    echo "▶ embedded chat client at: $APP_BUNDLE/Contents/Resources/blueconnect-chat ($(du -h "$APP_BUNDLE/Contents/Resources/blueconnect-chat" | cut -f1))"
else
    echo "⚠️  chat client binary missing — chat feature will be unavailable"
fi

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
    # Sign nested Mach-O binaries FIRST with hardened runtime +
    # secure timestamp. The outer `--deep` codesign on the bundle
    # alone doesn't propagate `--options runtime` to nested
    # standalone executables in Resources/ (notarytool rejects
    # them as "binary is not signed with a valid Developer ID
    # certificate" / "no secure timestamp" / "no hardened
    # runtime"). Sign each explicitly, then sign the outer bundle
    # without --deep so we don't re-sign and lose those flags.
    if [[ -f "$APP_BUNDLE/Contents/Resources/blueconnect-chat" ]]; then
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_ID" \
            "$APP_BUNDLE/Contents/Resources/blueconnect-chat"
    fi
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_ID" \
        "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_ID" "$APP_BUNDLE"
else
    echo "▶ codesign ad-hoc (no SIGN_ID set in .env-sign)"
    if [[ -f "$APP_BUNDLE/Contents/Resources/blueconnect-chat" ]]; then
        codesign --force -s - "$APP_BUNDLE/Contents/Resources/blueconnect-chat" >/dev/null 2>&1 || true
    fi
    codesign --force --deep -s - "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

echo "▶ verify signature"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/  /'

echo "✅ built: $APP_BUNDLE"
echo "   double-click it, or:  open \"$APP_BUNDLE\""
