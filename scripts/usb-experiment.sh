#!/bin/bash
# Waits for the phone on USB (local adb server), then compares wired vs Wi-Fi in the perf lab and
# checks that the app picks the cable on its own.   scripts/usb-experiment.sh <wifi-host>
cd "$(dirname "$0")/.."
unset ADB_SERVER_SOCKET
WIFI="${1:?Usage: scripts/usb-experiment.sh <wifi-host>}"
OUT=.build/perf/usb-$(date +%H%M%S).jsonl
echo "waiting for a USB device on the local adb server (plug in, unlock, tap Allow)..."
for _ in $(seq 1 1350); do
  USB=$(adb devices | awk 'NR>1 && $2=="device" && $1 !~ /[:.]/ {print $1; exit}')
  [ -n "$USB" ] && break
  STATE=$(adb devices | awk 'NR>1 && $1 !~ /[:.]/ {print $2; exit}')
  [ "$STATE" = "unauthorized" ] && [ -z "$SAID" ] && { echo "USB device present but unauthorized: tap Allow on the phone"; SAID=1; }
  sleep 2
done
[ -z "$USB" ] && { echo "no USB device within 45 min"; exit 1; }
echo "USB device: $USB ($(adb -s "$USB" shell getprop ro.product.model | tr -d '\r'))"
adb -s "$USB" shell 'cat /sys/class/android_usb/android0/state 2>/dev/null; getprop sys.usb.config; getprop sys.usb.speed' | tr '\n' ' '; echo
# Same key is now trusted for Wi-Fi too.
adb connect "$WIFI:5555" >/dev/null 2>&1; sleep 2
WSER="$WIFI:5555"; adb devices | grep -q "^$WSER\s*device" || WSER=""
pkill -x AndroidMirroring 2>/dev/null; sleep 1
wait_unlocked() { for _ in $(seq 1 90); do adb -s "$USB" shell dumpsys window | grep -q "isKeyguardShowing=false" && return 0; sleep 2; done; return 1; }
O="PERF_FPS=0 PERF_CODEC_OPTS=priority:int=0,vendor.qti-ext-enc-low-latency.enable:int=1"
SPECS=("usb-adb-a|$O PERF_TRANSPORT=adb PERF_BITRATE=20000000|$USB")
[ -n "$WSER" ] && SPECS+=("wifi-direct-a|$O PERF_TRANSPORT=direct PERF_BITRATE=16000000|$WSER")
SPECS+=("usb-adb-b|$O PERF_TRANSPORT=adb PERF_BITRATE=20000000|$USB")
[ -n "$WSER" ] && SPECS+=("wifi-direct-b|$O PERF_TRANSPORT=direct PERF_BITRATE=16000000|$WSER")
SPECS+=("usb-wifimedia|$O PERF_TRANSPORT=direct PERF_HOSTS=$WIFI PERF_BITRATE=16000000|$USB")
SPECS+=("usb-adb-40M|$O PERF_TRANSPORT=adb PERF_BITRATE=40000000|$USB")
for spec in "${SPECS[@]}"; do
  IFS='|' read -r label envs ser <<< "$spec"
  wait_unlocked || { echo "phone locked: skipping $label"; continue; }
  echo "== $label ($ser)"
  env $envs PERF_LABEL="$label" PERF_OUT="$PWD/$OUT" scripts/perf.sh "$ser" all 10 | grep -E "phone refresh|transport:|touch|fps during|queueing|failed"
done
uv run --no-project python - "$OUT" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
cols=[("label",16),("transport",9),("latency_p50",8),("latency_p90",8),("fps",6),("stutters",8),("interval_p99",8),("jitter_p50",8),("jitter_p90",8),("jitter_p99",8)]
print("".join(c[:w-1].ljust(w) for c,w in cols))
for r in rows: print("".join((f"{r.get(c):.1f}" if isinstance(r.get(c),float) else str(r.get(c,"")))[:w-1].ljust(w) for c,w in cols))
PY
echo "== app auto-selection (local adb)"
open -g "/Applications/Android Mirroring.app"; sleep 8
grep "up on" ~/Library/Logs/AndroidMirroring/mirroring.log | tail -1
"/Applications/Android Mirroring.app/Contents/MacOS/droidctl" status | grep -A3 active_path
