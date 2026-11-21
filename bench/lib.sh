# Shared helpers for the benchmark scripts. Sourced, not run.
#
# Every section prints a Buildkite log header and, when it ends, one line
#   BENCH|<section>|<seconds>|<exit status>
# which the result collector reads from the job log on every platform.
# A failed section doesn't stop the later ones; the script exits non-zero at the end.

set -uo pipefail

BENCH_ROOT="$(pwd)"
export BENCH_CACHE_DIR="$BENCH_ROOT/.bench-cache"
mkdir -p "$BENCH_CACHE_DIR"
BENCH_FAILED=""

# A job is root in its VM or container on every platform here; sudo only where needed.
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo -n"; fi
export SUDO

now() { date +%s.%N; }

# run_section <name> <command...>: runs the command in a subshell and times it.
run_section() {
  local name="$1"; shift
  echo "--- :stopwatch: $name"
  local start end status
  start=$(now)
  ( set -e; "$@" )
  status=$?
  end=$(now)
  awk -v n="$name" -v s="$start" -v e="$end" -v c="$status" 'BEGIN { printf "BENCH|%s|%.1f|%d\n", n, e - s, c }'
  if [ "$status" -ne 0 ]; then
    echo "^^^ +++"
    echo "Section '$name' failed with exit status $status"
    BENCH_FAILED="$BENCH_FAILED $name"
  fi
  return 0
}

# Prints the machine this job ran on, so every result records its shape.
machine_info() {
  echo "BENCH_INFO|platform|${BENCH_PLATFORM:-unknown}"
  echo "BENCH_INFO|cache_mode|${BENCH_CACHE:-cold}"
  echo "BENCH_INFO|kernel|$(uname -r)"
  echo "BENCH_INFO|page_size|$(getconf PAGESIZE)"
  echo "BENCH_INFO|vcpus|$(nproc)"
  echo "BENCH_INFO|mem_kb|$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  echo "BENCH_INFO|arch|$(uname -m)"
  echo "BENCH_INFO|os|$(. /etc/os-release && echo "$PRETTY_NAME")"
  echo "BENCH_INFO|cache_bytes_at_start|$(du -sb "$BENCH_CACHE_DIR" 2>/dev/null | cut -f1)"
}

# clone_at <url> <sha> <dir> [sparse patterns...]: shallow fetch of one commit.
clone_at() {
  local url="$1" sha="$2" dir="$3"; shift 3
  git init -q "$dir"
  git -C "$dir" remote add origin "$url"
  if [ "$#" -gt 0 ]; then
    git -C "$dir" config core.sparseCheckout true
    git -C "$dir" sparse-checkout set --no-cone "$@"
    git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$sha"
  else
    git -C "$dir" fetch -q --depth 1 origin "$sha"
  fi
  git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
  test "$(git -C "$dir" rev-parse HEAD)" = "$sha"
}

# Buildkite-artifact cache, for platforms with no cache of their own (bk-compute).
# BENCH_CACHE_BUILD names the build whose cache artifact a warm run restores.
artifact_cache_restore() {
  [ -n "${BENCH_CACHE_BUILD:-}" ] || { echo "BENCH_CACHE_BUILD not set"; return 1; }
  buildkite-agent artifact download "bench-cache.tar.zst" . --build "$BENCH_CACHE_BUILD"
  $SUDO tar -I zstd -xf bench-cache.tar.zst -C "$BENCH_ROOT"
  rm -f bench-cache.tar.zst
}

artifact_cache_save() {
  $SUDO tar -I 'zstd -T0 -3' -cf bench-cache.tar.zst -C "$BENCH_ROOT" .bench-cache
  ls -l bench-cache.tar.zst
  buildkite-agent artifact upload bench-cache.tar.zst
}

finish() {
  echo "BENCH_INFO|cache_bytes_at_end|$($SUDO du -sb "$BENCH_CACHE_DIR" 2>/dev/null | cut -f1)"
  if [ -n "$BENCH_FAILED" ]; then
    echo "Failed sections:$BENCH_FAILED"
    exit 1
  fi
}
