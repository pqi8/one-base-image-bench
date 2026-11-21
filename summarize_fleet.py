#!/usr/bin/env python3
"""Summarizes fleet-results.jsonl: wall clock, machine time and failures per project, platform and variant."""
import json
import os
import statistics
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ORDER = [("bk-compute", "three-machines"), ("buildkite-hosted", "three-machines"), ("github-actions", "three-machines"),
         ("buildkite-hosted", "uncapped"), ("github-actions", "uncapped")]
DESC = {
    ("bk-compute", "three-machines"): "bk-compute, Patrick's Mac (2 Medium + 1 Small, 10 vCPU / 36 GB)",
    ("buildkite-hosted", "three-machines"): "Buildkite hosted, at most 3 machines at once (12 vCPU / 48 GB)",
    ("github-actions", "three-machines"): "GitHub Actions, at most 3 runners at once (12 vCPU / 48 GB)",
    ("buildkite-hosted", "uncapped"): "Buildkite hosted, one machine per job",
    ("github-actions", "uncapped"): "GitHub Actions, one runner per job",
}


def rng(vals, scale=60, unit="min"):
    if not vals:
        return "–"
    return f"{statistics.median(vals) / scale:.1f} {unit} ({min(vals) / scale:.1f}–{max(vals) / scale:.1f}, n={len(vals)})"


def main():
    rows = [json.loads(l) for l in open(os.path.join(HERE, "fleet-results.jsonl")) if l.strip()]
    rows = [r for r in rows if "invalid" not in r["label"]]
    cells = defaultdict(list)
    for r in rows:
        cells[(r["project"], r["platform"], r["variant"])].append(r)
    for project, jobs in (("agent", 11), ("ghostty", 9)):
        print(f"### {project} fleet ({jobs} jobs)\n")
        print("| Platform | Wall clock (passed builds) | Machine time | Longest job wait | Builds with a failed job |")
        print("|---|---|---|---|---|")
        for pl, v in ORDER:
            rs = cells[(project, pl, v)]
            ok = [r for r in rs if not r["failed_jobs"]]
            bad = [r for r in rs if r["failed_jobs"]]
            print(f"| {DESC[(pl, v)]} | {rng([r['wall_s'] for r in ok])} | {rng([r['job_s_sum'] for r in ok])} "
                  f"| {rng([r['max_wait_s'] for r in ok], 1, 's')} | {len(bad)} of {len(rs)}"
                  + (f" ({'; '.join(', '.join(r['failed_jobs']) for r in bad)})" if bad else "") + " |")
        print()


if __name__ == "__main__":
    main()
