#!/usr/bin/env python3
"""Gates and assembly for the unified manual build workflow (.github/workflows/ci.yml, "Build (manual)"): input validation, source authority, build-number
uniqueness, per-platform packaging records, assembling and verifying the coordinated artifact set, and the publication authorisation check.
Every function is pure or read-only on the repository, so the same code runs in the workflow and in tests/test_build_gate.py. Standard library only.

  build_gate.py inputs    --platform P --source-sha SHA --build-number N --destination D
  build_gate.py source    --sha SHA [--workflow-sha SHA] [--repo DIR]      checked-out commit == SHA, SHA on the authoritative line, descends from every release tag
  build_gate.py number    --build-number N [--release-names FILE] [--repo DIR]
  build_gate.py package   --platform android --file F --out DIR --source-sha SHA --build-number N [--engine E]
  build_gate.py assemble  --in DIR --out DIR --platform P --source-sha SHA --build-number N
  build_gate.py verify    --dir DIR --platform P --source-sha SHA --build-number N
  build_gate.py authorize --permission ROLE --destination D --platform P

Exit 0 = passed, 1 = refused (the reasons are printed), 2 = cannot decide (shallow clone, missing refs): a failure, never a pass.
The build number is the studio's coordinated build id (Purgatory Dungeon Build NN). It continues the release series v1-v8 (v8 = build 8), is independent of
the native version in ./VERSION (which only a native release changes) and of the OTA ids, and is never reused: tags build-<N>, tags v<N> and releases titled
"Purgatory Dungeon Build N" all count as consumed.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
sys.path.insert(0, HERE)
import build as B          # noqa: E402  (artifact names, manifest writer / verifier, sha256)
import source_audit as SA  # noqa: E402  (authoritative line, release tags)

PLATFORMS = ("android", "windows", "linux", "all")
DESTINATIONS = ("local_only", "github_releases")
SHA40 = re.compile(r"^[0-9a-f]{40}$")
PUBLISH_ROLES = ("admin", "maintain")     # GitHub repository roles that may publish; read from the API for the triggering actor, never from an input
MAX_NUMBER = 999999


def platforms_for(platform: str) -> list:
    return ["android", "windows", "linux"] if platform == "all" else [platform]


# ── inputs ────────────────────────────────────────────────────────────────────────────────────────────────────

def check_inputs(platform: str, sha: str, number: str, destination: str) -> list:
    problems = []
    if platform not in PLATFORMS:
        problems.append(f"platform {platform!r} is not one of {', '.join(PLATFORMS)}")
    if not SHA40.match(sha or ""):
        problems.append("source_sha must be the exact 40-character lowercase commit SHA (a branch name or short SHA is refused)")
    if not re.fullmatch(r"[1-9][0-9]{0,5}", str(number or "")):
        problems.append(f"build_number {number!r} must be a positive integer (no sign, no leading zero, at most {MAX_NUMBER})")
    if destination not in DESTINATIONS:
        problems.append(f"destination {destination!r} is not one of {', '.join(DESTINATIONS)}")
    if destination == "github_releases" and platform != "all":
        problems.append("a public release needs all three platforms (platform=all); a partial set is never published")
    return problems


# ── source authority ──────────────────────────────────────────────────────────────────────────────────────────

def authoritative_line(repo: "SA.Repo", authority_root: str = "") -> tuple:
    """(ref, note) like source_audit.authoritative_ref, but the authority file is read from `authority_root` (the TRUSTED workflow checkout), never from the
    commit being judged: a source commit must not be able to declare itself authoritative."""
    if not authority_root:
        return SA.authoritative_ref(repo)
    auth = SA.load_authority(authority_root)
    branch = auth.get("authoritative_branch", "main")
    tags = repo.release_tags()
    latest = repo.resolve(tags[max(tags)]) if tags else ""
    main_ref = f"origin/{branch}"
    if repo.resolve(main_ref) and (not latest or repo.is_ancestor(latest, repo.resolve(main_ref))):
        return main_ref, f"{main_ref} (the authoritative branch)"
    interim = auth.get("current_line", {}).get("branch", "")
    if interim and repo.resolve(f"origin/{interim}"):
        return f"origin/{interim}", f"origin/{interim} (interim: {main_ref} does not yet contain the latest release)"
    return "HEAD", "no declared authoritative line found"


def check_source(repo: "SA.Repo", sha: str, workflow_sha: str = "", authority_root: str = "") -> tuple:
    """(exit code, messages). The commit being built is HEAD, is reachable from the authoritative line and contains every release tag."""
    msgs = []
    head = repo.resolve("HEAD")
    commit = repo.resolve(sha)
    if not commit:
        return 2, [f"commit {sha} is not in this clone (fetch it)"]
    if head != commit:
        return 1, [f"the checked-out commit {head[:12]} is not the requested source {commit[:12]}: build exactly the requested commit"]
    if repo.is_shallow():
        return 2, ["this clone is shallow: authority and lineage cannot be proven (fetch-depth 0)"]
    auth_ref, note = authoritative_line(repo, authority_root)
    if auth_ref == "HEAD" or not repo.resolve(auth_ref):
        return 2, [f"no authoritative line could be resolved ({note})"]
    if not repo.is_ancestor(commit, auth_ref):
        return 1, [f"{commit[:12]} is not on the authoritative line {note}: only commits of the single source history are built (docs/SOURCE_OF_TRUTH.md)"]
    msgs.append(f"{commit[:12]} is on the authoritative line {note}")
    if workflow_sha:
        wf = repo.resolve(workflow_sha)
        if not wf or not repo.is_ancestor(wf, auth_ref):
            return 1, [f"the workflow definition commit {workflow_sha[:12]} is not on the authoritative line: a workflow from a side branch is never trusted to build or publish"]
        msgs.append(f"the workflow definition {wf[:12]} is on the authoritative line")
    tags = repo.release_tags()
    bad = [t for k, t in sorted(tags.items()) if not repo.is_ancestor(repo.resolve(t), commit)]
    if bad:
        return 1, [f"{commit[:12]} does not contain release(s) {', '.join(bad)}: an outdated or side line of development"]
    msgs.append(f"descends from all {len(tags)} release tag(s) {('v' + str(min(tags))) + '..v' + str(max(tags)) if tags else ''}".rstrip())
    return 0, msgs


# ── build number ──────────────────────────────────────────────────────────────────────────────────────────────

def consumed_numbers(tags: list, release_names: list) -> set:
    used = set()
    for t in tags:
        m = re.fullmatch(r"(?:build-|v)([1-9][0-9]*)", t)
        if m:
            used.add(int(m.group(1)))
    for n in release_names:
        m = re.fullmatch(r"Purgatory Dungeon (?:Build |v)([1-9][0-9]*)", n.strip())
        if m:
            used.add(int(m.group(1)))
    return used


def check_number(number: int, tags: list, release_names: list, version: int) -> list:
    used = consumed_numbers(tags, release_names)
    # Build NN continues the release series and may equal ./VERSION when the native version was bumped to it (Build 9 ships
    # VERSION 9): the floor is the highest CONSUMED number, and never below the release before VERSION.
    floor = max(used | {version - 1})
    if number in used:
        return [f"build number {number} is already consumed (a tag or release carries it); the next valid number is {floor + 1}"]
    if number <= floor:
        return [f"build number {number} is not above the highest consumed number {floor} (release series plus any later Build NN, and never below the release before v{version}): the next valid number is {floor + 1}"]
    return []


# ── packaging records and the coordinated set ─────────────────────────────────────────────────────────────────

def package_one(platform: str, file: str, out: str, sha: str, number: int, engine: str, details: dict = None) -> str:
    """Copy a built artifact to its standard name in `out` and write that platform's manifest fragment + checksums."""
    os.makedirs(out, exist_ok=True)
    name = B.artifact_name(platform, number, "standard")
    dest = os.path.join(out, name)
    if os.path.abspath(file) != os.path.abspath(dest):
        shutil.copyfile(file, dest)
    B.write_manifest(out, number, sha, engine, "standard", {platform: {"status": "built", "path": dest, **({"details": details} if details else {})}})
    return dest


def _load(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def assemble(in_dir: str, out_dir: str, platform: str, sha: str, number: int) -> list:
    """Merge the per-platform fragments in <in_dir>/<platform>/ into one verified set in out_dir. Returns the problems (empty = assembled)."""
    problems = []
    wanted = platforms_for(platform)
    merged, artifacts, engines = {}, [], set()
    os.makedirs(out_dir, exist_ok=True)
    for p in wanted:
        d = os.path.join(in_dir, p)
        try:
            frag = _load(os.path.join(d, B.MANIFEST))
        except (OSError, ValueError) as e:
            problems.append(f"{p}: no readable {B.MANIFEST} ({e})")
            continue
        bad = B.verify_manifest(d)
        problems += [f"{p}: {x}" for x in bad]
        if frag.get("source_sha") != sha:
            problems.append(f"{p}: built from {str(frag.get('source_sha'))[:12]}, not the requested {sha[:12]} (platforms are never mixed across commits)")
        if frag.get("build_number") != number:
            problems.append(f"{p}: carries build number {frag.get('build_number')!r}, expected {number}")
        if frag.get("platforms", {}).get(p, {}).get("status") != "built":
            problems.append(f"{p}: not built ({frag.get('platforms', {}).get(p)})")
        mine = [a for a in frag.get("artifacts", []) if a.get("platform") == p]
        expect = B.artifact_name(p, number, "standard")
        if [a.get("file") for a in mine] != [expect]:
            problems.append(f"{p}: expected exactly the artifact {expect!r}, found {[a.get('file') for a in mine]}")
            continue
        engines.add(frag.get("engine"))
        merged[p] = frag["platforms"][p]
        artifacts += mine
        if not bad:
            shutil.copyfile(os.path.join(d, expect), os.path.join(out_dir, expect))
    if len(engines) > 1:
        problems.append(f"platforms were built with different engine versions: {sorted(map(str, engines))}")
    if problems:
        return problems
    manifest = _load(os.path.join(in_dir, wanted[0], B.MANIFEST))
    manifest.update({"platforms": merged, "artifacts": artifacts, "requested_platform": platform, "complete": True})
    with open(os.path.join(out_dir, B.MANIFEST), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    with open(os.path.join(out_dir, B.CHECKSUMS), "w", encoding="utf-8") as f:
        for a in artifacts:
            f.write(f"{a['sha256']}  {a['file']}\n")
    return verify_set(out_dir, platform, sha, number)


def verify_set(d: str, platform: str, sha: str, number: int) -> list:
    """The coordinated set in d is complete for `platform`, from one SHA and one build number, and every byte matches the manifest and checksums."""
    problems = list(B.verify_manifest(d))
    try:
        m = _load(os.path.join(d, B.MANIFEST))
    except (OSError, ValueError) as e:
        return problems + [f"cannot read {B.MANIFEST}: {e}"]
    if m.get("title") != B.TITLE:
        problems.append(f"manifest title {m.get('title')!r}")
    if m.get("source_sha") != sha:
        problems.append(f"manifest source_sha {str(m.get('source_sha'))[:12]} is not {sha[:12]}")
    if m.get("build_number") != number:
        problems.append(f"manifest build_number {m.get('build_number')!r} is not {number}")
    if m.get("complete") is not True:
        problems.append("the manifest does not declare a complete set")
    want = {B.artifact_name(p, number, "standard") for p in platforms_for(platform)}
    have = {a.get("file") for a in m.get("artifacts", [])}
    if have != want:
        problems.append(f"artifact set {sorted(have)} is not the expected {sorted(want)}")
    present = {f for f in os.listdir(d) if f not in (B.MANIFEST, B.CHECKSUMS)}
    if present != want:
        problems.append(f"files in the set {sorted(present)} are not exactly {sorted(want)}")
    for p in platforms_for(platform):
        if m.get("platforms", {}).get(p, {}).get("status") != "built":
            problems.append(f"manifest does not record {p} as built")
    return problems


# ── publication authorisation ─────────────────────────────────────────────────────────────────────────────────

def authorize(permission: str, destination: str, platform: str) -> list:
    """`permission` is the triggering actor's repository role as the GitHub API reports it for github.actor (never an input of the workflow)."""
    problems = []
    if destination != "github_releases":
        problems.append("destination is not github_releases: nothing may be published")
    if platform != "all":
        problems.append("a public release needs platform=all")
    if permission not in PUBLISH_ROLES:
        problems.append(f"the triggering actor's repository role is {permission!r}; publishing needs one of {', '.join(PUBLISH_ROLES)}")
    return problems


# ── CLI ──────────────────────────────────────────────────────────────────────────────────────────────────────

def _report(problems: list, ok: str) -> int:
    for p in problems:
        print("REFUSED:", p)
    if not problems:
        print(ok)
    return 1 if problems else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("inputs")
    s.add_argument("--platform", required=True)
    s.add_argument("--source-sha", required=True)
    s.add_argument("--build-number", required=True)
    s.add_argument("--destination", required=True)
    s = sub.add_parser("source")
    s.add_argument("--sha", required=True)
    s.add_argument("--workflow-sha", default="")
    s.add_argument("--authority-root", default="", help="checkout whose docs/source_authority.json names the authoritative line (the trusted workflow commit)")
    s.add_argument("--repo", default=ROOT)
    s = sub.add_parser("number")
    s.add_argument("--build-number", type=int, required=True)
    s.add_argument("--release-names", default="", help="file with one release title per line (the GitHub API listing)")
    s.add_argument("--repo", default=ROOT)
    s = sub.add_parser("package")
    s.add_argument("--platform", required=True, choices=("android", "windows", "linux"))
    s.add_argument("--file", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--source-sha", required=True)
    s.add_argument("--build-number", type=int, required=True)
    s.add_argument("--engine", default="4.6.stable")
    s.add_argument("--detail", action="append", default=[], metavar="KEY=VALUE", help="a fact about the artifact recorded in the manifest (e.g. package, version_code, cert_sha256)")
    for name in ("assemble", "verify"):
        s = sub.add_parser(name)
        s.add_argument("--in" if name == "assemble" else "--dir", dest="src", required=True)
        if name == "assemble":
            s.add_argument("--out", required=True)
        s.add_argument("--platform", required=True)
        s.add_argument("--source-sha", required=True)
        s.add_argument("--build-number", type=int, required=True)
    s = sub.add_parser("authorize")
    s.add_argument("--permission", required=True)
    s.add_argument("--destination", required=True)
    s.add_argument("--platform", required=True)
    a = ap.parse_args()

    if a.cmd == "inputs":
        return _report(check_inputs(a.platform, a.source_sha, a.build_number, a.destination), "inputs OK")
    if a.cmd == "source":
        code, msgs = check_source(SA.Repo(a.repo), a.sha, a.workflow_sha, a.authority_root)
        for m in msgs:
            print(m)
        return code
    if a.cmd == "number":
        repo = SA.Repo(a.repo)
        tags = repo.git("tag", "--list", check=False).split()
        names = open(a.release_names, encoding="utf-8").read().splitlines() if a.release_names else []
        try:
            version = repo.version()
        except (RuntimeError, OSError) as e:
            print(f"cannot read VERSION: {e}")
            return 2
        return _report(check_number(a.build_number, tags, names, version), f"build number {a.build_number} is unused and above every consumed number")
    if a.cmd == "package":
        details = dict(d.split("=", 1) for d in a.detail if "=" in d)
        path = package_one(a.platform, a.file, a.out, a.source_sha, a.build_number, a.engine, details)
        print(f"packaged {path} ({os.path.getsize(path)} bytes, sha256 {B.sha256_file(path)})")
        return 0
    if a.cmd == "assemble":
        return _report(assemble(a.src, a.out, a.platform, a.source_sha, a.build_number), f"assembled and verified the {a.platform} set in {a.out}")
    if a.cmd == "verify":
        return _report(verify_set(a.src, a.platform, a.source_sha, a.build_number), f"the {a.platform} set in {a.src} is complete and intact")
    return _report(authorize(a.permission, a.destination, a.platform), "publication is authorised for this actor")


if __name__ == "__main__":
    sys.exit(main())
