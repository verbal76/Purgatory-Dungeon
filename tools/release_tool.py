#!/usr/bin/env python3
"""Purgatory Dungeon release helper. The public version lives in ONE place: ./VERSION
(a single integer, e.g. 2 -> "Purgatory Dungeon v2"). Everything else is derived from it or
verified against it.

  release_tool.py check [--tag vN]   verify VERSION, project.godot, export preset (and tag)
  release_tool.py set N              set the public version everywhere (VERSION, project.godot, preset)
  release_tool.py build-info OUT --commit SHA [--run-id ID] [--release]
                                     write the build_info.json shipped inside the game
  release_tool.py next               print the next public version number
"""
import argparse
import datetime
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRODUCT = "Purgatory Dungeon"
VERSION_FILE = os.path.join(ROOT, "VERSION")
PROJECT = os.path.join(ROOT, "project.godot")
PRESETS = os.path.join(ROOT, "export_presets.cfg")


def read_version() -> int:
    text = open(VERSION_FILE, encoding="utf-8").read().strip()
    if not re.fullmatch(r"[1-9][0-9]*", text):
        sys.exit(f"VERSION must be a single positive integer (got {text!r})")
    return int(text)


def _grab(path: str, pattern: str) -> str:
    m = re.search(pattern, open(path, encoding="utf-8").read(), re.M)
    return m.group(1) if m else ""


def check(tag: str = "") -> int:
    v = read_version()
    problems = []
    pg = _grab(PROJECT, r'^config/version="([^"]*)"')
    if pg != str(v):
        problems.append(f'project.godot config/version is "{pg}", expected "{v}"')
    for key in ("file_version", "product_version"):
        got = _grab(PRESETS, rf'^application/{key}="([^"]*)"')
        if got != f"{v}.0.0.0":
            problems.append(f'export_presets.cfg application/{key} is "{got}", expected "{v}.0.0.0"')
    code = _grab(PRESETS, r'^version/code=(\d+)')
    name = _grab(PRESETS, r'^version/name="([^"]*)"')
    if code != str(v):
        problems.append(f"export_presets.cfg Android version/code is {code!r}, expected {v} (versionCode rises with the public version)")
    if name != str(v):
        problems.append(f'export_presets.cfg Android version/name is "{name}", expected "{v}"')
    for rel, needle in (("docs/RELEASES.md", "Purgatory Dungeon v"), ("CLAUDE.md", "docs/RELEASES.md")):
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path) or needle not in open(path, encoding="utf-8").read():
            problems.append(f"{rel} must exist and describe the release convention ({needle!r} not found)")
    if tag and tag != f"v{v}":
        problems.append(f"tag {tag} does not match VERSION ({v}); a tag must be v<VERSION>")
    for p in problems:
        print("VERSION CHECK FAILED:", p)
    if not problems:
        print(f"version check OK: {PRODUCT} v{v}")
    return 1 if problems else 0


def set_version(n: int) -> None:
    if n < 1:
        sys.exit("version must be >= 1")
    open(VERSION_FILE, "w", encoding="utf-8").write(f"{n}\n")
    for path, pairs in (
        (PROJECT, [(r'^(config/version=")[^"]*(")', f"\\g<1>{n}\\g<2>")]),
        (PRESETS, [(r'^(application/file_version=")[^"]*(")', f"\\g<1>{n}.0.0.0\\g<2>"),
                   (r'^(application/product_version=")[^"]*(")', f"\\g<1>{n}.0.0.0\\g<2>"),
                   # Android: versionName = the public number; versionCode rises with it (monotonic).
                   (r'^(version/code=)\d+', f"\\g<1>{n}"),
                   (r'^(version/name=")[^"]*(")', f"\\g<1>{n}\\g<2>")]),
    ):
        s = open(path, encoding="utf-8").read()
        for pat, rep in pairs:
            s, count = re.subn(pat, rep, s, flags=re.M)
            if count != 1:
                sys.exit(f"could not update {pat} in {path}")
        open(path, "w", encoding="utf-8").write(s)
    print(f"public version set to v{n}")


def build_info(out: str, commit: str, run_id: str, release: bool) -> None:
    info = {
        "product": PRODUCT,
        "public_version": read_version(),
        "release": release,           # true only for a build made from tag v<VERSION>
        "commit": commit,
        "ci_run": run_id,
        "built_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    with open(out, "w", encoding="utf-8") as f:
        json.dump(info, f, indent=2)
        f.write("\n")
    print(f"wrote {out}: {info}")


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--tag", default="")
    s = sub.add_parser("set")
    s.add_argument("n", type=int)
    b = sub.add_parser("build-info")
    b.add_argument("out")
    b.add_argument("--commit", required=True)
    b.add_argument("--run-id", default="")
    b.add_argument("--release", action="store_true")
    sub.add_parser("next")
    a = ap.parse_args()
    if a.cmd == "check":
        return check(a.tag)
    if a.cmd == "set":
        set_version(a.n)
    elif a.cmd == "build-info":
        build_info(a.out, a.commit, a.run_id, a.release)
    elif a.cmd == "next":
        print(read_version() + 1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
