#!/usr/bin/env bash
# run-candidate.sh <out dir>: the full bk-compute re-run for a candidate runner build, one build at a time.
#   1. acceptance (buildkite-agent-fleet at the acceptance commit), 2 runs
#   2. fleet tests: agent and ghostty, 3 runs each
#   3. single-job matrix: t3code, agent, ghostty (3 cold + 3 warm each)
# Results go to <out dir>/{results,fleet-results,acceptance}.jsonl; crash consoles to <out dir>/crashes.
set -uo pipefail
cd "$(dirname "$0")"
out="$1"; mkdir -p "$out/crashes"
export BUILDKITE_API_TOKEN="${BUILDKITE_API_TOKEN:-$(cat ~/.config/bk-bench/pqi-eval-plan-token)}"
export BENCH_RESULTS_FILE="$out/results.jsonl" BENCH_FLEET_RESULTS_FILE="$out/fleet-results.jsonl"
API=https://api.buildkite.com/v2/organizations/pqi-eval-plan
log() { echo "$(date '+%H:%M:%S') $*"; }

pgrep -f "crash-watch.sh $out/crashes" >/dev/null || { bash ~/bk-compute-vm-crash-evidence/crash-watch.sh "$out/crashes" & }

# Build #7 was the first job on the candidate (cold, cache not saved); record it too.
if [ -n "${EXTRA_GHOSTTY_BUILD:-}" ]; then
  ./wait-bk.sh "obi-bk-compute-ghostty#$EXTRA_GHOSTTY_BUILD"
  python3 collect.py bk obi-bk-compute-ghostty "$EXTRA_GHOSTTY_BUILD" cold-unsaved
fi

log "phase 1: acceptance"
for i in ${ACCEPTANCE_RUNS:-1 2}; do
  # ACCEPTANCE_BUILD_<i> resumes a run whose build is already going.
  existing="ACCEPTANCE_BUILD_$i"
  if [ -n "${!existing:-}" ]; then n="${!existing}"; else
  n=$(curl -sS -X POST -H "Authorization: Bearer $BUILDKITE_API_TOKEN" -H 'Content-Type: application/json' \
    "$API/pipelines/buildkite-agent-fleet/builds" \
    -d "{\"commit\":\"23e06924dac1b683bc8653b731cd633af67d4a8a\",\"branch\":\"main\",\"message\":\"candidate acceptance run $i\",\"env\":{\"BENCH_HOST\":\"patricks-macbook-pro\"}}" |
    python3 -c 'import sys,json; print(json.load(sys.stdin)["number"])'); fi
  log "acceptance run $i: build #$n"
  ./wait-bk.sh "buildkite-agent-fleet#$n"
  BENCH_FLEET_RESULTS_FILE="$out/acceptance.jsonl" python3 collect_fleet.py bk buildkite-agent-fleet "$n" acceptance "run-$i"
done

log "phase 2: fleet"
./run-fleet.sh bk-compute 3 agent ghostty

if [ -z "${SKIP_MATRIX:-}" ]; then
  log "phase 3: single-job matrix"
  ./run-matrix.sh bk-compute t3code agent ghostty
fi

log "all done"
touch "$out/DONE"
