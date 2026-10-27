#!/bin/bash
# FreeDisplay — Build & Package Script
# Usage:  ./build.sh
# Output: build/FreeDisplay.dmg

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/FreeDisplay.xcarchive"
APP_EXPORT_DIR="$PROJECT_ROOT/apps/Release"
APP_PATH="$APP_EXPORT_DIR/FreeDisplay.app"
DMG_PATH="$BUILD_DIR/FreeDisplay.dmg"
APP_VERSION="1.0.1"

build_hash_of() {
    /usr/libexec/PlistBuddy -c 'Print :FDBuildHash' "$1/Contents/Info.plist"
}

echo "==> Cleaning build dir…"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Ad-hoc export by default; a gitignored ExportOptions.local.plist overrides it.
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
if [ -f "$PROJECT_ROOT/ExportOptions.local.plist" ]; then
    EXPORT_OPTIONS="$PROJECT_ROOT/ExportOptions.local.plist"
else
    cat > "$EXPORT_OPTIONS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>mac-application</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>-</string>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
PLIST
fi

echo "==> Archiving (Release)…"
xcodebuild \
    -quiet \
    -scheme FreeDisplay \
    -configuration Release \
    archive \
    -archivePath "$ARCHIVE_PATH" \
    MARKETING_VERSION="$APP_VERSION"
echo "Archive succeeded."

ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/FreeDisplay.app"
BUILD_HASH="$(build_hash_of "$ARCHIVED_APP")"
echo "Build: v$APP_VERSION ($BUILD_HASH)"

echo "==> Exporting .app…"
rm -rf "$APP_EXPORT_DIR"
xcodebuild \
    -quiet \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$APP_EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS"
echo "Export succeeded."

[ "$(build_hash_of "$APP_PATH")" = "$BUILD_HASH" ] || { echo "Build hash changed during export"; exit 1; }
codesign --verify --deep --strict "$APP_PATH"

echo "==> Creating DMG…"
hdiutil create \
    -volname "FreeDisplay" \
    -srcfolder "$APP_PATH" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo ""
echo "Done! Output:"
echo "  App: $APP_PATH"
echo "  DMG: $DMG_PATH"
echo ""
echo "Note: App is development-signed but not notarized for public distribution."
