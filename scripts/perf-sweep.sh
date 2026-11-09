#!/bin/bash
# Run a list of configurations through the perf lab and print a comparison table.
#   scripts/perf-sweep.sh <serial> "label|ENV=v ENV2=v" "label2|..." ...
cd "$(dirname "$0")/.."
SERIAL="$1"; shift
OUT="${PERF_SWEEP_OUT:-.build/perf/sweep-$(date +%H%M%S).jsonl}"; mkdir -p "$(dirname "$OUT")"
for spec in "$@"; do
  label="${spec%%|*}"; envs="${spec#*|}"
  echo "== $label ($envs)"
  env $envs PERF_LABEL="$label" PERF_OUT="$PWD/$OUT" scripts/perf.sh "$SERIAL" "${PERF_MODE:-all}" "${PERF_ITER:-10}" | grep -E "phone refresh|touch|fps during|mac interval|device pts|queueing|frame KB|failed|transport: adb"
done
uv run --no-project python - "$OUT" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
cols=[("label",24),("refresh",5),("latency_p50",8),("latency_p90",8),("fps",6),("stutters",8),("interval_p99",8),("dev_interval_p99",8),("jitter_p90",8),("kb_p50",6)]
print("".join(c[:w-1].ljust(w) for c,w in cols))
for r in rows:
    print("".join((f"{r.get(c):.1f}" if isinstance(r.get(c),float) else str(r.get(c,"")))[:w-1].ljust(w) for c,w in cols))
PY
