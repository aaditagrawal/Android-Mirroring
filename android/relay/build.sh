#!/bin/bash
# Rebuild the checked-in DEX payload. Requires JDK 17+ and Android SDK platform/build-tools 35.
set -euo pipefail
cd "$(dirname "$0")"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
BT="$SDK/build-tools/${ANDROID_BUILD_TOOLS:-35.0.0}"
PLAT="$SDK/platforms/${ANDROID_PLATFORM:-android-35}"
if [ ! -x "$BT/d8" ] || [ ! -f "$PLAT/android.jar" ]; then
  echo "Missing SDK tools. Set ANDROID_HOME and install build-tools;35.0.0 and platforms;android-35." >&2
  exit 1
fi
command -v javac >/dev/null || { echo "Install JDK 17+ (javac not found)." >&2; exit 1; }
rm -rf out
mkdir -p out/classes
javac --release 8 -nowarn -cp "$PLAT/android.jar" -d out/classes src/Relay.java
classes=()
while IFS= read -r file; do classes+=("$file"); done < <(find out/classes -name '*.class' | sort)
"$BT/d8" --min-api 26 --lib "$PLAT/android.jar" --output out/relay.jar "${classes[@]}"
cp out/relay.jar ../../Resources/relay.jar
echo "Built Resources/relay.jar. Review the change and update Resources/SHA256SUMS before bundling."
