#!/usr/bin/env bash
# mac-load.sh <file>: every 30 s, appends the Mac's load average, free-memory percentage, swap used,
# and the CPU % of every process except the job VMs (com.apple.Virtualization.VirtualMachine).
# Used to spot bk-compute runs where other work on the Mac competed with the VMs.
out="$1"
[ -s "$out" ] || printf 'time\tload1\tmem_free_pct\tswap_used\tnon_vm_cpu_pct\ttop_non_vm\n' > "$out"
while :; do
  load=$(sysctl -n vm.loadavg | awk '{print $2}')
  free=$(memory_pressure -Q 2>/dev/null | awk -F': ' '/free percentage/ {print $2}')
  swap=$(sysctl -n vm.swapusage | awk '{print $6}')
  nonvm=$(ps -Ao pcpu=,comm= | awk '!/com.apple.Virtualization.VirtualMachine/ {s += $1} END {printf "%.0f", s}')
  top=$(ps -Ao pcpu=,comm= | grep -v com.apple.Virtualization.VirtualMachine | sort -nr | head -3 | awk '{n=$2; sub(/.*\//, "", n); printf "%s:%s ", n, $1}')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$load" "$free" "$swap" "$nonvm" "$top" >> "$out"
  sleep 30
done
