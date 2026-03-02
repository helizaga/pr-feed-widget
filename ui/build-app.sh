#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="PR Agent"
BUNDLE_ID="com.averyjennings.pr-agent-ui"
APP_DIR="$SCRIPT_DIR/build/${APP_NAME}.app"

echo "Building release..."
cd "$SCRIPT_DIR"
swift build -c release 2>&1

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
cp ".build/release/PRAgentUI" "$APP_DIR/Contents/MacOS/PRAgentUI"

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>PR Agent</string>
    <key>CFBundleDisplayName</key>
    <string>PR Agent</string>
    <key>CFBundleIdentifier</key>
    <string>com.averyjennings.pr-agent-ui</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>PRAgentUI</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSDesktopFolderUsageDescription</key>
    <string>PR Agent may need access to review code clones on your Desktop.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>PR Agent may need access to review code clones in Documents.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>PR Agent may need access to review code clones in Downloads.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>PR Agent needs to control iTerm to switch to the correct terminal tab for your review session.</string>
</dict>
</plist>
PLIST

# Code-sign with stable identity so macOS can remember TCC permission grants.
# Without this, the ad-hoc signature changes every build and macOS re-prompts.
ENTITLEMENTS="$SCRIPT_DIR/PRAgentUI.entitlements"
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/' || true)

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "Signing with: $SIGN_IDENTITY"
    codesign --force --sign "$SIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        "$APP_DIR/Contents/MacOS/PRAgentUI"
    codesign --force --sign "$SIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        "$APP_DIR"
else
    echo "Warning: No signing identity found. App will be ad-hoc signed."
    echo "  TCC permission prompts may repeat on each build."
    echo "  Create a self-signed certificate in Keychain Access to fix this."
fi

echo "Built: $APP_DIR"
echo ""
echo "To run:  open \"$APP_DIR\""
echo "To install: cp -r \"$APP_DIR\" /Applications/"
