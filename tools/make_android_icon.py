#!/usr/bin/env python3
"""Procedural Android launcher icon for Purgatory Dungeon (standard library only, no Pillow, no Godot).

    python3 tools/make_android_icon.py                       # writes android_icons/*.png
    python3 tools/make_android_icon.py --preview docs/icon_preview.png   # + launcher-mask contact sheet
    python3 tools/make_android_icon.py --preview-only docs/icon_preview.png  # sheet from the committed PNGs

Concept: a gilded gothic dungeon door. A pointed arch with a bevelled brass-gold frame, an iron-bound plank door, and a
single glowing ember keyhole that lights the planks around it. One shape, one focal point, no text. The brand's own
palette (docs/UI_DESIGN_SYSTEM.md, scripts/ui/pui.gd): void/iron darks, brass + gold rim light, ember accent. It is
original artwork; nothing is copied from the studio logo and Hot_Attic_Games_Master_Logo_ALPHA_FINAL.png is not read.

Outputs (the paths export_presets.cfg already points at, so the preset is unchanged):
    main_192.png          legacy icon (pre-adaptive launchers): art on the rounded-square background, transparent corners
    adaptive_fg_432.png   foreground layer, transparent; ALL artwork inside the 288 px safe circle (66% of the 108 dp canvas)
    adaptive_bg_432.png   background layer, fully opaque charred stone with a warm glow where the door leaks light
    adaptive_mono_432.png themed-icon layer (Android 13+): one colour (white) + alpha, door silhouette with the keyhole cut out

Everything is a signed-distance function evaluated per pixel with 1 px analytic anti-aliasing, so the output is
deterministic and resolution independent (hash noise, no random module). The tests (tests/test_android_icons.py) import
this module for the PNG reader and the layer renderers.
"""
import argparse
import math
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "android_icons")

CANVAS = 432          # adaptive layer size (108 dp at xxxhdpi)
SAFE_RADIUS = 144.0   # visible circle guaranteed by every launcher mask = 66 dp of 108 dp
LEGACY = 192


def hexc(s):
    s = s.lstrip("#")
    return (int(s[0:2], 16) / 255.0, int(s[2:4], 16) / 255.0, int(s[4:6], 16) / 255.0)


# Palette: the game's UI tokens (scripts/ui/pui.gd) plus a few derived shades.
VOID = hexc("0b0908")
IRON_DEEP = hexc("15110f")
IRON = hexc("1e1916")
IRON_RAISED = hexc("2b241f")
IRON_HOVER = hexc("372e27")
EDGE = hexc("4d4034")
EDGE_BRASS = hexc("85693a")
EMBER = hexc("cf8a2e")
EMBER_BRIGHT = hexc("efae4d")
EMBER_DEEP = hexc("8a5a1d")
KEY_GOLD = hexc("e0b84a")
PARCHMENT = hexc("d3bf93")
HOT = hexc("fff1c4")      # white-hot core of the keyhole

# ---------------------------------------------------------------------------------------------- PNG I/O


def write_png(path, w, h, rgba):
    """8-bit RGBA, non-interlaced, filter 0 (deterministic for a given zlib)."""
    raw = bytearray()
    stride = w * 4
    for y in range(h):
        raw.append(0)
        raw += rgba[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "wb") as f:
        f.write(png)


def read_png(path):
    """Returns (w, h, rgba bytearray). 8-bit RGB/RGBA, non-interlaced (what this tool and Godot write)."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG: " + path)
    pos, idat, w, h, ctype = 8, b"", 0, 0, 0
    while pos < len(data):
        n, tag = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if tag == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or ctype not in (2, 6) or interlace != 0:
                raise ValueError("unsupported PNG layout in " + path)
        elif tag == b"IDAT":
            idat += body
        pos += 12 + n
    bpp = 4 if ctype == 6 else 3
    raw = zlib.decompress(idat)
    stride = w * bpp
    out = bytearray(w * h * 4)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        ft = raw[p]
        line = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        if ft == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif ft == 3:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif ft == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        elif ft != 0:
            raise ValueError("bad PNG filter")
        prev = line
        if bpp == 4:
            out[y * w * 4:(y + 1) * w * 4] = line
        else:
            for x in range(w):
                o = (y * w + x) * 4
                out[o:o + 3] = line[x * 3:x * 3 + 3]
                out[o + 3] = 255
    return w, h, out


# ---------------------------------------------------------------------------------------------- maths


def clamp(x, a=0.0, b=1.0):
    return a if x < a else (b if x > b else x)


def smooth(a, b, x):
    t = clamp((x - a) / (b - a))
    return t * t * (3.0 - 2.0 * t)


def mix(c1, c2, t):
    return (c1[0] + (c2[0] - c1[0]) * t, c1[1] + (c2[1] - c1[1]) * t, c1[2] + (c2[2] - c1[2]) * t)


def scale(c, k):
    return (c[0] * k, c[1] * k, c[2] * k)


def add(c1, c2, k=1.0):
    return (c1[0] + c2[0] * k, c1[1] + c2[1] * k, c1[2] + c2[2] * k)


def _h2(ix, iy, seed):
    n = (ix * 374761393 + iy * 668265263 + seed * 1442695041) & 0xFFFFFFFF
    n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
    n ^= n >> 16
    return n / 4294967295.0


def vnoise(x, y, seed=0):
    """Smooth value noise in [0, 1]."""
    ix, iy = math.floor(x), math.floor(y)
    fx, fy = x - ix, y - iy
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    a, b = _h2(ix, iy, seed), _h2(ix + 1, iy, seed)
    c, d = _h2(ix, iy + 1, seed), _h2(ix + 1, iy + 1, seed)
    return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy


class Px:
    """Premultiplied accumulator: painter's algorithm with analytic coverage."""
    __slots__ = ("r", "g", "b", "a")

    def __init__(self):
        self.r = self.g = self.b = self.a = 0.0

    def over(self, col, alpha):
        if alpha <= 0.0:
            return
        k = 1.0 - alpha
        self.r = col[0] * alpha + self.r * k
        self.g = col[1] * alpha + self.g * k
        self.b = col[2] * alpha + self.b * k
        self.a = alpha + self.a * k

    def straight(self):
        if self.a <= 1e-6:
            return (0.0, 0.0, 0.0, 0.0)
        return (clamp(self.r / self.a), clamp(self.g / self.a), clamp(self.b / self.a), clamp(self.a))


def cover(d, s):
    """Anti-aliased coverage of a signed distance d (design units, negative inside) at s output px per unit."""
    return clamp(0.5 - d * s)


# ---------------------------------------------------------------------------------------------- shapes
# Design space: the 432 px adaptive canvas centred on (0, 0), +y down.

# Pointed (lancet) arch: both side walls are vertical up to the spring line, then two arcs of radius ARCH_R meet at the apex.
ARCH_W = 90.0                      # half width of the outer silhouette
ARCH_R = 1.5 * ARCH_W              # arc radius (1.5 w: a clear gothic point, not a semicircle)
ARCH_SPRING = -14.0                # v of the spring line
ARCH_BASE = 106.0                  # v of the flat base
# apex at ARCH_SPRING - sqrt(2 R w - w^2) = -141.3  -> 141.3 <= 144 (safe circle); base corners at r = 139.2
FRAME = 14.0                       # brass frame thickness
GAP = 5.0                          # shadow gap between frame and door
PLATE_V = 16.0                     # escutcheon / keyhole centre
PLATE_R = 42.0


def arch_d(u, v):
    """Signed distance (approximate beyond the corners, exact enough for AA) to the outer silhouette."""
    if v < ARCH_SPRING:
        d1 = math.hypot(u - (ARCH_R - ARCH_W), v - ARCH_SPRING) - ARCH_R   # left wall circle
        d2 = math.hypot(u + (ARCH_R - ARCH_W), v - ARCH_SPRING) - ARCH_R   # right wall circle
        d = max(d1, d2)
    else:
        d = abs(u) - ARCH_W
    return max(d, v - ARCH_BASE)


def keyhole_d(u, v):
    """Keyhole: round bow plus a flared slot, smooth-unioned."""
    cx, cy, r = 0.0, PLATE_V - 10.0, 15.5
    dc = math.hypot(u - cx, v - cy) - r
    # trapezoid slot from v=cy+3 (half width 7) to v=cy+42 (half width 15)
    t = clamp((v - (cy + 3.0)) / 39.0, -0.25, 1.1)
    hw = 7.0 + 8.0 * t
    ds = max(abs(u) - hw, (cy + 3.0) - v, v - (cy + 42.0))
    k = 5.0
    h = clamp(0.5 + 0.5 * (ds - dc) / k)
    return ds * (1 - h) + dc * h - k * h * (1 - h)


def lit(u, v):
    """0 (shadow side) .. 1 (lit side): light from the upper left."""
    return clamp(0.5 - (u * 0.55 + v * 0.8) / 330.0)


# ---------------------------------------------------------------------------------------------- layers


def fg_pixel(u, v, s):
    px = Px()
    d = arch_d(u, v)
    if d * s > 1.5:
        return px.straight()
    # --- frame: bevelled gilded band with a bright rim on the lit side and a dark inner bevel
    L = lit(u, v)
    e = -d  # depth inside the silhouette
    band = mix(EDGE_BRASS, KEY_GOLD, L ** 0.9)
    band = mix(band, scale(EMBER_DEEP, 0.9), smooth(8.0, 14.0, e) * 0.7)          # inner bevel darkens
    band = mix(band, mix(EMBER_BRIGHT, HOT, 0.55), (1.0 - smooth(0.0, 3.2, e)) * (0.35 + 0.65 * L))  # rim light
    # voussoir joints: short dark ticks across the band every 22 degrees around the arch
    if v < ARCH_SPRING and 1.0 < e < FRAME - 1.0:
        ang = math.atan2(v - ARCH_SPRING, u)
        seg = (ang * 180.0 / math.pi) / 20.0
        j = abs(seg - round(seg)) * 20.0 * math.pi / 180.0 * math.hypot(u, v - ARCH_SPRING)
        band = mix(band, scale(EMBER_DEEP, 0.45), (1.0 - smooth(0.6, 1.6, j)) * 0.8)
    px.over(band, cover(d, s))
    # --- shadow gap
    px.over(VOID, cover(d + FRAME, s))
    # --- door
    dd = d + FRAME + GAP
    cd = cover(dd, s)
    if cd > 0.0:
        px.over(door_color(u, v, -dd), cd)
        keyhole_plate(px, u, v, s)
    return px.straight()


def door_color(u, v, depth):
    # plank layout
    k = math.floor((u + 73.0) / 36.5)
    sx = (u + 73.0) - k * 36.5
    ds = min(sx, 36.5 - sx)                      # distance to nearest seam
    base = mix(IRON_RAISED, IRON, 0.25 + 0.5 * _h2(k, 7, 3))
    grain = vnoise(u * 0.55 + k * 17.0, v * 0.035, 11)
    base = scale(base, 0.62 + 0.34 * grain)
    # seam: dark groove + faint lit lip on its right side
    base = mix(base, VOID, 1.0 - smooth(0.5, 2.0, ds))
    base = mix(base, IRON_HOVER, (smooth(1.8, 2.4, sx) * (1.0 - smooth(2.4, 3.6, sx))) * 0.7)
    # iron straps
    for sv, hh in ((-66.0, 8.5), (73.0, 8.0)):
        t = abs(v - sv)
        if t < hh + 1.0:
            strap = mix(IRON_HOVER, EDGE, 0.55)
            strap = mix(strap, scale(EDGE_BRASS, 0.85), (1.0 - smooth(0.0, 2.2, (v - (sv - hh)))) * 0.75)   # top edge catch-light
            strap = mix(strap, VOID, (1.0 - smooth(0.0, 2.2, ((sv + hh) - v))) * 0.7)                      # bottom shadow
            base = mix(base, strap, 1.0 - smooth(hh - 0.6, hh + 0.6, t))
            for ru in (-52.0, -17.0, 17.0, 52.0):                                                           # rivets
                rd = math.hypot(u - ru, v - sv) - 3.6
                if rd < 1.0:
                    rc = mix(EDGE_BRASS, KEY_GOLD, clamp(0.5 - ((u - ru) * 0.6 + (v - sv) * 0.8) / 8.0))
                    base = mix(base, rc, 1.0 - smooth(-0.5, 0.5, rd))
    # inner shadow from the frame
    base = scale(base, 0.5 + 0.5 * smooth(0.0, 30.0, depth))
    # ember light from the keyhole
    dist = math.hypot(u, (v - PLATE_V) * 0.9)
    g = math.exp(-(dist / 70.0) ** 2)
    base = add(base, mix(EMBER, EMBER_BRIGHT, 0.3), 0.50 * g * (0.55 + 0.45 * smooth(0.0, 40.0, depth)))
    return (clamp(base[0]), clamp(base[1]), clamp(base[2]))


def keyhole_plate(px, u, v, s):
    pr = math.hypot(u, v - PLATE_V)
    if pr > PLATE_R + 40.0:
        return
    # brass escutcheon ring and a dark recess
    L = lit(u * 2.0, (v - PLATE_V) * 2.0)
    ring = mix(EMBER_DEEP, KEY_GOLD, L)
    px.over(ring, cover(pr - PLATE_R, s))
    px.over(mix(VOID, IRON_DEEP, 0.4), cover(pr - (PLATE_R - 3.5), s))
    # warm bloom from the keyhole, drawn over the recess and the planks
    dk = keyhole_d(u, v)
    bloom = 0.62 * math.exp(-max(dk, 0.0) / 11.0) * (1.0 - smooth(PLATE_R + 14.0, PLATE_R + 38.0, pr))
    px.over(EMBER, bloom * 0.55)
    # the keyhole itself: white-hot core fading to ember at the rim
    kcol = mix(EMBER_BRIGHT, HOT, smooth(1.0, 11.0, -dk))
    px.over(kcol, cover(dk, s))


def mono_pixel(u, v, s):
    px = Px()
    d = arch_d(u, v)
    if d * s > 1.5:
        return px.straight()
    W = (1.0, 1.0, 1.0)
    gap = 6.0   # wider than the colour layer's shadow gap so the frame reads as a ring at 48 px
    a = cover(d, s) * (1.0 - cover(d + FRAME, s))                  # frame ring
    a = a + cover(d + FRAME + gap, s) * (1.0 - a)                   # door mass
    # planks, escutcheon ring and keyhole are cut out of the mass
    pr = math.hypot(u, v - PLATE_V)
    if pr > PLATE_R + 3.0:
        for sx in (-36.5, 0.0, 36.5):
            a *= 1.0 - cover(abs(u - sx) - 1.8, s)
    a *= 1.0 - cover(abs(pr - (PLATE_R - 1.0)) - 2.6, s)
    a *= 1.0 - cover(keyhole_d(u, v), s)
    px.over(W, clamp(a))
    return px.straight()


# stone wall behind the door (adaptive background): subtle, charred, warm where the door leaks light
BLOCK_H = 72.0
BLOCK_W = 124.0
GLOW_C = (0.0, -6.0)


def bg_pixel(u, v, s):
    row = math.floor((v + 36.0) / BLOCK_H)
    off = (BLOCK_W * 0.5) if (row & 1) else 0.0
    bx = (u + off + 1000.0)
    col = math.floor(bx / BLOCK_W)
    fx = bx - col * BLOCK_W
    fy = (v + 36.0) - row * BLOCK_H
    tone = 0.80 + 0.40 * _h2(col, row, 5)
    base = scale(mix(IRON_RAISED, IRON, 0.55), tone)
    base = scale(base, 0.80 + 0.42 * vnoise(u * 0.045, v * 0.045, 2))      # large soot blotches
    base = scale(base, 0.90 + 0.20 * vnoise(u * 0.30, v * 0.30, 9))        # fine grain
    # mortar (dark) with a lit lip along the block tops
    md = min(fx, BLOCK_W - fx, fy, BLOCK_H - fy)
    mortar = 1.0 - smooth(1.6, 3.2, md)
    base = mix(base, scale(VOID, 1.0), mortar * 0.92)
    base = mix(base, scale(EDGE, 0.8), (smooth(3.2, 4.2, fy) * (1.0 - smooth(4.2, 6.0, fy))) * 0.25)
    # warm glow behind the door, vignette to the corners
    r = math.hypot(u - GLOW_C[0], v - GLOW_C[1])
    glow = math.exp(-(r / 165.0) ** 2)
    base = add(base, EMBER_DEEP, 0.42 * glow)
    base = scale(base, 1.0 - 0.6 * smooth(110.0, 330.0, r))
    # soft drop shadow of the door on the wall: dark halo hugging the frame separates gold from stone
    ds = arch_d(u, v - 5.0)
    base = scale(base, 1.0 - 0.8 * (1.0 - smooth(0.0, 26.0, ds)))
    return (clamp(base[0]), clamp(base[1]), clamp(base[2]), 1.0)


def render(fn, size, s, progress=None):
    """Evaluate fn(u, v, s) -> straight RGBA floats on a size x size canvas; s output px per design unit."""
    out = bytearray(size * size * 4)
    half = size / 2.0
    inv = 1.0 / s
    for j in range(size):
        v = (j + 0.5 - half) * inv
        row = j * size * 4
        for i in range(size):
            u = (i + 0.5 - half) * inv
            r, g, b, a = fn(u, v, s)
            o = row + i * 4
            out[o] = int(r * 255.0 + 0.5)
            out[o + 1] = int(g * 255.0 + 0.5)
            out[o + 2] = int(b * 255.0 + 0.5)
            out[o + 3] = int(a * 255.0 + 0.5)
        if progress and j % 72 == 0:
            progress(j, size)
    return out


def over_images(bg, fg):
    """Composite straight-alpha fg over an opaque bg (same size)."""
    out = bytearray(len(bg))
    for o in range(0, len(bg), 4):
        a = fg[o + 3]
        if a == 0:
            out[o:o + 4] = bg[o:o + 4]
        else:
            k = a / 255.0
            for c in range(3):
                out[o + c] = int(fg[o + c] * k + bg[o + c] * (1.0 - k) + 0.5)
            out[o + 3] = 255
    return out


def legacy_pixel(bg_fn, fg_fn, s):
    """Pre-adaptive icon: the same scene on a rounded-square tile with transparent corners (192 px)."""
    radius = 44.0
    half = LEGACY / 2.0

    def fn(u, v, ss):
        # u, v here are in design units; the tile edge is half a tile (96 px / s units) away
        hu, hv = half / ss, half / ss
        rr = radius / ss
        qx, qy = abs(u) - (hu - rr), abs(v) - (hv - rr)
        dm = math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - rr
        cm = cover(dm, ss)
        if cm <= 0.0:
            return (0.0, 0.0, 0.0, 0.0)
        br, bgc, bb, _ = bg_fn(u, v, ss)
        fr, fgc, fb, fa = fg_fn(u, v, ss)
        r = fr * fa + br * (1 - fa)
        g = fgc * fa + bgc * (1 - fa)
        b = fb * fa + bb * (1 - fa)
        return (r, g, b, cm)
    return fn


LEGACY_SCALE = 0.62   # 288 safe px -> 179 px of the 192 tile (art nearly fills the tile)


def build_all(progress=None):
    """Returns {filename: (w, h, rgba)} for the four files."""
    fg = render(fg_pixel, CANVAS, 1.0, progress)
    bg = render(bg_pixel, CANVAS, 1.0, progress)
    mono = render(mono_pixel, CANVAS, 1.0, progress)
    main = render(legacy_pixel(bg_pixel, fg_pixel, LEGACY_SCALE), LEGACY, LEGACY_SCALE, progress)
    return {
        "main_192.png": (LEGACY, LEGACY, main),
        "adaptive_fg_432.png": (CANVAS, CANVAS, fg),
        "adaptive_bg_432.png": (CANVAS, CANVAS, bg),
        "adaptive_mono_432.png": (CANVAS, CANVAS, mono),
    }


def build_legacy():
    return render(legacy_pixel(bg_pixel, fg_pixel, LEGACY_SCALE), LEGACY, LEGACY_SCALE)


# ---------------------------------------------------------------------------------------------- preview sheet


def _premul(rgba, w, h):
    ch = [[0.0] * (w * h) for _ in range(4)]
    for i in range(w * h):
        a = rgba[i * 4 + 3] / 255.0
        ch[0][i] = rgba[i * 4] / 255.0 * a
        ch[1][i] = rgba[i * 4 + 1] / 255.0 * a
        ch[2][i] = rgba[i * 4 + 2] / 255.0 * a
        ch[3][i] = a
    return ch


def _weights(src0, src1, n):
    step = (src1 - src0) / n
    res = []
    for i in range(n):
        a, b = src0 + i * step, src0 + (i + 1) * step
        lo, hi = int(math.floor(a)), int(math.ceil(b))
        ws = []
        for k in range(lo, hi):
            w = min(b, k + 1) - max(a, k)
            if w > 1e-9:
                ws.append((k, w / step))
        res.append(ws)
    return res


def resample(ch, w, h, x0, x1, y0, y1, n):
    """Area-average the source rectangle [x0,x1)x[y0,y1) down to n x n (premultiplied channels)."""
    wx, wy = _weights(x0, x1, n), _weights(y0, y1, n)
    out = [[0.0] * (n * n) for _ in range(4)]
    for c in range(4):
        src = ch[c]
        tmp = {}
        for oy in range(n):
            for k, wgt in wy[oy]:
                if k not in tmp:
                    row = src[k * w:(k + 1) * w]
                    tmp[k] = [sum(row[kx] * wk for kx, wk in wx[ox]) for ox in range(n)]
        for oy in range(n):
            acc = [0.0] * n
            for k, wgt in wy[oy]:
                t = tmp[k]
                for ox in range(n):
                    acc[ox] += t[ox] * wgt
            out[c][oy * n:(oy + 1) * n] = acc
    return out


MASKS = ("circle", "squircle", "rounded square", "teardrop")


def mask_cov(name, x, y, n):
    """Coverage of a launcher mask of diameter n at pixel centre (x, y)."""
    px, py = x - n / 2.0, y - n / 2.0
    r = n / 2.0
    if name == "circle":
        d = math.hypot(px, py) - r
    elif name == "squircle":
        d = (abs(px / r) ** 4 + abs(py / r) ** 4) ** 0.25 * r - r
    elif name == "rounded square":
        cr = n * 0.22
        qx, qy = abs(px) - (r - cr), abs(py) - (r - cr)
        d = math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - cr
    else:  # teardrop: circle with one nearly square corner (top right)
        d = math.hypot(px, py) - r
        cr = n * 0.08
        qx, qy = abs(px - r / 2.0) - (r / 2.0 - cr), abs(py + r / 2.0) - (r / 2.0 - cr)
        dbox = math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - cr
        d = min(d, dbox)
    return clamp(0.5 - d)


def preview_sheet(path, files=None):
    """Contact sheet: every mask x {192, 96, 72, 48, 36} on a dark and a light wallpaper, plus the legacy tile and the
    themed (monochrome) icon. Cells left to right: 192, 96, 72, 48, 36 px mask diameter."""
    files = files or {n: read_png(os.path.join(OUT_DIR, n)) for n in
                      ("main_192.png", "adaptive_fg_432.png", "adaptive_bg_432.png", "adaptive_mono_432.png")}
    w, h, fgp = files["adaptive_fg_432.png"]
    bgp = files["adaptive_bg_432.png"][2]
    comp = over_images(bgp, fgp)
    monop = files["adaptive_mono_432.png"][2]
    lw, lh, legp = files["main_192.png"]
    comp_ch = _premul(comp, w, h)
    mono_ch = _premul(monop, w, h)
    leg_ch = _premul(legp, lw, lh)
    sizes = (192, 96, 72, 48, 36)
    gut = 14
    half_w = sum(sizes) + gut * (len(sizes) + 1)
    rows = list(MASKS) + ["legacy", "themed"]
    row_h = 192 + gut
    W, H = half_w * 2, gut + row_h * len(rows)
    sheet = bytearray(W * H * 4)
    walls = ((0.13, 0.15, 0.20), (0.90, 0.88, 0.84))
    for half in (0, 1):
        for y in range(H):
            for x in range(half * half_w, (half + 1) * half_w):
                o = (y * W + x) * 4
                sheet[o:o + 3] = bytes(int(c * 255) for c in walls[half])
                sheet[o + 3] = 255
    cache = {}
    for ri, rname in enumerate(rows):
        for half in (0, 1):
            x = half * half_w + gut
            for n in sizes:
                key = (rname, n)
                if rname in MASKS:
                    if ("c", n) not in cache:
                        cache[("c", n)] = resample(comp_ch, w, h, 72.0, 360.0, 72.0, 360.0, n)
                    src = cache[("c", n)]
                elif rname == "legacy":
                    if ("l", n) not in cache:
                        cache[("l", n)] = resample(leg_ch, lw, lh, 0.0, float(lw), 0.0, float(lh), n)
                    src = cache[("l", n)]
                else:
                    if ("m", n) not in cache:
                        cache[("m", n)] = resample(mono_ch, w, h, 72.0, 360.0, 72.0, 360.0, n)
                    src = cache[("m", n)]
                y0 = gut + ri * row_h + (192 - n) // 2
                for yy in range(n):
                    for xx in range(n):
                        i = yy * n + xx
                        if rname in MASKS:
                            m = mask_cov(rname, xx + 0.5, yy + 0.5, n)
                            col = (src[0][i], src[1][i], src[2][i])
                            a = m * src[3][i]
                            col = tuple(c * m for c in col)
                        elif rname == "legacy":
                            col = (src[0][i], src[1][i], src[2][i])
                            a = src[3][i]
                        else:
                            m = mask_cov("circle", xx + 0.5, yy + 0.5, n)
                            plate = (0.93, 0.85, 0.66) if half == 1 else (0.42, 0.33, 0.18)
                            ink = (0.30, 0.17, 0.02) if half == 1 else (1.0, 0.86, 0.55)
                            ma = src[3][i]
                            col = tuple((ink[c] * ma + plate[c] * (1 - ma)) * m for c in range(3))
                            a = m
                            col = tuple(col)
                        o = ((y0 + yy) * W + x + xx) * 4
                        # col is premultiplied by a for the mask cases; blend onto the wallpaper
                        for c in range(3):
                            bgv = sheet[o + c] / 255.0
                            v = col[c] + bgv * (1.0 - a)
                            sheet[o + c] = int(clamp(v) * 255 + 0.5)
                x += n + gut
    write_png(path, W, H, sheet)
    return W, H


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=OUT_DIR, help="output directory (default android_icons/)")
    ap.add_argument("--preview", metavar="PNG", help="also write the launcher-mask contact sheet")
    ap.add_argument("--preview-only", metavar="PNG", help="only write the contact sheet from the committed icons")
    args = ap.parse_args(argv)
    if args.preview_only:
        print("preview %dx%d -> %s" % (*preview_sheet(args.preview_only), args.preview_only))
        return 0

    def prog(j, n):
        sys.stdout.write(".")
        sys.stdout.flush()

    files = build_all(prog)
    print()
    for name, (w, h, data) in files.items():
        write_png(os.path.join(args.out, name), w, h, data)
        print("wrote %s (%dx%d)" % (os.path.join(args.out, name), w, h))
    if args.preview:
        print("preview %dx%d -> %s" % (*preview_sheet(args.preview, files), args.preview))
    return 0


if __name__ == "__main__":
    sys.exit(main())
