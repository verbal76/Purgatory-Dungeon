#!/usr/bin/env python3
"""tools/build.py: naming, exact-commit export, manifest + checksums and their verification (no Godot needed; the exports themselves are exercised by running the tool)."""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
spec = importlib.util.spec_from_file_location("build", os.path.join(ROOT, "tools", "build.py"))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)

fails = 0


def check(cond: bool, label: str) -> None:
    global fails
    if not cond:
        fails += 1
        print("FAIL: " + label)


# Names: both conventions, one per platform.
check(build.top_folder(9) == "Purgatory-Dungeon-Build-9" and build.top_folder(9, "repo") == "Purgatory-Dungeon-v9", "package folders follow the naming")
check(build.artifact_name("windows", 9, "repo") == "Purgatory-Dungeon-v9-Windows.zip", "repo naming: Windows zip")
check(build.artifact_name("linux", 9, "repo") == "Purgatory-Dungeon-v9-Linux.tar.gz", "repo naming: Linux tar.gz")
check(build.artifact_name("android", 9, "repo") == "Purgatory-Dungeon-v9.apk", "repo naming: APK")
check([build.artifact_name(p, 45, "standard") for p in ("android", "windows", "linux")]
      == ["Purgatory Dungeon Build 45 APK.apk", "Purgatory Dungeon Build 45 EXE.zip", "Purgatory Dungeon Build 45 Linux.tar.gz"], "standard naming (master standard section 7)")

with tempfile.TemporaryDirectory() as tmp:
    # Manifest + checksums describe exactly the files that are there, and verification catches a changed or missing file.
    a = os.path.join(tmp, "a.zip")
    open(a, "wb").write(b"windows bytes")
    results = {"windows": {"status": "built", "path": a}, "linux": {"status": "blocked", "reason": "no template"}, "android": {"status": "blocked", "reason": "no SDK"}}
    m = build.write_manifest(tmp, 9, "a" * 40, "4.6.stable", "repo", results)
    check(m["build_number"] == 9 and m["source_sha"] == "a" * 40 and m["tested_on_device"] is False, "manifest records number, SHA and that nothing was device-tested")
    check([x["platform"] for x in m["artifacts"]] == ["windows"] and m["artifacts"][0]["bytes"] == 13, "only built artifacts are listed, with size")
    check(m["platforms"]["linux"]["status"] == "blocked" and "no template" in m["platforms"]["linux"]["reason"], "a blocked platform is recorded with its reason")
    check(build.verify_manifest(tmp) == [], "a fresh manifest verifies")
    open(a, "wb").write(b"changed bytes")
    check(any("SHA-256" in p for p in build.verify_manifest(tmp)), "a changed artifact fails verification")
    os.remove(a)
    check(any("missing" in p for p in build.verify_manifest(tmp)), "a missing artifact fails verification")

    # The build exports a COMMIT, not the working tree: a file edited after the commit is not in the extracted source.
    repo = os.path.join(tmp, "r")
    os.makedirs(repo)
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
    open(os.path.join(repo, "f.txt"), "w").write("committed")
    subprocess.run(["git", "add", "."], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-qm", "c"], cwd=repo, check=True, env=env)
    sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True, check=True).stdout.strip()
    open(os.path.join(repo, "f.txt"), "w").write("edited after the commit")
    build.ROOT = repo
    out = os.path.join(tmp, "out")
    os.makedirs(out)
    build.extract_source(sha, out)
    check(open(os.path.join(out, "f.txt")).read() == "committed", "the extracted source is the commit, not the working tree")

# The command line: a dry run builds nothing and refuses an unknown commit.
tool = os.path.join(ROOT, "tools", "build.py")
dry = subprocess.run([sys.executable, tool, "--platform", "all", "--dry-run", "--build-number", "9"], capture_output=True, text=True)
check(dry.returncode == 0 and "Purgatory Dungeon Build 9 EXE.zip" in dry.stdout and "Purgatory Dungeon Build 9 Linux.tar.gz" in dry.stdout
      and "Purgatory Dungeon Build 9 APK.apk" in dry.stdout, "dry run prints the plan for all three platforms with the standard names")
nonum = subprocess.run([sys.executable, tool, "--platform", "all", "--dry-run"], capture_output=True, text=True)
check(nonum.returncode != 0 and "build-number" in (nonum.stdout + nonum.stderr), "the build number is never guessed from VERSION")
legacy = subprocess.run([sys.executable, tool, "--platform", "all", "--dry-run", "--naming", "repo", "--build-number", "9"], capture_output=True, text=True)
check(legacy.returncode == 0 and "Purgatory-Dungeon-v9-Windows.zip" in legacy.stdout, "the v1-v8 names stay available as --naming repo")
bad = subprocess.run([sys.executable, tool, "--platform", "linux", "--source-sha", "deadbeef" * 5, "--dry-run"], capture_output=True, text=True)
check(bad.returncode != 0, "an unknown source commit is refused")
pub = subprocess.run([sys.executable, tool, "--platform", "linux", "--destination", "github_releases", "--dry-run"], capture_output=True, text=True)
check(pub.returncode != 0, "the local tool offers no way to publish")

# The workflow policy (dispatch only, nothing publishes except the guarded publish job, ...) is tests/test_build_workflow.py.

print(f"test_build_tool: {fails} failures")
sys.exit(1 if fails else 0)
