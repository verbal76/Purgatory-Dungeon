#!/usr/bin/env python3
"""Desktop / window icon for Purgatory Dungeon: the same gilded dungeon-door artwork as the Android launcher icon (tools/make_android_icon.py),
on its rounded tile, as one PNG (Godot window icon, `config/icon`), a Windows .ico and a macOS .icns. Standard library only, deterministic.

    python3 tools/make_desktop_icon.py            # writes app_icon/PurgatoryDungeon.{png,ico,icns}

The tile is rendered once at 512 px with the Android generator's own functions and area-averaged down to the other sizes.
"""
import math
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import make_android_icon as A  # noqa: E402

ROOT = os.path.dirname(HERE)
OUT_DIR = os.path.join(ROOT, "app_icon")
BASE = 512
ICO_SIZES = (256, 128, 64, 48, 32, 16)


def tile_fn(size):
    """A.legacy_pixel with the tile size as a parameter (its corner radius is 44 px on a 192 px tile)."""
    radius = 44.0 * size / A.LEGACY
    half = size / 2.0

    def fn(u, v, ss):
        hu, hv = half / ss, half / ss
        rr = radius / ss
        qx, qy = abs(u) - (hu - rr), abs(v) - (hv - rr)
        dm = math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - rr
        cm = A.cover(dm, ss)
        if cm <= 0.0:
            return (0.0, 0.0, 0.0, 0.0)
        br, bgc, bb, _ = A.bg_pixel(u, v, ss)
        fr, fgc, fb, fa = A.fg_pixel(u, v, ss)
        return (fr * fa + br * (1 - fa), fgc * fa + bgc * (1 - fa), fb * fa + bb * (1 - fa), cm)
    return fn


def down(rgba, n):
    """Area-average the BASE x BASE tile to n x n (premultiplied), back to straight RGBA bytes."""
    ch = A._premul(rgba, BASE, BASE)
    out_ch = A.resample(ch, BASE, BASE, 0, BASE, 0, BASE, n)
    out = bytearray(n * n * 4)
    for i in range(n * n):
        a = out_ch[3][i]
        if a <= 1e-6:
            continue
        for c in range(3):
            out[i * 4 + c] = max(0, min(255, int(out_ch[c][i] / a * 255.0 + 0.5)))
        out[i * 4 + 3] = max(0, min(255, int(a * 255.0 + 0.5)))
    return out


def png_bytes(w, h, rgba):
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as t:
        path = t.name
    try:
        A.write_png(path, w, h, rgba)
        with open(path, "rb") as f:
            return f.read()
    finally:
        os.unlink(path)


def make_ico(pngs):
    """pngs: {size: png bytes}, PNG-compressed entries (Vista+; 256 is stored as 0 in the directory)."""
    sizes = sorted(pngs, reverse=True)
    head = struct.pack("<HHH", 0, 1, len(sizes))
    off = 6 + 16 * len(sizes)
    ent, data = b"", b""
    for s in sizes:
        b = pngs[s]
        ent += struct.pack("<BBBBHHII", 0 if s >= 256 else s, 0 if s >= 256 else s, 0, 0, 1, 32, len(b), off + len(data))
        data += b
    return head + ent + data


def make_icns(pngs):
    """PNG-compressed ic07 (128), ic08 (256), ic09 (512)."""
    body = b""
    for tag, s in ((b"ic07", 128), (b"ic08", 256), (b"ic09", 512)):
        b = pngs[s]
        body += tag + struct.pack(">I", 8 + len(b)) + b
    return b"icns" + struct.pack(">I", 8 + len(body)) + body


def main():
    s = A.LEGACY_SCALE * BASE / A.LEGACY
    base = A.render(tile_fn(BASE), BASE, s)
    pngs = {BASE: png_bytes(BASE, BASE, base)}
    for n in sorted(set(ICO_SIZES) | {128, 256}):
        pngs[n] = png_bytes(n, n, down(base, n))
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(os.path.join(OUT_DIR, "PurgatoryDungeon.png"), "wb") as f:
        f.write(pngs[256])
    with open(os.path.join(OUT_DIR, "PurgatoryDungeon.ico"), "wb") as f:
        f.write(make_ico({n: pngs[n] for n in ICO_SIZES}))
    with open(os.path.join(OUT_DIR, "PurgatoryDungeon.icns"), "wb") as f:
        f.write(make_icns(pngs))
    print("wrote", OUT_DIR)


if __name__ == "__main__":
    main()
