#!/usr/bin/env python3
"""Collects one like-for-like or uncapped fleet build into $BENCH_FLEET_RESULTS_FILE.

  collect_lfl.py bk <pipeline slug> <build number> <variant> <label>
  collect_lfl.py gha <run id> <variant> <label>

variant is "lfl" (2 Medium + 1 Small at once) or "uncapped" (one machine per job).

Per build it records:
  wall_s          build created to last job finished
  job_s_sum       sum of every job's run time (started to finished), also split by lane
  last_start_s    latest job start, measured from build creation
  start_delays    for the first jobs in each lane (as many as the lane has slots): start - build created
  handoff_gaps    for every later job in a lane: start - the moment a slot in that lane freed
  overlaps        other jobs on the same platform's queues that ran during this build (contention)
  valid           build passed, every expected job passed, every timestamp present
Each job also carries the BENCH_INFO shape lines, BENCH section times and BENCH_RETRY count from its log.
"""
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from datetime import datetime

OUT = os.environ["BENCH_FLEET_RESULTS_FILE"]
ORG = "https://api.buildkite.com/v2/organizations/pqi-eval-plan"
REPO = "pqi8/one-base-image-bench"
EXPECTED = {"agent": 11, "ghostty": 9}
SLOTS = {"medium": 2, "small": 1}
HOSTED_QUEUES = ("hosted-linux-arm64", "hosted-linux-arm64-small", "hosted-linux", "hosted-linux-small")
MAC_QUEUES = ("local-macs-medium", "local-macs-small")


def ts(v):
    return datetime.fromisoformat(v.replace("Z", "+00:00")) if v else None


def secs(a, b):
    return round((b - a).total_seconds(), 1) if a and b else None


def bk_get(path, raw=False):
    req = urllib.request.Request(path if path.startswith("http") else ORG + path,
                                 headers={"Authorization": f"Bearer {os.environ['BUILDKITE_API_TOKEN']}"})
    with urllib.request.urlopen(req) as r:
        body = r.read().decode("utf-8", "replace")
        return (body, r.headers.get("Link", "")) if raw else json.loads(body)


def bk_paged(path):
    url = ORG + path
    while url:
        body, link = bk_get(url, raw=True)
        yield from json.loads(body)
        m = re.search(r'<([^>]+)>; rel="next"', link)
        url = m.group(1) if m else None


def gh(*a):
    return subprocess.run(["gh", *a], check=True, capture_output=True, text=True).stdout


def parse_log(text):
    info, sections, retries = {}, {}, 0
    for line in text.splitlines():
        line = re.sub(r"^.*?(BENCH)", r"\1", line)  # drop Buildkite/GitHub timestamp prefixes
        if line.startswith("BENCH_INFO|"):
            _, k, v = (line.rstrip().split("|", 2) + [""])[:3]
            info[k] = v
        elif line.startswith("BENCH_RETRY|"):
            retries += 1
        elif line.startswith("BENCH|"):
            parts = line.rstrip().split("|")
            if len(parts) == 4:
                sections[parts[1]] = {"s": float(parts[2]), "status": int(parts[3])}
    delta = lambda k: (int(info[k + "_at_end"]) - int(info[k + "_at_start"])
                       if info.get(k + "_at_end", "").isdigit() and info.get(k + "_at_start", "").isdigit() else None)
    return {"info": info, "sections": sections, "retries": retries,
            "oom_kills": delta("oom_kill"), "pswpout": delta("pswpout")}


def bk_lane(job, variant):
    if variant == "uncapped":
        return "uncapped"
    rules = " ".join(job.get("agent_query_rules") or [])
    return "small" if "-small" in rules else "medium"


def bk(slug, number, variant):
    b = bk_get(f"/pipelines/{slug}/builds/{number}")
    created = ts(b["created_at"])
    jobs = []
    for j in b["jobs"]:
        if j.get("type") != "script":
            continue
        log = ""
        if j.get("state") not in ("broken", "skipped") and j.get("started_at"):
            try:
                log = bk_get(f"/pipelines/{slug}/builds/{number}/jobs/{j['id']}/log.txt", raw=True)[0]
            except Exception as e:  # noqa: BLE001 - a missing log leaves the job without shape data
                log = f"log fetch failed: {e}"
        jobs.append({
            "name": j["name"], "lane": bk_lane(j, variant), "state": j["state"],
            "exit_status": j.get("exit_status"), "agent": (j.get("agent") or {}).get("name"),
            "started": ts(j.get("started_at")), "finished": ts(j.get("finished_at")), **parse_log(log),
        })
    return b["web_url"], b["state"], created, ts(b.get("finished_at")), jobs


def gha(run_id, variant):
    run = json.loads(gh("api", f"repos/{REPO}/actions/runs/{run_id}"))
    raw = json.loads(gh("api", f"repos/{REPO}/actions/runs/{run_id}/jobs?per_page=100"))["jobs"]
    jobs = []
    for j in raw:
        try:
            log = gh("run", "view", "--repo", REPO, "--job", str(j["id"]), "--log")
        except subprocess.CalledProcessError as e:
            log = f"log fetch failed: {e.stderr}"
        lane = "uncapped" if variant == "uncapped" else j["name"].split(" ", 1)[0]
        jobs.append({
            "name": j["name"], "lane": lane, "state": j["conclusion"], "exit_status": None,
            "agent": j.get("runner_name"), "started": ts(j["started_at"]), "finished": ts(j["completed_at"]),
            **parse_log(log),
        })
    return run["html_url"], run["conclusion"], ts(run["created_at"]), ts(run["updated_at"]), jobs


def lane_timing(jobs, created):
    """Start delays for each lane's first jobs, and handoff gaps for the rest."""
    out = {}
    for lane in sorted({j["lane"] for j in jobs}):
        lj = sorted((j for j in jobs if j["lane"] == lane and j["started"]), key=lambda j: j["started"])
        slots = SLOTS.get(lane, len(lj))
        delays = [secs(created, j["started"]) for j in lj[:slots]]
        gaps = []
        for i in range(slots, len(lj)):
            finishes = sorted(j["finished"] for j in lj[:i] if j["finished"])
            if len(finishes) > i - slots:
                gaps.append(secs(finishes[i - slots], lj[i]["started"]))
        out[lane] = {
            "jobs": len([j for j in jobs if j["lane"] == lane]),
            "job_s_sum": round(sum(secs(j["started"], j["finished"]) or 0 for j in lj), 1),
            "finish_s": max((secs(created, j["finished"]) or 0) for j in lj) if lj else None,
            "start_delays": delays, "handoff_gaps": gaps,
        }
    return out


def overlaps_bk(slug, number, start, end, queues):
    """Jobs from other builds on these queues whose run overlapped [start, end]."""
    found = []
    q = urllib.parse.urlencode({"created_to": end.isoformat(), "finished_from": start.isoformat(), "per_page": 100})
    active = "state[]=running&state[]=scheduled&state[]=failing&state[]=canceling&per_page=100"
    builds = list(bk_paged(f"/builds?{q}")) + list(bk_paged(f"/builds?{active}"))
    seen = set()
    for b in builds:
        if (b["pipeline"]["slug"], b["number"]) in seen or (b["pipeline"]["slug"] == slug and str(b["number"]) == str(number)):
            continue
        seen.add((b["pipeline"]["slug"], b["number"]))
        for j in b.get("jobs", []):
            rules = j.get("agent_query_rules") or []
            if not any(f"queue={k}" == r for r in rules for k in queues):
                continue
            s, f = ts(j.get("started_at")), ts(j.get("finished_at")) or end
            if s and s < end and f > start:
                found.append(f"{b['pipeline']['slug']}#{b['number']} {j.get('name')}")
    return found


def overlaps_gha(run_id, start, end):
    runs = json.loads(gh("api", f"repos/{REPO}/actions/runs?per_page=50"))["workflow_runs"]
    return [f"{r['name']} {r['id']}" for r in runs if str(r["id"]) != str(run_id)
            and ts(r["run_started_at"] or r["created_at"]) < end and ts(r["updated_at"]) > start]


MAC_CPU_LIMIT = 300  # percent of one core; 3 of the Mac's 12
SHAPES = {  # lane -> (vcpus, effective memory band in kB)
    "small": ("2", 3_600_000, 4_300_000),
    "medium": ("4", 15_000_000, 17_000_000),
    "uncapped": ("4", 15_000_000, 17_000_000),
}


def setup_problems(platform, variant, jobs, lanes):
    """Reasons the build didn't test the declared setup: wrong or unproven machine shape, a GitHub Small
    job whose emulation step didn't succeed, or more jobs running at once in a lane than it has slots."""
    out = []
    for j in jobs:
        info = j["info"]
        if not j["started"]:
            continue
        if platform == "github-actions" and j["lane"] == "small" and j["sections"].get("emulate small", {}).get("status") != 0:
            out.append(f"{j['name']}: Small emulation did not succeed")
            continue
        if j["lane"] not in SHAPES:
            out.append(f"{j['name']}: no lane (expected a name starting with small or medium)")
            continue
        want_cpu, lo, hi = SHAPES[j["lane"]]
        mem = int(info["effective_mem_kb"]) if info.get("effective_mem_kb", "").isdigit() else None
        # A job that failed before printing its shape (machine lost at start, say) stays a failure:
        # it is a platform result, not a setup problem. A passed job must prove its shape.
        if "vcpus" not in info and j["state"] not in ("passed", "success"):
            continue
        if info.get("vcpus") != want_cpu or mem is None or not lo <= mem <= hi:
            out.append(f"{j['name']}: shape vcpus={info.get('vcpus')} mem_kb={mem}, want {want_cpu} vCPU in {lo}-{hi} kB")
    if variant == "lfl":
        for lane, t in lanes.items():
            if any(g < -2 for g in t["handoff_gaps"]):
                out.append(f"{lane} lane ran more jobs at once than it has slots")
    return out


def mac_load(start, end):
    """Median non-VM CPU on the Mac during the build, from mac-load.sh samples (local time)."""
    path = os.environ.get("BENCH_MAC_LOAD")
    vals = []
    if path and os.path.exists(path):
        lo, hi = start.astimezone().replace(tzinfo=None), end.astimezone().replace(tzinfo=None)
        for line in open(path):
            f = line.rstrip("\n").split("\t")
            if f[0] == "time" or len(f) < 5 or not f[4].isdigit():
                continue
            if lo <= datetime.fromisoformat(f[0]) <= hi:
                vals.append(int(f[4]))
    vals.sort()
    return {"samples": len(vals), "non_vm_cpu_median": vals[len(vals) // 2] if vals else None,
            "non_vm_cpu_max": vals[-1] if vals else None}


def already_recorded(url):
    if not os.path.exists(OUT):
        return False
    return any(json.loads(l).get("url") == url for l in open(OUT) if l.strip())


def main():
    kind = sys.argv[1]
    if kind == "bk":
        slug, number, variant, label = sys.argv[2:6]
        url, state, created, finished, jobs = bk(slug, number, variant)
        platform = "bk-compute" if "bk-compute" in slug else "buildkite-hosted"
        project = "agent" if "agent" in slug else "ghostty"
    else:
        run_id, variant, label = sys.argv[2:5]
        url, state, created, finished, jobs = gha(run_id, variant)
        platform = "github-actions"
        name = json.loads(gh("api", f"repos/{REPO}/actions/runs/{run_id}"))["name"]
        project = "agent" if name.startswith("agent") else "ghostty"

    if already_recorded(url):
        print(f"{platform} {project} {variant} {label} already recorded: {url}")
        return
    ends = [j["finished"] for j in jobs if j["finished"]]
    end = max(ends) if ends else (finished or created)
    if platform == "github-actions":
        overlaps = overlaps_gha(run_id, created, end)
    else:
        overlaps = overlaps_bk(slug, number, created, end, MAC_QUEUES if platform == "bk-compute" else HOSTED_QUEUES)

    passed = [j for j in jobs if j["state"] in ("passed", "success")]
    complete = all(j["started"] and j["finished"] for j in jobs)
    lanes = lane_timing(jobs, created)
    setup = setup_problems(platform, variant, jobs, lanes)
    excluded = []
    if overlaps:
        excluded.append("contended: " + "; ".join(overlaps[:3]))
    if setup:
        excluded.append("invalid setup: " + "; ".join(setup[:5]))
    mac = mac_load(created, end) if platform == "bk-compute" else None
    if mac is not None:
        if mac["samples"] < max(1, (secs(created, end) or 0) / 30 / 2):
            excluded.append(f"too few Mac load samples ({mac['samples']})")
        elif mac["non_vm_cpu_median"] > MAC_CPU_LIMIT:
            excluded.append(f"Mac contended: median non-VM CPU {mac['non_vm_cpu_median']:.0f}%")
    valid = (state in ("passed", "success") and len(jobs) == EXPECTED[project] and len(passed) == len(jobs)
             and complete and not excluded)
    rec = {
        "platform": platform, "project": project, "variant": variant, "step": os.environ.get("BENCH_STEP", label),
        "label": label, "url": url, "state": state, "created": created.isoformat(), "valid": valid, "excluded": excluded,
        "mac_load": mac, "runner_log_bad_lines": int(os.environ["BENCH_RUNNER_BAD"]) if os.environ.get("BENCH_RUNNER_BAD") else None,
        "wall_s": secs(created, end),
        "job_s_sum": round(sum(secs(j["started"], j["finished"]) or 0 for j in jobs), 1),
        "last_start_s": max((secs(created, j["started"]) or 0) for j in jobs),
        "lanes": lanes,
        "failed_jobs": [j["name"] for j in jobs if j not in passed],
        # SIGKILL (137) in a section or a rise in /proc/vmstat oom_kill; the latter is the kernel's own count.
        "suspected_oom": [j["name"] for j in jobs if j not in passed and (
            j["oom_kills"] or any(s["status"] == 137 for s in j["sections"].values()))],
        "oom_kills": {j["name"]: j["oom_kills"] for j in jobs if j["oom_kills"]},
        # Failed jobs that never printed their end counters (the job itself may have been killed).
        "cause_unknown": [j["name"] for j in jobs if j not in passed and j["oom_kills"] is None],
        "retries": sum(j["retries"] for j in jobs),
        "overlaps": overlaps,
        "jobs": [{**{k: v for k, v in j.items() if k not in ("started", "finished")},
                  "start_s": secs(created, j["started"]), "end_s": secs(created, j["finished"]),
                  "run_s": secs(j["started"], j["finished"])} for j in jobs],
    }
    with open(OUT, "a") as f:
        f.write(json.dumps(rec) + "\n")
    lane_s = " ".join(f"{k}:finish={v['finish_s']}s" for k, v in lanes.items())
    print(f"{platform} {project} {variant} {label} {state} valid={valid} wall={rec['wall_s'] / 60:.1f}min "
          f"jobs={len(jobs)} job-time={rec['job_s_sum'] / 60:.1f}min {lane_s} retries={rec['retries']} "
          f"failed={rec['failed_jobs']} excluded={excluded}")


if __name__ == "__main__":
    main()
