#!/usr/bin/env python3
"""Collects benchmark results into results.jsonl, one line per run.

  collect.py gha <run id> [label]
  collect.py bk <pipeline slug> <build number> [label]

Each line records the platform, project, cache mode, machine info and section times
from the job log, and the queue wait and job duration from the platform's API.
Buildkite needs BUILDKITE_API_TOKEN; GitHub uses the gh CLI.
"""
import json
import os
import re
import subprocess
import sys
import urllib.request
from datetime import datetime

ORG = "pqi-eval-plan"
OUT = os.environ.get("BENCH_RESULTS_FILE") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "results.jsonl")
LINE = re.compile(r"BENCH\|([^|]+)\|([0-9.]+)\|(-?\d+)")
INFO = re.compile(r"BENCH_INFO\|([^|]+)\|(.*)$")


def ts(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None


def secs(a, b):
    return round((b - a).total_seconds(), 1) if a and b else None


def parse_log(text):
    sections, info = [], {}
    for raw in text.splitlines():
        line = re.sub(r"\x1b\[[0-9;]*m", "", raw)
        if m := LINE.search(line):
            sections.append({"name": m[1], "seconds": float(m[2]), "status": int(m[3])})
        elif m := INFO.search(line):
            info[m[1]] = m[2].strip()
    return sections, info


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def collect_gha(run_id, label):
    repo = "pqi8/one-base-image-bench"
    run = json.loads(gh("api", f"repos/{repo}/actions/runs/{run_id}"))
    jobs = json.loads(gh("api", f"repos/{repo}/actions/runs/{run_id}/jobs"))["jobs"]
    job = jobs[0]
    log = gh("run", "view", "--repo", repo, "--log", "--job", str(job["id"]))
    sections, info = parse_log(log)
    return {
        "platform": "github-actions",
        "project": run["name"],
        "id": str(run_id),
        "url": run["html_url"],
        "label": label,
        "state": job["conclusion"],
        "runner": job.get("labels"),
        "queue_wait_s": secs(ts(job["created_at"]), ts(job["started_at"])),
        "job_s": secs(ts(job["started_at"]), ts(job["completed_at"])),
        "steps": [
            {"name": s["name"], "seconds": secs(ts(s["started_at"]), ts(s["completed_at"]))}
            for s in job["steps"]
        ],
        "sections": sections,
        "info": info,
    }


def bk_get(path, raw=False):
    req = urllib.request.Request(
        f"https://api.buildkite.com/v2/organizations/{ORG}/{path}",
        headers={"Authorization": f"Bearer {os.environ['BUILDKITE_API_TOKEN']}"},
    )
    with urllib.request.urlopen(req) as resp:
        body = resp.read().decode()
    return body if raw else json.loads(body)


def collect_bk(pipeline, number, label):
    build = bk_get(f"pipelines/{pipeline}/builds/{number}")
    jobs = [j for j in build["jobs"] if j.get("type") == "script" and j.get("state") not in ("broken", "skipped")]
    job = jobs[0]
    # The jobs write their BENCH lines to build meta-data, which read_builds can see.
    sections, info = parse_log((build.get("meta_data") or {}).get("bench-results", ""))
    return {
        "platform": "bk-compute" if "bk-compute" in pipeline else "buildkite-hosted",
        "project": pipeline.split("-")[-1],
        "id": f"{pipeline}#{number}",
        "url": build["web_url"],
        "label": label,
        "state": job["state"],
        "agent": (job.get("agent") or {}).get("name"),
        # Runnable to started covers queueing and, on bk-compute and hosted, VM boot.
        "queue_wait_s": secs(ts(job.get("runnable_at")), ts(job.get("started_at"))),
        "job_s": secs(ts(job.get("started_at")), ts(job.get("finished_at"))),
        "build_s": secs(ts(build.get("created_at")), ts(build.get("finished_at"))),
        "sections": sections,
        "info": info,
    }


def main():
    kind = sys.argv[1]
    if kind == "gha":
        rec = collect_gha(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "")
    else:
        rec = collect_bk(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "")
    with open(OUT, "a") as f:
        f.write(json.dumps(rec) + "\n")
    total = sum(s["seconds"] for s in rec["sections"])
    print(f"{rec['platform']} {rec['project']} {rec['id']} {rec['state']} wait={rec['queue_wait_s']}s job={rec['job_s']}s sections={total:.0f}s")
    for s in rec["sections"]:
        print(f"  {s['name']:<20} {s['seconds']:>7.1f}s  exit {s['status']}")


if __name__ == "__main__":
    main()
