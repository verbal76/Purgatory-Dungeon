#!/usr/bin/env python3
"""Qualify an Android APK before it is delivered.

  verify_apk.py <apk> --version N [--package ID] [--target-sdk 36] [--min-sdk 30]
                [--release] [--require-logo] [--sha SHA] [--expect-cert SHA256]

Checks (Android SDK build-tools found via ANDROID_HOME):
  * identity: package id, versionCode == N, versionName == "N", targetSdk >= target, minSdk, arm64 only
  * 16 KB page size: every PT_LOAD segment of every packaged .so is aligned to >= 16384, and the APK
    passes `zipalign -c -P 16` (uncompressed native libs on 16 KB boundaries)
  * signature: apksigner verify (v2+), prints the signing certificate SHA-256 (optionally must equal
    --expect-cert, so a build can never be signed with a different key than the install line)
  * content: the game PCK inside the APK has the studio splash, the canonical logo, build_info.json
    for this version, and nothing from tests/archive/docs (same checks as the Windows package)
Prints SHA-256 of the APK. Exit 1 on any problem.
"""
import argparse
import glob
import hashlib
import os
import re
import struct
import subprocess
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_package as vp  # noqa: E402


def sdk_tool(name):
    home = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or ""
    cands = sorted(glob.glob(os.path.join(home, "build-tools", "*", name)), reverse=True)
    return cands[0] if cands else ""


def elf_load_alignments(data):
    if data[:4] != b"\x7fELF" or data[4] != 2:
        return None  # not ELF64
    e_phoff = struct.unpack_from("<Q", data, 0x20)[0]
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 0x36)
    out = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", data, off)[0]
        if p_type == 1:  # PT_LOAD
            out.append(struct.unpack_from("<Q", data, off + 48)[0])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("apk")
    ap.add_argument("--version", type=int, required=True)
    ap.add_argument("--package", default="com.hotatticgames.purgatorydungeon")
    ap.add_argument("--target-sdk", type=int, default=36)
    ap.add_argument("--min-sdk", type=int, default=30)
    ap.add_argument("--release", action="store_true")
    ap.add_argument("--require-logo", action="store_true")
    ap.add_argument("--sha", default="")
    ap.add_argument("--expect-cert", default="")
    a = ap.parse_args()
    problems, notes = [], []
    if not os.path.isfile(a.apk):
        print("APK not found:", a.apk)
        return 1
    notes.append(f"{os.path.basename(a.apk)}: {os.path.getsize(a.apk)} bytes, sha256 {vp.sha256(a.apk)}")

    aapt2 = sdk_tool("aapt2")
    if aapt2:
        out = subprocess.run([aapt2, "dump", "badging", a.apk], capture_output=True, text=True).stdout
        m = re.search(r"package: name='([^']*)' versionCode='(\d+)' versionName='([^']*)'", out)
        if not m:
            problems.append("could not read the APK manifest (aapt2 dump badging)")
        else:
            pkg, code, name = m.group(1), int(m.group(2)), m.group(3)
            if pkg != a.package:
                problems.append(f"package id is {pkg}, expected {a.package}")
            if code != a.version:
                problems.append(f"versionCode is {code}, expected {a.version}")
            if name != str(a.version):
                problems.append(f'versionName is "{name}", expected "{a.version}"')
            notes.append(f"package {pkg} versionCode {code} versionName {name}")
        t = re.search(r"targetSdkVersion:'(\d+)'", out)
        mn = re.search(r"(?<!target)[sS]dkVersion:'(\d+)'", out)
        if not t or int(t.group(1)) < a.target_sdk:
            problems.append(f"targetSdkVersion is {t.group(1) if t else '?'}, expected >= {a.target_sdk}")
        else:
            notes.append(f"targetSdkVersion {t.group(1)}")
        if not mn or int(mn.group(1)) != a.min_sdk:
            problems.append(f"minSdkVersion is {mn.group(1) if mn else '?'}, expected {a.min_sdk}")
        nc = re.search(r"native-code: ([^\n]*)", out)
        if not nc or "arm64-v8a" not in nc.group(1) or re.search(r"armeabi|x86", nc.group(1)):
            problems.append(f"native code should be arm64-v8a only (found {nc.group(1) if nc else 'none'})")
        for perm in re.findall(r"uses-permission: name='([^']*)'", out):
            notes.append(f"permission: {perm}")
    else:
        problems.append("aapt2 not found (set ANDROID_HOME)")

    with zipfile.ZipFile(a.apk) as z:
        bad = z.testzip()
        if bad:
            problems.append(f"APK member is corrupt: {bad}")
        sos = [n for n in z.namelist() if n.endswith(".so")]
        if not sos:
            problems.append("the APK contains no native libraries")
        for n in sos:
            al = elf_load_alignments(z.read(n))
            if al is None:
                problems.append(f"{n} is not a 64-bit ELF")
            elif not al or min(al) < 0x4000:
                problems.append(f"{n} is not 16 KB aligned (PT_LOAD p_align {[hex(x) for x in al]})")
        if sos:
            notes.append(f"{len(sos)} native libraries, all PT_LOAD segments 16 KB aligned" if not [p for p in problems if "16 KB" in p] else "16 KB check failed")
        # The game data is the Godot PCK stored as an APK asset (its name differs between template
        # versions), so identify it by content: an asset that starts with the "GDPC" magic.
        pck_members = []
        big_assets = []
        for i in z.infolist():
            if not i.filename.startswith("assets/") or i.file_size < 1_000_000:
                continue
            with z.open(i) as fh:
                magic = fh.read(4)
            big_assets.append((i.filename, i.file_size, magic))
            if magic == b"GDPC":
                pck_members.append(i)
        if not pck_members:
            problems.append("no game data (PCK) found in the APK; large assets: " + ", ".join(
                f"{n} ({sz} bytes, magic {mg!r})" for n, sz, mg in big_assets[:8]))
        else:
            notes.append(f"game data: {pck_members[0].filename} ({pck_members[0].file_size} bytes)")
            tmp = tempfile.mkdtemp()
            z.extract(pck_members[0], tmp)
            pck = os.path.join(tmp, pck_members[0].filename)
            vp.check_pck(pck, a.version, a.require_logo, a.release, a.sha, problems, notes)

    zipalign = sdk_tool("zipalign")
    if zipalign:
        r = subprocess.run([zipalign, "-c", "-P", "16", "4", a.apk], capture_output=True, text=True)
        if r.returncode != 0:
            problems.append("zipalign -P 16 reports misaligned entries: " + (r.stdout + r.stderr)[:300])
        else:
            notes.append("zipalign -c -P 16 passed (native libs on 16 KB boundaries)")
    apksigner = sdk_tool("apksigner")
    if apksigner:
        r = subprocess.run([apksigner, "verify", "--verbose", "--print-certs", a.apk], capture_output=True, text=True)
        out = r.stdout + r.stderr
        if r.returncode != 0:
            problems.append("apksigner verify failed: " + out[:300])
        else:
            cert = re.search(r"certificate SHA-256 digest:\s*([0-9a-fA-F:]+)", out)
            if not cert:
                kt = subprocess.run(["keytool", "-printcert", "-jarfile", a.apk], capture_output=True, text=True)
                cert = re.search(r"SHA256:\s*([0-9A-Fa-f:]+)", kt.stdout)
                if not cert:
                    problems.append("could not read the signing certificate; apksigner said: " + out[:400].replace("\n", " | "))
            if cert:
                cert_hex = cert.group(1).replace(":", "").lower()
                notes.append("signature verified; certificate SHA-256 " + cert_hex)
            dn = re.search(r"Signer #1 certificate DN: ([^\n]*)", out)
            if dn:
                notes.append("signer " + dn.group(1))
                if "Android Debug" in dn.group(1):
                    problems.append("the APK is signed with the generic Android debug certificate")
            if a.expect_cert and cert and cert_hex != a.expect_cert.lower():
                problems.append(f"signing certificate {cert_hex} != expected {a.expect_cert}")
    else:
        problems.append("apksigner not found")

    for n in notes:
        print("  ok:", n)
    for p in problems:
        print("  APK PROBLEM:", p)
    print("apk verification", "FAILED" if problems else "passed")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
