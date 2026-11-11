#!/bin/sh
# Builds build/Blink.app.
#   --install   also copies it to /Applications and relaunches
#   --release   signs with your Developer ID (hardened runtime), zips it, and notarises it if a
#               notarytool profile named "blink" exists (see README). Needs a "Developer ID Application" certificate.
set -e
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
swift build -c release
APP=build/Blink.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Blink "$APP/Contents/MacOS/Blink"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.local.blink</string>
    <key>CFBundleName</key><string>Blink</string>
    <key>CFBundleExecutable</key><string>Blink</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>__VERSION__</string>
    <key>CFBundleVersion</key><string>__VERSION__</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSContactsUsageDescription</key><string>Blink shows contact names next to your Messages conversations.</string>
    <key>NSAppleEventsUsageDescription</key><string>Blink sends your replies through Messages.</string>
</dict>
</plist>
PLIST
sed -i '' "s/__VERSION__/$VERSION/g" "$APP/Contents/Info.plist"

if [ "$1" = "--release" ]; then
    DEV_ID="${BLINK_DEVELOPER_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
    if [ -z "$DEV_ID" ]; then
        echo "No \"Developer ID Application\" certificate found."
        echo "Notarised builds need one (Apple Developer Program → Certificates). Local builds work without it."
        exit 1
    fi
    codesign --force --options runtime --timestamp --entitlements scripts/Blink.entitlements --sign "$DEV_ID" "$APP"
    codesign --verify --strict --verbose=1 "$APP"
    ZIP="build/Blink-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    if xcrun notarytool history --keychain-profile blink >/dev/null 2>&1; then
        echo "Submitting to Apple for notarisation (a few minutes)…"
        xcrun notarytool submit "$ZIP" --keychain-profile blink --wait
        xcrun stapler staple "$APP"
        rm -f "$ZIP"
        ditto -c -k --keepParent "$APP" "$ZIP"
        echo "Notarised: $ZIP"
    else
        echo "Signed: $ZIP (not notarised: no notarytool profile named \"blink\"; see README)"
    fi
    exit 0
fi

# A stable signing identity keeps macOS permissions across rebuilds; ad-hoc signing resets them.
ID="${BLINK_SIGN_ID:-$(security find-identity -v -p codesigning | awk 'NR==1 && $2 ~ /^[0-9A-F]+$/ {print $2}')}"
codesign --force --sign "${ID:--}" "$APP"
echo "Built $APP"
if [ "$1" = "--install" ]; then
    pkill -x Blink 2>/dev/null || true
    rm -rf /Applications/Blink.app
    cp -R "$APP" /Applications/Blink.app
    open /Applications/Blink.app
    echo "Installed and launched /Applications/Blink.app"
fi
