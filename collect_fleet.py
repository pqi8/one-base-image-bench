#!/usr/bin/env python3
"""Collects one fleet-test build into fleet-results.jsonl.

  collect_fleet.py bk <pipeline slug> <build number> <variant> [label]
  collect_fleet.py gha <run id> <variant> [label]

Wall clock runs from the build being created to its last job finishing. Job seconds
sum every job's own run time, which shows how much machine time the split used.
"""
import json
import os
import subprocess
import sys
import urllib.request
from datetime import datetime

OUT = os.environ.get("BENCH_FLEET_RESULTS_FILE") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "fleet-results.jsonl")


def ts(v):
    return datetime.fromisoformat(v.replace("Z", "+00:00")) if v else None


def secs(a, b):
    return round((b - a).total_seconds(), 1) if a and b else None


def bk(slug, number):
    req = urllib.request.Request(
        f"https://api.buildkite.com/v2/organizations/pqi-eval-plan/pipelines/{slug}/builds/{number}",
        headers={"Authorization": f"Bearer {os.environ['BUILDKITE_API_TOKEN']}"},
    )
    b = json.load(urllib.request.urlopen(req))
    jobs = [j for j in b["jobs"] if j.get("type") == "script" and j.get("state") not in ("broken", "skipped")]
    created = ts(b["created_at"])
    out = []
    for j in jobs:
        out.append({
            "name": j["name"], "state": j["state"], "agent": (j.get("agent") or {}).get("name"),
            "wait_s": secs(ts(j.get("runnable_at")), ts(j.get("started_at"))),
            "run_s": secs(ts(j.get("started_at")), ts(j.get("finished_at"))),
            "end_s": secs(created, ts(j.get("finished_at"))),
        })
    return b["web_url"], b["state"], created, out


def gha(run_id):
    repo = "pqi8/one-base-image-bench"
    gh = lambda *a: subprocess.run(["gh", *a], check=True, capture_output=True, text=True).stdout
    run = json.loads(gh("api", f"repos/{repo}/actions/runs/{run_id}"))
    jobs = json.loads(gh("api", f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=50"))["jobs"]
    created = ts(run["created_at"])
    out = [{
        "name": j["name"], "state": j["conclusion"], "agent": j.get("runner_name"),
        "wait_s": secs(ts(j["created_at"]), ts(j["started_at"])),
        "run_s": secs(ts(j["started_at"]), ts(j["completed_at"])),
        "end_s": secs(created, ts(j["completed_at"])),
    } for j in jobs]
    return run["html_url"], run["conclusion"], created, out


def main():
    kind = sys.argv[1]
    if kind == "bk":
        slug, number, variant = sys.argv[2], sys.argv[3], sys.argv[4]
        label = sys.argv[5] if len(sys.argv) > 5 else ""
        url, state, _, jobs = bk(slug, number)
        platform = "bk-compute" if "bk-compute" in slug else "buildkite-hosted"
        project = "agent" if "agent" in slug else "ghostty"
    else:
        run_id, variant = sys.argv[2], sys.argv[3]
        label = sys.argv[4] if len(sys.argv) > 4 else ""
        url, state, _, jobs = gha(run_id)
        platform = "github-actions"
        project = "agent" if "agent" in subprocess.run(["gh", "run", "view", run_id, "--repo", "pqi8/one-base-image-bench", "--json", "workflowName", "-q", ".workflowName"], capture_output=True, text=True).stdout else "ghostty"
    rec = {
        "platform": platform, "project": project, "variant": variant, "label": label, "url": url, "state": state,
        "jobs": jobs,
        "wall_s": max((j["end_s"] or 0) for j in jobs),
        "job_s_sum": round(sum(j["run_s"] or 0 for j in jobs), 1),
        "max_wait_s": max((j["wait_s"] or 0) for j in jobs),
        "failed_jobs": [j["name"] for j in jobs if j["state"] not in ("passed", "success")],
    }
    with open(OUT, "a") as f:
        f.write(json.dumps(rec) + "\n")
    print(f"{platform} {project} {variant} {label} {state} wall={rec['wall_s'] / 60:.1f}min jobs={len(jobs)} "
          f"machine-time={rec['job_s_sum'] / 60:.1f}min max-wait={rec['max_wait_s']:.0f}s failed={rec['failed_jobs']}")


if __name__ == "__main__":
    main()
