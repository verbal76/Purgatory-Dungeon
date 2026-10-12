#!/usr/bin/env python3
"""One local entry point for the three platform builds (Hot Attic Games master standard, sections 5-9). LOCAL ONLY: it never uploads, tags, releases or
publishes anything; a GitHub Release, an OTA, Steam or Play upload are separate, owner-authorised actions (docs/RELEASES.md).

  python3 tools/build.py --platform windows|linux|android|all [--build-number N] [--source-sha SHA] [--out DIR] [--godot BIN]
                         [--naming standard|repo] [--destination local_only] [--dry-run]

What it does, in the order the standard asks for:
  1. resolves the exact commit (default HEAD) and exports THAT commit, never the working tree: `git archive <sha>` into a scratch directory, so a build can not
     contain unrecorded local changes (uncommitted edits are listed and ignored);
  2. stamps build_info.json (tools/release_tool.py build-info, which records the commit, the platform, the engine and the native runtime identity);
  3. exports each selected platform with Godot headless and packages it (Windows .zip, Linux .tar.gz with the executable bit set, Android .apk);
  4. writes build-manifest.json (title, build number, platform, source SHA, engine, configuration, timestamp, and per artifact its SHA-256 and size) and
     checksums.sha256 next to the artifacts, then re-reads the files and verifies both against what is on disk (exit 1 on any mismatch).
A platform that cannot be built here is reported BLOCKED with the reason and the build exits 1; a partial result is never presented as a complete release.
For `all` every platform is built from the same SHA and the same build number.

Linux has no preset in export_presets.cfg (adding one would change the native fingerprint; docs/COMPLIANCE_AUDIT.md RED-3), so the Linux preset is appended to the
scratch copy only. Android needs the SDK, a keystore and the signing secrets that live outside the repository (tools/android/build_apk.sh, docs/ANDROID.md); it is only
attempted when ANDROID_HOME and the signing environment are present. Nothing here claims a platform was TESTED because it compiled.

--naming standard  Purgatory Dungeon Build <N> EXE.zip / Linux.tar.gz / APK.apk  (the convention for every future build; docs/RELEASES.md)
--naming repo      Purgatory-Dungeon-v<N>-Windows.zip / -Linux.tar.gz / .apk     (the convention of releases v1-v8, kept for reproducing them)

Standard library only (plus git and a Godot 4.6 binary).
"""
import argparse
import datetime
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
TITLE = "Purgatory Dungeon"
PLATFORMS = ("windows", "linux", "android")
MANIFEST = "build-manifest.json"
CHECKSUMS = "checksums.sha256"
# Same exclusions as the Android preset: the unreferenced AllSkyFree skyboxes, the intro video and the night-sky texture are ~300 MB of the desktop PCK that no
# scene uses (the Windows preset still ships them; trimming it changes export_presets.cfg and so the native fingerprint, docs/COMPLIANCE_AUDIT.md RED-4).
EXCLUDE = ("tests/*, archive/*, production/*, tools/*, ota/*, *.md, addons/AllSkyFree/*, Music & background images/*.mp4, "
           "Music & background images/night_sky_with_beautiful_twinkling_stars.png")

LINUX_PRESET = """
[preset.2]

name="Linux"
platform="Linux"
runnable=true
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter="build_info.json"
exclude_filter="{exclude}"
export_path="build/linux/PurgatoryDungeon.x86_64"
script_export_mode=2

[preset.2.options]

custom_template/debug=""
custom_template/release=""
debug/export_console_wrapper=0
binary_format/embed_pck=false
texture_format/s3tc_bptc=true
texture_format/etc2_astc=false
binary_format/architecture="x86_64"
"""


class Blocked(Exception):
    """A platform that cannot be built in this environment (not a failure of the tool)."""


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run(args: list, cwd: str = ROOT, check: bool = True) -> str:
    p = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(args)} failed ({p.returncode}): {(p.stderr or p.stdout).strip()[-600:]}")
    return p.stdout.strip()


def artifact_name(platform: str, number: int, naming: str) -> str:
    if naming == "standard":
        return {"windows": f"{TITLE} Build {number} EXE.zip", "linux": f"{TITLE} Build {number} Linux.tar.gz", "android": f"{TITLE} Build {number} APK.apk"}[platform]
    slug = TITLE.replace(" ", "-")
    return {"windows": f"{slug}-v{number}-Windows.zip", "linux": f"{slug}-v{number}-Linux.tar.gz", "android": f"{slug}-v{number}.apk"}[platform]


def resolve_sha(ref: str) -> str:
    sha = run(["git", "rev-parse", "--verify", "--quiet", ref + "^{commit}"], check=False)
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise SystemExit(f"build: {ref!r} is not a commit in this repository")
    return sha


def read_build_number() -> int:
    return int(open(os.path.join(ROOT, "VERSION"), encoding="utf-8").read().strip())


def godot_version(godot: str) -> str:
    out = run([godot, "--version"])           # e.g. 4.6.stable.official.89cea1439
    m = re.match(r"(\d+\.\d+)\.(\w+)", out)
    return f"{m.group(1)}.{m.group(2)}" if m else out


def have_template(version: str, name: str) -> bool:
    base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    return os.path.isfile(os.path.join(base, "godot", "export_templates", version, name))


def extract_source(sha: str, dest: str) -> None:
    """The exact commit, with nothing from the working tree."""
    data = subprocess.run(["git", "archive", "--format=tar", sha], cwd=ROOT, capture_output=True, check=True).stdout
    with tarfile.open(fileobj=io.BytesIO(data)) as t:
        t.extractall(dest, filter="data")


def stamp_build_info(src: str, sha: str, platform: str, engine: str, release: bool, number: int = 0) -> None:
    args = [sys.executable, os.path.join(src, "tools", "release_tool.py"), "build-info", os.path.join(src, "build_info.json"),
            "--commit", sha, "--run-id", os.environ.get("GITHUB_RUN_ID", "local"), "--ref", os.environ.get("GITHUB_REF", "local-build"), "--platform", platform, "--engine", engine]
    if number:
        args += ["--build-number", str(number)]
    if release:
        args.append("--release")
    run(args, cwd=src)


def export(godot: str, src: str, preset: str, out_rel: str) -> str:
    out = os.path.join(src, out_rel)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    run([godot, "--headless", "--path", src, "--import"], cwd=src, check=False)       # first import fills .godot; its exit code is not meaningful
    run([godot, "--headless", "--path", src, "--export-release", preset, out_rel], cwd=src)
    if not os.path.isfile(out) or os.path.getsize(out) == 0:
        raise RuntimeError(f"export of {preset!r} produced no {out_rel}")
    return out


def top_folder(number: int, naming: str = "standard") -> str:
    """The folder inside every package (tools/verify_package.py expects it)."""
    return f"{TITLE.replace(' ', '-')}-{'Build-' if naming == 'standard' else 'v'}{number}"


def package_files(folder: str, platform: str, number: int, sha: str, engine: str, naming: str = "standard") -> dict:
    """The exported files plus the same VERSION.txt / BUILD_INFO.txt a CI release carries. Returns {archive name: (bytes or path, mode)}."""
    files = {}
    for f in sorted(os.listdir(folder)):
        full = os.path.join(folder, f)
        if os.path.isfile(full):
            files[f] = (full, 0o755 if f.endswith(".x86_64") else 0o644)
    label = {"windows": "Windows (x86-64)", "linux": "Linux (x86-64)"}[platform]
    start = "PurgatoryDungeon.exe" if platform == "windows" else "PurgatoryDungeon.x86_64"
    head = f"{TITLE} Build {number}" if naming == "standard" else f"{TITLE} v{number}"
    files["VERSION.txt"] = ((f"{head}\nNative version: v{read_build_number()}\nPlatform: {label}\nInstall: extract ALL files into one folder, keep {start} and PurgatoryDungeon.pck together, then run {start}.\n"
                             f"Saves: the PurgetoryDungeon folder (unchanged from earlier builds).\nSource commit: {sha}\n").encode(), 0o644)
    files["BUILD_INFO.txt"] = ((f"{TITLE} - {platform} build\nbuild_number={number}\nsource_sha={sha}\nref=local-build\ngodot={engine}\n"
                                f"built_utc={datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}\n"
                                f"export_preset={'Windows Desktop' if platform == 'windows' else 'Linux'} (release, x86_64, external PCK)\nsha256:\n"
                                + "".join(f"{sha256_file(v[0])}  {k}\n" for k, v in files.items() if isinstance(v[0], str))).encode(), 0o644)
    return files


def build_windows(godot: str, src: str, dest: str, name: str, version: str, number: int, sha: str, naming: str = "standard") -> str:
    if not have_template(version, "windows_release_x86_64.exe"):
        raise Blocked(f"Godot {version} Windows export template is not installed")
    exe = export(godot, src, "Windows Desktop", "build/windows/PurgatoryDungeon.exe")
    folder = os.path.dirname(exe)
    path = os.path.join(dest, name)
    top = top_folder(number, naming)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for arc, (data, _mode) in package_files(folder, "windows", number, sha, version, naming).items():
            if isinstance(data, str):
                z.write(data, f"{top}/{arc}")
            else:
                z.writestr(f"{top}/{arc}", data)
    return path


def build_linux(godot: str, src: str, dest: str, name: str, version: str, number: int, sha: str, naming: str = "standard") -> str:
    if not have_template(version, "linux_release.x86_64"):
        raise Blocked(f"Godot {version} Linux export template (linux_release.x86_64) is not installed; install the official export templates tpz")
    with open(os.path.join(src, "export_presets.cfg"), "a", encoding="utf-8") as f:   # the scratch copy only; the tracked file is untouched
        f.write(LINUX_PRESET.format(exclude=EXCLUDE))
    exe = export(godot, src, "Linux", "build/linux/PurgatoryDungeon.x86_64")
    folder = os.path.dirname(exe)
    os.chmod(exe, 0o755)
    path = os.path.join(dest, name)
    top = top_folder(number, naming)
    with tarfile.open(path, "w:gz") as t:
        for arc, (data, mode) in package_files(folder, "linux", number, sha, version, naming).items():
            info = tarfile.TarInfo(f"{top}/{arc}")
            info.mode = mode
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            if isinstance(data, str):
                info.size = os.path.getsize(data)
                with open(data, "rb") as fh:
                    t.addfile(info, fh)
            else:
                info.size = len(data)
                t.addfile(info, io.BytesIO(data))
    return path


def build_android(src: str, dest: str, name: str) -> str:
    if not os.environ.get("ANDROID_HOME") and not os.environ.get("ANDROID_SDK_ROOT"):
        raise Blocked("no Android SDK (ANDROID_HOME) in this environment")
    if not os.environ.get("ANDROID_KEYSTORE_B64") and not os.environ.get("ANDROID_KEYSTORE"):
        raise Blocked("the persistent Android signing key is not available here (it lives in the CI key store, never in the repository); "
                      "see docs/ANDROID.md for the signed pipeline")
    raise Blocked("the signed APK pipeline is tools/android/build_apk.sh run by ci.yml; this local tool does not re-implement it (docs/ANDROID.md)")


def write_manifest(dest: str, number: int, sha: str, engine: str, naming: str, results: dict) -> dict:
    artifacts = []
    for platform, r in results.items():
        if r.get("status") == "built":
            artifacts.append({"platform": platform, "file": os.path.basename(r["path"]), "sha256": sha256_file(r["path"]), "bytes": os.path.getsize(r["path"])})
    manifest = {
        "title": TITLE, "build_number": number, "source_sha": sha, "engine": engine, "configuration": "release", "naming": naming,
        "built_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "toolchain": {"python": sys.version.split()[0], "godot_export": engine},
        "platforms": {p: {"status": r["status"], **({"reason": r["reason"]} if "reason" in r else {})} for p, r in results.items()},
        "artifacts": artifacts,
        "tested_on_device": False,     # a package that compiled is not a package that was tested (master standard step 4)
    }
    with open(os.path.join(dest, MANIFEST), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    with open(os.path.join(dest, CHECKSUMS), "w", encoding="utf-8") as f:
        for a in artifacts:
            f.write(f"{a['sha256']}  {a['file']}\n")
    return manifest


def verify_manifest(dest: str) -> list:
    """Re-read build-manifest.json and checksums.sha256 and compare with the files on disk. Returns the problems (empty = verified)."""
    problems = []
    try:
        manifest = json.load(open(os.path.join(dest, MANIFEST), encoding="utf-8"))
    except (OSError, ValueError) as e:
        return [f"cannot read {MANIFEST}: {e}"]
    sums = {}
    try:
        for line in open(os.path.join(dest, CHECKSUMS), encoding="utf-8").read().splitlines():
            h, _, n = line.partition("  ")
            sums[n] = h
    except OSError as e:
        problems.append(f"cannot read {CHECKSUMS}: {e}")
    for a in manifest.get("artifacts", []):
        p = os.path.join(dest, a["file"])
        if not os.path.isfile(p):
            problems.append(f"{a['file']}: missing")
            continue
        if sha256_file(p) != a["sha256"]:
            problems.append(f"{a['file']}: SHA-256 differs from the manifest")
        if os.path.getsize(p) != a["bytes"]:
            problems.append(f"{a['file']}: size differs from the manifest")
        if sums.get(a["file"]) != a["sha256"]:
            problems.append(f"{a['file']}: not matching {CHECKSUMS}")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--platform", required=True, choices=PLATFORMS + ("all",))
    ap.add_argument("--build-number", type=int, default=0, help="the coordinated build number (required with --naming standard); with --naming repo the default is ./VERSION")
    ap.add_argument("--source-sha", default="HEAD")
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "dist"))
    ap.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    ap.add_argument("--naming", choices=("repo", "standard"), default="standard")
    ap.add_argument("--destination", choices=("local_only",), default="local_only",
                    help="only local_only exists here: publishing to GitHub Releases is a separate, owner-authorised step")
    ap.add_argument("--dry-run", action="store_true", help="resolve and print the plan; build nothing")
    a = ap.parse_args()

    sha = resolve_sha(a.source_sha)
    if a.naming == "standard" and a.build_number < 1:
        raise SystemExit("build: --build-number N (a positive integer) is required: the build number is an explicit decision, never guessed from VERSION")
    number = a.build_number or read_build_number()
    wanted = list(PLATFORMS) if a.platform == "all" else [a.platform]
    dirty = run(["git", "status", "--porcelain", "--untracked-files=no"], check=False)
    print(f"build {TITLE} #{number} from {sha} for {', '.join(wanted)} (local_only)")
    if dirty:
        print("NOTE: the working tree has uncommitted changes; they are NOT in this build (the exact commit is exported).")
    for p in wanted:
        print(f"  {p}: {artifact_name(p, number, a.naming)}")
    if a.dry_run:
        return 0

    version = godot_version(a.godot) if shutil.which(a.godot) or os.path.isfile(a.godot) else ""
    dest = os.path.abspath(a.out)
    os.makedirs(dest, exist_ok=True)
    results = {}
    scratch = tempfile.mkdtemp(prefix="pd-build-")
    try:
        for platform in wanted:
            name = artifact_name(platform, number, a.naming)
            try:
                if platform != "android" and not version:
                    raise Blocked(f"Godot binary {a.godot!r} not found (--godot / $GODOT)")
                src = os.path.join(scratch, platform)
                os.makedirs(src)
                extract_source(sha, src)
                stamp_build_info(src, sha, platform, f"{version}", release=False, number=number if a.naming == "standard" else 0)
                if platform == "windows":
                    path = build_windows(a.godot, src, dest, name, version, number, sha, a.naming)
                elif platform == "linux":
                    path = build_linux(a.godot, src, dest, name, version, number, sha, a.naming)
                else:
                    path = build_android(src, dest, name)
                results[platform] = {"status": "built", "path": path}
                print(f"  {platform}: built {name} ({os.path.getsize(path)} bytes)")
                if platform != "android":
                    # Inspect the FINAL package (layout, executable, PCK content, and that it boots headless into the main menu), as the release does.
                    vargs = ["--version", str(read_build_number())] + (["--build-number", str(number)] if a.naming == "standard" else [])
                    v = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "verify_package.py"), path, *vargs, "--godot", a.godot],
                                       capture_output=True, text=True)
                    if v.returncode != 0:
                        raise RuntimeError("package verification failed:\n" + "\n".join(l for l in v.stdout.splitlines() if "PROBLEM" in l)[:500])
                    print(f"  {platform}: package verification passed (boots headless to the main menu; this is not a device test)")
            except Blocked as e:
                results[platform] = {"status": "blocked", "reason": str(e)}
                print(f"  {platform}: BLOCKED: {e}")
            except (RuntimeError, OSError, subprocess.CalledProcessError) as e:
                results[platform] = {"status": "failed", "reason": str(e)[:400]}
                print(f"  {platform}: FAILED: {str(e)[:400]}")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    write_manifest(dest, number, sha, version or "unknown", a.naming, results)
    problems = verify_manifest(dest)
    for p in problems:
        print("MANIFEST PROBLEM: " + p)
    complete = all(r["status"] == "built" for r in results.values())
    print(f"manifest and checksums written to {dest}: {'verified' if not problems else 'NOT verified'}; "
          f"{'complete' if complete else 'INCOMPLETE: not a complete release'}")
    return 0 if complete and not problems else 1


if __name__ == "__main__":
    sys.exit(main())
