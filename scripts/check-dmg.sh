#!/bin/bash
# Mount our installer read-only and test the exact app that users download.
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${1:?Usage: scripts/check-dmg.sh build/Android-Mirroring-VERSION-ARCH.dmg}"
[ -f "$IMAGE" ] || { echo "DMG not found: $IMAGE" >&2; exit 1; }
hdiutil verify "$IMAGE"
MOUNT=$(mktemp -d "$PWD/build/dmg-check.XXXXXX")
MOUNTED=false
cleanup() {
  if "$MOUNTED"; then hdiutil detach "$MOUNT" >/dev/null || return 1; fi
  rmdir "$MOUNT"
}
trap cleanup EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$IMAGE" >/dev/null
MOUNTED=true
APP="$MOUNT/Android Mirroring.app"
[ "$(readlink "$MOUNT/Applications")" = /Applications ]
[ -f "$MOUNT/Install.txt" ]
codesign --verify --deep --strict "$APP"
for resource in scrcpy-server relay.jar scrcpy-LICENSE LICENSE THIRD_PARTY_NOTICES.md; do
  [ -f "$APP/Contents/Resources/$resource" ]
done
scripts/check-cli.sh "$APP/Contents/MacOS/droidctl"
echo "DMG app signature, installation link, resources, and CLI/MCP checks passed"
