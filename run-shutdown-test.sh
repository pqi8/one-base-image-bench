#!/usr/bin/env bash
# run-shutdown-test.sh <out dir> <label>: one 10-job bk-compute-shutdown-test build on the Small VM,
# then copies every Small-VM console and the runner log lines from the build's time window.
set -uo pipefail
cd "$(dirname "$0")"
out="$1/$2"; mkdir -p "$out/consoles"
export BUILDKITE_API_TOKEN="${BUILDKITE_API_TOKEN:-$(cat ~/.config/bk-bench/pqi-eval-plan-token)}"
API=https://api.buildkite.com/v2/organizations/pqi-eval-plan
BKC="$HOME/Library/Application Support/BuildkiteCompute"
start=$(date +%s)
n=$(curl -sS -X POST -H "Authorization: Bearer $BUILDKITE_API_TOKEN" -H 'Content-Type: application/json' \
  "$API/pipelines/bk-compute-shutdown-test/builds" -d "{\"commit\":\"HEAD\",\"branch\":\"main\",\"message\":\"shutdown test: $2\"}" |
  python3 -c 'import sys,json; print(json.load(sys.stdin)["number"])')
echo "$2: build #$n"
# Copy consoles as they appear; the diagnostics folder keeps only recent VMs.
while :; do
  for d in "$BKC/vm/diagnostics"/bk-vm-2-*; do
    ts=${d##*-}; [ "$ts" -ge "$start" ] || continue
    [ -f "$out/consoles/$(basename "$d").log" ] || cp "$d/console.log" "$out/consoles/$(basename "$d").log" 2>/dev/null
  done
  s=$(curl -sS -H "Authorization: Bearer $BUILDKITE_API_TOKEN" "$API/pipelines/bk-compute-shutdown-test/builds/$n" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("state",""))')
  case "$s" in passed|failed|canceled) break;; esac
  sleep 10
done
sleep 15
for d in "$BKC/vm/diagnostics"/bk-vm-2-*; do
  ts=${d##*-}; [ "$ts" -ge "$start" ] && cp -n "$d/console.log" "$out/consoles/$(basename "$d").log" 2>/dev/null
done
curl -sS -H "Authorization: Bearer $BUILDKITE_API_TOKEN" "$API/pipelines/bk-compute-shutdown-test/builds/$n" > "$out/build.json"
python3 - "$start" "$BKC/timings.jsonl" > "$out/timings.jsonl" <<'PY'
import json, sys
start = float(sys.argv[1])
for line in open(sys.argv[2]):
    try: d = json.loads(line)
    except Exception: continue
    t = d.get("at") or d.get("time") or 0
    if isinstance(t, (int, float)) and t >= start and d.get("vm") == "bk-vm-2": print(line, end="")
PY
awk -v s="$(date -r "$start" '+%-I:%M')" 'f || index($0, "["s) {f=1} f' "$BKC/bk-compute.log" | grep "bk-vm-2" > "$out/runner.log"
echo "$2: build #$n $s; consoles: $(ls "$out/consoles" | wc -l)"
