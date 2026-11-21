#!/usr/bin/env bash
# run-lfl-next.sh <out dir>: runs one build: the next step of <out dir>/plan.txt that isn't done.
# plan.txt lines: <platform> <project> <variant> <step>
#   platform: bk-compute | hosted | gha     variant: lfl | uncapped
#
# Results go to <out dir>/fleet-results.jsonl, one record per attempt. A step is done once it has an
# attempt the collector didn't exclude. Excluded attempts (contended, invalid setup, Mac busy) stay in
# the file and the step runs again under the label <step>-a<n>, up to 3 attempts. Failed builds are
# not excluded: they count as the step's result.
# A shakedown step that doesn't produce a valid build stops the driver (exit 2) for review.
#
# The triggered build is written to <out dir>/pending before waiting, so a build whose collection fails
# is collected on the next call instead of being replaced.
# Before each build the driver waits until that platform is idle (bk-compute: Patrick's three agents
# connected with no job; hosted: no active build has a job on a hosted queue; GitHub: no queued or
# running run). It keeps crash-watch.sh and mac-load.sh running, and for bk-compute builds it saves the
# new runner-log lines to <out dir>/runner-log/ and counts "drain" / "no heartbeat" lines.
set -uo pipefail
cd "$(dirname "$0")"
out="$1"
export BUILDKITE_API_TOKEN="${BUILDKITE_API_TOKEN:-$(cat ~/.config/bk-bench/pqi-eval-plan-token)}"
export BENCH_FLEET_RESULTS_FILE="$out/fleet-results.jsonl" BENCH_MAC_LOAD="$out/mac-load.tsv"
API=https://api.buildkite.com/v2/organizations/pqi-eval-plan
GH_REPO=pqi8/one-base-image-bench
RUNNER_LOG="$HOME/Library/Application Support/BuildkiteCompute/bk-compute.log"
log() { echo "$(date '+%H:%M:%S') $*" | tee -a "$out/driver.log" >&2; }
touch "$BENCH_FLEET_RESULTS_FILE"
mkdir -p "$out/crashes" "$out/runner-log"

pgrep -f "crash-watch.sh $out/crashes" >/dev/null || nohup bash ~/bk-compute-vm-crash-evidence/crash-watch.sh "$out/crashes" >/dev/null 2>&1 &
pgrep -f "mac-load.sh $BENCH_MAC_LOAD" >/dev/null || nohup bash ./mac-load.sh "$BENCH_MAC_LOAD" >/dev/null 2>&1 &

slug_for() {  # <platform> <project> <variant>
  if [ "$1" = bk-compute ]; then echo "obi-bk-compute-$2-fleet"
  elif [ "$3" = lfl ]; then echo "obi-hosted-lfl-$2-fleet"
  else echo "obi-hosted-$2-fleet"; fi
}

runner_check() {  # <from line> <file name>: saves new runner-log lines, prints the drain/no-heartbeat count
  tail -n +"$(($1 + 1))" "$RUNNER_LOG" > "$out/runner-log/$2.log"
  grep -c -E 'drain|no heartbeat' "$out/runner-log/$2.log"
}

collect() {  # <platform> <project> <variant> <step> <label> <build ref> <runner-log start line>
  local platform="$1" project="$2" variant="$3" step="$4" label="$5" ref="$6" from="$7" result
  export BENCH_STEP="$step" BENCH_RUNNER_BAD=""
  if [ "$platform" = gha ]; then
    until gh run view --repo "$GH_REPO" "$ref" --json status -q .status 2>/dev/null | grep -q completed; do sleep 30; done
  else
    ./wait-bk.sh "$ref" >> "$out/driver.log"
  fi
  sleep 20  # let job logs settle
  if [ "$platform" = bk-compute ]; then
    BENCH_RUNNER_BAD=$(runner_check "$from" "$project-$label")
    log "runner log: $BENCH_RUNNER_BAD drain/no-heartbeat lines"
  fi
  if [ "$platform" = gha ]; then result=$(python3 collect_lfl.py gha "$ref" "$variant" "$label")
  else result=$(python3 collect_lfl.py bk "${ref%#*}" "${ref#*#}" "$variant" "$label"); fi || {
    log "collect failed for $ref; pending kept"; exit 1; }
  rm -f "$out/pending"
  log "$result"
  echo "$result${BENCH_RUNNER_BAD:+ runner-log-bad-lines=$BENCH_RUNNER_BAD}"
}

# A build triggered by an earlier call that wasn't collected comes first.
if [ -s "$out/pending" ]; then
  read -r platform project variant step label ref from < "$out/pending"
  log "collecting pending $ref"
  collect "$platform" "$project" "$variant" "$step" "$label" "$ref" "$from"
  exit 0
fi

next=$(python3 - "$out/plan.txt" "$BENCH_FLEET_RESULTS_FILE" <<'PY'
import json, sys
names = {"bk-compute": "bk-compute", "hosted": "buildkite-hosted", "gha": "github-actions"}
recs = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
for line in open(sys.argv[1]):
    f = line.split()
    if len(f) != 4 or line.startswith("#"):
        continue
    plat, project, variant, step = f
    tries = [r for r in recs if (r["platform"], r["project"], r["variant"], r.get("step", r["label"])) == (names[plat], project, variant, step)]
    if any(not r.get("excluded") for r in tries) and not (step == "shakedown" and not any(r["valid"] for r in tries)):
        continue
    if tries and step == "shakedown":
        print("STOP shakedown", plat, project, variant, "has no valid build:", tries[-1].get("excluded") or tries[-1]["failed_jobs"]); break
    if len(tries) >= 3:
        print("STOP", plat, project, variant, step, "excluded 3 times"); break
    print(plat, project, variant, step, step if not tries else f"{step}-a{len(tries) + 1}"); break
PY
)
[ -n "$next" ] || { echo "plan done"; exit 0; }
case "$next" in STOP*) log "$next"; echo "$next"; exit 2;; esac
read -r platform project variant step label <<<"$next"
log "step: $platform $project $variant $step (label $label)"

wait_idle() {
  local busy n
  while :; do
    case "$1" in
      bk-compute)
        busy=$(curl -sS -H "Authorization: Bearer $BUILDKITE_API_TOKEN" "$API/agents?per_page=100" | python3 -c '
import sys, json
a = [x for x in json.load(sys.stdin) if x["name"].startswith("patricks-macbook-pro-")]
print("ok" if len(a) == 3 and all(x["connection_state"] == "connected" and not x.get("job") for x in a) else "busy")') ;;
      hosted)
        busy=$(curl -sS -H "Authorization: Bearer $BUILDKITE_API_TOKEN" "$API/builds?state[]=running&state[]=scheduled&state[]=failing&state[]=canceling&per_page=100" | python3 -c '
import sys, json
q = {"queue=hosted-linux-arm64", "queue=hosted-linux-arm64-small", "queue=hosted-linux", "queue=hosted-linux-small"}
hit = [b for b in json.load(sys.stdin) for j in b.get("jobs", []) if set(j.get("agent_query_rules") or []) & q
       and j.get("state") in ("scheduled", "assigned", "accepted", "running", "waiting", "limited", "limiting", "canceling")]
print("busy" if hit else "ok")') ;;
      gha)
        n=$(gh run list --repo "$GH_REPO" --limit 20 --json status -q '[.[] | select(.status != "completed")] | length')
        busy=$([ "$n" = 0 ] && echo ok || echo busy) ;;
    esac
    [ "$busy" = ok ] && return
    log "waiting: $1 is busy"
    sleep 30
  done
}

wait_idle "$platform"
from=0
[ "$platform" = bk-compute ] && from=$(wc -l < "$RUNNER_LOG" | tr -d ' ')

case "$platform" in
  bk-compute|hosted)
    slug=$(slug_for "$platform" "$project" "$variant")
    n=$(./trigger.sh "$slug" "fleet $variant $label" | cut -d' ' -f1)
    [[ "$n" =~ ^[0-9]+$ ]] || { log "trigger failed for $slug: $n"; exit 1; }
    ref="$slug#$n"
    ;;
  gha)
    wf=$([ "$variant" = lfl ] && echo "$project-fleet-lfl.yml" || echo "$project-fleet.yml")
    before=$(gh run list --repo "$GH_REPO" --workflow "$wf" --limit 1 --json databaseId -q '.[0].databaseId')
    if [ "$variant" = lfl ]; then gh workflow run --repo "$GH_REPO" "$wf"
    else gh workflow run --repo "$GH_REPO" "$wf" -f max_parallel=20; fi
    ref="$before"
    until [ -n "$ref" ] && [ "$ref" != "$before" ]; do sleep 5; ref=$(gh run list --repo "$GH_REPO" --workflow "$wf" --limit 1 --json databaseId -q '.[0].databaseId'); done
    ;;
esac
echo "$platform $project $variant $step $label $ref $from" > "$out/pending"
log "triggered $ref"
collect "$platform" "$project" "$variant" "$step" "$label" "$ref" "$from"
