#!/usr/bin/env python3
"""Policy tests for the unified manual build workflow (.github/workflows/ci.yml) and its neighbours: it can only be dispatched by hand, local_only can not publish
anything, and the single job that can write a release re-validates source, number, actor role and artifact integrity first. Static checks of the workflow files:
a mistake here would otherwise only show up in a paid run, or as an accidental publication."""
import glob
import json
import os
import re
import sys
import unittest

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
WF = os.path.join(ROOT, ".github", "workflows")

try:
    import yaml
except ImportError:
    print("NOTICE: PyYAML is not installed; the build workflow policy tests are skipped")
    sys.exit(0)


def load(name):
    text = open(os.path.join(WF, name), encoding="utf-8").read()
    return text, yaml.safe_load(text)


WRITES = re.compile(r"gh release (create|upload|edit|delete)|git (tag|push)\b|gh api[^\n]*(-X|--method)\s+(POST|PUT|PATCH|DELETE)|curl[^\n]*-X\s+(POST|PUT|PATCH|DELETE)|upload-release-asset|action-gh-release")


def runs(job):
    return "\n".join(str(s.get("run", "")) for s in job.get("steps", []))


class TestTriggers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text, cls.ci = load("ci.yml")

    def test_dispatch_only(self):
        self.assertEqual(list(self.ci[True]), ["workflow_dispatch"], "nothing but a manual dispatch may start the build workflow")

    def test_inputs_are_exactly_the_four_standard_ones(self):
        inputs = self.ci[True]["workflow_dispatch"]["inputs"]
        self.assertEqual(sorted(inputs), ["build_number", "destination", "platform", "source_sha"])
        self.assertEqual(inputs["platform"]["options"], ["android", "windows", "linux", "all"])
        self.assertEqual(inputs["destination"]["options"], ["local_only", "github_releases"])
        self.assertEqual(inputs["destination"]["default"], "local_only", "the default never publishes")
        self.assertTrue(inputs["source_sha"]["required"] and inputs["build_number"]["required"])

    def test_no_other_workflow_is_started_by_a_tag_a_release_branch_or_a_promote_branch(self):
        for path in sorted(glob.glob(os.path.join(WF, "*.yml"))):
            d = yaml.safe_load(open(path, encoding="utf-8").read())
            push = (d[True] or {}).get("push") or {}
            self.assertNotIn("tags", push, os.path.basename(path))
            for b in push.get("branches", []):
                self.assertFalse(b.startswith(("release/", "promote/", "v")), f"{os.path.basename(path)} triggers on {b}")

    def test_the_only_push_triggered_publisher_is_the_documented_ota_one(self):
        publishers = []
        for path in sorted(glob.glob(os.path.join(WF, "*.yml"))):
            text = open(path, encoding="utf-8").read()
            d = yaml.safe_load(text)
            if "push" in (d[True] or {}) and WRITES.search(re.sub(r"(?m)^\s*#.*$", "", text)):
                publishers.append(os.path.basename(path))
        self.assertEqual(publishers, ["ota-publish.yml"], "a push may start only the OTA publisher (an `ota/<channel>/<sha>` branch, owner-authorised); tests.yml only validates")
        self.assertEqual(load("ota-publish.yml")[1][True], {"push": {"branches": ["ota/**"]}})
        self.assertEqual(load("tests.yml")[1][True]["push"], {"branches": ["main"]})

    def test_the_engine_pin_is_the_same_in_every_workflow(self):
        pins = {n: (d["env"]["GODOT_VERSION"], d["env"]["GODOT_RELEASE"]) for n, (_, d) in ((n, load(n)) for n in ("ci.yml", "tests.yml"))}
        self.assertEqual(len(set(pins.values())), 1, pins)
        self.assertIn('GODOT_RELEASE: "4.6-stable"', self.text, "tools/ota_runtime.py reads the engine pin from this file")


class TestLocalOnlyCanNotPublish(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text, cls.ci = load("ci.yml")
        cls.jobs = cls.ci["jobs"]

    def test_only_the_publish_job_writes_a_release_a_tag_or_pushes(self):
        for name, job in self.jobs.items():
            if name == "publish":
                continue
            self.assertIsNone(WRITES.search(runs(job)), f"{name} must not create a release, tag, push or upload")
            for s in job.get("steps", []):
                self.assertNotIn("release", str(s.get("uses", "")).lower().replace("download-artifact", ""), f"{name}: {s.get('uses')}")

    def test_the_publish_job_runs_only_for_github_releases_with_all_platforms(self):
        cond = self.jobs["publish"]["if"]
        for needle in ("inputs.destination == 'github_releases'", "inputs.platform == 'all'", "needs.assemble.result == 'success'"):
            self.assertIn(needle, cond)

    def test_the_token_is_read_only_except_for_the_two_jobs_that_say_why(self):
        self.assertEqual(self.ci["permissions"], {"contents": "read"})
        writers = sorted(n for n, j in self.jobs.items() if (j.get("permissions") or {}).get("contents") == "write")
        self.assertEqual(writers, ["android", "publish"])
        self.assertEqual(self.jobs["publish"]["permissions"], {"contents": "write"})

    def test_android_may_only_use_an_existing_key_and_writes_nothing(self):
        steps = self.jobs["android"]["steps"]
        signing = next(s for s in steps if s.get("name", "").startswith("Android signing key"))
        self.assertEqual(signing["env"]["ANDROID_REQUIRE_EXISTING_KEY"], "1")
        sh = open(os.path.join(ROOT, "tools", "android", "signing.sh"), encoding="utf-8").read()
        guard = sh.index('ANDROID_REQUIRE_EXISTING_KEY')
        self.assertLess(guard, sh.index("generating the Android signing identity"), "the guard comes before the key is generated")
        self.assertLess(guard, sh.index("gh release create"), "...and before a release could be created")
        self.assertIsNone(WRITES.search(runs(self.jobs["android"])))

    def test_artifacts_are_private_to_the_run_and_expire(self):
        for name, job in self.jobs.items():
            for s in job.get("steps", []):
                if str(s.get("uses", "")).startswith("actions/upload-artifact"):
                    self.assertLessEqual(int(s["with"]["retention-days"]), 7, f"{name}")
                    self.assertEqual(s["with"]["if-no-files-found"], "error")

    def test_inputs_are_never_interpolated_into_a_script(self):
        for name, job in self.jobs.items():
            for s in job.get("steps", []):
                self.assertNotIn("${{ inputs.", str(s.get("run", "")), f"{name}.{s.get('name')}: pass inputs through env: so they can not inject shell")
                self.assertNotIn("${{ github.event.inputs", str(s.get("run", "")))

    def test_a_build_number_is_serialised_and_a_started_build_is_never_cancelled(self):
        self.assertEqual(self.ci["concurrency"], {"group": "build-${{ inputs.build_number }}", "cancel-in-progress": False})
        self.assertEqual(self.jobs["publish"]["concurrency"]["cancel-in-progress"], False)

    def test_history_is_never_deleted_or_rewritten(self):
        code = re.sub(r"(?m)^\s*#.*$", "", self.text)
        for bad in ("gh release delete", "git push --delete", "--force", "git tag -d", "update-ref", "gh api -X DELETE", "--prerelease=false"):
            self.assertNotIn(bad, code)


class TestPublishIsGuarded(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text, cls.ci = load("ci.yml")
        cls.steps = cls.ci["jobs"]["publish"]["steps"]
        cls.names = [s.get("name", "") or "" for s in cls.steps]

    def idx(self, prefix):
        hits = [i for i, n in enumerate(self.names) if n.startswith(prefix)]
        self.assertEqual(len(hits), 1, f"{prefix!r}: {self.names}")
        return hits[0]

    def test_the_guards_come_before_the_release_is_created(self):
        create = self.idx("Create the release")
        for guard in ("Actor authorisation", "Re-validate source authority", "Re-verify the artifact set"):
            self.assertLess(self.idx(guard), create, guard)
        self.assertEqual([i for i, s in enumerate(self.steps) if re.search(r"gh release create", str(s.get("run", "")))], [create], "exactly one step creates the release")

    def test_actor_authorisation_reads_the_role_from_github_not_from_an_input(self):
        step = self.steps[self.idx("Actor authorisation")]
        self.assertEqual(step["env"]["ACTOR"], "${{ github.triggering_actor }}")
        self.assertIn("collaborators/${ACTOR}/permission", step["run"])
        self.assertIn("build_gate.py authorize", step["run"])
        self.assertNotIn("inputs.", json.dumps(step["run"]))

    def test_the_source_the_number_and_the_artifacts_are_revalidated_in_the_publishing_job(self):
        reval = self.steps[self.idx("Re-validate source authority")]["run"]
        self.assertIn("build_gate.py source", reval)
        self.assertIn("--workflow-sha", reval)
        self.assertIn("build_gate.py number", reval)
        verify = self.steps[self.idx("Re-verify the artifact set")]
        self.assertIn("build_gate.py verify", verify["run"])
        self.assertIn("ASSEMBLED_MANIFEST_SHA256", verify["env"], "the set must be the one `assemble` produced")
        self.assertIn("sha256sum -c checksums.sha256", verify["run"])

    def test_the_release_is_created_at_the_exact_commit_and_refuses_an_existing_tag(self):
        run = self.steps[self.idx("Create the release")]["run"]
        self.assertIn('--target "$SOURCE_SHA"', run)
        self.assertIn('tag="build-${BUILD_NUMBER}"', run)
        self.assertLess(run.index("already exists"), run.index("gh release create"))
        self.assertIn('--title "Purgatory Dungeon Build ${BUILD_NUMBER}"', run)

    def test_the_trusted_tools_come_from_the_workflow_commit(self):
        first = self.steps[0]
        self.assertTrue(first["uses"].startswith("actions/checkout"))
        self.assertNotIn("ref", first.get("with", {}), "the first checkout is the workflow commit, not the source being judged")


class TestEveryJobIsBoundedAndOrdered(unittest.TestCase):
    def test_gate_before_validate_before_builds_before_assemble(self):
        _, ci = load("ci.yml")
        j = ci["jobs"]
        self.assertNotIn("needs", j["gate"])
        self.assertEqual(j["validate"]["needs"], "gate")
        for b in ("windows", "linux", "android"):
            self.assertEqual(sorted(j[b]["needs"]), ["gate", "validate"])
        self.assertEqual(sorted(j["assemble"]["needs"]), ["android", "gate", "linux", "validate", "windows"])
        for name, job in j.items():
            self.assertLessEqual(job["timeout-minutes"], 60, name)


if __name__ == "__main__":
    unittest.main()
