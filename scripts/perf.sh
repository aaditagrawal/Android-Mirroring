#!/bin/bash
# Run the performance lab under launchd (normal scheduling priority; shells spawned by some
# tools run at background priority, which coarsens timers to ~100+ ms).
#   PERF_LABEL=baseline scripts/perf.sh <serial> [latency|smooth|all|passive] [iterations]
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$PWD/.build/release/mirror-bench"
OUT="${PERF_LOGDIR:-$PWD/.build/perf}"; mkdir -p "$OUT"
LOG="$OUT/run-$$.log"; : > "$LOG"
[ -x "$BIN" ] || { echo "Build the benchmark first: swift build -c release --product mirror-bench" >&2; exit 1; }
ENVS=()
while IFS='=' read -r key value; do
  case "$key" in PERF_*|ADB_SERVER_SOCKET) ENVS+=("$key=$value");; esac
done < <(env)
ENVS+=("PERF_OUT=${PERF_OUT:-$OUT/results.jsonl}")
LABEL="am.perf.$$"
trap 'launchctl remove "$LABEL" 2>/dev/null || true' EXIT
launchctl submit -l "$LABEL" -o "$LOG" -e "$LOG" -- /usr/bin/env "${ENVS[@]}" "$BIN" "$@"
for _ in $(seq 1 600); do grep -qE "^DONE|start failed|no frames|not found" "$LOG" 2>/dev/null && break; sleep 0.5; done
launchctl remove "$LABEL" 2>/dev/null || true
grep -v "^DONE" "$LOG"
