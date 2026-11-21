#!/usr/bin/env bash
# trigger.sh <pipeline slug> <message> [KEY=VALUE ...]: starts a build of main and prints its number.
set -euo pipefail
slug="$1" msg="$2"; shift 2
env_json=$(python3 -c 'import json,sys; print(json.dumps(dict(a.split("=",1) for a in sys.argv[1:])))' "$@")
curl -sS -X POST -H "Authorization: Bearer $BUILDKITE_API_TOKEN" -H 'Content-Type: application/json' \
  "https://api.buildkite.com/v2/organizations/pqi-eval-plan/pipelines/$slug/builds" \
  -d "{\"commit\":\"HEAD\",\"branch\":\"main\",\"message\":\"$msg\",\"env\":$env_json}" |
  python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("number"), d.get("web_url") or d)'
