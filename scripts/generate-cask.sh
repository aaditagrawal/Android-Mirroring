#!/bin/bash
# Generate a cask from an actual release ZIP, never a placeholder checksum.
# Upload the exact ZIP to the matching vVERSION GitHub release before publishing the generated cask.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${1:?Usage: scripts/generate-cask.sh OWNER/REPO build/Android-Mirroring-VERSION-ARCH.zip}"
ZIP="${2:?Supply a packaged release ZIP}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Invalid repository" >&2; exit 2; }
[ -f "$ZIP" ] || { echo "ZIP not found: $ZIP" >&2; exit 1; }
NAME=$(basename "$ZIP")
[[ "$NAME" =~ ^Android-Mirroring-([0-9]+\.[0-9]+\.[0-9]+)-(arm64|x86_64|universal)\.zip$ ]] || { echo "Use an archive from scripts/package-release.sh" >&2; exit 2; }
VERSION="${BASH_REMATCH[1]}"
ARCH="${BASH_REMATCH[2]}"
SHA=$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)
OUT=build/homebrew/Casks/android-mirroring.rb
mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<CASK
cask "android-mirroring" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/Android-Mirroring-#{version}-$ARCH.zip"
  name "Android Mirroring"
  desc "Native Android screen mirroring and agent control"
  homepage "https://github.com/$REPO"

CASK
if [ "$ARCH" != universal ]; then echo "  depends_on arch: :$ARCH" >> "$OUT"; fi
cat >> "$OUT" <<'CASK'
  depends_on cask: "android-platform-tools"
  depends_on macos: :sonoma

  app "Android Mirroring.app"
  binary "#{appdir}/Android Mirroring.app/Contents/MacOS/droidctl", target: "droidctl"
end
CASK
echo "Generated $OUT for $ARCH. Publish it only after uploading the matching ZIP to v$VERSION."
