#!/usr/bin/env bash
# emulate-small.sh: restricts a GitHub 4 vCPU / 16 GB arm64 runner to the bk-compute Small VM's
# budget (2 vCPU, MemTotal 4,069,280 kB) for the like-for-like fleet test. Run as root, before
# the bench script. Fails (exit 1) unless the restriction took effect, so a job that didn't get
# the Small budget never produces a result.
#   CPUs 2 and up go offline, so nproc, Go and Zig see 2 CPUs.
#   2 MB hugepages reserve the rest of RAM: nothing but hugetlbfs can use them, so the kernel,
#   Docker and every container share what is left. Swap (4 GB on GitHub) is untouched.
# MemTotal in /proc/meminfo still reports the whole VM; BENCH_INFO|effective_mem_kb records
# MemTotal minus Hugetlb.
set -euo pipefail
TARGET_KB="${SMALL_MEM_KB:-4069280}"   # bk-compute Small VM's MemTotal
start=$(date +%s.%N)

# Hyper-V refuses to offline a CPU that a VMBus channel interrupt is bound to; move those to CPUs 0-1.
i=0
for ch in /sys/bus/vmbus/devices/*/channels/*/cpu; do
  [ -f "$ch" ] || continue
  if [ "$(cat "$ch")" -ge 2 ]; then echo $(( i % 2 )) > "$ch" || echo "could not move $ch"; i=$((i + 1)); fi
done
echo "moved $i VMBus channels to CPUs 0-1"

for c in /sys/devices/system/cpu/cpu[0-9]*; do
  n="${c##*cpu}"
  if [ "$n" -ge 2 ] && [ -f "$c/online" ]; then echo 0 > "$c/online"; fi
done
online="$(cat /sys/devices/system/cpu/online)"
echo "cpus online: $online, nproc: $(nproc)"
[ "$online" = "0-1" ] && [ "$(nproc)" = 2 ] || { echo "CPU offlining did not take effect"; exit 1; }

sync
echo 3 > /proc/sys/vm/drop_caches
echo 1 > /proc/sys/vm/compact_memory
hp_kb=$(awk '/^Hugepagesize:/ {print $2}' /proc/meminfo)
total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
want=$(( (total_kb - TARGET_KB) / hp_kb ))
for _ in 1 2 3; do
  echo "$want" > /proc/sys/vm/nr_hugepages
  [ "$(cat /proc/sys/vm/nr_hugepages)" -ge "$want" ] && break
  echo 1 > /proc/sys/vm/compact_memory
done
got=$(cat /proc/sys/vm/nr_hugepages)
effective_kb=$(( total_kb - got * hp_kb ))
echo "hugepages: $got x ${hp_kb} kB (wanted $want); effective memory $effective_kb kB, target $TARGET_KB kB"
# Within 2% of the target.
diff=$(( effective_kb > TARGET_KB ? effective_kb - TARGET_KB : TARGET_KB - effective_kb ))
[ $(( diff * 100 )) -le $(( TARGET_KB * 2 )) ] || { echo "memory reservation missed the target"; exit 1; }

# Docker sized itself when it started on 4 CPUs; restart it so it sees 2.
systemctl restart containerd docker
ncpu="$(docker info --format '{{.NCPU}}')"
echo "docker NCPU: $ncpu"
[ "$ncpu" = 2 ] || { echo "Docker still sees $ncpu CPUs"; exit 1; }

grep -E '^(MemTotal|MemAvailable|SwapTotal|Hugetlb):' /proc/meminfo
awk -v s="$start" -v e="$(date +%s.%N)" 'BEGIN { printf "BENCH|emulate small|%.1f|0\n", e - s }'
