#!/usr/bin/env python3
"""Import the studio controller-glyph library (owner-provided Source.zip) into assets/ui/glyphs/ as a CURATED subset.

  python3 tools/import_glyph_library.py /path/to/Source.zip

Only the glyphs the game can show are copied (about 150 of the 1,580 PNGs), under normalized names:

  assets/ui/glyphs/xbox/<token>.png      Xbox (XGamepad/Light)
  assets/ui/glyphs/ps5/<token>.png       PlayStation (P5Gamepad/Light; DualShock 4 players see the same shapes)
  assets/ui/glyphs/switch/<token>.png    Nintendo Switch (SGamepad/Light)
  assets/ui/glyphs/keyboard/<key>.png    keyboard + mouse (Keyboard_Mouse/White)
  assets/ui/glyphs/LIBRARY.json          source archive sha256, and for every file its source path and sha256
  assets/ui/glyphs/NOTICE.md             provenance and the (unverified) license status

A token is a button by POSITION: a b x y = south east west north (Godot's joypad layout), lb rb lt rt, l3 r3, view, menu, dpad_*; the per-family
file decides what it is drawn as (south is "A" on Xbox, a cross on PlayStation, "B" on Switch). The Xbox set ships Menu (hamburger) and View (two windows) only as cells of
its sprite sheet (T_X_Light_Sprite.svg), so those two are rendered from that SVG and cropped (needs Pillow + cairosvg; the committed PNGs are the result). The Steam Deck uses the Xbox shapes with the PlayStation-style
L1 / R1 / L2 / R2 shoulders, which are the Deck's own labels (controller_glyphs.gd decides).

Standard library only. The archive is treated as untrusted: member names are checked, nothing is executed, only PNG files are read.
"""
import hashlib
import json
import os
import re
import sys
import zipfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
OUT = os.path.join(ROOT, "assets", "ui", "glyphs")

XBOX = {
    "a": "T_X_A_Color", "b": "T_X_B_Color", "x": "T_X_X_Color", "y": "T_X_Y_Color",
    "lb": "T_X_LB", "rb": "T_X_RB", "lt": "T_X_LT", "rt": "T_X_RT",
    "l3": "T_X_Left_Stick_Click", "r3": "T_X_Right_Stick_Click",
    "lstick": "T_X_L", "rstick": "T_X_R",
    "dpad_up": "T_X_Dpad_Up", "dpad_down": "T_X_Dpad_Down", "dpad_left": "T_X_Dpad_Left", "dpad_right": "T_X_Dpad_Right",
}
PS5 = {
    "a": "T_P5_Cross_Color", "b": "T_P5_Circle_Color", "x": "T_P5_Square_Color", "y": "T_P5_Triangle_Color",
    "lb": "T_P5_L1", "rb": "T_P5_R1", "lt": "T_P5_L2", "rt": "T_P5_R2", "l3": "T_P5_L3", "r3": "T_P5_R3",
    "view": "T_P5_Share", "menu": "T_P5_Options", "lstick": "T_P5_L", "rstick": "T_P5_R",
    "dpad_up": "T_P5_Dpad_UP", "dpad_down": "T_P5_Dpad_Down", "dpad_left": "T_P5_Dpad_Left", "dpad_right": "T_P5_Dpad_Right",
}
SWITCH = {   # positional: the south button is labelled B on a Switch pad
    "a": "T_S_B", "b": "T_S_A", "x": "T_S_Y", "y": "T_S_X",
    "lb": "T_S_LB", "rb": "T_S_RB", "lt": "T_S_LT", "rt": "T_S_RT", "l3": "T_S_L", "r3": "T_S_R",
    "view": "T_S_Minus", "menu": "T_S_Plus", "lstick": "T_S_L", "rstick": "T_S_R",
    "dpad_up": "T_S_Dpad_Up", "dpad_down": "T_S_Dpad_Down", "dpad_left": "T_S_Dpad_Left", "dpad_right": "T_S_Dpad_Right",
}
# The Light / White variants: light glyphs read clearly on the game's near-black UI (the Default / Dark ones are dark on dark).
FAMILIES = {"xbox": ("XGamepad/Light", XBOX), "ps5": ("P5Gamepad/Light", PS5), "switch": ("SGamepad/Light", SWITCH)}
SUFFIX = "_Light"
KEY_DIR = "Keyboard_Mouse/White"
KEY_SKIP = re.compile(r"Sprite|\.svg|-1\.png$|Key_Dark_Key")
KEY_RENAME = {"crtl": "ctrl", "esc": "esc", "enter": "enter", "pageup": "page_up", "pagedown": "page_down", "capslock": "caps_lock", "numlock": "num_lock",
              "prtscrn": "print_screen", "ins": "insert", "del": "delete", "backspace": "backspace", "mouse_scroll_key_dark": "mouse_scroll"}


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


# Xbox Menu / View exist only as cells of the Light sprite sheet. Rendered at scale 4: (name, left, top) of a 96 px cell on that render.
SPRITE = "XGamepad/Light/T_X_Light_Sprite.svg"
SPRITE_SCALE = 4
SPRITE_CELLS = {"menu": (16, 1696), "view": (184, 1696)}
CELL = 96
CANVAS = 128


def put_sprite_glyphs(z, names, manifest) -> None:
    """Render the sprite sheet and crop the Menu / View cells onto a 128 px canvas (like the other library files)."""
    member = "Source/" + SPRITE
    if member not in names:
        sys.exit("missing in the archive: " + member)
    try:
        import io
        import cairosvg
        from PIL import Image
    except ImportError:
        print("NOTE: Pillow + cairosvg are not installed; xbox/menu.png and xbox/view.png were left as they are (they are only needed when re-importing)")
        return
    svg = z.read(member)
    sheet = Image.open(io.BytesIO(cairosvg.svg2png(bytestring=svg, scale=SPRITE_SCALE))).convert("RGBA")
    d = os.path.join(OUT, "xbox")
    os.makedirs(d, exist_ok=True)
    for token, (left, top) in SPRITE_CELLS.items():
        cell = sheet.crop((left, top, left + CELL, top + CELL))
        canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
        canvas.paste(cell, ((CANVAS - CELL) // 2, (CANVAS - CELL) // 2))
        out = io.BytesIO()
        canvas.save(out, "PNG")
        blob = out.getvalue()
        with open(os.path.join(d, token + ".png"), "wb") as f:
            f.write(blob)
        manifest["files"][f"xbox/{token}.png"] = {"source": SPRITE + f" (rendered x{SPRITE_SCALE}, cell {left},{top} {CELL}px)", "sha256": sha(blob)}


def main() -> int:
    if len(sys.argv) != 2 or not os.path.isfile(sys.argv[1]):
        print(__doc__)
        return 2
    path = sys.argv[1]
    data = open(path, "rb").read()
    z = zipfile.ZipFile(path)
    names = z.namelist()
    for n in names:
        if n.startswith("/") or ".." in n.split("/"):
            sys.exit("refusing an archive with an unsafe member name: " + n)
    prefix = "Source/"
    manifest = {"source_archive_sha256": sha(data), "source_archive_bytes": len(data), "files": {}}

    def put(family: str, token: str, member: str) -> None:
        if member not in names:
            sys.exit("missing in the archive: " + member)
        blob = z.read(member)
        if blob[:8] != b"\x89PNG\r\n\x1a\n":
            sys.exit("not a PNG: " + member)
        d = os.path.join(OUT, family)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, token + ".png"), "wb") as f:
            f.write(blob)
        manifest["files"][f"{family}/{token}.png"] = {"source": member[len(prefix):], "sha256": sha(blob)}

    for family, (folder, table) in FAMILIES.items():
        for token, stem in table.items():
            put(family, token, f"{prefix}{folder}/{stem}{SUFFIX}.png")
    put_sprite_glyphs(z, names, manifest)
    for n in sorted(names):
        if n.startswith(f"{prefix}{KEY_DIR}/") and n.endswith("_Key_White.png") and not KEY_SKIP.search(n):
            stem = os.path.basename(n)[len("T_"):-len("_Key_White.png")].lower()
            put("keyboard", KEY_RENAME.get(stem, stem), n)
    with open(os.path.join(OUT, "LIBRARY.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=1, sort_keys=True)
        f.write("\n")
    with open(os.path.join(OUT, "NOTICE.md"), "w", encoding="utf-8") as f:
        f.write(NOTICE.format(sha=manifest["source_archive_sha256"], n=len(manifest["files"])))
    print(f"imported {len(manifest['files'])} glyphs from {path} (sha256 {manifest['source_archive_sha256'][:16]}...)")
    return 0


NOTICE = """# Controller and keyboard glyphs: provenance and license

**Source.** The glyphs under `xbox/`, `ps5/`, `switch/` and `keyboard/` are a curated subset ({n} files) of the Hot Attic Games studio glyph library, delivered by the
owner as `Source.zip` (sha256 `{sha}`). `LIBRARY.json` lists, for every file, the member it came from and its own sha256. Re-run
`python3 tools/import_glyph_library.py <Source.zip>` to regenerate them.

**License: CC0 1.0 Universal, from the author's distribution page.** The owner supplied (2026-10-12) a screenshot of the library's distribution page ("Input Prompts"
pack by **JulioCacko**, published 2023-06-30, updated 2025-02-03; released on itch.io and FAB; "No generative AI was used"). It states: *"License: CC0 1.0 Universal. Free to
use in any project, commercial or non-commercial. No attribution required (but appreciated!)."* and lists **Asset license: Creative Commons Zero v1.0 Universal** (and
Code license: MIT). The archive itself contains no license file, and the screenshot image could not be stored in the repository by the session that recorded this notice, so:
keep a saved copy of that page (or the CC0 text) in `docs/licenses/` and note the page URL here when it is at hand. Evidence level: license stated by the author, seen by the
owner; not re-fetched from the source by us. Attribution is not required; crediting JulioCacko is a courtesy (done in `docs/THIRD_PARTY.md`).

**Derived.** `xbox/menu.png` and `xbox/view.png` are the library's own Menu and View glyphs, rendered from its sprite sheet (`XGamepad/Light/T_X_Light_Sprite.svg`) and
cropped; nothing is redrawn. The game no longer ships any hand-drawn glyph.

**Use in the game.** `scripts/controller_glyphs.gd` picks the family from the controller in use (or the Options > Controls override) and `scripts/glyph_prompt.gd`
shows the glyph in prompts. PlayStation shapes are also used for the Steam Deck's L1 / R1 / L2 / R2, which are the Deck's own labels.
"""

if __name__ == "__main__":
    sys.exit(main())
