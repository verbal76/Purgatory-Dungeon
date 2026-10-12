#!/usr/bin/env python3
"""Third-party asset provenance (docs/THIRD_PARTY_ASSETS.md): what ships is inventoried, what claims a license has the evidence file, and the glyph library
files are byte-identical to what LIBRARY.json recorded at import. Never asserts that an UNVERIFIED asset is licensed."""
import hashlib
import json
import os
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
fails = 0


def check(cond: bool, label: str) -> None:
    global fails
    if not cond:
        fails += 1
        print("FAIL: " + label)


def read(p: str) -> str:
    return open(os.path.join(ROOT, p), encoding="utf-8").read()


inv = read("docs/THIRD_PARTY_ASSETS.md")

# Every folder under addons/ is accounted for in the inventory.
for d in sorted(os.listdir(os.path.join(ROOT, "addons"))):
    if os.path.isdir(os.path.join(ROOT, "addons", d)):
        check(f"addons/{d}" in inv, f"addons/{d} is listed in docs/THIRD_PARTY_ASSETS.md")

# Assets the inventory calls VERIFIED by FILE have that file.
for need in ("assets/fonts/OFL-Cinzel.txt", "assets/fonts/OFL-SourceSans3.txt", "addons/kenney_ui_audio/LICENSE.txt", "addons/kenney_particle_pack/LICENSE.txt",
             "assets/ui/glyphs/NOTICE.md", "assets/ui/glyphs/LIBRARY.json"):
    check(os.path.isfile(os.path.join(ROOT, need)) and (need in inv or os.path.basename(need) in inv), f"{need} exists and the inventory cites it")

# Glyph provenance: every recorded file exists with the recorded hash, and no unrecorded PNG sits next to them.
lib = json.loads(read("assets/ui/glyphs/LIBRARY.json"))
check(len(lib["files"]) > 100 and len(lib["source_archive_sha256"]) == 64, "LIBRARY.json records the archive and its files")
for rel, meta in lib["files"].items():
    p = os.path.join(ROOT, "assets", "ui", "glyphs", rel)
    ok = os.path.isfile(p) and hashlib.sha256(open(p, "rb").read()).hexdigest() == meta["sha256"]
    check(ok, f"glyph {rel} matches its recorded sha256")
on_disk = set()
for sub in ("xbox", "ps5", "switch", "keyboard"):
    for f in os.listdir(os.path.join(ROOT, "assets", "ui", "glyphs", sub)):
        if f.endswith(".png"):
            on_disk.add(f"{sub}/{f}")
check(on_disk == set(lib["files"]), "no glyph PNG outside LIBRARY.json (unrecorded: %s)" % sorted(on_disk - set(lib["files"]))[:3])
check("CC0" in read("assets/ui/glyphs/NOTICE.md") and "CC0" in inv, "the glyph license claim is stated with its evidence level")

# Unreferenced media stays out of every build (.gdignore), and is not silently referenced by a scene or script.
for d in ("addons/AllSkyFree", "Music & background images/unused_media"):
    check(os.path.isfile(os.path.join(ROOT, d, ".gdignore")), f"{d} has .gdignore")
needles = ("AllSkyFree", "unused_media", "Andromeda", "night_sky_with")
for base in ("scenes", "scripts", "characters", "dungeon modules", "tests"):
    for dp, _dn, fn in os.walk(os.path.join(ROOT, base)):
        for f in fn:
            if f.endswith((".gd", ".tscn", ".tres")):
                t = open(os.path.join(dp, f), encoding="utf-8", errors="replace").read()
                for n in needles:
                    if n in t and f != "test_licenses.py":
                        check(False, f"{os.path.join(dp, f)} references excluded media {n}")

print(f"test_licenses: {fails} failures")
sys.exit(1 if fails else 0)
