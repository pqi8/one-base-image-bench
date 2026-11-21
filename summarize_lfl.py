#!/usr/bin/env python3
"""Summarizes a like-for-like fleet results file into one Markdown table per project.

  summarize_lfl.py <fleet-results.jsonl>

Rows: bk-compute, GitHub and hosted with 2 Medium + 1 Small at once ("lfl"), then GitHub and hosted
with one machine per job ("uncapped"). Shakedown builds and builds with a contending job are left out
of the tables and listed below them. Timing columns use valid builds only (build passed, all jobs
passed, all timestamps present); failure columns count every build in the cell.

Cost per build:
  hosted   job run seconds x $0.004 per vCPU-minute (Small 2 vCPU, Medium and uncapped 4 vCPU),
           billed per second; Buildkite doesn't bill machine startup or shutdown.
  GitHub   $0: standard runners are free in public repos. The hypothetical column prices every job,
           emulated Small jobs included, at the 4-core arm64 larger-runner rate ($0.008/min), each job
           rounded up to a whole minute, which is what an org would pay for a 4 vCPU arm64 runner.
  bk-compute  no metered fee; see the break-even lines.
"""
import json
import math
import statistics
import sys
from collections import defaultdict

HOSTED_PER_VCPU_MIN = 0.004
GH_4CORE_ARM_PER_MIN = 0.008
MAC_PRICE = 2799  # assumed purchase price of the Mac, USD; see the report
ROWS = [
    ("bk-compute", "lfl", "bk-compute: 2 Medium + 1 Small VMs on one Mac"),
    ("github-actions", "lfl", "GitHub: 2 at once on 4x16 + 1 at a time on 4x16 restricted to 2 vCPU / ~4 GB"),
    ("buildkite-hosted", "lfl", "Buildkite hosted: 2 at once on 4x16 + 1 at a time on 2x4"),
    ("github-actions", "uncapped", "GitHub: one 4x16 runner per job"),
    ("buildkite-hosted", "uncapped", "Buildkite hosted: one 4x16 machine per job"),
]


def med_rng(vals, scale=60.0, fmt="{:.1f}"):
    vals = [v for v in vals if v is not None]
    if not vals:
        return "–"
    f = lambda v: fmt.format(v / scale)
    return f"{f(statistics.median(vals))} ({f(min(vals))}–{f(max(vals))})"


def cost(r):
    if r["platform"] == "buildkite-hosted":
        return sum((j["run_s"] or 0) / 60 * HOSTED_PER_VCPU_MIN * (2 if j["lane"] == "small" else 4) for j in r["jobs"])
    if r["platform"] == "github-actions":
        return sum(math.ceil((j["run_s"] or 0) / 60) * GH_4CORE_ARM_PER_MIN for j in r["jobs"])
    return 0.0


def excluded(r):
    return "shakedown" in r.get("step", r["label"]) or bool(r.get("excluded"))


def main():
    rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
    cells = defaultdict(list)
    for r in rows:
        if not excluded(r):
            cells[(r["project"], r["platform"], r["variant"])].append(r)
    for project, njobs in (("agent", 11), ("ghostty", 9)):
        print(f"### {'buildkite/agent' if project == 'agent' else 'libghostty-vt'} fleet ({njobs} jobs)\n")
        print("| Platform | Valid builds | Wall clock, min: median (range) | Job time, min (Small / Medium) "
              "| Last job start, min | Slot handoff gap, s: median / max | First start, s "
              "| Failed jobs | 429 retries | Cost per build |")
        print("|---|---|---|---|---|---|---|---|---|---|")
        for platform, variant, desc in ROWS:
            rs = cells[(project, platform, variant)]
            if not rs:
                continue
            ok = [r for r in rs if r["valid"]]
            lane = lambda r, k: r["lanes"].get(k, {}).get("job_s_sum")
            split = (f" ({med_rng([lane(r, 'small') for r in ok])} / {med_rng([lane(r, 'medium') for r in ok])})"
                     if variant == "lfl" else "")
            gaps = [g for r in ok for l in r["lanes"].values() for g in l["handoff_gaps"]]
            gap = f"{statistics.median(gaps):.0f} / {max(gaps):.0f}" if gaps else "–"
            first = [min(d for l in r["lanes"].values() for d in l["start_delays"]) for r in ok]
            fails = [f"{r['label']}: {', '.join(r['failed_jobs'])}"
                     + (" (suspected OOM)" if r["suspected_oom"] else " (cause unknown)" if r.get("cause_unknown") else "")
                     for r in rs if r["failed_jobs"]]
            if platform == "github-actions":
                c = f"$0 (hypothetical ${statistics.median(cost(r) for r in ok):.2f})" if ok else "$0"
            elif platform == "buildkite-hosted":
                c = f"${statistics.median(cost(r) for r in ok):.2f}" if ok else "–"
            else:
                c = "no metered fee"
            print(f"| {desc} | {len(ok)} of {len(rs)} | {med_rng([r['wall_s'] for r in ok])} "
                  f"| {med_rng([r['job_s_sum'] for r in ok])}{split} | {med_rng([r['last_start_s'] for r in ok])} "
                  f"| {gap} | {med_rng(first, 1, '{:.0f}')} | {'; '.join(fails) or 'none'} "
                  f"| {sum(r['retries'] for r in rs)} | {c} |")
        print()
        mac = [r["mac_load"]["non_vm_cpu_median"] for r in cells[(project, "bk-compute", "lfl")] if r.get("mac_load")]
        if mac:
            print(f"bk-compute: median non-VM CPU on the Mac during the builds was {statistics.median(mac):.0f}% "
                  f"(range {min(mac)}–{max(mac)}%; 100% is one core). Its first start is short because the three VMs "
                  f"were booted and idle before each build; GitHub and hosted provision machines on demand.\n")
        emu = [sum(j["sections"].get("emulate small", {}).get("s", 0) for j in r["jobs"])
               for r in cells[(project, "github-actions", "lfl")] if r["valid"]]
        if emu:
            print(f"GitHub like-for-like: the Small emulation step (bench/emulate-small.sh) took a median "
                  f"{statistics.median(emu):.0f} s per build in total across the serial Small lane; it is included "
                  f"in GitHub's wall clock, job time and Small lane finish.\n")
        bad = [r["runner_log_bad_lines"] for r in cells[(project, "bk-compute", "lfl")] if r.get("runner_log_bad_lines") is not None]
        if bad:
            print(f"bk-compute runner log: {sum(bad)} drain / no-heartbeat lines across {len(bad)} builds.\n")
        hosted = [cost(r) for r in cells[(project, "buildkite-hosted", "lfl")] if r["valid"]]
        if hosted:
            per_day = MAC_PRICE / (3 * 365)
            print(f"Break-even: at a median ${statistics.median(hosted):.2f} per hosted like-for-like build, "
                  f"a ${MAC_PRICE} Mac written off over 3 years (${per_day:.2f} a day) matches hosted spend at "
                  f"{per_day / statistics.median(hosted):.0f} builds a day.\n")
    hosted_all = sum(cost(r) for r in rows if r["platform"] == "buildkite-hosted")
    gh_all = sum(cost(r) for r in rows if r["platform"] == "github-actions")
    print(f"Campaign spend, every attempt including failed, excluded and shakedown builds: Buildkite hosted "
          f"${hosted_all:.2f} (estimated from job run time); GitHub $0 actual, ${gh_all:.2f} at the hypothetical "
          f"4-core rate. The Mac break-even leaves out electricity and other running costs.\n")
    ex = [r for r in rows if excluded(r)]
    if ex:
        print("Left out of the tables:\n")
        for r in ex:
            why = "; ".join(r.get("excluded") or []) or "shakedown"
            why += f"; build {r['state']}" + (f", failed: {', '.join(r['failed_jobs'])}" if r["failed_jobs"] else "")
            print(f"- {r['platform']} {r['project']} {r['variant']} {r['label']}: {why} ({r['url']})")


if __name__ == "__main__":
    main()
