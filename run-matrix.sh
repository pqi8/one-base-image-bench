#!/usr/bin/env bash
# run-matrix.sh <platform> <project...>: runs each project's benchmark one build at a time
# on one platform (bk-compute, hosted or gha) and appends every run to results.jsonl.
#
# Per project: three cold runs, then three warm runs. Cold run 1 saves the cache
# (bk-compute: a Buildkite artifact; GitHub: actions/cache). Hosted cache volumes fill
# on their first use, so hosted gets one extra warm run first, labelled warm-seed.
set -uo pipefail
cd "$(dirname "$0")"
platform="$1"; shift
export BUILDKITE_API_TOKEN="${BUILDKITE_API_TOKEN:-$(cat ~/.config/bk-bench/pqi-eval-plan-token)}"
API=https://api.buildkite.com/v2/organizations/pqi-eval-plan

bk_run() { # bk_run <slug> <label> [env...]: one build, waited for and collected
  local slug="$1" label="$2"; shift 2
  local n
  n=$(./trigger.sh "$slug" "$label" "$@" | cut -d' ' -f1)
  ./wait-bk.sh "$slug#$n"
  python3 collect.py bk "$slug" "$n" "$label"
  LAST_BUILD_ID=$(curl -sS -H "Authorization: Bearer $BUILDKITE_API_TOKEN" "$API/pipelines/$slug/builds/$n" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
}

gha_run() { # gha_run <project> <label> <cache> <save>
  local project="$1" label="$2" cache="$3" save="$4" before id
  before=$(gh run list --workflow "$project.yml" --limit 1 --json databaseId -q '.[0].databaseId')
  gh workflow run "$project.yml" -f cache="$cache" -f save_cache="$save"
  for _ in $(seq 60); do
    id=$(gh run list --workflow "$project.yml" --limit 1 --json databaseId -q '.[0].databaseId')
    [ "$id" != "$before" ] && break
    sleep 5
  done
  gh run watch "$id" --interval 30 >/dev/null 2>&1
  python3 collect.py gha "$id" "$label"
}

for project in "$@"; do
  case "$platform" in
    bk-compute)
      slug="obi-bk-compute-$project"
      bk_run "$slug" cold-1 BENCH_CACHE=cold BENCH_SAVE_CACHE=1
      seed="$LAST_BUILD_ID"
      bk_run "$slug" cold-2 BENCH_CACHE=cold
      bk_run "$slug" cold-3 BENCH_CACHE=cold
      for i in 1 2 3; do bk_run "$slug" "warm-$i" BENCH_CACHE=warm BENCH_CACHE_BUILD="$seed"; done
      ;;
    hosted)
      slug="obi-hosted-$project"
      for i in 1 2 3; do bk_run "$slug" "cold-$i" BENCH_CACHE=cold; done
      bk_run "$slug" warm-seed BENCH_CACHE=warm
      for i in 1 2 3; do bk_run "$slug" "warm-$i" BENCH_CACHE=warm; done
      ;;
    gha)
      gha_run "$project" cold-1 cold true
      gha_run "$project" cold-2 cold false
      gha_run "$project" cold-3 cold false
      for i in 1 2 3; do gha_run "$project" "warm-$i" warm false; done
      ;;
  esac
done
echo "matrix done: $platform $*"
