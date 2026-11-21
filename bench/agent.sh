#!/usr/bin/env bash
# buildkite/agent: the Linux ARM64 test suite and the linux/arm64 binary build, in the
# repo's own Docker Compose `agent` service (.buildkite/Dockerfile-compile), as the
# agent's .buildkite/pipeline.yml runs them. Upstream splits the tests across parallel
# jobs; here one job runs all packages so every platform does the same work.
source "$(dirname "$0")/lib.sh"

AGENT_SHA="${AGENT_SHA:-23e06924dac1b683bc8653b731cd633af67d4a8a}"
GO_CACHE="$BENCH_CACHE_DIR/go"
mkdir -p "$GO_CACHE"

machine_info
[ "${BENCH_CACHE_TRANSPORT:-}" = artifact ] && [ "${BENCH_CACHE:-cold}" = warm ] && run_section "cache restore" artifact_cache_restore

run_section "checkout" clone_at https://github.com/buildkite/agent.git "$AGENT_SHA" src
cd src

compose() { docker compose -f .buildkite/docker-compose.yml "$@"; }
# The Go module and build caches live in .bench-cache so each platform's cache can carry them.
in_agent() {
  compose run --rm -v "$GO_CACHE:/go-cache" -e GOMODCACHE=/go-cache/mod -e GOCACHE=/go-cache/build \
    -e BUILDKITE_BUILD_NUMBER=1 agent bash -euo pipefail -c "git config --global --add safe.directory /work; $1"
}

run_section "docker image" compose build agent
run_section "go mod download" in_agent 'go mod download && go version'
run_section "go test" in_agent 'go tool gotestsum --format testname --junitfile junit.xml -- -count=1 ./...'
run_section "build linux/arm64" in_agent './scripts/build-binary.sh linux arm64 1 && ls -l pkg'

cd "$BENCH_ROOT"
[ "${BENCH_CACHE_TRANSPORT:-}" = artifact ] && [ "${BENCH_SAVE_CACHE:-}" = 1 ] && run_section "cache save" artifact_cache_save
finish
