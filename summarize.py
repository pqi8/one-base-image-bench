#!/usr/bin/env python3
"""Summarizes results.jsonl into Markdown tables: median and range per project, platform and cache mode.

Job time is the platform's own job duration (start to finish of the job, after it was
picked up), minus the time spent saving a cache, which only the seeding run does.
Wait is from the job becoming runnable (Buildkite) or created (GitHub) until it started.
"""
import json
import os
import statistics
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
PLATFORMS = ["bk-compute", "buildkite-hosted", "github-actions"]
PROJECTS = ["agent", "ghostty", "t3code"]


def load():
    runs = [json.loads(l) for l in open(os.path.join(HERE, "results.jsonl")) if l.strip()]
    return [r for r in runs if r["label"].startswith(("cold-", "warm-")) and r["label"] != "warm-seed"]


def job_seconds(r):
    save = sum(s["seconds"] for s in r["sections"] if s["name"] == "cache save")
    save += sum(s["seconds"] or 0 for s in r.get("steps", []) if s["name"] == "Save .bench-cache")
    return r["job_s"] - save


def fmt(values):
    if not values:
        return "–"
    med = statistics.median(values)
    return f"{med / 60:.1f} min ({min(values) / 60:.1f}–{max(values) / 60:.1f}, n={len(values)})"


def main():
    runs = load()
    failed = [r for r in runs if r["state"] not in ("passed", "success")]
    cells = defaultdict(list)
    for r in runs:
        if r in failed:
            continue
        mode = r["label"].split("-")[0]
        # A warm run whose cache was empty at start ran cold; it gets its own row.
        # bk-compute restores its cache inside the script, after the size is recorded, so
        # there a warm run counts when its "cache restore" section passed.
        if r["platform"] == "bk-compute":
            hit = any(s["name"] == "cache restore" and s["status"] == 0 for s in r["sections"])
        else:
            hit = r["info"].get("cache_bytes_at_start") not in ("0", "", None)
        if mode == "warm" and not hit:
            mode = "warm-miss"
        cells[(r["project"], r["platform"], mode)].append(r)

    print("| Project | Platform | Cold job time | Warm job time | Wait to start (median) |")
    print("|---|---|---|---|---|")
    for p in PROJECTS:
        for pl in PLATFORMS:
            cold, warm = cells[(p, pl, "cold")], cells[(p, pl, "warm")]
            waits = [r["queue_wait_s"] for r in cold + warm if r["queue_wait_s"] is not None]
            wait = f"{statistics.median(waits):.0f} s" if waits else "–"
            print(f"| {p} | {pl} | {fmt([job_seconds(r) for r in cold])} | {fmt([job_seconds(r) for r in warm])} | {wait} |")

    print()
    for p in PROJECTS:
        names = []
        for pl in PLATFORMS:
            for mode in ("cold", "warm"):
                for r in cells[(p, pl, mode)]:
                    for s in r["sections"]:
                        if s["name"] not in names and s["name"] != "cache save":
                            names.append(s["name"])
        print(f"### {p}: section medians in seconds\n")
        cols = [(pl, m) for pl in PLATFORMS for m in ("cold", "warm")]
        print("| Section | " + " | ".join(f"{pl} {m}" for pl, m in cols) + " |")
        print("|---|" + "---:|" * len(cols))
        for n in names:
            row = []
            for pl, m in cols:
                vals = [s["seconds"] for r in cells[(p, pl, m)] for s in r["sections"] if s["name"] == n]
                row.append(f"{statistics.median(vals):.0f}" if vals else "–")
            print(f"| {n} | " + " | ".join(row) + " |")
        print()

    shapes = {}
    for r in runs:
        i = r["info"]
        shapes.setdefault(r["platform"], f"{i.get('vcpus')} vCPU, {int(i.get('mem_kb', 0)) / 1024 / 1024:.1f} GiB, page {i.get('page_size')}, kernel {i.get('kernel')}, {i.get('os')}")
    print("Machines:")
    for k, v in shapes.items():
        print(f"- {k}: {v}")
    if failed:
        print("\nFailed runs (excluded):")
        for r in failed:
            print(f"- {r['platform']} {r['project']} {r['label']} {r['url']}")


if __name__ == "__main__":
    sys.exit(main())
