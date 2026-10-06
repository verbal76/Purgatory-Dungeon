#!/usr/bin/env python3
"""Has the SAME full test suite already passed on this EXACT commit? (docs/OTA.md section 11a, docs/RELEASES.md "CI cost")

The OTA publisher must not publish code the full headless suite has not passed on. Running that suite twice for one commit (once
for the pull request / merge / earlier publish attempt, once for the publication) costs about 15 billed minutes per repeat, so a
publication may REUSE a green result, but only one it can verify through the GitHub API itself. Everything fails closed to
"run the suite": any doubt, any API problem, any unexpected shape prints reuse=0 and the publisher runs the suite as before.

  proven_suite.py find --repo OWNER/NAME --sha SHA40 [--run-id CURRENT_RUN] [--api URL] [--max-age-days N]
        prints   reuse=0|1  reason=...  [source_run_id= source_run_url= source_workflow= source_event= ]
        (always exit 0: a missing proof is not an error, it just means the suite runs)
  proven_suite.py same-tree --sha SHA40
        exit 0 only when the tree of HEAD is the tree of SHA40 (the checked-out tree IS the commit's tree); used by the
        "Exact-SHA attestation" steps of ci.yml and ota-tests.yml
  proven_suite.py sources
        the allow-list as JSON (the workflow tests compare it with the real workflow files)

A run is accepted only when ALL of these hold (see check_run):
  * it belongs to THIS repository (not a fork), its workflow file path is one of SOURCES, and its event is allowed for that source;
  * run.head_sha == the pinned SHA (exact 40-hex equality), it is completed, its conclusion is allowed (never cancelled / skipped /
    timed out), it is attempt 1 (a re-run is never trusted), it is not the current run and it is not older than max-age-days;
  * the required job exists exactly once, belongs to that run and that SHA, is attempt 1, concluded success, and no step of it failed;
  * the suite step AND the attestation step both concluded success, in that order. The attestation step only runs after the suite
    passed AND `same-tree` proved that the tree the suite ran on is the tree of run.head_sha (this is what makes a pull_request run,
    which checks out a synthetic merge commit, equal to a run on the exact commit).
Trust model: identical to before. The workflow files are part of the reviewed commit, publication is authorised by a human pushing
`ota/<channel>/<sha>`, and the suite step names below are static strings tied to the workflow files by tests/test_ota_tools.py.
Standard library + git + (for `find`) one HTTPS GET family to the GitHub REST API.
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import otalib

SUITE_STEP_CI = "Validate project and run tests"
SUITE_STEP_OTA = "Full suite (tests/run_tests.sh)"
ATTEST_STEP = "Exact-SHA attestation (the suite above passed on the tree of the commit)"
OTA_SUITE_JOB = "Full test suite on the exact SHA / Full test suite on the exact SHA"   # caller job name / called job name

# workflow file path -> what a verified green result of the suite looks like there
SOURCES = {
    ".github/workflows/ci.yml": {
        "name": "CI",
        "events": ("push", "pull_request"),
        "run_conclusions": ("success",),            # a red run (any job) is never reused, even when the suite job was green
        "job": "validate-and-export",
        "steps": (SUITE_STEP_CI, ATTEST_STEP),
    },
    ".github/workflows/ota-publish.yml": {
        "name": "OTA publish",
        "events": ("push",),
        "run_conclusions": ("success", "failure"),   # an earlier publish attempt that failed AFTER its green suite job (the job decides)
        "job": OTA_SUITE_JOB,
        "steps": (SUITE_STEP_OTA, ATTEST_STEP),
    },
}
OK_STEP = ("success", "skipped")
MAX_RUNS = 10
DEFAULT_MAX_AGE_DAYS = 30


def _parse_time(text):
    try:
        return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except (TypeError, ValueError):
        return None


def _full_name(repo_obj):
    return str((repo_obj or {}).get("full_name") or "").lower() if isinstance(repo_obj, dict) else ""


def check_run(run, jobs, sha, repo, now, current_run_id=None, max_age_days=DEFAULT_MAX_AGE_DAYS):
    """[] when `run` (+ its job list) is a verified green result of the suite on exactly `sha`, else the list of reasons."""
    problems = []
    if not isinstance(run, dict):
        return ["run is not an object"]
    rid = run.get("id")
    spec = SOURCES.get(run.get("path"))
    if spec is None:
        return [f"run {rid}: workflow {run.get('path')!r} is not an allowed source of a suite result"]
    if run.get("head_sha") != sha:
        problems.append(f"run {rid}: head_sha {run.get('head_sha')!r} is not the pinned commit")
    if _full_name(run.get("repository")) != repo.lower() or _full_name(run.get("head_repository")) != repo.lower():
        problems.append(f"run {rid}: not a run of this repository's own branch (fork or other repository)")
    if not str(run.get("html_url") or "").startswith("https://"):
        problems.append(f"run {rid}: no https html_url to name it in the receipt")
    if run.get("event") not in spec["events"]:
        problems.append(f"run {rid}: event {run.get('event')!r} is not allowed for {spec['name']}")
    if run.get("status") != "completed":
        problems.append(f"run {rid}: status {run.get('status')!r}, not completed")
    if run.get("conclusion") not in spec["run_conclusions"]:
        problems.append(f"run {rid}: conclusion {run.get('conclusion')!r} is not one of {list(spec['run_conclusions'])}")
    if run.get("run_attempt") != 1:
        problems.append(f"run {rid}: run_attempt {run.get('run_attempt')!r}; a re-run is never trusted")
    if current_run_id is not None and str(rid) == str(current_run_id):
        problems.append(f"run {rid}: this is the current run")
    finished = _parse_time(run.get("updated_at"))
    if finished is None:
        problems.append(f"run {rid}: no usable updated_at")
    elif max_age_days is not None and (now - finished).total_seconds() > max_age_days * 86400:
        problems.append(f"run {rid}: older than {max_age_days} days")
    if finished is not None and finished > now + datetime.timedelta(minutes=5):
        problems.append(f"run {rid}: finished in the future")
    matching = [j for j in (jobs or []) if isinstance(j, dict) and j.get("name") == spec["job"]]
    if len(matching) != 1:
        problems.append(f"run {rid}: expected exactly one job named {spec['job']!r}, found {len(matching)}")
        return problems
    job = matching[0]
    if job.get("run_id") != rid:
        problems.append(f"run {rid}: the job belongs to run {job.get('run_id')!r}")
    if job.get("head_sha") != sha:
        problems.append(f"run {rid}: the job ran on {job.get('head_sha')!r}, not the pinned commit")
    if job.get("status") != "completed" or job.get("conclusion") != "success":
        problems.append(f"run {rid}: job {spec['job']!r} is {job.get('status')!r}/{job.get('conclusion')!r}, not completed/success")
    if job.get("run_attempt", 1) != 1:
        problems.append(f"run {rid}: the job ran in attempt {job.get('run_attempt')!r}")
    steps = job.get("steps")
    if not isinstance(steps, list) or not steps:
        problems.append(f"run {rid}: the job has no step list")
        return problems
    for s in steps:
        if s.get("conclusion") not in OK_STEP:
            problems.append(f"run {rid}: step {s.get('name')!r} is {s.get('conclusion')!r}")
    last = -1
    for want in spec["steps"]:
        hits = [s for s in steps if s.get("name") == want]
        if len(hits) != 1:
            problems.append(f"run {rid}: expected exactly one step {want!r}, found {len(hits)}")
            continue
        s = hits[0]
        if s.get("conclusion") != "success" or s.get("status") != "completed":
            problems.append(f"run {rid}: step {want!r} is {s.get('status')!r}/{s.get('conclusion')!r}, not completed/success")
        n = s.get("number")
        if not isinstance(n, int) or n <= last:
            problems.append(f"run {rid}: step {want!r} is out of order (the attestation must come after the suite)")
        else:
            last = n
    return problems


def decide(sha, repo, runs, jobs_of, now, current_run_id=None, max_age_days=DEFAULT_MAX_AGE_DAYS):
    """The decision: {'reuse': bool, 'reason': str, 'run': the accepted run or None}. `jobs_of(run_id)` -> that run's job list.
    The newest verified run wins; with none, the reason lists why each candidate was refused."""
    if not otalib.HEX40.match(sha or ""):
        return {"reuse": False, "reason": f"{sha!r} is not a full 40-hex commit id", "run": None}
    candidates = [r for r in (runs or []) if isinstance(r, dict) and r.get("path") in SOURCES]
    if not candidates:
        return {"reuse": False, "reason": "no earlier run of an allowed workflow for this commit", "run": None}
    candidates.sort(key=lambda r: str(r.get("updated_at") or ""), reverse=True)
    refused = []
    for run in candidates[:MAX_RUNS]:
        try:
            jobs = jobs_of(run.get("id"))
            problems = check_run(run, jobs, sha, repo, now, current_run_id, max_age_days)
        except Exception as exc:   # noqa: BLE001 - any doubt means "run the suite"
            problems = [f"run {run.get('id')}: could not be verified ({type(exc).__name__}: {exc})"]
        if not problems:
            return {"reuse": True, "reason": "verified", "run": run}
        refused.append(problems[0])
    return {"reuse": False, "reason": "; ".join(refused)[:900], "run": None}


# ---------------------------------------------------------------- GitHub REST (read only)

def _get(api, path, token="", timeout=30, retries=3, sleep=None):
    url = api.rstrip("/") + path
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "purgatory-ota-proven-suite", "X-GitHub-Api-Version": "2022-11-28"}
    if token:
        headers["Authorization"] = "Bearer " + token
    last = None
    for attempt in range(max(1, retries)):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            last = exc
            if exc.code < 500 and exc.code != 429:
                break
        except (urllib.error.URLError, OSError, ValueError) as exc:
            last = exc
        if attempt + 1 < retries:
            (sleep or time.sleep)(2 * (attempt + 1))
    raise otalib.OtaError(f"GET {path}: {last}")


def find(repo, sha, api="https://api.github.com", token="", current_run_id=None, max_age_days=DEFAULT_MAX_AGE_DAYS, now=None, get=None):
    """Query the API and decide. `get(path)` is injectable for tests. Never raises: a failure is reuse=False with the reason."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    get = get or (lambda path: _get(api, path, token))
    try:
        if not otalib.HEX40.match(sha or ""):
            return {"reuse": False, "reason": f"{sha!r} is not a full 40-hex commit id", "run": None}
        q = urllib.parse.urlencode({"head_sha": sha, "status": "completed", "per_page": 100})
        listing = get(f"/repos/{repo}/actions/runs?{q}")
        runs = listing.get("workflow_runs") if isinstance(listing, dict) else None
        if not isinstance(runs, list):
            return {"reuse": False, "reason": "unexpected shape of the runs listing", "run": None}

        def jobs_of(run_id):
            d = get(f"/repos/{repo}/actions/runs/{int(run_id)}/jobs?filter=latest&per_page=100")
            if not isinstance(d, dict) or not isinstance(d.get("jobs"), list):
                raise otalib.OtaError("unexpected shape of the jobs listing")
            if d.get("total_count", len(d["jobs"])) > len(d["jobs"]):
                raise otalib.OtaError("the jobs listing is paginated; not trusted")
            return d["jobs"]
        return decide(sha, repo, runs, jobs_of, now, current_run_id, max_age_days)
    except Exception as exc:   # noqa: BLE001
        return {"reuse": False, "reason": f"cannot verify an earlier result ({type(exc).__name__}: {exc})"[:400], "run": None}


def verdict_lines(d, repo=""):
    one = lambda s: " ".join(str(s).split())   # noqa: E731 - a GITHUB_OUTPUT value must be one line
    lines = [f"reuse={'1' if d['reuse'] else '0'}", f"reason={one(d['reason'])}"]
    run = d.get("run")
    if d["reuse"] and run:
        lines += [f"source_run_id={run['id']}", f"source_run_url={run.get('html_url') or ''}", f"source_workflow={run['path']}",
                  f"source_event={run['event']}"]
    return lines


# ---------------------------------------------------------------- same tree

def same_tree(sha, cwd=None, fetch=True):
    """(ok, why): the tree of HEAD equals the tree of commit `sha`. A pull_request run checks out a synthetic merge commit; when the
    head already contains the base, the merge's tree IS the head's tree, and only then is the run an exact-SHA run."""
    def git(*args, check=True):
        return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=check, timeout=300)
    if not otalib.HEX40.match(sha or ""):
        return False, f"{sha!r} is not a full 40-hex commit id"
    try:
        have = git("cat-file", "-e", f"{sha}^{{commit}}", check=False).returncode == 0
        if not have and fetch:
            git("fetch", "--no-tags", "--depth=1", "origin", sha)
        want = git("rev-parse", "--verify", f"{sha}^{{tree}}").stdout.strip()
        got = git("rev-parse", "--verify", "HEAD^{tree}").stdout.strip()
    except (subprocess.SubprocessError, OSError) as exc:
        return False, f"cannot compare trees: {exc}"
    if want != got:
        return False, f"the checked-out tree {got} is not the tree {want} of commit {sha}"
    return True, f"tree {got} is the tree of commit {sha}"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("find")
    p.add_argument("--repo", required=True)
    p.add_argument("--sha", required=True)
    p.add_argument("--run-id", default="")
    p.add_argument("--api", default=os.environ.get("GITHUB_API_URL") or "https://api.github.com")   # set by the Actions runner
    p.add_argument("--max-age-days", type=int, default=DEFAULT_MAX_AGE_DAYS)
    p = sub.add_parser("same-tree")
    p.add_argument("--sha", required=True)
    sub.add_parser("sources")
    a = ap.parse_args(argv)
    if a.cmd == "find":
        d = find(a.repo, a.sha, a.api, os.environ.get("GH_TOKEN", ""), a.run_id or None, a.max_age_days)
        print("\n".join(verdict_lines(d, a.repo)))
        return 0
    if a.cmd == "same-tree":
        ok, why = same_tree(a.sha)
        print(("OK: " if ok else "NOT THE SAME TREE: ") + why)
        return 0 if ok else 1
    print(json.dumps({"sources": SOURCES, "ota_suite_job": OTA_SUITE_JOB}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except otalib.OtaError as exc:
        print(f"proven_suite: {exc}", file=sys.stderr)
        sys.exit(1)
