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
BENCH_RESULTS="$BENCH_ROOT/bench-results.txt"
: > "$BENCH_RESULTS"

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
  mkdir -p "$BENCH_ROOT/section-logs"
  local key; key=$(printf '%s' "$name" | tr -c 'A-Za-z0-9_.-' '-')
  local log="$BENCH_ROOT/section-logs/$key.log"
  ( set -e; "$@" ) 2>&1 | tee "$log"
  status=${PIPESTATUS[0]}
  # A failed section's output tail goes to build meta-data too, for readers without log access.
  if [ "$status" -ne 0 ] && [ -n "${BUILDKITE_JOB_ID:-}" ]; then
    tail -c 60000 "$log" | buildkite-agent meta-data set "bench-fail-$key${BUILDKITE_PARALLEL_JOB:+-$BUILDKITE_PARALLEL_JOB}" || true
    grep -n -i -E -B2 -A8 'error|fatal|killed|out of memory|signal' "$log" | grep -v '(warn)' | tail -c 60000 |
      buildkite-agent meta-data set "bench-errors-$key${BUILDKITE_PARALLEL_JOB:+-$BUILDKITE_PARALLEL_JOB}" || true
  fi
  end=$(now)
  awk -v n="$name" -v s="$start" -v e="$end" -v c="$status" 'BEGIN { printf "BENCH|%s|%.1f|%d\n", n, e - s, c }' | tee -a "$BENCH_RESULTS"
  if [ "$status" -ne 0 ]; then
    echo "^^^ +++"
    echo "Section '$name' failed with exit status $status"
    BENCH_FAILED="$BENCH_FAILED $name"
  fi
  return 0
}

# Prints the machine this job ran on, so every result records its shape.
machine_info() {
  {
  echo "BENCH_INFO|platform|${BENCH_PLATFORM:-unknown}"
  echo "BENCH_INFO|cache_mode|${BENCH_CACHE:-cold}"
  echo "BENCH_INFO|kernel|$(uname -r)"
  echo "BENCH_INFO|page_size|$(getconf PAGESIZE)"
  echo "BENCH_INFO|vcpus|$(nproc)"
  echo "BENCH_INFO|mem_kb|$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  echo "BENCH_INFO|swap_kb|$(awk '/SwapTotal/ {print $2}' /proc/meminfo)"
  echo "BENCH_INFO|arch|$(uname -m)"
  echo "BENCH_INFO|os|$(. /etc/os-release && echo "$PRETTY_NAME")"
  echo "BENCH_INFO|cache_bytes_at_start|$(du -sb "$BENCH_CACHE_DIR" 2>/dev/null | cut -f1)"
  # The shape the job actually got. For an emulated Small (bench/emulate-small.sh), MemTotal
  # still reports the whole VM, so effective memory subtracts the reserved hugepages.
  echo "BENCH_INFO|cpus_online|$(cat /sys/devices/system/cpu/online 2>/dev/null)"
  echo "BENCH_INFO|cpu_model|$(lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^ +/, "", $2); print $2; exit}')"
  echo "BENCH_INFO|hugetlb_kb|$(awk '/^Hugetlb:/ {print $2}' /proc/meminfo)"
  echo "BENCH_INFO|effective_mem_kb|$(awk '/^MemTotal:/ {t=$2} /^Hugetlb:/ {h=$2} END {print t - h}' /proc/meminfo)"
  echo "BENCH_INFO|mem_available_kb_at_start|$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
  echo "BENCH_INFO|thp|$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)"
  echo "BENCH_INFO|oom_kill_at_start|$(awk '/^oom_kill / {print $2}' /proc/vmstat)"
  echo "BENCH_INFO|pswpout_at_start|$(awk '/^pswpout / {print $2}' /proc/vmstat)"
  } | tee -a "$BENCH_RESULTS"
}

# retry_rate_limited <command...>: runs the command up to 3 times, retrying only when it failed
# with a registry rate-limit error (HTTP 429). Each retry prints BENCH_RETRY|<attempt>; the
# backoff counts in the section's time. Any other failure returns at once.
retry_rate_limited() {
  local attempt out status
  set +e  # run_section's subshell has set -e and pipefail; this function reads each status itself
  for attempt in 1 2 3; do
    out="$(mktemp)"
    "$@" 2>&1 | tee "$out"
    status=${PIPESTATUS[0]}
    if [ "$status" -eq 0 ]; then rm -f "$out"; return 0; fi
    if [ "$attempt" -lt 3 ] && grep -q -E 'toomanyrequests|429 Too Many Requests' "$out"; then
      rm -f "$out"
      echo "BENCH_RETRY|$attempt" | tee -a "$BENCH_RESULTS"
      sleep $(( attempt == 1 ? 30 : 90 ))
      continue
    fi
    rm -f "$out"
    return "$status"
  done
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
  {
  echo "BENCH_INFO|cache_bytes_at_end|$($SUDO du -sb "$BENCH_CACHE_DIR" 2>/dev/null | cut -f1)"
  echo "BENCH_INFO|oom_kill_at_end|$(awk '/^oom_kill / {print $2}' /proc/vmstat)"
  echo "BENCH_INFO|pswpout_at_end|$(awk '/^pswpout / {print $2}' /proc/vmstat)"
  } | tee -a "$BENCH_RESULTS"
  # Build meta-data carries the results to readers with only read_builds (no log access).
  if [ -n "${BUILDKITE_JOB_ID:-}" ]; then
    buildkite-agent meta-data set "${BENCH_META_KEY:-bench-results}" < "$BENCH_RESULTS" || true
  fi
  if [ -n "$BENCH_FAILED" ]; then
    echo "Failed sections:$BENCH_FAILED"
    exit 1
  fi
}
