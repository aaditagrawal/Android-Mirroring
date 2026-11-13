#!/bin/bash
# Builds "Android Mirroring.app" (release) into ./build and optionally installs it.
#   scripts/build-app.sh            build
#   scripts/build-app.sh --install  build and copy to /Applications (falls back to ~/Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
  ""|--install|--homebrew) ;;
  --help|-h) echo "Usage: scripts/build-app.sh [--install|--homebrew]"; exit 0 ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

# Homebrew supplies its own sandbox. SwiftPM must not create a nested sandbox.
SWIFT_OPTIONS=(--configuration release)
if [ "${1:-}" = "--homebrew" ]; then SWIFT_OPTIONS+=(--disable-sandbox); fi
scripts/check-resources.sh

APP_NAME="Android Mirroring"
BUNDLE_ID="com.aaditagrawal.AndroidMirroring"
VERSION="1.0.1"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "▸ Compiling (release)…"
swift build "${SWIFT_OPTIONS[@]}" --product AndroidMirroring
swift build "${SWIFT_OPTIONS[@]}" --product droidctl
BIN="$(swift build "${SWIFT_OPTIONS[@]}" --show-bin-path)"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/AndroidMirroring" "$APP/Contents/MacOS/AndroidMirroring"
cp "$BIN/droidctl" "$APP/Contents/MacOS/droidctl"
cp Resources/scrcpy-server "$APP/Contents/Resources/scrcpy-server"
cp Resources/relay.jar "$APP/Contents/Resources/relay.jar"
cp Resources/scrcpy-LICENSE "$APP/Contents/Resources/scrcpy-LICENSE"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

if [ ! -f "$BUILD_DIR/AppIcon.icns" ] || [ scripts/make-icon.swift -nt "$BUILD_DIR/AppIcon.icns" ]; then
  echo "▸ Rendering icon…"
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  swift scripts/make-icon.swift "$BUILD_DIR/icon-1024.png" >/dev/null
  for s in 16 32 128 256 512; do
    sips -z $s $s "$BUILD_DIR/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$BUILD_DIR/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"
fi
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>AndroidMirroring</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppSleepDisabled</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Android Mirroring finds and connects to your phone on the local network (Wireless debugging).</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_adb-tls-pairing._tcp</string>
    <string>_adb-tls-connect._tcp</string>
    <string>_adb._tcp</string>
  </array>
  <key>NSHumanReadableCopyright</key><string>Video/control server: scrcpy (Apache 2.0, Genymobile).</string>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)…"
codesign --force --sign - --options runtime --timestamp=none "$APP/Contents/MacOS/droidctl"
codesign --force --sign - --options runtime --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "✓ Built $APP"

if [ "${1:-}" = "--install" ]; then
  DEST="/Applications"
  [ -w "$DEST" ] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  pkill -x AndroidMirroring 2>/dev/null || true
  sleep 0.5
  rm -rf "$DEST/$APP_NAME.app"
  cp -R "$APP" "$DEST/"
  echo "✓ Installed to $DEST/$APP_NAME.app"
fi
