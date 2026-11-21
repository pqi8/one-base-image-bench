#!/usr/bin/env bash
# One job of buildkite/agent's own CI split, for the fleet test:
#   agent-fleet.sh lint
#   agent-fleet.sh test <shard> <shards>
#   agent-fleet.sh race <shard> <shards>
#   agent-fleet.sh build <os> <arch>
# The commands match the agent's .buildkite/pipeline.yml, run in the repo's Docker Compose
# services; test shards split the packages the way the fleet pipeline does.
source "$(dirname "$0")/lib.sh"
export BENCH_META_KEY="bench-results-${BUILDKITE_JOB_ID:-local}"

AGENT_SHA="${AGENT_SHA:-23e06924dac1b683bc8653b731cd633af67d4a8a}"
mode="$1"; shift

machine_info
run_section "checkout" clone_at https://github.com/buildkite/agent.git "$AGENT_SHA" src
cd src
compose() { docker compose -f .buildkite/docker-compose.yml "$@"; }

case "$mode" in
  lint)
    run_section "docker image" compose build lint
    run_section "lint" compose run --rm lint sh -euc '
      git config --global --add safe.directory /work
      go mod tidy && git diff --no-ext-diff --exit-code
      out="$(go tool gofumpt -extra -l .)"; if [ -n "$out" ]; then echo "$out"; exit 1; fi
      go generate ./... && git diff --no-ext-diff --exit-code
      golangci-lint run'
    ;;
  test|race)
    shard="$1" shards="$2"
    race=""; [ "$mode" = race ] && race="-race"
    run_section "docker image" compose build agent
    run_section "go test $mode $shard/$shards" compose run --rm -e SHARD="$shard" -e SHARDS="$shards" -e RACE_FLAG="$race" agent bash -euo pipefail -c '
      git config --global --add safe.directory /work
      packages="$(go list ./... | awk -v n="$SHARDS" -v i="$SHARD" "NR % n == i")"
      go tool gotestsum --format testname -- -count=1 $RACE_FLAG $packages'
    ;;
  build)
    os="$1" arch="$2"
    run_section "docker image" compose build agent
    run_section "build $os/$arch" compose run --rm -e BUILDKITE_BUILD_NUMBER=1 agent bash -euo pipefail -c "
      git config --global --add safe.directory /work
      ./scripts/build-binary.sh $os $arch 1 && ls -l pkg"
    ;;
esac

cd "$BENCH_ROOT"
finish
