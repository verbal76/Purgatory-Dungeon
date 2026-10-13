#!/usr/bin/env python3
"""Assembles the tiny Godot project in which tools/ota_make_manifest.gd and tools/ota_inspect_pack.gd run.

  tool_project.py <dest-dir> [--root DIR] [--standin]

The two GDScript tools need only the native layer's own scripts (scripts/boot/*: OtaCore, OtaConfig), the game layer's
save-schema constants, the boundary, VERSION and themselves. Running them in a copy of just those files avoids importing
the whole 640 MB game, and it runs the REAL client code (the same files the APK embeds). Project layout produced:
  project.godot  scripts/boot/*  scripts/save_schema.gd  ota/boundary.json  VERSION  tools/ota_make_manifest.gd
  tools/ota_inspect_pack.gd
--standin copies tests/ota_standin/ files for the pieces the tree does not have yet (tests only; never in CI);
prefer_standin (tests: OTA_TEST_STANDIN=1) uses the stand-in client even when the tree has the real one.
"""
import argparse
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import otalib  # noqa: E402
from otalib import OtaError  # noqa: E402

PROJECT = ('config_version=5\n\n[application]\n\nconfig/name="PD OTA tool project"\n'
           'config/features=PackedStringArray("4.6")\n')


def assemble(dest: str, root: str = "", standin: bool = False, prefer_standin: bool = False) -> str:
    root = os.path.abspath(root or otalib.REPO_ROOT)
    standin_dir = os.path.join(root, "tests", "ota_standin")
    if os.path.exists(dest) and os.listdir(dest):
        raise OtaError(f"{dest} is not empty")
    os.makedirs(dest, exist_ok=True)

    def put(rel: str, src: str) -> None:
        d = os.path.join(dest, *rel.split("/"))
        os.makedirs(os.path.dirname(d), exist_ok=True)
        shutil.copyfile(src, d)

    boot = os.path.join(root, "scripts", "boot")
    if os.path.isdir(boot) and os.path.isfile(os.path.join(boot, "ota_core.gd")) and not (standin and prefer_standin):
        for f in sorted(os.listdir(boot)):
            if os.path.isfile(os.path.join(boot, f)):
                put("scripts/boot/" + f, os.path.join(boot, f))
    elif standin:
        sb = os.path.join(standin_dir, "scripts", "boot")
        for f in sorted(os.listdir(sb)):
            put("scripts/boot/" + f, os.path.join(sb, f))
    else:
        raise OtaError("scripts/boot/ota_core.gd does not exist in the tree (the native layer)")
    schema = os.path.join(root, "scripts", "save_schema.gd")
    if os.path.isfile(schema):
        put("scripts/save_schema.gd", schema)
    elif standin:
        put("scripts/save_schema.gd", os.path.join(standin_dir, "scripts", "save_schema.gd"))
    else:
        raise OtaError("scripts/save_schema.gd does not exist in the tree (game layer, SAVE_SCHEMA / MIN_SAVE_SCHEMA)")
    put("ota/boundary.json", os.path.join(root, "ota", "boundary.json"))
    put("VERSION", os.path.join(root, "VERSION"))
    for t in ("ota_make_manifest.gd", "ota_inspect_pack.gd"):
        put("tools/" + t, os.path.join(otalib.REPO_ROOT, "tools", t))
    with open(os.path.join(dest, "project.godot"), "w", encoding="utf-8") as f:
        f.write(PROJECT)
    return dest


def import_project(godot: str, dest: str) -> None:
    """Registers the global classes of the tiny project (a few seconds)."""
    subprocess.run([godot, "--headless", "--path", dest, "--import"], capture_output=True, timeout=300)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("dest")
    ap.add_argument("--root", default="")
    ap.add_argument("--standin", action="store_true")
    ap.add_argument("--godot", default="", help="also run `godot --import` in the new project")
    a = ap.parse_args(argv)
    try:
        assemble(a.dest, a.root, a.standin)
        if a.godot:
            import_project(a.godot, a.dest)
    except OtaError as e:
        print(f"tool_project.py: {e}", file=sys.stderr)
        return 1
    print(f"tool project assembled in {a.dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
