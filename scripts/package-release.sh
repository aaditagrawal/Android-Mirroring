#!/bin/bash
# Build precompiled ZIP and drag-to-Applications DMG installers with checksums.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  "") scripts/build-app.sh ;;
  --no-build) ;;
  *) echo "Usage: scripts/package-release.sh [--no-build]" >&2; exit 2 ;;
esac
APP="build/Android Mirroring.app"
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid app version: $VERSION" >&2; exit 1; }
ARCHS=$(lipo -archs "$APP/Contents/MacOS/AndroidMirroring")
case "$ARCHS" in
  arm64|x86_64) ARCH="$ARCHS" ;;
  "x86_64 arm64"|"arm64 x86_64") ARCH=universal ;;
  *) echo "Unsupported architecture: $ARCHS" >&2; exit 1 ;;
esac
CLI_ARCHS=$(lipo -archs "$APP/Contents/MacOS/droidctl")
[ "$(printf '%s\n' "$ARCHS" | tr ' ' '\n' | sort)" = "$(printf '%s\n' "$CLI_ARCHS" | tr ' ' '\n' | sort)" ] || {
  echo "App and CLI architectures differ" >&2; exit 1;
}
ZIP="build/Android-Mirroring-$VERSION-$ARCH.zip"
DMG="build/Android-Mirroring-$VERSION-$ARCH.dmg"
[ ! -f "$ZIP" ] || unlink "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

STAGE=$(mktemp -d "$PWD/build/dmg-stage.XXXXXX")
cleanup() { rm -r "$STAGE"; }
trap cleanup EXIT
ditto "$APP" "$STAGE/Android Mirroring.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Install.txt" <<INSTALL
Android Mirroring $VERSION ($ARCH)

Drag Android Mirroring.app to Applications, then open the installed app.
Install Android platform tools for pairing: brew install --cask android-platform-tools

The bundled command-line tool is inside the app at Contents/MacOS/droidctl.
Settings > Agents contains setup instructions.

Builds use ad-hoc signing unless separately signed by the release maintainer.
An ad-hoc signature is not Apple notarization; macOS may block the downloaded app.
Source, documentation, and license notices: https://github.com/aaditagrawal/Android-Mirroring
INSTALL
[ ! -f "$DMG" ] || unlink "$DMG"
hdiutil create -volname "Android Mirroring" -srcfolder "$STAGE" -format UDZO -fs HFS+ "$DMG"
scripts/check-dmg.sh "$DMG"
for artifact in "$ZIP" "$DMG"; do
  (cd build && shasum -a 256 "$(basename "$artifact")" > "$(basename "$artifact").sha256")
done
echo "Packaged $ZIP and $DMG"
echo "Publishing requires documenting the build's actual signing/notarization status."
