#!/usr/bin/env bash
#
# Build Android Tablet Display.app.
#
# Why a bundle and not just `swift build`: macOS attaches Screen Recording and
# Accessibility permission to an application's bundle identity. A bare SwiftPM
# executable has none, so the permission gets attached to whatever launched it
# (your terminal) and will not stick. Running the app from this bundle is the
# only way the permissions persist across launches.
#
#   ./tools/build-app.sh            debug build
#   ./tools/build-app.sh release    optimised build
#
# The result is build/Android Tablet Display.app — drag it to /Applications.

set -euo pipefail

CONFIGURATION="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/macos-host/USBDisplayApp"
OUTPUT="$ROOT/build"
APP="$OUTPUT/Android Tablet Display.app"

# Build outside the checkout. SwiftPM keeps its build state in a SQLite
# database, and SQLite does not survive being written inside a folder that a
# sync client (Dropbox, iCloud Drive, Syncthing) is watching — it fails with
# "disk I/O error" partway through. Keeping the build directory in the user
# cache avoids that entirely, and keeps the checkout clean.
SCRATCH="${USBDISPLAY_BUILD_DIR:-$HOME/Library/Caches/dev.notinept.usbtabletdisplay/build}"
mkdir -p "$SCRATCH"

echo "Building ($CONFIGURATION) in $SCRATCH ..."
swift build --package-path "$PACKAGE" --configuration "$CONFIGURATION" \
    --scratch-path "$SCRATCH"

BINARY="$SCRATCH/$CONFIGURATION/USBDisplayApp"
if [ ! -x "$BINARY" ]; then
    echo "error: $BINARY was not produced" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/USBDisplayApp"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Android Tablet Display</string>
    <key>CFBundleDisplayName</key>
    <string>Android Tablet Display</string>
    <key>CFBundleIdentifier</key>
    <string>dev.notinept.usbtabletdisplay</string>
    <key>CFBundleExecutable</key>
    <string>USBDisplayApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <!-- Menu bar only: no Dock icon, no main window. -->
    <key>LSUIElement</key>
    <true/>
    <!-- Shown in the permission prompts, so say why in plain words. -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>Finds your tablet on the same Wi-Fi network when you choose wireless mode.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_usbtablet._tcp</string>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc signature. Enough to give the bundle a stable identity for TCC on
# this machine; distributing it to other people needs a Developer ID and
# notarisation, which is out of scope here.
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null \
    || echo "warning: could not sign the bundle; permissions may not persist"

echo "Built: $APP"
echo
echo "Next:"
echo "  1. open \"$APP\"    (or drag it to /Applications first)"
echo "  2. Grant Screen Recording and Accessibility when the menu asks."
echo "  3. Plug the tablet in and pick Start from the menu bar."
