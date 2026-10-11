#!/usr/bin/env python3
"""Tests for the ECONOMICS of the OTA / CI workflows (docs/OTA.md 11a "invariant -> enforcing step", docs/RELEASES.md "CI cost").

  python3 tests/test_ota_workflows.py [-v] [TestClass[.test_name]]

No Godot, no network, no GitHub: standard library (+ PyYAML for the structural part when it is installed, otherwise those tests print a
NOTICE and skip). Covers
  * tools/ota/proven_suite.py: the "is there a VERIFIED green result of the same suite for this exact SHA?" decision, against fixtures
    recorded from the real runs of this repository (tools/ota/fixtures/suite_runs_recorded.json) plus mutations: wrong SHA, cancelled,
    failed, re-run, wrong event, fork, stale, missing / duplicated / skipped / mis-ordered steps, API errors and odd shapes (all must end
    in "run the suite"), and the HTTP client against a local server (query parameters, token only when given, 5xx retried, 4xx not);
  * `same-tree` (the attestation) on temporary git repositories, including a merge commit whose tree is / is not the head's tree;
  * the structure of ota-publish.yml / ota-tests.yml / ci.yml: gate order, the truth table of the job conditions (publish can never run
    after a failed or cancelled suite or a failed prepare), permissions (contents: write on the publishing job only), concurrency
    (publication never cancelled; only test-only runs cancel), no secret reaches an echo / set -x / log, the constants that tie the
    verifier to the workflow files, and job timeouts.
"""
import copy
import datetime
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OTA = os.path.join(ROOT, "tools", "ota")
WORKFLOWS = os.path.join(ROOT, ".github", "workflows")
sys.path.insert(0, OTA)
sys.dont_write_bytecode = True

import otalib  # noqa: E402
import proven_suite as ps  # noqa: E402

REPO = "verbal76/Purgatory-Dungeon"
SHA = "6dd77bea6c73b5c677b0e6f7d0144ee7e72cd567"
OTHER = "0" * 40
NOW = datetime.datetime(2026, 10, 7, 12, 0, 0, tzinfo=datetime.timezone.utc)
GIT_ENV = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@e",
               GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull)


def notice(msg):
    print(f"NOTICE: {msg}", flush=True)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def wf(name):
    return read(os.path.join(WORKFLOWS, name))


def load_yaml(text):
    try:
        import yaml
    except ImportError:
        notice("PyYAML not installed: skipping the structural YAML assertions")
        return None
    return yaml.safe_load(text)


RECORDED = json.load(open(os.path.join(OTA, "fixtures", "suite_runs_recorded.json"), encoding="utf-8"))
REC_CI_RUN = next(r for r in RECORDED["runs"] if r["path"].endswith("ci.yml"))
REC_OTA_RUN = next(r for r in RECORDED["runs"] if r["path"].endswith("ota-publish.yml"))


def attested(jobs, run_id):
    """The recorded job lists predate the attestation steps: insert the two new steps right after the suite step, like the workflows do."""
    jobs = copy.deepcopy(jobs)
    spec = ps.SOURCES[next(r["path"] for r in RECORDED["runs"] if r["id"] == run_id)]
    for j in jobs:
        if j["name"] != spec["job"]:
            continue
        i = next(k for k, s in enumerate(j["steps"]) if s["name"] == spec["steps"][0])
        n = j["steps"][i]["number"]
        new = [{"name": "Exact-tree check (is the tested tree the tree of the pinned commit?)", "status": "completed", "conclusion": "success", "number": n + 1},
               {"name": ps.ATTEST_STEP, "status": "completed", "conclusion": "success", "number": n + 2}]
        for s in j["steps"][i + 1:]:
            s["number"] += 2
        j["steps"][i + 1:i + 1] = new
    return jobs


def case(kind="ci", sha=SHA):
    """(run, jobs) of a verified-green run on `sha` of the given kind, derived from the recorded real run."""
    src = REC_CI_RUN if kind == "ci" else REC_OTA_RUN
    run = copy.deepcopy(src)
    jobs = attested(RECORDED["jobs"][str(src["id"])], src["id"])
    run["head_sha"] = sha
    for j in jobs:
        j["head_sha"] = sha
    return run, jobs


def verdict(run, jobs, sha=SHA, **kw):
    return ps.decide(sha, REPO, [run], lambda rid: jobs, kw.pop("now", NOW), **kw)


class TestProvenSuiteDecision(unittest.TestCase):
    def accepted(self, run, jobs, **kw):
        d = verdict(run, jobs, **kw)
        self.assertTrue(d["reuse"], d["reason"])
        return d

    def refused(self, run, jobs, needle="", **kw):
        d = verdict(run, jobs, **kw)
        self.assertFalse(d["reuse"], "must NOT reuse: " + needle)
        self.assertIn(needle, d["reason"])
        return d

    # ---- the real recorded runs
    def test_recorded_real_runs_predate_the_attestation_and_are_refused(self):
        for src in (REC_CI_RUN, REC_OTA_RUN):
            d = verdict(src, RECORDED["jobs"][str(src["id"])])
            self.assertFalse(d["reuse"])
            self.assertIn("expected exactly one step", d["reason"], "a green suite WITHOUT the exact-tree attestation proves nothing about the tree")

    def test_recorded_shapes_match_what_the_verifier_reads(self):
        for src in (REC_CI_RUN, REC_OTA_RUN):
            self.assertIn(src["path"], ps.SOURCES)
            names = [j["name"] for j in RECORDED["jobs"][str(src["id"])]]
            self.assertIn(ps.SOURCES[src["path"]]["job"], names, "the job name constants match the real API output")
            job = next(j for j in RECORDED["jobs"][str(src["id"])] if j["name"] == ps.SOURCES[src["path"]]["job"])
            self.assertIn(ps.SOURCES[src["path"]]["steps"][0], [s["name"] for s in job["steps"]], "the suite step name matches the real API output")
            self.assertEqual((job["run_attempt"], job["conclusion"], job["run_id"]), (1, "success", src["id"]))
        self.assertEqual((REC_CI_RUN["event"], REC_OTA_RUN["event"]), ("pull_request", "push"))

    # ---- accepted
    def test_accepts_a_verified_ci_run_even_for_a_pull_request(self):
        run, jobs = case("ci")
        self.assertEqual(run["event"], "pull_request")
        d = self.accepted(run, jobs)
        self.assertEqual(d["run"]["id"], run["id"])
        run["event"] = "push"
        self.accepted(run, jobs)

    def test_accepts_an_earlier_publish_attempt_that_failed_after_its_green_suite(self):
        run, jobs = case("ota")
        for c in ("success", "failure"):
            run["conclusion"] = c
            self.accepted(run, jobs)

    def test_newest_verified_run_wins_and_bad_ones_are_skipped(self):
        good, gj = case("ci")
        old = copy.deepcopy(good)
        old["id"] = 5
        old["updated_at"] = "2026-10-05T10:00:00Z"
        bad = copy.deepcopy(good)
        bad["id"] = 9
        bad["updated_at"] = "2026-10-06T23:00:00Z"
        bad["conclusion"] = "cancelled"

        def jobs_of(rid):
            out = copy.deepcopy(gj)
            for j in out:
                j["run_id"] = rid
            return out
        d = ps.decide(SHA, REPO, [old, bad, good], jobs_of, NOW)
        self.assertTrue(d["reuse"])
        self.assertEqual(d["run"]["id"], good["id"], "the cancelled run (newest) is skipped; the newest VERIFIED run is used")

    # ---- refused: the run itself
    def test_refuses_every_run_level_doubt(self):
        for field, value, needle in (("head_sha", OTHER, "head_sha"), ("conclusion", "cancelled", "conclusion"), ("conclusion", "failure", "conclusion"),
                                     ("conclusion", "skipped", "conclusion"), ("conclusion", None, "conclusion"), ("status", "in_progress", "completed"),
                                     ("run_attempt", 2, "re-run"), ("event", "workflow_dispatch", "event"), ("event", "pull_request_target", "event"),
                                     ("path", ".github/workflows/other.yml", "not an allowed source"), ("path", None, "not an allowed source"),
                                     ("updated_at", "2025-01-01T00:00:00Z", "older than"), ("updated_at", "garbage", "updated_at"),
                                     ("updated_at", "2027-01-01T00:00:00Z", "future"), ("html_url", "", "html_url"), ("html_url", None, "html_url"),
                                     ("html_url", "http://x/run/1", "html_url")):
            run, jobs = case("ci")
            run[field] = value
            if field == "path":
                self.assertFalse(ps.decide(SHA, REPO, [run], lambda rid: jobs, NOW)["reuse"], value)
                continue
            self.refused(run, jobs, needle)
        run, jobs = case("ota")
        run["event"] = "pull_request"
        self.refused(run, jobs, "event")
        run["event"] = "push"
        run["conclusion"] = "cancelled"
        self.refused(run, jobs, "conclusion")

    def test_a_red_ci_run_is_never_reused_even_if_the_suite_job_was_green(self):
        run, jobs = case("ci")
        run["conclusion"] = "failure"
        self.refused(run, jobs, "conclusion")

    def test_refuses_forks_and_other_repositories(self):
        run, jobs = case("ci")
        run["head_repository"] = {"full_name": "someone/Purgatory-Dungeon"}
        self.refused(run, jobs, "fork")
        run, jobs = case("ci")
        run["repository"] = {"full_name": "someone/else"}
        self.refused(run, jobs, "fork")
        run, jobs = case("ci")
        run["head_repository"] = None
        self.refused(run, jobs, "fork")
        run, jobs = case("ci")
        run["repository"]["full_name"] = REPO.upper()
        run["head_repository"]["full_name"] = REPO.lower()
        self.accepted(run, jobs)

    def test_refuses_the_current_run_itself(self):
        run, jobs = case("ota")
        self.refused(run, jobs, "current run", current_run_id=run["id"])
        self.refused(run, jobs, "current run", current_run_id=str(run["id"]))
        self.accepted(run, jobs, current_run_id=run["id"] + 1)

    def test_refuses_a_malformed_pinned_sha(self):
        run, jobs = case("ci")
        for bad in ("", "abc", SHA.upper(), SHA[:-1], SHA + "0", None):
            d = ps.decide(bad, REPO, [run], lambda rid: jobs, NOW)
            self.assertFalse(d["reuse"], repr(bad))

    # ---- refused: the job and its steps
    def test_refuses_job_level_doubt(self):
        def mutate(kind, fn, needle):
            run, jobs = case(kind)
            fn(jobs, ps.SOURCES[run["path"]])
            self.refused(run, jobs, needle)
        def job(jobs, spec):
            return next(j for j in jobs if j["name"] == spec["job"])
        mutate("ci", lambda j, s: job(j, s).update(conclusion="failure"), "not completed/success")
        mutate("ci", lambda j, s: job(j, s).update(conclusion="cancelled"), "not completed/success")
        mutate("ci", lambda j, s: job(j, s).update(conclusion="skipped"), "not completed/success")
        mutate("ci", lambda j, s: job(j, s).update(status="in_progress"), "not completed/success")
        mutate("ci", lambda j, s: job(j, s).update(head_sha=OTHER), "ran on")
        mutate("ci", lambda j, s: job(j, s).update(run_id=1), "belongs to run")
        mutate("ci", lambda j, s: job(j, s).update(run_attempt=2), "attempt")
        mutate("ci", lambda j, s: j.remove(job(j, s)), "found 0")
        mutate("ci", lambda j, s: j.append(copy.deepcopy(job(j, s))), "found 2")
        mutate("ota", lambda j, s: j.remove(job(j, s)), "found 0")
        mutate("ota", lambda j, s: job(j, s).update(steps=[]), "no step list")
        mutate("ota", lambda j, s: job(j, s).pop("steps"), "no step list")

    def test_refuses_step_level_doubt(self):
        for kind in ("ci", "ota"):
            spec_steps = ps.SOURCES[case(kind)[0]["path"]]["steps"]
            for which, want in enumerate(spec_steps):
                for conc in ("skipped", "failure", "cancelled", None):
                    run, jobs = case(kind)
                    j = next(x for x in jobs if x["name"] == ps.SOURCES[run["path"]]["job"])
                    next(s for s in j["steps"] if s["name"] == want)["conclusion"] = conc
                    d = verdict(run, jobs)
                    self.assertFalse(d["reuse"], f"{kind}: step {want!r} = {conc}")
                run, jobs = case(kind)
                j = next(x for x in jobs if x["name"] == ps.SOURCES[run["path"]]["job"])
                j["steps"] = [s for s in j["steps"] if s["name"] != want]
                self.refused(run, jobs, "found 0")
                run, jobs = case(kind)
                j = next(x for x in jobs if x["name"] == ps.SOURCES[run["path"]]["job"])
                j["steps"].append(dict(next(s for s in j["steps"] if s["name"] == want), number=999))
                self.refused(run, jobs, "found 2")
            run, jobs = case(kind)
            j = next(x for x in jobs if x["name"] == ps.SOURCES[run["path"]]["job"])
            a = next(s for s in j["steps"] if s["name"] == spec_steps[0])
            b = next(s for s in j["steps"] if s["name"] == spec_steps[1])
            a["number"], b["number"] = b["number"], a["number"]
            self.refused(run, jobs, "out of order")

    def test_any_other_failed_step_in_the_job_refuses(self):
        run, jobs = case("ci")
        j = next(x for x in jobs if x["name"] == "validate-and-export")
        j["steps"][-1]["conclusion"] = "failure"   # e.g. "Upload Windows build" after a green suite: the run is red, not trusted
        self.refused(run, jobs, "failure")

    def test_the_old_suite_job_names_do_not_match_a_renamed_job(self):
        run, jobs = case("ota")
        for j in jobs:
            j["name"] = "suite"
        self.refused(run, jobs, "found 0")

    # ---- the decision as a whole
    def test_no_runs_or_only_foreign_workflows(self):
        self.assertFalse(ps.decide(SHA, REPO, [], lambda r: [], NOW)["reuse"])
        self.assertFalse(ps.decide(SHA, REPO, None, lambda r: [], NOW)["reuse"])
        run, jobs = case("ci")
        run["path"] = ".github/workflows/ota-tests.yml"
        d = ps.decide(SHA, REPO, [run], lambda r: jobs, NOW)
        self.assertFalse(d["reuse"])
        self.assertIn("no earlier run", d["reason"])
        self.assertFalse(ps.decide(SHA, REPO, ["junk", 3, None], lambda r: [], NOW)["reuse"])

    def test_an_exception_while_verifying_means_run_the_suite(self):
        run, _ = case("ci")
        def boom(rid):
            raise RuntimeError("api exploded")
        d = ps.decide(SHA, REPO, [run], boom, NOW)
        self.assertFalse(d["reuse"])
        self.assertIn("could not be verified", d["reason"])

    def test_only_a_bounded_number_of_runs_is_examined(self):
        run, jobs = case("ci")
        seen = []
        def jobs_of(rid):
            seen.append(rid)
            return []
        runs = []
        for i in range(40):
            r = copy.deepcopy(run)
            r["id"] = 100 + i
            runs.append(r)
        ps.decide(SHA, REPO, runs, jobs_of, NOW)
        self.assertLessEqual(len(seen), ps.MAX_RUNS)

    def test_verdict_lines_are_single_line_key_values(self):
        run, jobs = case("ci")
        d = verdict(run, jobs)
        lines = ps.verdict_lines(d)
        self.assertEqual(lines[0], "reuse=1")
        self.assertTrue(all(re.match(r"^[a-z_]+=[^\n]*$", l) for l in lines), lines)
        self.assertIn("source_run_url=" + run["html_url"], lines)
        nasty = {"reuse": False, "reason": "a\nreuse=1\r\nb", "run": None}
        out = ps.verdict_lines(nasty)
        self.assertEqual(len(out), 2, "a reason can never smuggle a second key into $GITHUB_OUTPUT")
        self.assertEqual(out[0], "reuse=0")
        self.assertNotIn("\n", out[1])


# ------------------------------------------------------------------------------------------------ the API client

class _Api(http.server.BaseHTTPRequestHandler):
    routes = {}
    seen = []
    status = 200

    def log_message(self, *a):
        pass

    def do_GET(self):  # noqa: N802
        type(self).seen.append((self.path, self.headers.get("Authorization")))
        if type(self).status != 200:
            self.send_response(type(self).status)
            self.end_headers()
            return
        path = self.path.split("?")[0]
        body = type(self).routes.get(path)
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class TestFindAgainstALocalApi(unittest.TestCase):
    def setUp(self):
        _Api.seen = []
        _Api.status = 200
        run, jobs = case("ci")
        _Api.routes = {f"/repos/{REPO}/actions/runs": {"total_count": 1, "workflow_runs": [run]},
                       f"/repos/{REPO}/actions/runs/{run['id']}/jobs": {"total_count": len(jobs), "jobs": jobs}}
        self.run_obj = run
        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Api)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.api = f"http://127.0.0.1:{self.srv.server_address[1]}"
        patcher = mock.patch.object(ps.time, "sleep", lambda s: None)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.srv.server_close)
        self.addCleanup(self.srv.shutdown)

    def test_finds_and_asks_the_right_questions(self):
        d = ps.find(REPO, SHA, self.api, token="tok", now=NOW)
        self.assertTrue(d["reuse"], d["reason"])
        paths = [p for p, _ in _Api.seen]
        self.assertIn("head_sha=" + SHA, paths[0])
        self.assertIn("status=completed", paths[0])
        self.assertIn("filter=latest", paths[1])
        self.assertTrue(all(a == "Bearer tok" for _, a in _Api.seen))

    def test_anonymous_when_there_is_no_token(self):
        ps.find(REPO, SHA, self.api, now=NOW)
        self.assertTrue(all(a is None for _, a in _Api.seen))

    def test_http_errors_end_in_run_the_suite(self):
        _Api.status = 500
        d = ps.find(REPO, SHA, self.api, now=NOW)
        self.assertFalse(d["reuse"])
        self.assertGreaterEqual(len(_Api.seen), 3, "5xx is retried")
        _Api.seen = []
        _Api.status = 403   # rate limit / forbidden: not retried, never trusted
        d = ps.find(REPO, SHA, self.api, now=NOW)
        self.assertFalse(d["reuse"])
        self.assertEqual(len(_Api.seen), 1)
        _Api.status = 404
        self.assertFalse(ps.find(REPO, SHA, self.api, now=NOW)["reuse"])

    def test_unreachable_api_and_odd_shapes_end_in_run_the_suite(self):
        self.assertFalse(ps.find(REPO, SHA, "http://127.0.0.1:9", now=NOW)["reuse"])
        for listing in ([], "x", {"workflow_runs": "no"}, {"workflow_runs": None}, {}):
            _Api.routes[f"/repos/{REPO}/actions/runs"] = listing
            self.assertFalse(ps.find(REPO, SHA, self.api, now=NOW)["reuse"], listing)
        _Api.routes[f"/repos/{REPO}/actions/runs"] = {"workflow_runs": [self.run_obj]}
        for jobs in ([], {"jobs": "no"}, {"jobs": None}, {"total_count": 500, "jobs": _Api.routes[f"/repos/{REPO}/actions/runs/{self.run_obj['id']}/jobs"]["jobs"]}):
            _Api.routes[f"/repos/{REPO}/actions/runs/{self.run_obj['id']}/jobs"] = jobs
            self.assertFalse(ps.find(REPO, SHA, self.api, now=NOW)["reuse"], str(jobs)[:60])

    def test_never_raises(self):
        self.assertFalse(ps.find(REPO, "nope", self.api, now=NOW)["reuse"])
        self.assertFalse(ps.find(REPO, SHA, self.api, now=NOW, get=lambda p: 1 / 0)["reuse"])

    def run_step_05b(self, api, extra_path=""):
        """Run the REAL script text of step 05b of ota-publish.yml (bash), against the local API, and return (GITHUB_OUTPUT lines, stdout)."""
        d = load_yaml(wf("ota-publish.yml"))
        if d is None:
            self.skipTest("PyYAML not installed")
        script = next(s for s in d["jobs"]["prepare"]["steps"] if s.get("name", "").startswith("05b"))["run"]
        work = tempfile.mkdtemp(prefix="step05b-")
        self.addCleanup(shutil.rmtree, work, True)
        os.symlink(os.path.join(ROOT, "tools"), os.path.join(work, "tools"))
        out_file = os.path.join(work, "github_output")
        env = dict(os.environ, GITHUB_REPOSITORY=REPO, SHA=SHA, GITHUB_RUN_ID="1", GITHUB_OUTPUT=out_file, GITHUB_API_URL=api, GH_TOKEN="t")
        r = subprocess.run(["bash", "-e", "-c", script], cwd=work, env=env, capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 0, "the step never fails the job: " + r.stdout + r.stderr)
        return open(out_file).read().splitlines() if os.path.exists(out_file) else [], r.stdout

    def test_the_real_step_script_reuses_and_falls_back(self):
        # the fixture's runs are old by the wall clock: reuse needs the age check satisfied, so refresh the timestamps
        now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        _Api.routes[f"/repos/{REPO}/actions/runs"]["workflow_runs"][0]["updated_at"] = now
        lines, out = self.run_step_05b(self.api)
        self.assertIn("reuse=1", lines, out)
        self.assertTrue(any(l.startswith("source_run_url=https://") for l in lines), lines)
        self.assertIn("step 06 is skipped", out)
        _Api.status = 500
        lines, out = self.run_step_05b(self.api)
        self.assertEqual([l for l in lines if l.startswith("reuse=")], ["reuse=0"], lines)
        self.assertIn("the full suite runs in step 06", out)
        lines, out = self.run_step_05b("http://127.0.0.1:9")
        self.assertEqual([l for l in lines if l.startswith("reuse=")], ["reuse=0"], lines)

    def test_cli_prints_key_values_and_always_exits_zero(self):
        env = dict(os.environ, GH_TOKEN="")
        for api, want in ((self.api, "reuse=1"), ("http://127.0.0.1:9", "reuse=0")):
            r = subprocess.run([sys.executable, os.path.join(OTA, "proven_suite.py"), "find", "--repo", REPO, "--sha", SHA, "--api", api,
                                "--max-age-days", "3650"], capture_output=True, text=True, env=env, timeout=120)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout.splitlines()[0], want)
        r = subprocess.run([sys.executable, os.path.join(OTA, "proven_suite.py"), "find", "--repo", REPO, "--sha", "bad"], capture_output=True, text=True, timeout=60)
        self.assertEqual((r.returncode, r.stdout.splitlines()[0]), (0, "reuse=0"))


# ------------------------------------------------------------------------------------------------ same-tree (the attestation)

def git(cwd, *args, check=True):
    r = subprocess.run(["git", *args], cwd=cwd, env=GIT_ENV, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise AssertionError(f"git {' '.join(args)}: {r.stderr}")
    return r.stdout.strip()


class TestSameTree(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp(prefix="same-tree-")
        self.addCleanup(shutil.rmtree, self.t, True)
        self.origin = os.path.join(self.t, "origin")
        os.makedirs(self.origin)
        git(self.origin, "init", "-q", "-b", "main")
        git(self.origin, "config", "uploadpack.allowAnySHA1InWant", "true")
        self.commit(self.origin, "a.txt", "one")
        self.base = git(self.origin, "rev-parse", "HEAD")

    def commit(self, repo, name, text, msg="c"):
        with open(os.path.join(repo, name), "w") as f:
            f.write(text)
        git(repo, "add", name)
        git(repo, "commit", "-q", "-m", msg)
        return git(repo, "rev-parse", "HEAD")

    def test_head_is_the_commit(self):
        ok, why = ps.same_tree(self.base, cwd=self.origin)
        self.assertTrue(ok, why)

    def test_a_different_commit_is_refused(self):
        other = self.commit(self.origin, "b.txt", "two")
        git(self.origin, "checkout", "-q", self.base)
        ok, why = ps.same_tree(other, cwd=self.origin)
        self.assertFalse(ok)
        self.assertIn("is not the tree", why)

    def test_a_merge_commit_whose_tree_equals_the_heads_tree(self):
        """pull_request runs check out a synthetic merge: exact only when the head already contains the base."""
        git(self.origin, "checkout", "-q", "-b", "feature")
        head = self.commit(self.origin, "b.txt", "two")
        git(self.origin, "checkout", "-q", "main")          # base unchanged since the branch point -> merge tree == head tree
        git(self.origin, "merge", "-q", "--no-ff", "-m", "merge", "feature")
        self.assertNotEqual(git(self.origin, "rev-parse", "HEAD"), head)
        ok, why = ps.same_tree(head, cwd=self.origin)
        self.assertTrue(ok, why)
        # the base moved on after the branch point: the merge tree is NOT the head's tree
        git(self.origin, "checkout", "-q", "-b", "feature2", self.base)
        head2 = self.commit(self.origin, "c.txt", "three")
        git(self.origin, "checkout", "-q", "main")
        self.commit(self.origin, "d.txt", "base moved on")
        git(self.origin, "merge", "-q", "--no-ff", "-m", "merge2", "feature2")
        ok, why = ps.same_tree(head2, cwd=self.origin)
        self.assertFalse(ok, "the suite ran on base+head, not on the head: no exact-SHA claim")

    def test_a_missing_commit_is_fetched_from_origin_once(self):
        git(self.origin, "checkout", "-q", "-b", "feature")
        head = self.commit(self.origin, "b.txt", "two")
        git(self.origin, "checkout", "-q", "main")
        git(self.origin, "merge", "-q", "--no-ff", "-m", "merge", "feature")
        clone = os.path.join(self.t, "clone")
        git(self.t, "clone", "-q", "--depth=1", "file://" + self.origin, clone)
        self.assertNotEqual(git(clone, "cat-file", "-t", head, check=False), "commit")
        ok, why = ps.same_tree(head, cwd=clone)
        self.assertTrue(ok, why)
        ok, why = ps.same_tree(head, cwd=clone, fetch=False)
        self.assertTrue(ok, "now present")

    def test_unfetchable_or_malformed_means_no(self):
        clone = os.path.join(self.t, "clone2")
        git(self.t, "clone", "-q", "file://" + self.origin, clone)
        ok, why = ps.same_tree("f" * 40, cwd=clone)
        self.assertFalse(ok)
        for bad in ("", "HEAD", "main", self.base[:10]):
            self.assertFalse(ps.same_tree(bad, cwd=clone)[0], bad)
        self.assertFalse(ps.same_tree(self.base, cwd=self.t)[0], "not a git repository")

    def test_cli_exit_status(self):
        r = subprocess.run([sys.executable, os.path.join(OTA, "proven_suite.py"), "same-tree", "--sha", self.base], cwd=self.origin, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        r = subprocess.run([sys.executable, os.path.join(OTA, "proven_suite.py"), "same-tree", "--sha", "e" * 40], cwd=self.origin, capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)


# ------------------------------------------------------------------------------------------------ tests/run_tests.sh helper block

class TestSuiteRunnerParallelMode(unittest.TestCase):
    """TEST_JOBS=N (opt-in) runs Godot stages concurrently; the default must be the old strictly sequential behaviour."""
    HARNESS = r'''
set -u
SCRATCH="$(mktemp -d)"; rc=0; FAILED_STAGES=(); STAGE_TIMES=()
sed -n '/^LOG=/,/^echo "=== release_tool check"/p' "$RUNNER" | sed '$d' > "$SCRATCH/block.sh"
source "$SCRATCH/block.sh"
mkdir -p "$SCRATCH/conc"
cat > "$SCRATCH/probe.sh" <<'EOS'
echo "P$1 seed=$SEED save=${PURGATORY_SAVE_ROOT:-none}"; touch "$2/conc/$$"; echo "$(ls "$2/conc" | wc -l)" >> "$2/conc.max"; sleep 0.4; rm -f "$2/conc/$$"
EOS
SEED=1 run "stage A" bash -c 'echo "A seed=$SEED"; sleep 0.5'
SEED=2 run "stage B (script error)" bash -c 'echo "SCRIPT ERROR: boom"'
SEED=3 run "stage C (exit 7)" bash -c 'exit 7'
for i in 1 2 3 4 5 6; do SEED=$i run "stage P$i" bash "$SCRATCH/probe.sh" $i "$SCRATCH"; done
TEST_FILTER='^nothing$' run "filtered out" echo never-printed
_par_flush all
echo "RESULT rc=$rc failed=${#FAILED_STAGES[@]} stages=${#STAGE_TIMES[@]} maxconc=$(sort -n "$SCRATCH/conc.max" | tail -1)"
printf 'FAILED %s\n' "${FAILED_STAGES[@]}"
rm -rf "$SCRATCH"
'''

    def run_it(self, jobs):
        env = dict(os.environ, RUNNER=os.path.join(ROOT, "tests", "run_tests.sh"))
        # Hermetic: when this file is run BY tests/run_tests.sh the parent already exported a scratch PURGATORY_SAVE_ROOT, which the
        # "sequential path leaves it alone" check below would see. Start from the environment a developer's shell has.
        env.pop("PURGATORY_SAVE_ROOT", None)
        env.pop("TEST_FILTER", None)
        if jobs is None:
            env.pop("TEST_JOBS", None)
        else:
            env["TEST_JOBS"] = jobs
        r = subprocess.run(["bash", "-c", self.HARNESS], capture_output=True, text=True, env=env, timeout=120)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def check_common(self, out):
        order = [l for l in out.splitlines() if l.startswith("=== ")]
        self.assertEqual(order, ["=== stage A", "=== stage B (script error)", "=== stage C (exit 7)"] + [f"=== stage P{i}" for i in range(1, 7)],
                         "stages are reported in order; a TEST_FILTER-ed stage never appears")
        self.assertIn("!!! FAILED (script errors): stage B (script error)", out)
        self.assertIn("!!! FAILED (exit 7): stage C (exit 7)", out)
        self.assertIn("RESULT rc=1 failed=2 stages=9", out, "exit status and SCRIPT ERROR are judged exactly like the sequential runner")
        for i in range(1, 7):
            self.assertIn(f"P{i} seed={i}", out, "a stage's own environment prefix reaches it")
        self.assertNotIn("never-printed", out)

    def test_default_is_sequential(self):
        for jobs in (None, "", "1", "0", "abc", "-3"):
            out = self.run_it(jobs)
            self.check_common(out)
            self.assertIn("maxconc=1", out, f"TEST_JOBS={jobs!r} must stay sequential")
            self.assertIn("save=none", out.split("P1 seed=1")[1].splitlines()[0], "the sequential path leaves PURGATORY_SAVE_ROOT alone (the script exports one)")

    def test_parallel_mode_is_bounded_ordered_and_isolated(self):
        out = self.run_it("3")
        self.check_common(out)
        m = re.search(r"maxconc=(\d+)", out)
        self.assertEqual(m.group(1), "3", "never more than TEST_JOBS stages at once, and really concurrent")
        roots = re.findall(r"save=(\S+)", out)
        self.assertEqual(len(roots), 6)
        self.assertEqual(len(set(roots)), 6, "every concurrent stage has its own PURGATORY_SAVE_ROOT")

    def test_ci_switch_is_a_variable_defaulting_to_sequential(self):
        ci = load_yaml(wf("ci.yml"))
        if ci is None:
            self.skipTest("PyYAML not installed")
        step = next(s for s in ci["jobs"]["validate-and-export"]["steps"] if s.get("name") == ps.SUITE_STEP_CI)
        self.assertEqual(step["env"]["TEST_JOBS"], "${{ vars.CI_TEST_JOBS }}")
        self.assertNotIn("TEST_JOBS", wf("ota-tests.yml"), "the release gate of an OTA stays sequential until the owner decides otherwise")


# ------------------------------------------------------------------------------------------------ workflow structure

def eval_expr(expr, ctx):
    """Evaluate the small subset of the GitHub expression language the job conditions use (names from ctx, == != && || ! parentheses)."""
    e = expr.strip()
    if e.startswith("${{") and e.endswith("}}"):
        e = e[3:-2].strip()
    e = e.replace("!cancelled()", "True").replace("success()", "True")
    e = re.sub(r"\bneeds\.([A-Za-z0-9_.]+)", lambda m: f"C[{m.group(1)!r}]", e)
    e = e.replace("&&", " and ").replace("||", " or ")
    return bool(eval(e, {"__builtins__": {}}, {"C": ctx, "True": True}))   # noqa: S307 - the expression is a repository file under test


class TestWorkflowStructure(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pub_text, cls.tests_text, cls.ci_text = wf("ota-publish.yml"), wf("ota-tests.yml"), wf("ci.yml")
        cls.pub, cls.tests, cls.ci = (load_yaml(t) for t in (cls.pub_text, cls.tests_text, cls.ci_text))
        if cls.pub is None:
            raise unittest.SkipTest("PyYAML not installed")

    # ---- the constants that tie the verifier to the files
    def test_verifier_constants_equal_the_workflow_files(self):
        ci_job = self.ci["jobs"]["validate-and-export"]
        self.assertNotIn("name", ci_job, "the API reports the job key as its name; a name: would break the verifier's job constant")
        self.assertEqual(ps.SOURCES[".github/workflows/ci.yml"]["job"], "validate-and-export")
        suite = next(s for s in ci_job["steps"] if s.get("name") == ps.SUITE_STEP_CI)
        self.assertEqual(suite["run"].strip(), 'tests/run_tests.sh "$GODOT"', "the FULL suite")
        self.assertNotIn("TEST_FILTER", json.dumps(suite), "no subset")
        names = [s.get("name") for s in ci_job["steps"]]
        self.assertEqual(names.count(ps.ATTEST_STEP), 1)
        self.assertLess(names.index(ps.SUITE_STEP_CI), names.index(ps.ATTEST_STEP))
        # OTA publication: caller job name / called job name
        caller = self.pub["jobs"]["tests"]["name"]
        callee = self.tests["jobs"]["suite"]["name"]
        self.assertEqual(ps.OTA_SUITE_JOB, f"{caller} / {callee}")
        osteps = [s.get("name") for s in self.tests["jobs"]["suite"]["steps"]]
        self.assertEqual(osteps.count(ps.SUITE_STEP_OTA), 1)
        self.assertEqual(osteps.count(ps.ATTEST_STEP), 1)
        self.assertLess(osteps.index(ps.SUITE_STEP_OTA), osteps.index(ps.ATTEST_STEP))
        suite2 = next(s for s in self.tests["jobs"]["suite"]["steps"] if s.get("name") == ps.SUITE_STEP_OTA)
        self.assertEqual(suite2["run"].strip(), 'tests/run_tests.sh "$GODOT"')
        for steps in (ci_job["steps"], self.tests["jobs"]["suite"]["steps"]):
            by = {s.get("name"): s for s in steps}
            self.assertEqual(by[ps.ATTEST_STEP]["if"], "steps.exacttree.outputs.same == 'true'", "skipped (not failed) unless the trees are identical")
            check = next(s for s in steps if s.get("id") == "exacttree")
            self.assertIn("proven_suite.py same-tree --sha", check["run"])
            self.assertLess(steps.index(by[ps.SUITE_STEP_CI] if ps.SUITE_STEP_CI in by else by[ps.SUITE_STEP_OTA]), steps.index(check))
            self.assertNotIn("continue-on-error", json.dumps(steps), "no step may fail open")

    def test_sources_only_name_events_their_workflow_triggers(self):
        self.assertTrue(set(ps.SOURCES[".github/workflows/ci.yml"]["events"]) <= set(self.ci[True]))
        self.assertTrue(set(ps.SOURCES[".github/workflows/ota-publish.yml"]["events"]) <= set(self.pub[True]))
        for path in ps.SOURCES:
            self.assertTrue(os.path.isfile(os.path.join(ROOT, path)), path)
        self.assertEqual(sorted(ps.SOURCES), [".github/workflows/ci.yml", ".github/workflows/ota-publish.yml"], "adding a source is a reviewed change to this test")
        out = subprocess.run([sys.executable, os.path.join(OTA, "proven_suite.py"), "sources"], capture_output=True, text=True).stdout
        self.assertEqual(json.loads(out)["ota_suite_job"], ps.OTA_SUITE_JOB)

    # ---- ordering (the owner's list)
    def publish_steps(self):
        return [s.get("name", "") for s in self.pub["jobs"]["publish"]["steps"]]

    def idx(self, prefix):
        names = self.publish_steps()
        hits = [i for i, n in enumerate(names) if n.startswith(prefix)]
        self.assertEqual(len(hits), 1, f"exactly one step starting {prefix!r}: {names}")
        return hits[0]

    def test_pin_before_tests_before_payload(self):
        prep = [s.get("name", "") for s in self.pub["jobs"]["prepare"]["steps"]]
        pin = next(i for i, n in enumerate(prep) if n.startswith("01 Pin"))
        for later in ("02a", "02b", "02c", "03 ", "04 ", "05 ", "05b"):
            self.assertGreater(next(i for i, n in enumerate(prep) if n.startswith(later)), pin, later)
        self.assertEqual(self.pub["jobs"]["tests"]["needs"], "prepare")
        self.assertEqual(self.pub["jobs"]["publish"]["needs"], ["prepare", "tests"], "payload, signing and publication come after the suite decision")
        payload_jobs = [n for n, j in self.pub["jobs"].items() if any("ota_build_payload.sh" in str(s.get("run", "")) for s in j.get("steps", []))]
        self.assertEqual(payload_jobs, ["publish"], "the payload is built only in the job that runs after the tests")
        self.assertLess(prep.index(next(n for n in prep if n.startswith("05 "))), prep.index(next(n for n in prep if n.startswith("05b"))))

    def test_signing_before_release_before_anonymous_verification_before_pointer(self):
        order = [self.idx(p) for p in ("07 Build the payload", "08 Build the manifest", "09 Signing key", "10 The key", "11 Sign", "12 Inspect",
                                      "13 Create the immutable release", "14 Re-download", "15 Verify the published objects", "16 Advance the channel pointer",
                                      "17 Publication receipt")]
        self.assertEqual(order, sorted(order))
        self.assertLess(self.idx("03b Native baseline APK"), self.idx("07 Build the payload"))

    def test_pointer_is_the_last_write_to_any_release(self):
        steps = self.pub["jobs"]["publish"]["steps"]
        writers = [i for i, s in enumerate(steps) if re.search(r"gh release (create|upload|edit|delete)|gh api (-X|--method) (POST|PATCH|PUT|DELETE)", str(s.get("run", "")))]
        self.assertEqual(writers, [self.idx("13 Create"), self.idx("16 Advance")], "only the immutable release (13) and the pointer (16) write")
        self.assertEqual(writers[-1], self.idx("16 Advance"))
        for s in steps[writers[-1] + 1:]:
            self.assertNotRegex(str(s.get("run", "")), r"gh (release|api)", "nothing after the pointer step touches a release")
        step16 = next(s for s in steps if s.get("name", "").startswith("16 "))["run"]
        self.assertLess(step16.index("pointer-decision"), step16.index("gh release upload"))
        self.assertLess(step16.index("gh release upload"), step16.index("pointer-confirm"))

    def test_every_publishing_step_after_the_key_is_guarded_by_the_key_check(self):
        for prefix in ("10 ", "11 ", "12 ", "13 ", "14 ", "15 ", "16 "):
            step = self.pub["jobs"]["publish"]["steps"][self.idx(prefix)]
            self.assertEqual(step["if"], "steps.key.outputs.ok == 'true'", prefix)

    def test_the_signature_is_checked_by_the_clients_own_code_twice(self):
        runs = " ".join(str(s.get("run", "")) for s in self.pub["jobs"]["publish"]["steps"])
        self.assertGreaterEqual(runs.count("ota_inspect_pack.gd"), 2)
        self.assertIn("openssl dgst -sha256 -sign", runs)
        self.assertLess(self.idx("10 "), self.idx("11 "))

    # ---- the job conditions: a truth table instead of a reading
    def test_job_condition_truth_table(self):
        tests_if = self.pub["jobs"]["tests"]["if"]
        publish_if = self.pub["jobs"]["publish"]["if"]
        results = ("success", "failure", "cancelled", "skipped")
        outs = ("1", "0", "")
        ran_publish = 0
        for prep in results:
            for proceed in outs:
                for reuse in outs:
                    for tests_res in results:
                        ctx = {"prepare.result": prep, "prepare.outputs.proceed": proceed, "prepare.outputs.suite_reuse": reuse, "tests.result": tests_res}
                        # GitHub: an `if` WITHOUT a status function gets an implicit success() of every need; one with !cancelled() / always() does not
                        implicit = "!cancelled()" not in publish_if and "always()" not in publish_if
                        needs_ok = prep == "success" and tests_res == "success" if implicit else True
                        publish_runs = needs_ok and eval_expr(publish_if, ctx)
                        if not publish_runs:
                            continue
                        ran_publish += 1
                        where = str(ctx)
                        self.assertEqual(prep, "success", where)
                        self.assertEqual(proceed, "1", "the public-repo gate said proceed: " + where)
                        self.assertNotIn(tests_res, ("failure", "cancelled"), "never after a failed or cancelled suite: " + where)
                        if tests_res == "skipped":
                            self.assertEqual(reuse, "1", "a skipped suite is only legitimate when a verified result was found: " + where)
                            self.assertFalse(prep != "success" or eval_expr(tests_if, ctx), "tests would have run: " + where)
        self.assertGreater(ran_publish, 0)
        # the tests job: runs exactly when a proceed=1 prepare found nothing reusable
        for proceed in outs:
            for reuse in outs:
                ctx = {"prepare.outputs.proceed": proceed, "prepare.outputs.suite_reuse": reuse}
                self.assertEqual(eval_expr(tests_if, ctx), proceed == "1" and reuse != "1", str(ctx))
        # and the two reachable end states of a normal run
        ok = {"prepare.result": "success", "prepare.outputs.proceed": "1"}
        self.assertTrue(eval_expr(publish_if, dict(ok, **{"prepare.outputs.suite_reuse": "0", "tests.result": "success"})))
        self.assertTrue(eval_expr(publish_if, dict(ok, **{"prepare.outputs.suite_reuse": "1", "tests.result": "skipped"})))
        self.assertFalse(eval_expr(publish_if, dict(ok, **{"prepare.outputs.suite_reuse": "0", "tests.result": "skipped"})))

    def test_suite_mode_is_recorded_for_the_receipt(self):
        env = self.pub["jobs"]["publish"]["env"]
        self.assertIn("needs.tests.result == 'success' && 'own-run'", env["SUITE_MODE"])
        self.assertIn("'reused'", env["SUITE_MODE"])
        step17 = next(s for s in self.pub["jobs"]["publish"]["steps"] if s.get("name", "").startswith("17 "))["run"]
        self.assertIn("--suite-mode", step17)
        self.assertIn("--suite-run-url", step17)

    def test_reuse_step_is_read_only_and_fails_closed(self):
        step = next(s for s in self.pub["jobs"]["prepare"]["steps"] if s.get("name", "").startswith("05b"))
        self.assertEqual(step["id"], "suite")
        self.assertEqual(step["env"]["GH_TOKEN"], "${{ github.token }}")
        self.assertIn("proven_suite.py find", step["run"])
        self.assertIn('|| echo "reuse=0"', step["run"], "a crash of the helper is 'run the suite'")
        self.assertEqual(self.pub["jobs"]["prepare"]["permissions"], {"contents": "read", "actions": "read"})
        self.assertNotRegex(step["run"], r"gh release|gh api", "it only reads through proven_suite.py")
        self.assertEqual(self.pub["jobs"]["prepare"]["outputs"]["suite_reuse"], "${{ steps.suite.outputs.reuse }}")

    def test_baseline_apk_is_byte_identical_between_the_jobs(self):
        step03 = next(s for s in self.pub["jobs"]["prepare"]["steps"] if s.get("name", "").startswith("03 "))["run"]
        self.assertIn("native_apk_sha256=", step03)
        step03b = next(s for s in self.pub["jobs"]["publish"]["steps"] if s.get("name", "").startswith("03b"))["run"]
        self.assertIn('= "$NATIVE_APK_SHA256"', step03b)
        self.assertIn("test -n \"$NATIVE_APK_SHA256\"", step03b, "an empty expected hash can never pass")
        self.assertEqual(self.pub["jobs"]["publish"]["env"]["NATIVE_APK_SHA256"], "${{ needs.prepare.outputs.native_apk_sha256 }}")

    # ---- permissions, concurrency, secrets
    def test_contents_write_only_on_the_publishing_job(self):
        self.assertEqual(self.pub["permissions"], {"contents": "read"})
        for name, job in self.pub["jobs"].items():
            perms = job.get("permissions", {})
            if name == "publish":
                self.assertEqual(perms, {"contents": "write"})
            else:
                self.assertNotIn("write", set(perms.values()), name)
        self.assertEqual(self.tests["permissions"], {"contents": "read"})
        self.assertEqual(self.tests["jobs"]["suite"]["permissions"], {"contents": "read"})
        for text in (self.pub_text, self.tests_text):
            for bad in ("write-all", "id-token", "actions: write", "packages: write", "pull-requests: write", "pull_request_target"):
                self.assertNotIn(bad, text)
        # the called workflow can never be handed more than read
        self.assertEqual(self.pub["jobs"]["tests"]["permissions"], {"contents": "read"})

    def test_publication_is_serialised_and_never_cancelled(self):
        self.assertEqual(self.pub["concurrency"], {"group": "ota-publish", "cancel-in-progress": False})
        self.assertNotIn("concurrency", self.tests, "the reusable suite inherits the caller's non-cancelling group")
        for job in self.tests["jobs"].values():
            self.assertNotIn("concurrency", job)

    def test_only_test_only_runs_are_cancellable(self):
        group = self.ci["concurrency"]
        self.assertEqual(group["cancel-in-progress"], "${{ github.event_name == 'pull_request' || github.ref == 'refs/heads/main' }}")
        for ref in ("refs/tags/v7", "refs/heads/release/v7", "refs/heads/promote/v7/1/" + SHA):
            ctx = {"event": "push", "ref": ref}
            self.assertFalse(ctx["event"] == "pull_request" or ctx["ref"] == "refs/heads/main", "releases and promotions are never cancelled: " + ref)
        self.assertNotIn("cancel-in-progress: true", self.pub_text)
        self.assertEqual(self.ci["jobs"]["android"]["concurrency"]["cancel-in-progress"], False, "the signing-key job is never cancelled")

    def test_secrets_are_never_printed_or_traced(self):
        for name, text in (("ota-publish.yml", self.pub_text), ("ota-tests.yml", self.tests_text), ("ci.yml", self.ci_text)):
            for bad in ("set -x", "set -o xtrace", "ACTIONS_STEP_DEBUG", "ACTIONS_RUNNER_DEBUG", "--debug", "curl -v", "::add-mask::"):
                self.assertNotIn(bad, text, f"{name}: {bad}")
        runs = []
        for wfd in (self.pub, self.tests, self.ci):
            for job in wfd["jobs"].values():
                for s in job.get("steps", []):
                    runs.append(str(s.get("run", "")))
        for run in runs:
            self.assertNotIn("${{ secrets.", run, "secrets are passed through env: only, never interpolated into a script")
            self.assertNotIn("${{ github.token", run)
            for line in run.splitlines():
                if re.match(r"\s*(echo|printf|cat|tee)\b", line):
                    self.assertNotRegex(line, r"\$\{?(OTA_SIGNING_KEY\w*|OTA_PRIVATE_KEY\w*|ANDROID_KEYSTORE\w*|GH_TOKEN|GITHUB_TOKEN)\b|secrets\.", line)
        for name, wfd in (("pub", self.pub), ("ci", self.ci)):
            for jn, job in wfd["jobs"].items():
                for s in job.get("steps", []):
                    self.assertNotIn("secrets.", str(s.get("with", "")), f"{name}.{jn}: a secret is never an action input")

    def test_signing_key_only_in_the_signing_step(self):
        holders = []
        for s in self.pub["jobs"]["publish"]["steps"]:
            if any("secrets.OTA_SIGNING_KEY_PEM_BASE64" in str(v) for v in (s.get("env") or {}).values()):
                holders.append(s["name"].split(" ")[0])
        self.assertEqual(holders, ["09"])
        self.assertIn("shred -u", self.pub_text)
        self.assertEqual(sorted(set(re.findall(r"secrets\.([A-Za-z0-9_]+)", self.pub_text))), ["OTA_SIGNING_KEY_PEM_BASE64"])

    def test_the_trigger_is_unchanged(self):
        self.assertEqual(self.pub[True], {"push": {"branches": ["ota/**"]}})
        self.assertEqual(self.tests[True]["workflow_call"]["inputs"]["ref"]["required"], True)
        self.assertEqual(list(self.tests[True]), ["workflow_call"])

    # ---- a local stand-in for actionlint (not installable offline): shell syntax and expression references
    def all_jobs(self):
        for label, wfd in (("ota-publish", self.pub), ("ota-tests", self.tests), ("ci", self.ci)):
            for name, job in wfd["jobs"].items():
                yield label, name, job, wfd

    def test_every_run_script_is_valid_bash(self):
        checked = 0
        for label, name, job, _ in self.all_jobs():
            for i, step in enumerate(job.get("steps", [])):
                script = step.get("run")
                if not script:
                    continue
                script = re.sub(r"\$\{\{.*?\}\}", "EXPR", script)
                r = subprocess.run(["bash", "-n"], input=script, capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, f"{label}.{name} step {i} ({step.get('name')}): {r.stderr}")
                checked += 1
        self.assertGreater(checked, 40)

    def test_expression_references_resolve(self):
        """A typo in steps.<id>.outputs.<name> / needs.<job>.outputs.<name> would only show up in a paid run: check them here."""
        for label, name, job, wfd in self.all_jobs():
            text = json.dumps(job)
            ids = {s.get("id") for s in job.get("steps", []) if s.get("id")}
            for m in re.finditer(r"steps\.([A-Za-z0-9_-]+)\.", text):
                self.assertIn(m.group(1), ids, f"{label}.{name}: steps.{m.group(1)} does not exist")
            needs = job.get("needs", [])
            needs = [needs] if isinstance(needs, str) else needs
            for m in re.finditer(r"needs\.([A-Za-z0-9_-]+)\.(outputs\.([A-Za-z0-9_]+)|result)", text):
                self.assertIn(m.group(1), needs, f"{label}.{name}: needs.{m.group(1)} is not a dependency")
                if m.group(3):
                    self.assertIn(m.group(3), wfd["jobs"][m.group(1)].get("outputs", {}), f"{label}.{name}: {m.group(1)} has no output {m.group(3)}")
            for oname, expr in (job.get("outputs") or {}).items():
                for m in re.finditer(r"steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_]+)", expr):
                    self.assertIn(m.group(1), ids, f"{label}.{name}: output {oname} reads a missing step")
        # a step output that is read must be WRITTEN by its step (grep the producing script for `name=`)
        for label, name, job, _ in self.all_jobs():
            text = json.dumps(job)
            for m in set(re.findall(r"steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_]+)", text)):
                step = next(s for s in job["steps"] if s.get("id") == m[0])
                body = str(step.get("run", "")) + str(step.get("uses", ""))
                if step.get("run"):
                    explicit = re.search(rf"(?m)\b{re.escape(m[1])}=", body) is not None
                    streamed = re.search(r"(tee -a|cat \S+ >>|grep [^\n]*>>) \"?\$GITHUB_OUTPUT", body) is not None   # a whole key=value file is appended
                    self.assertTrue(explicit or streamed, f"{label}.{name}: step {m[0]} never writes output {m[1]}")

    def test_the_publish_job_variable_names_are_all_defined(self):
        """Every $UPPER_CASE variable a publish step expands is defined by the job env, an earlier GITHUB_ENV write, the runner or the step itself."""
        job = self.pub["jobs"]["publish"]
        defined = set(job["env"]) | set(self.pub["env"]) | {"GITHUB_REPOSITORY", "GITHUB_SHA", "GITHUB_RUN_ID", "GITHUB_RUN_NUMBER", "GITHUB_RUN_ATTEMPT", "GITHUB_SERVER_URL",
                                                              "GITHUB_ENV", "GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY", "RUNNER_TEMP", "HOME", "GODOT", "OUT",
                                                              "OTA_PRIVATE_KEY_PATH"}   # the last one is exported by the sourced tools/ota/keys.sh
        for step in job["steps"]:
            run = str(step.get("run", ""))
            for m in re.finditer(r'echo "([A-Z][A-Z0-9_]+)=[^"]*"? >> "\$GITHUB_ENV"', run):
                defined.add(m.group(1))
            for m in re.finditer(r"([A-Z][A-Z0-9_]+)=", run):
                defined.add(m.group(1))
            defined |= set((step.get("env") or {}))
        used = set()
        for step in job["steps"]:
            for m in re.finditer(r"\$\{?([A-Z][A-Z0-9_]+)\}?", str(step.get("run", ""))):
                used.add(m.group(1))
        missing = sorted(u for u in used if u not in defined and not u.startswith(("GITHUB_", "RUNNER_")) and u not in ("PATH", "RANDOM"))
        self.assertEqual(missing, [], "variables used but never defined in the publish job")

    # ---- economics
    def test_no_job_can_run_for_hours(self):
        for label, wfd in (("ota-publish", self.pub), ("ota-tests", self.tests), ("ci", self.ci)):
            for name, job in wfd["jobs"].items():
                if "uses" in job:
                    continue
                self.assertIn("timeout-minutes", job, f"{label}.{name}: the default is 360 minutes")
                self.assertLessEqual(job["timeout-minutes"], 60, f"{label}.{name}")

    def test_the_suite_is_not_duplicated_inside_one_ci_run(self):
        code = re.sub(r"(?m)^\s*#.*$", "", self.ci_text + self.pub_text + self.tests_text)
        self.assertNotIn("TEST_FILTER", code, "no subset of the suite is re-run on the same commit")
        runners = [(n, j) for n, j in self.ci["jobs"].items() if any("run_tests.sh" in str(s.get("run", "")) for s in j.get("steps", []))]
        self.assertEqual([n for n, _ in runners], ["validate-and-export"], "one job runs the suite per ci.yml run")
        self.assertEqual(self.ci["jobs"]["android"]["needs"], "validate-and-export")
        self.assertEqual(sorted(self.ci["jobs"]["publish"]["needs"]), ["android", "validate-and-export"])

    def test_docs_only_changes_cost_nothing(self):
        pr = self.ci[True]["pull_request"]
        self.assertEqual(pr["types"], ["opened", "synchronize", "reopened", "ready_for_review"])
        for p in ("docs/**", "**/*.md"):
            self.assertIn(p, pr["paths-ignore"])
        self.assertIn("!github.event.pull_request.draft", self.ci["jobs"]["validate-and-export"]["if"], "drafts never run")

    def test_artifacts_expire(self):
        for text in (self.pub_text, self.ci_text):
            d = load_yaml(text)
            for job in d["jobs"].values():
                for s in job.get("steps", []):
                    if str(s.get("uses", "")).startswith("actions/upload-artifact"):
                        with_ = s.get("with", {})
                        self.assertLessEqual(int(with_.get("retention-days", 90)), 14, s.get("name"))
        self.assertIn("retention-days", self.pub_text, "the receipt artifact has an explicit, short retention")


if __name__ == "__main__":
    unittest.main(verbosity=1)
