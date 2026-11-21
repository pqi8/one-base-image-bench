#!/usr/bin/env bash
# run-fleet.sh <platform> <runs> <project...>: runs each fleet test <runs> times, one build at a time.
#   platform: bk-compute | hosted (one machine per job) | hosted-capped (3 at once)
#             | gha (one runner per job) | gha-capped (3 at once)
set -uo pipefail
cd "$(dirname "$0")"
platform="$1" runs="$2"; shift 2
export BUILDKITE_API_TOKEN="${BUILDKITE_API_TOKEN:-$(cat ~/.config/bk-bench/pqi-eval-plan-token)}"

for project in "$@"; do
  for i in $(seq "${START:-1}" $(( ${START:-1} + runs - 1 ))); do
    case "$platform" in
      bk-compute|hosted|hosted-capped)
        slug="obi-$platform-$project-fleet"
        variant=$([ "$platform" = hosted ] && echo uncapped || echo three-machines)
        n=$(./trigger.sh "$slug" "fleet run $i" | cut -d' ' -f1)
        ./wait-bk.sh "$slug#$n"
        until python3 collect_fleet.py bk "$slug" "$n" "$variant" "run-$i"; do sleep 30; done
        ;;
      gha|gha-capped)
        mp=$([ "$platform" = gha ] && echo 20 || echo 3)
        variant=$([ "$platform" = gha ] && echo uncapped || echo three-machines)
        before=$(gh run list --workflow "$project-fleet.yml" --limit 1 --json databaseId -q '.[0].databaseId')
        gh workflow run "$project-fleet.yml" -f max_parallel="$mp"
        id="$before"
        until [ -n "$id" ] && [ "$id" != "$before" ]; do sleep 5; id=$(gh run list --workflow "$project-fleet.yml" --limit 1 --json databaseId -q '.[0].databaseId'); done
        until gh run view "$id" --json status -q .status 2>/dev/null | grep -q completed; do sleep 30; done
        until python3 collect_fleet.py gha "$id" "$variant" "run-$i"; do sleep 30; done
        ;;
    esac
  done
done
echo "fleet done: $platform $*"
