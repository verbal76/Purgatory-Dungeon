#!/usr/bin/env python3
"""Android launcher icon checks (standard library only, no Godot, a few seconds).

  python3 tests/test_android_icons.py [-v]

Asserts what no launcher can be trusted to forgive (docs/ANDROID_ICON.md): the four files export_presets.cfg points at exist
with the sizes/format Godot's exporter requires; the adaptive foreground and monochrome layers keep their artwork inside the
66 dp safe circle (a launcher mask never crops it); the monochrome layer is one colour plus alpha; the background layer is
fully opaque; the legacy icon is a 192 px tile; the committed legacy PNG is exactly what tools/make_android_icon.py renders.
"""
import math
import os
import re
import struct
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.dont_write_bytecode = True
import make_android_icon as icon  # noqa: E402

ICON_DIR = os.path.join(ROOT, "android_icons")
PRESET_KEYS = {
    "launcher_icons/main_192x192": ("main_192.png", 192),
    "launcher_icons/adaptive_foreground_432x432": ("adaptive_fg_432.png", 432),
    "launcher_icons/adaptive_background_432x432": ("adaptive_bg_432.png", 432),
    "launcher_icons/adaptive_monochrome_432x432": ("adaptive_mono_432.png", 432),
}
_cache = {}


def load(name):
    if name not in _cache:
        _cache[name] = icon.read_png(os.path.join(ICON_DIR, name))
    return _cache[name]


def lum(r, g, b):
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0


class PresetWiring(unittest.TestCase):
    def test_export_presets_reference_the_icon_files(self):
        with open(os.path.join(ROOT, "export_presets.cfg"), encoding="utf-8") as f:
            cfg = f.read()
        for key, (name, _) in PRESET_KEYS.items():
            m = re.search(r"^" + re.escape(key) + r'="([^"]*)"', cfg, re.M)
            self.assertIsNotNone(m, key + " missing from export_presets.cfg")
            self.assertEqual(m.group(1), "res://android_icons/" + name)

    def test_files_exist_with_import_sidecars(self):
        for name, _ in PRESET_KEYS.values():
            self.assertTrue(os.path.isfile(os.path.join(ICON_DIR, name)), name)
            self.assertTrue(os.path.isfile(os.path.join(ICON_DIR, name + ".import")), name + ".import (editor import metadata)")

    def test_png_header_is_8bit_rgba(self):
        for name, size in PRESET_KEYS.values():
            with open(os.path.join(ICON_DIR, name), "rb") as f:
                head = f.read(33)
            self.assertEqual(head[:8], b"\x89PNG\r\n\x1a\n", name)
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", head[16:29])
            self.assertEqual((w, h), (size, size), name + " size")
            self.assertEqual((depth, ctype, interlace), (8, 6, 0), name + " must be 8-bit RGBA, not interlaced")


class SafeZone(unittest.TestCase):
    """Android masks the 108 dp layers to at most the central 72 dp circle: radius 144 px of the 432 px canvas."""

    def _inside_fraction(self, name, min_alpha=1):
        w, h, d = load(name)
        c = w / 2.0
        total = inside = 0
        far = 0.0
        for y in range(h):
            for x in range(w):
                if d[(y * w + x) * 4 + 3] >= min_alpha:
                    total += 1
                    r = math.hypot(x + 0.5 - c, y + 0.5 - c)
                    far = max(far, r)
                    if r <= icon.SAFE_RADIUS:
                        inside += 1
        return total, inside, far

    def test_foreground_artwork_inside_safe_circle(self):
        total, inside, far = self._inside_fraction("adaptive_fg_432.png")
        self.assertGreater(total, 432 * 432 * 0.12, "foreground is (nearly) empty")
        self.assertGreaterEqual(inside / total, 0.99, "foreground artwork leaves the 66 dp safe circle")
        self.assertLessEqual(far, icon.SAFE_RADIUS + 3, "foreground reaches %.1f px from centre" % far)

    def test_monochrome_artwork_inside_safe_circle(self):
        total, inside, far = self._inside_fraction("adaptive_mono_432.png")
        self.assertGreater(total, 432 * 432 * 0.10, "monochrome is (nearly) empty")
        self.assertGreaterEqual(inside / total, 0.99)
        self.assertLessEqual(far, icon.SAFE_RADIUS + 3)

    def test_foreground_has_real_transparency(self):
        w, h, d = load("adaptive_fg_432.png")
        clear = sum(1 for i in range(3, len(d), 4) if d[i] == 0)
        self.assertGreater(clear / (w * h), 0.35, "foreground must be a cut-out, not a full-bleed picture")
        for x, y in ((0, 0), (431, 0), (0, 431), (431, 431), (216, 4)):
            self.assertEqual(d[(y * w + x) * 4 + 3], 0)


class Layers(unittest.TestCase):
    def test_monochrome_is_single_colour_alpha(self):
        w, h, d = load("adaptive_mono_432.png")
        colours = set()
        partial = solid = 0
        for i in range(0, len(d), 4):
            a = d[i + 3]
            if a:
                colours.add((d[i], d[i + 1], d[i + 2]))
                if a == 255:
                    solid += 1
                else:
                    partial += 1
        self.assertEqual(colours, {(255, 255, 255)}, "themed layer must be one colour; the launcher tints it")
        self.assertGreater(solid, 432 * 432 * 0.08)
        self.assertGreater(partial, 0, "expected anti-aliased edges")
        # the keyhole is a hole, not ink
        cx, cy = 216, int(216 + icon.PLATE_V - 10)
        self.assertEqual(d[(cy * w + cx) * 4 + 3], 0, "keyhole must be cut out of the monochrome silhouette")

    def test_monochrome_matches_foreground_silhouette(self):
        w, h, fg = load("adaptive_fg_432.png")
        mono = load("adaptive_mono_432.png")[2]
        strong = bad = 0
        for i in range(3, len(mono), 4):
            if mono[i] > 128:
                strong += 1
                if fg[i] < 128:
                    bad += 1
        self.assertLess(bad / strong, 0.005, "themed silhouette must sit inside the coloured one")

    def test_background_is_fully_opaque_dark_and_not_flat(self):
        w, h, d = load("adaptive_bg_432.png")
        alphas = {d[i] for i in range(3, len(d), 4)}
        self.assertEqual(alphas, {255}, "background layer must have no transparency")
        ls = [lum(d[i], d[i + 1], d[i + 2]) for i in range(0, len(d), 16)]
        mean = sum(ls) / len(ls)
        sd = math.sqrt(sum((x - mean) ** 2 for x in ls) / len(ls))
        self.assertLess(mean, 0.25, "background should stay dark so the gold door pops")
        self.assertGreater(sd, 0.02, "background should carry some stone texture")

    def test_legacy_icon_is_tile_with_transparent_corners(self):
        w, h, d = load("main_192.png")
        self.assertEqual((w, h), (192, 192))
        self.assertEqual(d[3], 0, "corner pixel should be transparent (rounded tile)")
        self.assertEqual(d[(96 * 192 + 96) * 4 + 3], 255)
        self.assertEqual(d[(96 * 192 + 2) * 4 + 3], 255, "tile edge midpoints are filled")

    def test_door_reads_at_small_size(self):
        """Keyhole glow is much brighter than the door around it and the frame much brighter than the wall behind it."""
        w, h, fg = load("adaptive_fg_432.png")
        bg = load("adaptive_bg_432.png")[2]
        comp = icon.over_images(bg, fg)

        def at(x, y):
            o = (y * w + x) * 4
            return lum(comp[o], comp[o + 1], comp[o + 2])

        cy = int(216 + icon.PLATE_V - 10)
        keyhole = at(216, cy)
        door = at(216 - 58, cy - 30)
        self.assertGreater(keyhole, 0.6)
        self.assertGreater(keyhole - door, 0.35, "keyhole must stand out from the planks")
        frame = at(216 - int(icon.ARCH_W) + 6, 216 + 40)       # left wall of the frame
        wall = at(216 - int(icon.ARCH_W) - 28, 216 + 40)
        self.assertGreater(frame - wall, 0.2, "gold frame must stand out from the wall")


class Reproducible(unittest.TestCase):
    def test_legacy_png_matches_generator(self):
        w, h, d = load("main_192.png")
        fresh = icon.build_legacy()
        self.assertEqual(bytes(d), bytes(fresh), "android_icons/main_192.png is stale: rerun tools/make_android_icon.py")

    def test_generator_does_not_touch_studio_logo(self):
        with open(os.path.join(ROOT, "tools", "make_android_icon.py"), encoding="utf-8") as f:
            src = f.read()
        code = "\n".join(l for l in src.splitlines() if not l.lstrip().startswith("#"))
        # the only mention allowed is the docstring that says the logo is NOT used
        body = code.split('"""', 2)[2] if code.count('"""') >= 2 else code
        self.assertNotIn("Hot_Attic", body)
        self.assertNotIn("logo", body.lower())


class TestDesktopIcon(unittest.TestCase):
    """The window/desktop icon set (app_icon/) is the same artwork, wired from project.godot, and reproducible."""

    def test_project_points_at_the_new_icons(self):
        text = open(os.path.join(ROOT, "project.godot"), encoding="utf-8").read()
        for key, path in (("config/icon", "res://app_icon/PurgatoryDungeon.png"),
                          ("config/windows_native_icon", "res://app_icon/PurgatoryDungeon.ico"),
                          ("config/macos_native_icon", "res://app_icon/PurgatoryDungeon.icns")):
            self.assertIn('%s="%s"' % (key, path), text)
            self.assertTrue(os.path.isfile(os.path.join(ROOT, path[len("res://"):])), path)
        self.assertNotIn("VPP_logo_from_source_256", text, "the old placeholder icon must not be referenced any more")

    def test_png_ico_icns_are_valid(self):
        import struct
        d = os.path.join(ROOT, "app_icon")
        png = open(os.path.join(d, "PurgatoryDungeon.png"), "rb").read()
        self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
        w, h, depth, ctype = struct.unpack(">IIBB", png[16:26])
        self.assertEqual((w, h, depth, ctype), (256, 256, 8, 6))
        ico = open(os.path.join(d, "PurgatoryDungeon.ico"), "rb").read()
        reserved, kind, count = struct.unpack("<HHH", ico[:6])
        self.assertEqual((reserved, kind), (0, 1))
        self.assertEqual(count, 6)
        sizes = []
        for i in range(count):
            ww, hh, _c, _r, _pl, bpp, nbytes, off = struct.unpack("<BBBBHHII", ico[6 + 16 * i:22 + 16 * i])
            sizes.append(ww or 256)
            self.assertEqual(ico[off:off + 8], b"\x89PNG\r\n\x1a\n", "PNG-compressed entry")
            self.assertEqual(bpp, 32)
            self.assertLessEqual(off + nbytes, len(ico))
        self.assertEqual(sorted(sizes), [16, 32, 48, 64, 128, 256])
        icns = open(os.path.join(d, "PurgatoryDungeon.icns"), "rb").read()
        self.assertEqual(icns[:4], b"icns")
        self.assertEqual(struct.unpack(">I", icns[4:8])[0], len(icns))
        for tag in (b"ic07", b"ic08", b"ic09"):
            self.assertIn(tag, icns)

    def test_generator_reproduces_the_committed_png(self):
        import tempfile
        sys.path.insert(0, os.path.join(ROOT, "tools"))
        import make_desktop_icon as M
        base = M.A.render(M.tile_fn(M.BASE), M.BASE, M.A.LEGACY_SCALE * M.BASE / M.A.LEGACY)
        fresh = M.png_bytes(256, 256, M.down(base, 256))
        self.assertEqual(fresh, open(os.path.join(ROOT, "app_icon", "PurgatoryDungeon.png"), "rb").read())


if __name__ == "__main__":
    unittest.main(verbosity=2 if "-v" in sys.argv else 1, argv=[a for a in sys.argv if a != "-v"])
