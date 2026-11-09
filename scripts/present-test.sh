#!/bin/bash
# In-app presentation test: mirrors a virtual display (nothing on the phone's own screen), opens
# Settings there, drives identical swipes under each pacing mode and prints what was presented.
#   ADB_SERVER_SOCKET=... scripts/present-test.sh [modes...]
set -euo pipefail
APP="/Applications/Android Mirroring.app"; D="$APP/Contents/MacOS/droidctl"
LOG=~/Library/Logs/AndroidMirroring/mirroring.log
if [ "$#" -gt 0 ]; then MODES=("$@"); else MODES=(immediate balanced smooth); fi
OLD_VD=$(defaults read com.aaditagrawal.AndroidMirroring debugVirtualDisplay 2>/dev/null || true)
OLD_PACING=$(defaults read com.aaditagrawal.AndroidMirroring pacing 2>/dev/null || true)
restore_settings() {
  if [ -n "$OLD_VD" ]; then defaults write com.aaditagrawal.AndroidMirroring debugVirtualDisplay -string "$OLD_VD"
  else defaults delete com.aaditagrawal.AndroidMirroring debugVirtualDisplay 2>/dev/null || true; fi
  if [ -n "$OLD_PACING" ]; then defaults write com.aaditagrawal.AndroidMirroring pacing -string "$OLD_PACING"
  else defaults delete com.aaditagrawal.AndroidMirroring pacing 2>/dev/null || true; fi
}
trap restore_settings EXIT
defaults write com.aaditagrawal.AndroidMirroring debugVirtualDisplay "1080x2340/420"
pkill -x AndroidMirroring || true; sleep 1
if [ -n "${ADB_SERVER_SOCKET:-}" ]; then open -g --env "ADB_SERVER_SOCKET=$ADB_SERVER_SOCKET" "$APP"
else open -g "$APP"; fi
for _ in $(seq 1 40); do "$D" status 2>/dev/null | grep -q '"state" : "streaming"' && break; sleep 0.5; done
ID=$(grep "New display" "$LOG" | tail -1 | sed -E 's/.*id=([0-9]+).*/\1/')
SER=$("$D" status | grep -m1 '"serial"' | sed -E 's/.*: "([^"]+)".*/\1/')
"$D" shell "am start --display $ID -f 0x18000000 -a android.settings.SETTINGS" >/dev/null
"$D" show; sleep 2
grep "up on" "$LOG" | tail -1 | sed -E 's/.* in ([0-9]+ ms.*)/session: \1/'
for m in "${MODES[@]}"; do
  "$D" call debug_present "{\"pacing\":\"$m\",\"reset\":true}" >/dev/null
  for i in 1 2 3 4 5 6; do
    if (( i % 2 )); then "$D" call swipe '{"x1":540,"y1":1900,"x2":540,"y2":700,"duration_ms":1000,"space":"device"}' >/dev/null
    else "$D" call swipe '{"x1":540,"y1":700,"x2":540,"y2":1900,"duration_ms":1000,"space":"device"}' >/dev/null; fi
    sleep 0.4
  done
  echo "== $m"; "$D" call debug_present '{}' | tr -d '\n ' | sed 's/,"/  "/g'; echo
done
echo "Settings restored on exit. Relaunch the app before resuming normal mirroring."
