#!/usr/bin/env bash
# wait-bk.sh <slug>#<number> ...: returns when every build has finished, printing each state.
set -uo pipefail
for b in "$@"; do
  slug="${b%#*}" n="${b#*#}"
  while :; do
    s=$(curl -sS -H "Authorization: Bearer $BUILDKITE_API_TOKEN" "https://api.buildkite.com/v2/organizations/pqi-eval-plan/pipelines/$slug/builds/$n" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["state"], d.get("finished_at") or "")')
    case "$s" in passed*|failed*|canceled*|blocked*) echo "$b $s"; break;; esac
    sleep 30
  done
done
