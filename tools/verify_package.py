#!/usr/bin/env python3
"""Inspect a Windows package before it is delivered (a build directory or the final .zip).

  verify_package.py <build_dir | package.zip> --version N [--require-logo] [--release]
                    [--sha SHA] [--godot GODOT_BINARY]

Checks the executable and Godot PCK are there, the PCK really contains the studio splash (scene,
script, the canonical logo) and the generated build_info.json for the right version, that no tests,
archive material, fixtures or notes were exported, and (with --godot) that the PCK boots headless
through the splash into the main menu with no script errors. Prints SHA-256s. Exit 1 on any problem.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

LOGO = "Hot_Attic_Games_Master_Logo_ALPHA_FINAL.png"
FORBIDDEN_PREFIXES = ("res://tests/", "res://archive/", "res://production/", "res://docs/", "res://tools/")
FORBIDDEN_SUBSTR = ("fixture", "stress_generation", "/test_")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_pck(path):
    """Returns {res_path: (offset, size)} for a Godot 4 PCK."""
    with open(path, "rb") as f:
        if f.read(4) != b"GDPC":
            raise ValueError("not a Godot PCK (bad magic)")
        fmt, major, minor, patch = struct.unpack("<IIII", f.read(16))
        files = {}
        if fmt >= 2:
            flags, file_base = struct.unpack("<IQ", f.read(12))
        else:
            flags, file_base = 0, 0
        dir_offset = None
        if fmt >= 3:
            (dir_offset,) = struct.unpack("<Q", f.read(8))
        f.read(16 * 4)  # reserved
        if fmt >= 3:
            f.seek(dir_offset)
        (count,) = struct.unpack("<I", f.read(4))
        for _ in range(count):
            (plen,) = struct.unpack("<I", f.read(4))
            name = f.read(plen).rstrip(b"\0").decode("utf-8", "replace")
            offset, size = struct.unpack("<QQ", f.read(16))
            f.read(16)  # md5
            f.read(4)   # per-file flags (format >= 2)
            files[name] = (offset + file_base, size)
        return files, (major, minor, patch), fmt


def read_member(pck, entry):
    offset, size = entry
    with open(pck, "rb") as f:
        f.seek(offset)
        return f.read(size)


def check_pck(pck, version, require_logo, release, sha, problems, notes):
    """Inspect a Godot PCK (inside a build directory, a zip, or an APK) and append to problems/notes."""
    try:
        files, ver, fmt = read_pck(pck)
    except Exception as e:  # noqa: BLE001
        problems.append(f"PCK could not be read: {e}")
        return
    notes.append(f"pck sha256 {sha256(pck)} ({len(files)} files, Godot {ver[0]}.{ver[1]}.{ver[2]}, format {fmt})")
    check_names(list(files), lambda n: read_member(pck, files[n]), "PCK", version, require_logo, release, sha, problems, notes)
    return files


def check_names(names, read, what, version, require_logo, release, sha, problems, notes):
    """The content rules shared by a PCK and by the loose asset tree of a Godot Android APK.
    `read(name)` returns that member's bytes."""

    def has(sub):
        return any(sub in n for n in names)

    for need in ("scenes/StudioSplash.tscn", "scripts/studio_splash.gd", "scenes/MainMenu.tscn", "build_info.json", "scripts/build_info.gd"):
        if not (has(need) or has(need.replace(".gd", ".gdc")) or has(need + ".remap")):
            problems.append(f"the {what} does not contain {need}")
    if not has(LOGO):
        (problems if require_logo else notes).append(f"the {what} does not contain the canonical logo {LOGO}")
    else:
        notes.append(f"canonical logo {LOGO} is packed")
    for n in names:
        norm = n if n.startswith("res://") else "res://" + n   # APK assets carry no res:// prefix
        if norm.startswith(FORBIDDEN_PREFIXES) or any(x in n.lower() for x in FORBIDDEN_SUBSTR) or n.endswith(".md"):
            problems.append(f"the {what} contains a file that must not ship: {n}")
    # OTA client present -> the build must carry the PUBLIC trust anchor and the channel config, and no key material.
    if has("scripts/ota/ota_core"):
        pem_name = next((n for n in names if n.endswith("ota_trust.pem") and "/" not in n.replace("res://", "")), "")
        if not pem_name:
            problems.append(f"the {what} contains the OTA client but no ota_trust.pem (CI writes it before export)")
        else:
            pem = read(pem_name).decode("utf-8", "replace")
            if "-----BEGIN PUBLIC KEY-----" not in pem:
                problems.append("ota_trust.pem is not a PEM public key")
            if "PRIVATE" in pem:
                problems.append("ota_trust.pem contains PRIVATE key material")
            notes.append("OTA trust anchor present (public key only)")
        if not has("ota_channel.json"):
            problems.append(f"the {what} does not contain ota_channel.json")
        for n in names:
            low = n.lower()
            if low.endswith((".key", ".p12", ".jks", ".keystore")) or "ota-signing" in low or "ota_signing" in low:
                problems.append(f"the {what} contains key material: {n}")
    bi_name = next((n for n in names if n.endswith("build_info.json")), "")
    if bi_name:
        try:
            bi = json.loads(read(bi_name).decode("utf-8"))
            if int(bi.get("public_version", bi.get("version", -1))) != version:
                problems.append(f"build_info.json is for v{bi.get('public_version', bi.get('version'))}, expected v{version}")
            if release and not bi.get("release", False):
                problems.append("build_info.json is not stamped as a release build")
            if sha and bi.get("commit") and bi["commit"] != sha:
                problems.append(f"build_info.json commit {bi['commit']} != {sha}")
            notes.append("build_info.json: " + json.dumps(bi, sort_keys=True))
        except Exception as e:  # noqa: BLE001
            problems.append(f"build_info.json unreadable: {e}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("target")
    ap.add_argument("--version", type=int, required=True)
    ap.add_argument("--require-logo", action="store_true")
    ap.add_argument("--release", action="store_true", help="build_info.json must be the release stamp")
    ap.add_argument("--sha", default="")
    ap.add_argument("--godot", default="")
    a = ap.parse_args()
    problems, notes = [], []
    tmp = None
    root = a.target
    zip_sha = ""
    zip_name_expected = f"Purgatory-Dungeon-v{a.version}-Windows.zip"
    if a.target.lower().endswith(".zip"):
        if os.path.basename(a.target) != zip_name_expected:
            problems.append(f"package is named {os.path.basename(a.target)}, expected {zip_name_expected}")
        zip_sha = sha256(a.target)
        tmp = tempfile.mkdtemp()
        with zipfile.ZipFile(a.target) as z:
            bad = z.testzip()
            if bad:
                problems.append(f"zip member is corrupt: {bad}")
            z.extractall(tmp)
        tops = os.listdir(tmp)
        expected_top = f"Purgatory-Dungeon-v{a.version}"
        if tops != [expected_top]:
            problems.append(f"zip must contain exactly the folder {expected_top}/ (found {tops})")
        root = os.path.join(tmp, expected_top)
        for must in ("VERSION.txt", "BUILD_INFO.txt"):
            if not os.path.isfile(os.path.join(root, must)):
                problems.append(f"{must} is missing from the zip")
        vt = os.path.join(root, "VERSION.txt")
        if os.path.isfile(vt) and f"Purgatory Dungeon v{a.version}" not in open(vt, encoding="utf-8").read():
            problems.append("VERSION.txt does not say Purgatory Dungeon v%d" % a.version)
    exe = os.path.join(root, "PurgatoryDungeon.exe")
    pck = os.path.join(root, "PurgatoryDungeon.pck")
    for p in (exe, pck):
        if not os.path.isfile(p) or os.path.getsize(p) == 0:
            problems.append(f"{os.path.basename(p)} is missing or empty")
    if os.path.isfile(exe):
        with open(exe, "rb") as f:
            if f.read(2) != b"MZ":
                problems.append("PurgatoryDungeon.exe is not a Windows executable (no MZ header)")
        notes.append("exe sha256 " + sha256(exe))
    if os.path.isfile(pck):
        check_pck(pck, a.version, a.require_logo, a.release, a.sha, problems, notes)
        if a.godot and not problems:
            home = tempfile.mkdtemp()
            env = dict(os.environ, PURGATORY_SAVE_ROOT=os.path.join(home, "PurgetoryDungeon"))
            # The splash takes ~2.4 s of real time, so let the packaged game run ~12 s, then stop it.
            proc = subprocess.Popen([a.godot, "--headless", "--main-pack", pck], stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True, env=env)
            try:
                out, _ = proc.communicate(timeout=12)
            except subprocess.TimeoutExpired:
                proc.kill()
                out, _ = proc.communicate()
            try:
                if "SCRIPT ERROR" in out:
                    problems.append("the packaged game printed SCRIPT ERROR on boot:\n" + "\n".join(l for l in out.splitlines() if "SCRIPT ERROR" in l)[:600])
                if a.require_logo and "not found in the project" in out:
                    problems.append("the packaged game could not find the studio logo at runtime")
                if f"Version: v{a.version}" not in out:
                    problems.append(f"the packaged game did not report version v{a.version} (reached the main menu?)")
                else:
                    notes.append("packaged game boots headless through the splash into the main menu and reports v%d" % a.version)
            finally:
                shutil.rmtree(home, ignore_errors=True)
    if zip_sha:
        notes.append(f"{os.path.basename(a.target)} sha256 {zip_sha}")
    if tmp:
        shutil.rmtree(tmp, ignore_errors=True)
    for n in notes:
        print("  ok:", n)
    for p in problems:
        print("  PACKAGE PROBLEM:", p)
    print("package verification", "FAILED" if problems else "passed")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
