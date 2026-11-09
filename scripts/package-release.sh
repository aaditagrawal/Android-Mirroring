#!/bin/bash
# Build a native-architecture release ZIP with the app at its root, then record its checksum.
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
ARCHS=$(lipo -archs "$APP/Contents/MacOS/AndroidMirroring")
case "$ARCHS" in
  arm64|x86_64) ARCH="$ARCHS" ;;
  "x86_64 arm64"|"arm64 x86_64") ARCH=universal ;;
  *) echo "Unsupported architecture: $ARCHS" >&2; exit 1 ;;
esac
ZIP="build/Android-Mirroring-$VERSION-$ARCH.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd build && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "Packaged $ZIP"
echo "Local builds are ad-hoc signed. Public downloads still need your release signing/notarization process."
