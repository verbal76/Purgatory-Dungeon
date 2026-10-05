#!/usr/bin/env python3
"""Checks that the base.pck an OTA patch was built against really is what the shipped native build contains.

An update is a patch against base.pck; the device holds the NATIVE build's files, so the two must be identical
file for file (otherwise the patch silently omits files that differ and the device runs a mixed state).

  native_check.py compare --platform android|windows --base-pck base.pck --native <artifact>
                          [--allow PATH]... [--warn-only]
  native_check.py extract --platform P --native <artifact> --path build_info.json --out FILE

<artifact>:  windows  the build folder, PurgatoryDungeon.exe, PurgatoryDungeon.pck or the release zip
                      (the exe's sibling PurgatoryDungeon.pck is read)
             android  the APK. Godot's gradle export stores either one PCK under assets/ (found by its GDPC
                      magic) or the project's files loose under assets/ (res://x -> assets/x; this project keeps its
                      import data in godot/ rather than .godot/, so godot/imported/... -> assets/godot/imported/...).
                      Both layouts are handled.
compare lists, per file of base.pck, differences (content differs / missing in the native build) = errors and
files only the native build has = warnings. --allow names paths that are expected to differ (build_info.json is
stamped per build and is never part of a patch). --tolerate names import products (godot/imported/, godot/exported/):
Godot's importer is NOT byte-deterministic (random scene-unique ids inside .scn/.res; measured: 126 of 892 files
differ between two imports of the same commit), so for those only existence is required. Exit 0 clean, 1 on errors
(or 0 with --warn-only).
"""
import argparse
import hashlib
import os
import sys
import tempfile
import zipfile

import otalib
import pck as pcklib
from otalib import OtaError


class PckSource:
    def __init__(self, path):
        self.pck = pcklib.read_pck(path)
        self.desc = path

    def names(self):
        return {e.path for e in self.pck.entries if not e.removal}

    def md5(self, name):
        e = self.pck.by_path.get(name)
        if e is None or e.removal:
            return None
        return e.md5 if not e.encrypted else None

    def read(self, name):
        e = self.pck.by_path.get(name)
        return None if e is None else pcklib.read_entry(self.pck, e)


class ApkSource:
    """Loose files under assets/ of an APK."""

    def __init__(self, zf, desc):
        self.zf = zf
        self.desc = desc
        self.members = {i.filename: i for i in zf.infolist() if not i.is_dir() and i.filename.startswith("assets/")}

    @staticmethod
    def candidates(name):
        c = ["assets/" + name]
        if name.startswith(".godot/"):
            c.append("assets/godot/" + name[len(".godot/"):])
        return c

    def _member(self, name):
        for c in self.candidates(name):
            if c in self.members:
                return self.members[c]
        return None

    def names(self):
        return {m[len("assets/"):] for m in self.members}

    def md5(self, name):
        m = self._member(name)
        return None if m is None else hashlib.md5(self.zf.read(m)).hexdigest()

    def read(self, name):
        m = self._member(name)
        return None if m is None else self.zf.read(m)


def open_native(platform: str, path: str, tmp: str):
    if platform == "windows":
        if os.path.isdir(path):
            path = os.path.join(path, "PurgatoryDungeon.pck")
        elif path.lower().endswith(".exe"):
            path = path[:-4] + ".pck"
        elif path.lower().endswith(".zip"):
            with zipfile.ZipFile(path) as z:
                pcks = [n for n in z.namelist() if n.lower().endswith(".pck")]
                if len(pcks) != 1:
                    raise OtaError(f"{path} must contain exactly one .pck (found {len(pcks)})")
                z.extract(pcks[0], tmp)
                path = os.path.join(tmp, pcks[0])
        if not os.path.isfile(path):
            raise OtaError(f"native pack not found: {path}")
        return PckSource(path)
    if platform == "android":
        if not os.path.isfile(path):
            raise OtaError(f"APK not found: {path}")
        z = zipfile.ZipFile(path)
        for i in z.infolist():
            if i.filename.startswith("assets/") and i.file_size >= 100:
                with z.open(i) as fh:
                    if fh.read(4) == pcklib.MAGIC:
                        z.extract(i, tmp)
                        return PckSource(os.path.join(tmp, i.filename))
        src = ApkSource(z, path)
        if not src.members:
            raise OtaError(f"{path} holds neither a PCK nor loose files under assets/")
        return src
    raise OtaError(f"unknown platform {platform!r}")


def _tolerated(path, tolerate) -> bool:
    return any(path == t or (t.endswith("/") and path.startswith(t)) for t in tolerate)


def compare(platform, base_pck, native, allow, warn_only, tolerate=()) -> int:
    base = pcklib.read_pck(base_pck)
    with tempfile.TemporaryDirectory(prefix="ota-native-") as tmp:
        src = open_native(platform, native, tmp)
        errors, warnings = [], []
        base_names = set()
        tolerated_diff = 0
        for e in base.entries:
            if e.removal:
                continue
            base_names.add(e.path)
            if e.path in allow:
                continue
            got = src.md5(e.path)
            if got is None:
                errors.append(f"missing in the native build: {e.path}")
            elif got != e.md5:
                if _tolerated(e.path, tolerate):
                    tolerated_diff += 1       # import products: Godot's importer is not byte-deterministic
                else:
                    errors.append(f"content differs from the native build: {e.path}")
        for n in sorted(src.names() - base_names):
            if n not in allow:
                warnings.append(f"only in the native build (not in base.pck): {n}")
        for w in warnings[:50]:
            print("warning:", w)
        if len(warnings) > 50:
            print(f"warning: ... and {len(warnings) - 50} more")
        for e in errors[:100]:
            print("ERROR:", e)
        if len(errors) > 100:
            print(f"ERROR: ... and {len(errors) - 100} more")
        n = len([e for e in base.entries if not e.removal])
        print(f"native check ({platform}, {src.desc}): {n} base files compared, {len(errors)} error(s), {len(warnings)} warning(s)"
              + (f", {tolerated_diff} byte-different but tolerated import product(s)" if tolerated_diff else ""))
        if errors and warn_only:
            print("native check: errors downgraded to warnings (--warn-only)")
            return 0
        return 1 if errors else 0


def extract(platform, native, path, out) -> int:
    with tempfile.TemporaryDirectory(prefix="ota-native-") as tmp:
        src = open_native(platform, native, tmp)
        data = src.read(path)
        if data is None:
            raise OtaError(f"{path} not found in the native build")
        otalib.write_atomic(out, data)
        return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("compare")
    c.add_argument("--platform", required=True, choices=otalib.PLATFORMS)
    c.add_argument("--base-pck", required=True)
    c.add_argument("--native", required=True)
    c.add_argument("--allow", action="append", default=[])
    c.add_argument("--tolerate", action="append", default=[], metavar="PREFIX/",
                   help="files under this prefix (or this exact path) must exist in the native build but may differ in bytes")
    c.add_argument("--warn-only", action="store_true")
    x = sub.add_parser("extract")
    x.add_argument("--platform", required=True, choices=otalib.PLATFORMS)
    x.add_argument("--native", required=True)
    x.add_argument("--path", required=True)
    x.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    try:
        if a.cmd == "compare":
            return compare(a.platform, a.base_pck, a.native, set(a.allow), a.warn_only, tuple(a.tolerate))
        return extract(a.platform, a.native, a.path, a.out)
    except (OtaError, pcklib.PckError, zipfile.BadZipFile) as e:
        print(f"native_check.py: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
