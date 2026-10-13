#!/usr/bin/env python3
"""One authoritative product history (docs/SOURCE_OF_TRUTH.md): tests for the enforcement.

  python3 tests/test_source_of_truth.py [-v] [TestClass[.test_name]]

No Godot, no network. Standard library (+ PyYAML for the workflow-wiring tests when installed; otherwise they print a NOTICE and skip).
  * tools/source_audit.py lineage-gate / base-check on throwaway git repositories: a release must contain every earlier release tag, a
    side branch / a stale snapshot is refused, a release number is never reused or moved, a shallow clone is "cannot decide" (exit 2,
    never a silent pass), the tag must be v<VERSION>;
  * the ledger: integrated vs unmerged, accounted exceptions;
  * tools/release_tool.py build-info records the provenance fields;
  * ci.yml wiring: every build-info call stamps the same SOURCE_SHA, the lineage gate runs for releases and promotes BEFORE anything is
    built, both platform artifacts are named by that same SOURCE_SHA;
  * the policy is durable: CLAUDE.md, docs/SOURCE_OF_TRUTH.md, docs/source_authority.json, docs/BRANCH_LEDGER.md exist and say what they must;
  * when this clone has the other branches (a full clone, not CI's single-branch one): every remote branch is integrated or accounted for.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import source_audit  # noqa: E402

AUDIT = os.path.join(ROOT, "tools", "source_audit.py")


def git(path, *args, env=None):
    e = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    if env:
        e.update(env)
    p = subprocess.run(["git", "-C", path, *args], capture_output=True, text=True, env=e)
    if p.returncode != 0:
        raise RuntimeError(f"git {args}: {p.stderr}")
    return p.stdout.strip()


class Fixture:
    """A throwaway repository with a linear release history v1..vN and helpers to branch off it."""

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="sot_")
        git(self.dir, "init", "-q", "-b", "main")
        self.n = 0

    def commit(self, version, msg="work", tag=False, file="f.txt", content=None):
        with open(os.path.join(self.dir, "VERSION"), "w") as f:
            f.write(f"{version}\n")
        self.n += 1
        with open(os.path.join(self.dir, file), "w") as f:
            f.write(content if content is not None else f"{self.n}\n")
        git(self.dir, "add", "-A")
        git(self.dir, "commit", "-q", "-m", msg)
        sha = git(self.dir, "rev-parse", "HEAD")
        if tag:
            git(self.dir, "tag", f"v{version}")
        return sha

    def gate(self, sha, tag="", repo=None):
        return source_audit.lineage_gate(source_audit.Repo(repo or self.dir), sha, tag)

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)


class LineageGate(unittest.TestCase):
    def setUp(self):
        self.fx = Fixture()
        self.v1 = self.fx.commit(1, "release 1", tag=True)
        self.v2 = self.fx.commit(2, "release 2", tag=True)
        self.v3 = self.fx.commit(3, "work toward 3")

    def tearDown(self):
        self.fx.cleanup()

    def test_descendant_of_every_earlier_release_passes(self):
        code, msgs = self.fx.gate(self.v3, "v3")
        self.assertEqual(code, 0, msgs)
        self.assertIn("lineage OK", msgs[-1])

    def test_branch_tag_already_on_this_commit_passes(self):
        git(self.fx.dir, "tag", "v3")
        self.assertEqual(self.fx.gate(self.v3, "v3")[0], 0)

    def test_side_branch_from_before_the_last_release_is_refused(self):
        git(self.fx.dir, "checkout", "-q", "-b", "stale", self.v1)
        stale = self.fx.commit(3, "built on the old snapshot", file="g.txt")
        code, msgs = self.fx.gate(stale, "v3")
        self.assertEqual(code, 1)
        self.assertIn("v2", msgs[0])
        self.assertIn("outdated or side line", msgs[0])

    def test_unrelated_history_is_refused(self):
        git(self.fx.dir, "checkout", "-q", "--orphan", "orphan")
        orphan = self.fx.commit(3, "unrelated root", file="o.txt")
        code, msgs = self.fx.gate(orphan, "v3")
        self.assertEqual(code, 1, msgs)

    def test_a_release_number_is_never_reused_or_moved(self):
        git(self.fx.dir, "checkout", "-q", "-b", "other", self.v2)
        other = self.fx.commit(3, "another v3", file="x.txt")
        git(self.fx.dir, "tag", "v3", self.v3)
        code, msgs = self.fx.gate(other, "v3")
        self.assertEqual(code, 1)
        self.assertIn("never reused", msgs[0])

    def test_tag_must_match_version(self):
        code, msgs = self.fx.gate(self.v3, "v4")
        self.assertEqual(code, 1)
        self.assertIn("does not match VERSION", msgs[0])

    def test_a_missing_earlier_release_tag_is_refused_in_a_full_clone(self):
        git(self.fx.dir, "tag", "-d", "v2")
        code, msgs = self.fx.gate(self.v3, "v3")
        self.assertEqual(code, 1)
        self.assertIn("v2", msgs[0])

    def test_unknown_commit_cannot_be_decided(self):
        self.assertEqual(self.fx.gate("0" * 40, "v3")[0], 2)

    def test_a_shallow_clone_is_not_a_silent_pass(self):
        clone = tempfile.mkdtemp(prefix="sot_shallow_")
        try:
            subprocess.run(["git", "clone", "-q", "--depth", "1", "--no-tags", "file://" + self.fx.dir, clone], check=True, capture_output=True)
            code, msgs = source_audit.lineage_gate(source_audit.Repo(clone), "HEAD", "v3")
            self.assertEqual(code, 2, msgs)
            self.assertIn("shallow", msgs[0])
        finally:
            shutil.rmtree(clone, ignore_errors=True)

    def test_command_line_exit_codes(self):
        run = lambda *a: subprocess.run([sys.executable, AUDIT, "--repo", self.fx.dir, *a], capture_output=True, text=True).returncode
        self.assertEqual(run("lineage-gate", "--sha", self.v3, "--tag", "v3"), 0)
        self.assertEqual(run("lineage-gate", "--sha", self.v3, "--tag", "v9"), 1)
        self.assertEqual(run("lineage-gate", "--sha", "0" * 40, "--tag", "v3"), 2)


class BaseCheck(unittest.TestCase):
    def setUp(self):
        self.fx = Fixture()
        self.v1 = self.fx.commit(1, "release 1", tag=True)
        self.v2 = self.fx.commit(2, "release 2", tag=True)
        self.tip = self.fx.commit(2, "work")

    def tearDown(self):
        self.fx.cleanup()

    def test_current_line_is_ok_and_an_old_snapshot_is_stale(self):
        repo = source_audit.Repo(self.fx.dir)
        self.assertEqual(source_audit.base_check(repo, self.tip)[0], 0)
        self.assertEqual(source_audit.base_check(repo, self.v1)[0], 1)
        self.assertIn("STALE BASE", source_audit.base_check(repo, self.v1)[1][0])


class Ledger(unittest.TestCase):
    def setUp(self):
        self.fx = Fixture()
        self.base = self.fx.commit(1, "release 1", tag=True)
        self.line = self.fx.commit(1, "line work")
        # a clone gives us refs/remotes/origin/*
        self.clone = tempfile.mkdtemp(prefix="sot_clone_")
        git(self.fx.dir, "branch", "integrated", self.base)
        git(self.fx.dir, "checkout", "-q", "-b", "lost-work", self.base)
        self.fx.commit(1, "only on a side branch", file="side.txt")
        git(self.fx.dir, "checkout", "-q", "main")
        subprocess.run(["git", "clone", "-q", "file://" + self.fx.dir, self.clone], check=True, capture_output=True)

    def tearDown(self):
        self.fx.cleanup()
        shutil.rmtree(self.clone, ignore_errors=True)

    def rows(self):
        repo = source_audit.Repo(self.clone)
        return {r["ref"]: source_audit.classify(r, source_audit.load_authority(self.clone)) for r in source_audit.branch_rows(repo, "origin/main")}

    def test_integrated_and_unmerged_branches_are_told_apart(self):
        rows = self.rows()
        self.assertEqual(rows["integrated"], "integrated")
        self.assertTrue(rows["lost-work"].startswith("UNMERGED"), rows)

    def test_ledger_check_fails_for_unaccounted_unmerged_work_and_passes_when_accounted(self):
        run = lambda: subprocess.run([sys.executable, AUDIT, "--repo", self.clone, "ledger", "--auth", "origin/main", "--check"], capture_output=True, text=True)
        self.assertEqual(run().returncode, 1)
        os.makedirs(os.path.join(self.clone, "docs"), exist_ok=True)
        with open(os.path.join(self.clone, "docs", "source_authority.json"), "w") as f:
            json.dump({"accounted_unmerged": {"lost-work": "owner reviewed: abandoned experiment"}}, f)
        self.assertEqual(run().returncode, 0)


class ProvenanceFields(unittest.TestCase):
    def test_build_info_records_where_the_build_came_from(self):
        import release_tool
        out = os.path.join(tempfile.mkdtemp(prefix="sot_bi_"), "build_info.json")
        rt = {"runtime_id": "android-godot-4.6.0-r2", "runtime_fingerprint": "0" * 64, "ota_channel": "dev"}
        release_tool.build_info(out, "a" * 40, "123", True, rt, source_ref="refs/tags/v8", platform="windows", engine="4.6-stable")
        with open(out) as f:
            info = json.load(f)
        for k, v in {"commit": "a" * 40, "source_ref": "refs/tags/v8", "platform": "windows", "engine": "4.6-stable", "build_config": "release", "ci_run": "123"}.items():
            self.assertEqual(info[k], v, k)
        self.assertRegex(info["built_utc"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertEqual(info["public_version"], release_tool.read_version())
        release_tool.build_info(out, "b" * 40, "1", False, rt)   # old callers keep working
        with open(out) as f:
            self.assertEqual(json.load(f)["build_config"], "development")
        shutil.rmtree(os.path.dirname(out), ignore_errors=True)


class CiWiring(unittest.TestCase):
    """The unified manual build workflow (.github/workflows/ci.yml): every platform of a build comes from ONE validated commit (more in tests/test_build_workflow.py)."""

    @classmethod
    def setUpClass(cls):
        cls.text = open(os.path.join(ROOT, ".github", "workflows", "ci.yml"), encoding="utf-8").read()
        try:
            import yaml
            cls.wf = yaml.safe_load(cls.text)
        except ImportError:
            cls.wf = None
            print("NOTICE: PyYAML is not installed; the structural CI wiring tests are skipped")

    def need_yaml(self):
        if self.wf is None:
            self.skipTest("PyYAML not installed")

    def test_every_build_info_is_stamped_with_the_one_source_sha(self):
        # Android writes build_info.json itself; Windows and Linux go through tools/build.py, which stamps the commit it exports.
        calls = re.findall(r"release_tool\.py build-info[^\n]*", self.text)
        self.assertEqual(len(calls), 1)
        self.assertIn('--commit "$SOURCE_SHA"', calls[0])
        self.assertIn("--platform android", calls[0])
        self.assertIn("--engine", calls[0])
        self.assertIn('--build-number "$BUILD_NUMBER"', calls[0])
        for platform in ("windows", "linux"):
            self.assertRegex(self.text, rf'tools/build\.py --platform {platform} --godot "\$GODOT" --source-sha "\$SOURCE_SHA" --build-number "\$BUILD_NUMBER"')
        build_py = open(os.path.join(ROOT, "tools", "build.py"), encoding="utf-8").read()
        self.assertIn('"--commit", sha', build_py)
        self.assertIn('"git", "archive"', build_py)

    def test_source_sha_is_the_dispatched_input_and_every_job_checks_it_out(self):
        self.need_yaml()
        self.assertEqual(self.wf["env"]["SOURCE_SHA"], "${{ inputs.source_sha }}")
        for job in ("validate", "windows", "linux", "android", "assemble"):
            ref = [s["with"]["ref"] for s in self.wf["jobs"][job]["steps"] if s.get("uses", "").startswith("actions/checkout")]
            self.assertEqual(ref, ["${{ inputs.source_sha }}"], f"{job} builds / checks the exact requested commit")

    def test_the_platform_parts_are_assembled_and_checked_against_the_one_sha(self):
        self.need_yaml()
        self.assertIn("build_gate.py assemble", self.text)
        self.assertIn('--source-sha "$SOURCE_SHA" --build-number "$BUILD_NUMBER"', self.text)
        self.assertEqual(sorted(self.wf["jobs"]["assemble"]["needs"]), ["android", "gate", "linux", "validate", "windows"])

    def test_the_authority_gate_runs_first_and_everything_waits_for_it(self):
        self.need_yaml()
        names = [s.get("name", "") or "" for s in self.wf["jobs"]["gate"]["steps"]]
        order = [next(i for i, n in enumerate(names) if n.startswith(p)) for p in ("Validate the inputs", "Source commit", "Source authority", "Build number")]
        self.assertEqual(order, sorted(order))
        authority = next(s for s in self.wf["jobs"]["gate"]["steps"] if s.get("name", "").startswith("Source authority"))["run"]
        self.assertIn("build_gate.py source", authority)
        self.assertIn('--sha "$SOURCE_SHA"', authority)
        self.assertIn('--workflow-sha "$GITHUB_SHA"', authority)
        self.assertIn("--authority-root .", authority)
        for job in ("validate", "windows", "linux", "android"):
            self.assertIn("gate", self.wf["jobs"][job]["needs"] if isinstance(self.wf["jobs"][job]["needs"], list) else [self.wf["jobs"][job]["needs"]], job)

    def test_publish_needs_the_gate_and_the_assembled_set(self):
        self.need_yaml()
        self.assertEqual(sorted(self.wf["jobs"]["publish"]["needs"]), ["assemble", "gate"])


class PolicyIsDurable(unittest.TestCase):
    def read(self, rel):
        path = os.path.join(ROOT, rel)
        self.assertTrue(os.path.isfile(path), rel + " must exist")
        return open(path, encoding="utf-8").read()

    def test_claude_md_carries_the_rule(self):
        t = self.read("CLAUDE.md")
        self.assertIn("docs/SOURCE_OF_TRUTH.md", t)
        self.assertIn("ONE GAME", t)
        self.assertIn("source_audit.py", t)

    def test_policy_document_covers_the_required_ground(self):
        t = self.read("docs/SOURCE_OF_TRUTH.md")
        for needle in ("Single source of truth", "lineage gate", "Branches are workspaces", "build_info.json", "docs/BRANCH_LEDGER.md",
                       "source_authority.json", "OTA", "Not allowed without the owner"):
            self.assertIn(needle, t, needle)

    def test_authority_file_is_valid(self):
        a = json.loads(self.read("docs/source_authority.json"))
        self.assertEqual(a["authoritative_branch"], "main")
        self.assertIn("branch", a["current_line"])
        self.assertIsInstance(a["accounted_unmerged"], dict)

    def test_the_ledger_exists_and_lists_every_release_tag(self):
        t = self.read("docs/BRANCH_LEDGER.md")
        for k in range(1, 9):
            self.assertIn(f"`v{k}`", t, f"release tag v{k} must be in the ledger")


class WholeRepository(unittest.TestCase):
    """Only meaningful in a clone that has the other branches (CI checks out one commit): then nothing may be left behind."""

    def test_every_remote_branch_is_integrated_or_accounted_for(self):
        repo = source_audit.Repo(ROOT)
        remotes = [r for r in repo.git("for-each-ref", "--format=%(refname:short)", "refs/remotes/origin", check=False).split()
                   if r not in ("origin", "origin/HEAD")]
        if len(remotes) < 3 or repo.is_shallow():
            print("NOTICE: this clone has %d remote branch(es)%s: the whole-repository branch audit is NOT checked here "
                  "(run it in a full clone: python3 tools/source_audit.py ledger --check)" % (len(remotes), " and is shallow" if repo.is_shallow() else ""))
            self.skipTest("single-branch / shallow clone")
        # the line under test is this checkout (HEAD); a branch that has work HEAD lacks must be accounted for
        accounted = source_audit.load_authority(ROOT).get("accounted_unmerged", {})
        lost = [r["ref"] for r in source_audit.branch_rows(repo, "HEAD") if r["unique"] and r["ref"] not in accounted]
        self.assertEqual(lost, [], "branches holding work this line lacks (integrate them or account for them in docs/source_authority.json)")


if __name__ == "__main__":
    unittest.main(verbosity=2 if "-v" in sys.argv else 1, argv=[a for a in sys.argv if a != "-v"])
