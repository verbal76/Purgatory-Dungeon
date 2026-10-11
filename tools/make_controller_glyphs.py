#!/usr/bin/env python3
"""Original controller button glyphs (license-free) -> assets/ui/glyphs/*.png.

Pure standard library (zlib + struct), deterministic: a re-run reproduces identical files. 128x128 RGBA, 4x4 supersampled.
Run from the repo root:
    python3 tools/make_controller_glyphs.py
then `godot --headless --import` and commit the PNGs together with their .import files.

Set: face buttons a b x y, sticks l3 r3 (stick-click), view, menu, the four d-pad directions, and the shoulder/trigger
buttons in two label sets: Xbox (lb rb lt rt) and Steam Deck / Steam Controller (l1 r1 l2 r2). Letters are drawn from a small
stroke font defined below, so no font file is involved and the art is entirely ours.
"""
import math
import os
import struct
import zlib

SIZE = 128
SS = 4   # supersampling per axis
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "ui", "glyphs")

INK = (30, 26, 28)
RIM = (214, 204, 186)
BONE = (236, 228, 212)
COLORS = {"a": (112, 190, 120), "b": (226, 100, 92), "x": (96, 158, 226), "y": (228, 196, 84)}

# Stroke font on a 0..1 x 0..1.4 box (x right, y down); each glyph is a list of polylines.
FONT = {
    "A": [[(0, 1.4), (0.5, 0), (1, 1.4)], [(0.18, 0.95), (0.82, 0.95)]],
    "B": [[(0, 0), (0, 1.4)], [(0, 0), (0.62, 0), (0.92, 0.2), (0.92, 0.5), (0.62, 0.68), (0, 0.68)],
          [(0.62, 0.68), (0.98, 0.9), (0.98, 1.2), (0.66, 1.4), (0, 1.4)]],
    "X": [[(0, 0), (1, 1.4)], [(1, 0), (0, 1.4)]],
    "Y": [[(0, 0), (0.5, 0.72), (1, 0)], [(0.5, 0.72), (0.5, 1.4)]],
    "L": [[(0, 0), (0, 1.4), (0.85, 1.4)]],
    "R": [[(0, 0), (0, 1.4)], [(0, 0), (0.64, 0), (0.94, 0.2), (0.94, 0.55), (0.64, 0.72), (0, 0.72)], [(0.5, 0.72), (1, 1.4)]],
    "T": [[(0, 0), (1, 0)], [(0.5, 0), (0.5, 1.4)]],
    "1": [[(0.15, 0.3), (0.55, 0), (0.55, 1.4)], [(0.15, 1.4), (0.95, 1.4)]],
    "2": [[(0.05, 0.3), (0.3, 0), (0.75, 0), (1, 0.28), (0.95, 0.62), (0.05, 1.4), (1, 1.4)]],
    "3": [[(0.05, 0.1), (0.3, 0), (0.75, 0), (0.98, 0.22), (0.98, 0.5), (0.7, 0.68), (0.35, 0.68)],
          [(0.7, 0.68), (1, 0.9), (1, 1.2), (0.75, 1.4), (0.3, 1.4), (0.02, 1.3)]],
}


def seg_dist(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = 0.0 if dx == 0 and dy == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    cx, cy = ax + t * dx, ay + t * dy
    return math.hypot(px - cx, py - cy)


class Canvas:
    def __init__(self):
        self.px = [[(0.0, 0.0, 0.0, 0.0) for _ in range(SIZE * SS)] for _ in range(SIZE * SS)]   # r,g,b,a (a 0/1, hi-res)

    def put(self, x, y, c):
        self.px[y][x] = (c[0], c[1], c[2], 1.0)

    def shape(self, fn, color, bounds):
        x0, y0, x1, y1 = [int(v * SS) for v in bounds]
        for y in range(max(0, y0), min(SIZE * SS, y1)):
            for x in range(max(0, x0), min(SIZE * SS, x1)):
                if fn((x + 0.5) / SS, (y + 0.5) / SS):
                    self.put(x, y, color)

    def circle(self, cx, cy, r, color):
        self.shape(lambda x, y: (x - cx) ** 2 + (y - cy) ** 2 <= r * r, color, (cx - r - 1, cy - r - 1, cx + r + 1, cy + r + 1))

    def ring(self, cx, cy, r0, r1, color):
        self.shape(lambda x, y: r0 * r0 <= (x - cx) ** 2 + (y - cy) ** 2 <= r1 * r1, color, (cx - r1 - 1, cy - r1 - 1, cx + r1 + 1, cy + r1 + 1))

    def rrect(self, x0, y0, x1, y1, r, color):
        def inside(x, y):
            qx = max(x0 + r - x, 0, x - (x1 - r))
            qy = max(y0 + r - y, 0, y - (y1 - r))
            return qx * qx + qy * qy <= r * r and x0 <= x <= x1 and y0 <= y <= y1
        self.shape(inside, color, (x0 - 1, y0 - 1, x1 + 1, y1 + 1))

    def stroke(self, pts, width, color):
        hw = width / 2.0
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        def near(x, y):
            for i in range(len(pts) - 1):
                if seg_dist(x, y, pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1]) <= hw:
                    return True
            return False
        self.shape(near, color, (min(xs) - hw - 1, min(ys) - hw - 1, max(xs) + hw + 1, max(ys) + hw + 1))

    def text(self, s, cx, cy, height, width, color):
        """Centered stroke text; `height` is the cap height in output pixels."""
        scale = height / 1.4
        glyph_w = 1.0 * scale
        gap = 0.28 * scale
        total = len(s) * glyph_w + (len(s) - 1) * gap
        x = cx - total / 2.0
        for ch in s:
            for line in FONT[ch]:
                self.stroke([(x + px * scale, cy - height / 2.0 + py * scale) for px, py in line], width, color)
            x += glyph_w + gap

    def to_rgba(self):
        rows = []
        for y in range(SIZE):
            row = bytearray()
            for x in range(SIZE):
                r = g = b = a = 0.0
                for sy in range(SS):
                    for sx in range(SS):
                        p = self.px[y * SS + sy][x * SS + sx]
                        r += p[0] * p[3]
                        g += p[1] * p[3]
                        b += p[2] * p[3]
                        a += p[3]
                n = SS * SS
                if a > 0:
                    row += bytes((int(r / a + 0.5), int(g / a + 0.5), int(b / a + 0.5), int(255 * a / n + 0.5)))
                else:
                    row += b"\x00\x00\x00\x00"
            rows.append(bytes(row))
        return rows


def write_png(path, rows):
    raw = b"".join(b"\x00" + r for r in rows)
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


C = SIZE / 2.0


def face(letter):
    cv = Canvas()
    cv.circle(C, C, 60, RIM)
    cv.circle(C, C, 54, INK)
    cv.text(letter.upper(), C, C, 50, 9, COLORS[letter])
    return cv


def pill(label, trigger):
    cv = Canvas()
    if trigger:   # triggers are drawn taller and narrower than bumpers
        cv.rrect(12, 8, 116, 120, 26, RIM)
        cv.rrect(19, 15, 109, 113, 20, INK)
    else:
        cv.rrect(2, 22, 126, 106, 30, RIM)
        cv.rrect(9, 29, 119, 99, 24, INK)
    cv.text(label, C, 64, 44 if len(label) > 1 else 40, 9, BONE)
    return cv


def stick_click(side):
    cv = Canvas()
    cv.circle(C, C, 60, RIM)
    cv.circle(C, C, 54, INK)
    cv.text(side + "3", C, C, 34, 7, BONE)
    return cv


def menu():
    cv = Canvas()
    cv.circle(C, C, 60, RIM)
    cv.circle(C, C, 54, INK)
    for dy in (-18, 0, 18):
        cv.stroke([(34, C + dy), (94, C + dy)], 9, BONE)
    return cv


def view():
    cv = Canvas()
    cv.circle(C, C, 60, RIM)
    cv.circle(C, C, 54, INK)
    cv.rrect(30, 40, 78, 82, 6, BONE)
    cv.rrect(36, 46, 72, 76, 3, INK)
    cv.rrect(50, 52, 98, 94, 6, BONE)
    cv.rrect(56, 58, 92, 88, 3, INK)
    return cv


def dpad(direction):
    cv = Canvas()
    arm = 36
    def cross(x, y):
        return (abs(x - C) <= 20 and abs(y - C) <= arm) or (abs(y - C) <= 20 and abs(x - C) <= arm)
    cv.shape(cross, RIM, (C - arm - 2, C - arm - 2, C + arm + 2, C + arm + 2))
    def inner(x, y):
        return (abs(x - C) <= 15 and abs(y - C) <= arm - 5) or (abs(y - C) <= 15 and abs(x - C) <= arm - 5)
    cv.shape(inner, INK, (C - arm - 2, C - arm - 2, C + arm + 2, C + arm + 2))
    dx, dy = {"up": (0, -1), "down": (0, 1), "left": (-1, 0), "right": (1, 0)}[direction]
    # a filled arrow-head triangle pointing `direction`
    px, py = -dy, dx   # perpendicular
    a = (C + dx * 34, C + dy * 34)
    b = (C + dx * 14 + px * 13, C + dy * 14 + py * 13)
    c = (C + dx * 14 - px * 13, C + dy * 14 - py * 13)
    def tri(x, y):
        d1 = (x - b[0]) * (a[1] - b[1]) - (a[0] - b[0]) * (y - b[1])
        d2 = (x - c[0]) * (b[1] - c[1]) - (b[0] - c[0]) * (y - c[1])
        d3 = (x - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (y - a[1])
        neg = d1 < 0 or d2 < 0 or d3 < 0
        pos = d1 > 0 or d2 > 0 or d3 > 0
        return not (neg and pos)
    cv.shape(tri, BONE, (C - 40, C - 40, C + 40, C + 40))
    return cv


GLYPHS = {}
for _l in "abxy":
    GLYPHS[_l] = (lambda l=_l: face(l))
GLYPHS.update({
    "l3": lambda: stick_click("L"), "r3": lambda: stick_click("R"), "menu": menu, "view": view,
    "dpad_up": lambda: dpad("up"), "dpad_down": lambda: dpad("down"), "dpad_left": lambda: dpad("left"), "dpad_right": lambda: dpad("right"),
    "lb": lambda: pill("LB", False), "rb": lambda: pill("RB", False), "lt": lambda: pill("LT", True), "rt": lambda: pill("RT", True),
    "l1": lambda: pill("L1", False), "r1": lambda: pill("R1", False), "l2": lambda: pill("L2", True), "r2": lambda: pill("R2", True),
})


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, fn in sorted(GLYPHS.items()):
        write_png(os.path.join(OUT, name + ".png"), fn().to_rgba())
        print("wrote", name)


if __name__ == "__main__":
    main()
