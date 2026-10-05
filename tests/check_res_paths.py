#!/usr/bin/env python3
"""Static check: every res:// path used by load()/preload() and by scene/resource
ext_resource entries must exist with EXACT case. Windows is case-insensitive and hides
mismatches that break on Linux/Android. Comments and docs are ignored on purpose."""
import os
import re
import subprocess
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
files = subprocess.check_output(["git", "ls-files"], cwd=root, text=True).splitlines()
exact = set(files)
lower = {}
for f in files:
    lower.setdefault(f.lower(), []).append(f)

# Any "res://dir/file.ext" string literal in code (consts, load(), preload(), ResourceLoader
# calls...). Directories (no extension) and templated paths are skipped.
load_re = re.compile(r'"res://([^"]+\.[A-Za-z0-9]+)"')
ext_re = re.compile(r'^\[ext_resource [^\]]*\bpath="res://([^"]+)"', re.M)
# Generated at build time by CI and handled when absent (see scripts/build_info.gd).
OPTIONAL_GENERATED = {"build_info.json", "ota_trust.pem"}
problems = []


def check(src, ref):
    if "%" in ref or "{" in ref or ref.endswith("/"):
        return
    if ref in exact or ref in OPTIONAL_GENERATED:
        return
    if ref.lower() in lower:
        problems.append(f"CASE MISMATCH in {src}: res://{ref} (actual: {lower[ref.lower()][0]})")
    else:
        problems.append(f"MISSING in {src}: res://{ref}")


for f in files:
    path = os.path.join(root, f)
    if f.startswith(("addons/", "tests/")) or not os.path.isfile(path):
        continue
    if f.endswith(".gd"):
        for line in open(path, encoding="utf-8", errors="ignore"):
            code = line.split("#", 1)[0]
            for m in load_re.finditer(code):
                check(f, m.group(1))
    elif f.endswith((".tscn", ".tres")):
        for m in ext_re.finditer(open(path, encoding="utf-8", errors="ignore").read()):
            check(f, m.group(1))

for p in problems:
    print(p)
print(f"check_res_paths: {len(problems)} problem(s)")
sys.exit(1 if problems else 0)
