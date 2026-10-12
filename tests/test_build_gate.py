#!/usr/bin/env python3
"""tools/build_gate.py: input validation, source authority (throwaway clones), build-number uniqueness, the coordinated artifact set, publication authorisation."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import build as B  # noqa: E402
import build_gate as G  # noqa: E402
import source_audit as SA  # noqa: E402

ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
SHA = "a" * 40


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True, env=ENV).stdout.strip()


class TestInputs(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(G.check_inputs("all", SHA, "9", "github_releases"), [])
        self.assertEqual(G.check_inputs("linux", SHA, "9", "local_only"), [])

    def test_refusals(self):
        for bad_sha in ("main", "abc1234", "A" * 40, "g" * 40, SHA + "0", ""):
            self.assertTrue(G.check_inputs("all", bad_sha, "9", "local_only"), bad_sha)
        for bad_n in ("0", "09", "-1", "1.5", "", "abc", "1000000", "9 "):
            self.assertTrue(G.check_inputs("all", SHA, bad_n, "local_only"), repr(bad_n))
        self.assertTrue(G.check_inputs("mac", SHA, "9", "local_only"))
        self.assertTrue(G.check_inputs("all", SHA, "9", "steam"))

    def test_a_public_release_needs_every_platform(self):
        for p in ("android", "windows", "linux"):
            self.assertTrue(G.check_inputs(p, SHA, "9", "github_releases"), p)


class TestNumber(unittest.TestCase):
    TAGS = [f"v{i}" for i in range(1, 9)] + ["ota-dev-000007", "ota-channel-dev"]

    def test_next_after_the_release_series_is_nine(self):
        self.assertEqual(G.check_number(9, self.TAGS, [], 8), [])
        self.assertTrue(G.check_number(8, self.TAGS, [], 8), "v8 is build 8: duplicate")
        self.assertTrue(G.check_number(3, self.TAGS, [], 8), "below the consumed series")
        self.assertIn("next valid number is 9", " ".join(G.check_number(8, self.TAGS, [], 8)))

    def test_ota_ids_do_not_consume_build_numbers(self):
        self.assertEqual(G.consumed_numbers(["ota-dev-000007", "ota-channel-dev"], ["Purgatory Dungeon v8.5 (OTA #000007)"]), set())

    def test_build_tags_and_release_titles_are_consumed_and_monotonic(self):
        tags = self.TAGS + ["build-9"]
        self.assertTrue(G.check_number(9, tags, [], 8))
        self.assertEqual(G.check_number(10, tags, [], 8), [])
        names = ["Purgatory Dungeon Build 12", "OTA signing key (do not delete)"]
        self.assertTrue(G.check_number(12, tags, names, 8))
        self.assertTrue(G.check_number(11, tags, names, 8), "a number below an existing build conflicts")
        self.assertEqual(G.check_number(13, tags, names, 8), [])

    def test_version_alone_sets_the_floor(self):
        self.assertTrue(G.check_number(5, [], [], 8))
        self.assertEqual(G.check_number(9, [], [], 8), [])


class TestSource(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp()
        self.origin = os.path.join(self.t, "origin")
        os.makedirs(self.origin)
        git(self.origin, "init", "-q", "-b", "main")
        os.makedirs(os.path.join(self.origin, "docs"))
        open(os.path.join(self.origin, "docs", "source_authority.json"), "w").write(json.dumps({"authoritative_branch": "main"}))
        open(os.path.join(self.origin, "VERSION"), "w").write("2\n")
        git(self.origin, "add", ".")
        git(self.origin, "commit", "-qm", "c1")
        git(self.origin, "tag", "v1")
        open(os.path.join(self.origin, "f"), "w").write("x")
        git(self.origin, "add", ".")
        git(self.origin, "commit", "-qm", "c2")
        git(self.origin, "tag", "v2")
        self.main_tip = git(self.origin, "rev-parse", "HEAD")
        git(self.origin, "checkout", "-q", "-b", "side", "v1")
        open(os.path.join(self.origin, "side"), "w").write("s")
        git(self.origin, "add", ".")
        git(self.origin, "commit", "-qm", "side")
        self.side_tip = git(self.origin, "rev-parse", "HEAD")
        git(self.origin, "checkout", "-q", "main")
        self.clone = os.path.join(self.t, "clone")
        subprocess.run(["git", "clone", "-q", "file://" + self.origin, self.clone], check=True, env=ENV, capture_output=True)

    def tearDown(self):
        shutil.rmtree(self.t, ignore_errors=True)

    def checkout(self, sha):
        git(self.clone, "checkout", "-q", "--detach", sha)
        return SA.Repo(self.clone)

    def test_a_commit_on_the_authoritative_line_passes(self):
        code, msgs = G.check_source(self.checkout(self.main_tip), self.main_tip)
        self.assertEqual(code, 0, msgs)

    def test_an_old_ancestor_that_lacks_later_release_tags_is_refused(self):
        c1 = git(self.clone, "rev-parse", "v1^{commit}")
        code, msgs = G.check_source(self.checkout(c1), c1)
        self.assertEqual(code, 1, "v1 is on main but does not contain release v2: " + str(msgs))

    def test_a_side_branch_commit_is_refused(self):
        code, msgs = G.check_source(self.checkout(self.side_tip), self.side_tip)
        self.assertEqual(code, 1, msgs)
        self.assertIn("not on the authoritative line", " ".join(msgs))

    def test_the_checked_out_commit_must_be_the_requested_one(self):
        repo = self.checkout(self.main_tip)
        code, msgs = G.check_source(repo, self.side_tip)
        self.assertEqual(code, 1, msgs)

    def test_the_authority_file_of_the_judged_commit_is_not_trusted(self):
        # a side commit that declares ITSELF the authoritative line must still be refused when the trusted root says main
        trusted = os.path.join(self.t, "trusted")
        os.makedirs(os.path.join(trusted, "docs"))
        json.dump({"authoritative_branch": "main"}, open(os.path.join(trusted, "docs", "source_authority.json"), "w"))
        repo = self.checkout(self.side_tip)
        code, msgs = G.check_source(repo, self.side_tip, authority_root=trusted)
        self.assertEqual(code, 1, msgs)

    def test_a_workflow_from_a_side_branch_is_never_trusted(self):
        code, msgs = G.check_source(self.checkout(self.main_tip), self.main_tip, workflow_sha=self.side_tip)
        self.assertEqual(code, 1, msgs)
        code, msgs = G.check_source(self.checkout(self.main_tip), self.main_tip, workflow_sha=self.main_tip)
        self.assertEqual(code, 0, msgs)

    def test_unknown_commit_and_shallow_clone_cannot_decide(self):
        self.assertEqual(G.check_source(SA.Repo(self.clone), "f" * 40)[0], 2)
        shallow = os.path.join(self.t, "shallow")
        subprocess.run(["git", "clone", "-q", "--depth", "1", "file://" + self.origin, shallow], check=True, env=ENV, capture_output=True)
        head = git(shallow, "rev-parse", "HEAD")
        self.assertEqual(G.check_source(SA.Repo(shallow), head)[0], 2)


class TestSet(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp()
        self.inp = os.path.join(self.t, "in")
        self.out = os.path.join(self.t, "out")
        for p in ("android", "windows", "linux"):
            f = os.path.join(self.t, p + ".bin")
            open(f, "wb").write(("bytes of " + p).encode())
            G.package_one(p, f, os.path.join(self.inp, p), SHA, 9, "4.6.stable")

    def tearDown(self):
        shutil.rmtree(self.t, ignore_errors=True)

    def test_standard_names_and_a_verified_set(self):
        self.assertEqual(G.assemble(self.inp, self.out, "all", SHA, 9), [])
        self.assertEqual(sorted(os.listdir(self.out)), sorted(["Purgatory Dungeon Build 9 APK.apk", "Purgatory Dungeon Build 9 EXE.zip",
                                                              "Purgatory Dungeon Build 9 Linux.tar.gz", "build-manifest.json", "checksums.sha256"]))
        m = json.load(open(os.path.join(self.out, "build-manifest.json")))
        self.assertTrue(m["complete"] and m["source_sha"] == SHA and m["build_number"] == 9 and len(m["artifacts"]) == 3)
        self.assertEqual(G.verify_set(self.out, "all", SHA, 9), [])

    def test_a_missing_platform_is_an_incomplete_set(self):
        shutil.rmtree(os.path.join(self.inp, "linux"))
        self.assertTrue(G.assemble(self.inp, self.out, "all", SHA, 9))

    def test_a_single_platform_set_is_complete_for_that_platform_only(self):
        self.assertEqual(G.assemble(self.inp, self.out, "windows", SHA, 9), [])
        self.assertTrue(G.verify_set(self.out, "all", SHA, 9), "a one-platform set is never a complete coordinated release")

    def test_a_platform_built_from_another_commit_is_refused(self):
        p = os.path.join(self.inp, "linux", "build-manifest.json")
        m = json.load(open(p))
        m["source_sha"] = "b" * 40
        json.dump(m, open(p, "w"))
        self.assertTrue(any("not the requested" in x for x in G.assemble(self.inp, self.out, "all", SHA, 9)))

    def test_a_different_build_number_is_refused(self):
        self.assertTrue(G.assemble(self.inp, self.out, "all", SHA, 10))

    def test_a_changed_artifact_is_refused_before_and_after_assembly(self):
        open(os.path.join(self.inp, "windows", "Purgatory Dungeon Build 9 EXE.zip"), "ab").write(b"x")
        self.assertTrue(any("SHA-256" in x for x in G.assemble(self.inp, self.out, "all", SHA, 9)))
        shutil.rmtree(self.out, ignore_errors=True)
        shutil.rmtree(self.inp)
        self.setUp()
        self.assertEqual(G.assemble(self.inp, self.out, "all", SHA, 9), [])
        open(os.path.join(self.out, "Purgatory Dungeon Build 9 APK.apk"), "ab").write(b"x")
        self.assertTrue(any("SHA-256" in x for x in G.verify_set(self.out, "all", SHA, 9)))

    def test_an_unlisted_file_in_the_set_is_refused(self):
        self.assertEqual(G.assemble(self.inp, self.out, "all", SHA, 9), [])
        open(os.path.join(self.out, "extra.txt"), "w").write("x")
        self.assertTrue(G.verify_set(self.out, "all", SHA, 9))


class TestPackageBuildNumber(unittest.TestCase):
    """verify_package / verify_apk insist that build_info.json carries the coordinated build number."""

    def run_check(self, expect, carried):
        import verify_package as vp
        vp.EXPECT_BUILD_NUMBER = expect
        names = ["scenes/StudioSplash.tscn", "scripts/studio_splash.gd", "scenes/MainMenu.tscn", "scripts/build_info.gd", "build_info.json", vp.LOGO,
                 "data/buffs.json", "data/globe_effects.json", "data/codex_lore.json"]
        info = {"public_version": 8, "release": False, "commit": SHA, "runtime_id": "android-godot-4.6.0-r2", "runtime_fingerprint": "d" * 64, "ota_channel": "dev",
                **({"build_number": carried} if carried is not None else {})}
        problems, notes = [], []
        vp.check_names(names, lambda n: json.dumps(info).encode() if n == "build_info.json" else b"x", "PCK", 8, True, False, SHA, problems, notes)
        vp.EXPECT_BUILD_NUMBER = 0
        return problems

    def test_the_number_must_match(self):
        self.assertEqual(self.run_check(9, 9), [])
        self.assertTrue(any("build number" in p for p in self.run_check(9, 8)))
        self.assertTrue(any("build number" in p for p in self.run_check(9, None)))

    def test_no_expectation_no_check(self):
        self.assertEqual(self.run_check(0, 123), [])


class TestAuthorize(unittest.TestCase):
    def test_roles(self):
        self.assertEqual(G.authorize("admin", "github_releases", "all"), [])
        self.assertEqual(G.authorize("maintain", "github_releases", "all"), [])
        for role in ("write", "triage", "read", "none", "", "ADMIN"):
            self.assertTrue(G.authorize(role, "github_releases", "all"), role)

    def test_local_only_and_partial_sets_never_publish(self):
        self.assertTrue(G.authorize("admin", "local_only", "all"))
        self.assertTrue(G.authorize("admin", "github_releases", "linux"))


if __name__ == "__main__":
    unittest.main()
