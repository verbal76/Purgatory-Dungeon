#!/usr/bin/env python3
"""Tests for the OTA build tooling in tools/ota/ (docs/OTA.md). Standard library + the openssl CLI only.

  python3 tests/test_ota_tools.py [-v] [TestClass[.test_name]]

Covers: path rules and classify.py (against a temporary git repository), the independent PCK reader (against the
real Godot 4.6 sample packs in tools/ota/fixtures, plus a pack writer proven byte-identical to Godot's output),
make_bundle / channel / verify_bundle round trips with tamper cases, native_check, keys.sh (local OTA_KEY_DIR mode,
races, secret handling) and static checks of .github/workflows/ota.yml.
Tests that need the Godot 4.6 binary ($GODOT or /opt/godot/...) print a NOTICE and skip when it is absent
(or when OTA_TOOLS_NO_GODOT=1 is set, to run only the fast tests).
"""
import base64
import concurrent.futures
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OTA = os.path.join(ROOT, "tools", "ota")
FIX = os.path.join(OTA, "fixtures")
sys.path.insert(0, OTA)
sys.dont_write_bytecode = True
warnings.simplefilter("ignore", ResourceWarning)

import otalib  # noqa: E402
import pck as pcklib  # noqa: E402

BASE40 = "1" * 40
SRC40 = "2" * 40
OTHER40 = "3" * 40
ENGINE = "4.6.stable.official.89cea1439"
T0 = "2026-10-05T19:00:00Z"


def notice(msg):
    print(f"NOTICE: {msg}", flush=True)


def godot_bin():
    if os.environ.get("OTA_TOOLS_NO_GODOT"):
        return None
    for c in (os.environ.get("GODOT", ""), "/opt/godot/Godot_v4.6-stable_linux.x86_64", "godot"):
        c = (shutil.which(c) or c) if c else ""
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            try:
                v = subprocess.run([c, "--version"], capture_output=True, text=True, timeout=60).stdout.strip()
            except (OSError, subprocess.SubprocessError):
                continue
            if v.startswith("4.6."):
                return c
    return None


def run(args, cwd=None, env=None, input_text=None):
    e = dict(os.environ)
    e.update(env or {})
    return subprocess.run(args, cwd=cwd, env=e, capture_output=True, text=True, input=input_text)


def tool(name, *args, cwd=None, env=None):
    return run([sys.executable, os.path.join(OTA, name)] + [str(a) for a in args], cwd=cwd, env=env)


def out(p):
    return p.stdout + p.stderr


def genkey(path, bits=3072):
    subprocess.run(["openssl", "genrsa", "-out", path, str(bits)], check=True, capture_output=True)
    pub = path + ".pub"
    subprocess.run(["openssl", "pkey", "-in", path, "-pubout", "-out", pub], check=True, capture_output=True)
    return pub


def make_pck(entries, engine=(4, 6, 0)):
    """Writes a PCK the way Godot 4.6 does (verified byte-identical against real packs below).
    entries: [(path, data_bytes, flags)]; a removal entry (flags & 2) has no data."""
    body = bytearray()
    ents = []
    for path, data, flags in entries:
        off = len(body)
        if flags & pcklib.FILE_REMOVAL:
            size, md5 = 0, b"\0" * 16
        else:
            size, md5 = len(data), hashlib.md5(data).digest()
            body += data
            body += b"\0" * (-len(body) % 16)
        ents.append((path, off, size, md5, flags))
    file_base = 0x70
    hdr = struct.pack("<4sIIIIIQQ", b"GDPC", 3, engine[0], engine[1], engine[2], pcklib.PACK_REL_FILEBASE,
                      file_base, file_base + len(body))
    hdr += b"\0" * (file_base - len(hdr))
    d = bytearray(struct.pack("<I", len(ents)))
    for path, off, size, md5, flags in ents:
        raw = path.encode()
        raw += b"\0" * (-len(raw) % 4)
        d += struct.pack("<I", len(raw)) + raw + struct.pack("<QQ", off, size) + md5 + struct.pack("<I", flags)
    return bytes(hdr + body + d)


def rb(path):
    with open(path, "rb") as f:
        return f.read()


def rt(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def jload(path):
    return json.loads(rt(path))


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode())
    return path


def pck_of(path, files):
    """files: {path: bytes | None (removal)} -> writes a pack."""
    return write(path, make_pck([(p, d, pcklib.FILE_REMOVAL if d is None else 0) for p, d in sorted(files.items())]))


class TmpCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ota-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def p(self, *parts):
        return os.path.join(self.tmp, *parts)


# ------------------------------------------------------------------------------------------------ rules

class TestRules(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rules = otalib.load_rules()

    def cat(self, path):
        return otalib.classify_source(self.rules, path)[0]

    def test_shape_and_stability(self):
        r = self.rules
        for sect in ("protected", "guarded", "not_shipped"):
            for key in ("exact", "prefixes", "suffixes"):
                lst = r[sect][key]
                self.assertEqual(lst, sorted(set(lst)), f"{sect}.{key} must be sorted and unique (stable for the client check)")
        self.assertEqual(r["max_payload_bytes"], 512 * 1024 * 1024)
        for p in r["protected"]["prefixes"] + r["not_shipped"]["prefixes"]:
            self.assertTrue(p.endswith("/"), p)

    def test_documented_categories(self):
        apk = ["project.godot", "project.binary", "export_presets.cfg", "android/build/gradle.properties",
               "addons/x/bin/libx.so", "addons/x/x.gdextension", "addons/x/x.dll", "addons/x/x.dylib",
               "scripts/ota/ota_client.gd", "ota_trust.pem", "ota_channel.json", "build_info.json", "VERSION"]
        for p in apk:
            self.assertEqual(self.cat(p), "apk_required", p)
        for p in ("scripts/save_manager.gd", "scripts/storage_paths.gd", "scripts/SettingsManager.gd"):
            self.assertEqual(self.cat(p), "guarded", p)
        for p in ("tools/ota/classify.py", "tests/test_ota_tools.py", "docs/OTA.md", "README.md", "CLAUDE.md",
                  "archive/old.gd", "production/x.png", ".github/workflows/ota.yml", "scripts/ota/README.md"):
            self.assertEqual(self.cat(p), "not_shipped", p)
        for p in ("scripts/enemy_manager.gd", "data/buffs.json", "scenes/MainMenu.tscn", "addons/AllSkyFree/x.tres",
                  "autoloads/GameClock.gd", "Music & background images/a.ogg", "scripts/otaish.gd", "characters/brute/b.tscn"):
            self.assertEqual(self.cat(p), "safe", p)

    def test_pack_paths(self):
        v = lambda p: otalib.pack_violation(self.rules, p)[0]  # noqa: E731
        for p in ("project.binary", "scripts/ota/a.gdc", "scripts/ota/a.gd.remap", "ota_trust.pem", "build_info.json",
                  "res://project.binary", "addons/q/q.so", "android/x"):
            self.assertEqual(v(p), "protected", p)
        for p in ("scripts/save_manager.gdc", "scripts/save_manager.gd.remap", "scripts/storage_paths.gdc"):
            self.assertEqual(v(p), "guarded", p)
        for p in ("../x", "/abs", "user://x", "a//b", "a/./b", "a\\b", "C:/x", ""):
            self.assertEqual(v(p), "escape", p)
        for p in ("data/new.json", ".godot/imported/x.ctex", "scripts/enemy_manager.gdc", "scenes/MainMenu.tscn.remap"):
            self.assertEqual(v(p), "", p)


# ------------------------------------------------------------------------------------------------ classify

class TestClassify(TmpCase):
    def sh(self, *args):
        env = {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        r = run(["git", "-C", self.repo] + list(args), env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip()

    def commit(self, msg="c"):
        self.sh("add", "-A")
        self.sh("-c", "commit.gpgsign=false", "commit", "-q", "-m", msg)
        return self.sh("rev-parse", "HEAD")

    def setUp(self):
        super().setUp()
        self.repo = self.p("repo")
        os.makedirs(self.repo)
        self.sh("init", "-q")
        for f, c in (("project.godot", "a"), ("VERSION", "5\n"), ("scripts/enemy.gd", "1"), ("scripts/ota/c.gd", "1"),
                     ("scripts/save_manager.gd", "1"), ("data/buffs.json", "{}"), ("docs/a.md", "x"), ("README.md", "x"),
                     ("scripts/old_name.gd", "old content that is long enough to be detected as a rename " * 5)):
            write(os.path.join(self.repo, f), c)
        self.base = self.commit("base")

    def classify(self, *args):
        return tool("classify.py", *args, cwd=self.repo)

    def test_safe_change(self):
        write(os.path.join(self.repo, "scripts/enemy.gd"), "2")
        write(os.path.join(self.repo, "data/new.json"), "{}")
        self.commit()
        r = self.classify(self.base, "HEAD")
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("RESULT: OTA-safe", r.stdout)
        self.assertIn("scripts/enemy.gd", r.stdout)

    def test_nothing_shipped(self):
        write(os.path.join(self.repo, "docs/a.md"), "changed")
        write(os.path.join(self.repo, "tests/t.gd"), "x")
        write(os.path.join(self.repo, "tools/t.py"), "x")
        self.commit()
        r = self.classify(self.base)
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("nothing that ships changed", r.stdout)

    def test_apk_required_lists_paths_and_rules(self):
        write(os.path.join(self.repo, "project.godot"), "b")
        write(os.path.join(self.repo, "scripts/enemy.gd"), "2")
        self.commit()
        r = self.classify(self.base)
        self.assertEqual(r.returncode, 10, out(r))
        self.assertIn("project.godot", r.stdout)
        self.assertIn("exact project.godot", r.stdout)
        self.assertIn("APK REQUIRED", r.stdout)

    def test_apk_beats_guarded_and_accept_does_not_override(self):
        write(os.path.join(self.repo, "VERSION"), "6\n")
        write(os.path.join(self.repo, "scripts/save_manager.gd"), "2")
        self.commit()
        self.assertEqual(self.classify(self.base).returncode, 10)
        self.assertEqual(self.classify(self.base, "HEAD", "--accept-guarded", "reason").returncode, 10)

    def test_guarded(self):
        write(os.path.join(self.repo, "scripts/save_manager.gd"), "2")
        self.commit()
        r = self.classify(self.base)
        self.assertEqual(r.returncode, 11, out(r))
        self.assertIn("scripts/save_manager.gd", r.stdout)
        r = self.classify(self.base, "HEAD", "--accept-guarded", "stays readable")
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("stays readable", r.stdout)
        self.assertEqual(self.classify(self.base, "HEAD", "--accept-guarded", "  ").returncode, 11, "blank reason must not count")

    def test_delete_of_protected_file(self):
        os.remove(os.path.join(self.repo, "scripts/ota/c.gd"))
        self.commit()
        r = self.classify(self.base)
        self.assertEqual(r.returncode, 10, out(r))
        self.assertIn("scripts/ota/c.gd", r.stdout)

    def test_rename_out_of_protected_dir_counts_both_sides(self):
        self.sh("mv", "scripts/ota/c.gd", "scripts/c.gd")
        self.commit()
        r = self.classify(self.base, "--json")
        self.assertEqual(r.returncode, 10, out(r))
        data = json.loads(r.stdout)
        paths = {e["path"]: e for e in data["entries"]}
        self.assertEqual(paths["scripts/ota/c.gd"]["category"], "apk_required")
        self.assertEqual(paths["scripts/c.gd"]["category"], "safe")
        self.assertEqual(paths["scripts/c.gd"]["old_path"], "scripts/ota/c.gd")

    def test_safe_rename_and_delete(self):
        self.sh("mv", "scripts/old_name.gd", "scripts/new_name.gd")
        os.remove(os.path.join(self.repo, "data/buffs.json"))
        self.commit()
        r = self.classify(self.base, "--json")
        self.assertEqual(r.returncode, 0, out(r))
        data = json.loads(r.stdout)
        self.assertEqual(data["result"], "ota_safe")
        self.assertEqual({e["path"] for e in data["entries"]}, {"scripts/old_name.gd", "scripts/new_name.gd", "data/buffs.json"})

    def test_json_output_and_bad_ref(self):
        r = self.classify(self.base, "--json")
        data = json.loads(r.stdout)
        self.assertEqual((data["exit_code"], data["result"], data["entries"]), (0, "nothing_shipped_changed", []))
        r = self.classify("no-such-ref")
        self.assertEqual(r.returncode, 2)
        self.assertIn("cannot resolve", r.stderr)


# ------------------------------------------------------------------------------------------------ pck reader

SAMPLE_PATCH_EXPECT = [
    ("data/new.json", "add", 12, "1456a95e6c00d384815f9f732a74f4f4"),
    ("data/probe.json", "replace", 20, "8a470adb5c541eb2d5c18f6b84b438cc"),
    ("later.gdc", "replace", 304, "571e95135432bddbc3386d92a900ab6d"),
]


class TestPck(TmpCase):
    def fx(self, name):
        return os.path.join(FIX, name)

    def test_sample_patch_against_sample_base(self):
        patch, base = pcklib.read_pck(self.fx("sample_patch.pck")), pcklib.read_pck(self.fx("sample_base.pck"))
        self.assertEqual((patch.format, patch.engine, patch.flags), (3, (4, 6, 0), pcklib.PACK_REL_FILEBASE))
        got = [(p, op, patch.by_path[p].size, patch.by_path[p].md5) for p, op in pcklib.ops(patch, base)]
        self.assertEqual(got, SAMPLE_PATCH_EXPECT)
        self.assertEqual(pcklib.verify_entries(patch), [])
        self.assertEqual(pcklib.verify_entries(base), [])
        self.assertEqual(pcklib.read_entry(patch, patch.by_path["data/new.json"]), b'{"added":1}\n')
        self.assertEqual(len(base.entries), 12)
        self.assertIn("project.binary", base.by_path)
        self.assertIn("data/probe.json", base.by_path)
        self.assertNotIn("data/new.json", base.by_path)

    def test_samples_outside_the_repo_are_the_same_files(self):
        for name in ("sample_base.pck", "sample_patch.pck"):
            ext = os.path.join("/tmp/claude-0", name)
            if os.path.isfile(ext):
                self.assertEqual(rb(ext), rb(self.fx(name)), name)

    def test_removal_sample(self):
        patch, base = pcklib.read_pck(self.fx("remove_patch.pck")), pcklib.read_pck(self.fx("remove_base.pck"))
        self.assertEqual(pcklib.ops(patch, base), [("data/new.json", "add"), ("data/probe.json", "remove")])
        rm = patch.by_path["data/probe.json"]
        self.assertTrue(rm.removal)
        self.assertEqual((rm.size, rm.md5, rm.flags), (0, "0" * 32, 2))
        self.assertEqual(pcklib.verify_entries(patch), [])
        # a removal of a path the base does not hold is a patch for another base
        other_base = pcklib.read_pck(pck_of(self.p("other_base.pck"), {"a": b"1"}))
        with self.assertRaises(pcklib.PckError):
            pcklib.ops(patch, other_base)

    def test_delta_sample_is_flagged(self):
        patch = pcklib.read_pck(self.fx("delta_patch.pck"))
        e = patch.by_path["data/probe.json"]
        self.assertTrue(e.delta and not e.removal)
        self.assertEqual(pcklib.verify_entries(patch), [], "the md5 of a delta entry covers the stored delta bytes")
        self.assertEqual(pcklib.ops(patch, pcklib.read_pck(self.fx("delta_base.pck"))), [("data/probe.json", "replace")])

    def test_writer_is_byte_identical_to_godot(self):
        """The pack writer used by these tests reproduces three real Godot 4.6 patch packs bit for bit."""
        for name in ("sample_patch.pck", "remove_patch.pck", "delta_patch.pck"):
            pck = pcklib.read_pck(self.fx(name))
            raw = rb(self.fx(name))
            entries = sorted(pck.entries, key=lambda e: e.offset)
            rebuilt = make_pck([(e.path, pcklib.read_entry(pck, e), e.flags) for e in entries])
            self.assertEqual(rebuilt, raw, name)

    def test_cli_list_and_verify(self):
        r = tool("pck.py", "list", self.fx("sample_patch.pck"), "--base", self.fx("sample_base.pck"))
        self.assertEqual(r.returncode, 0, out(r))
        for path, op, size, md5 in SAMPLE_PATCH_EXPECT:
            self.assertRegex(r.stdout, rf"{op}\s+{path}\s+{size}\s+{md5}")
        j = json.loads(tool("pck.py", "list", self.fx("remove_patch.pck"), "--base", self.fx("remove_base.pck"), "--json").stdout)
        self.assertEqual([(f["path"], f["op"]) for f in j["files"]], [("data/new.json", "add"), ("data/probe.json", "remove")])
        self.assertEqual(tool("pck.py", "verify", self.fx("sample_base.pck")).returncode, 0)

    def test_content_corruption_is_detected(self):
        raw = bytearray(rb(self.fx("sample_patch.pck")))
        raw[0x70] ^= 0xFF
        bad = write(self.p("bad.pck"), bytes(raw))
        r = tool("pck.py", "verify", bad)
        self.assertEqual(r.returncode, 1)
        self.assertIn("data/new.json", r.stdout)

    def test_structural_damage_is_rejected(self):
        raw = rb(self.fx("sample_patch.pck"))

        def mutate(off, fmt, val):
            b = bytearray(raw)
            struct.pack_into(fmt, b, off, val)
            return write(self.p("m.pck"), bytes(b))

        cases = {
            "bad magic": write(self.p("a.pck"), b"XXXX" + raw[4:]),
            "format 2": mutate(4, "<I", 2),
            "unknown pack flags": mutate(20, "<I", 0x10),
            "encrypted directory": mutate(20, "<I", 3),
            "directory outside": mutate(32, "<Q", len(raw) + 10),
            "truncated": write(self.p("t.pck"), raw[:0x1e0]),
            "tiny": write(self.p("tiny.pck"), raw[:20]),
            "path not padded": mutate(0x1d4, "<I", 15),
            "data outside the file": mutate(0x1f0, "<Q", 10 ** 9),
            "unknown file flags": mutate(0x208, "<I", 0x80),
        }
        for label, path in cases.items():
            with self.assertRaises(pcklib.PckError, msg=label):
                pcklib.read_pck(path)
        with self.assertRaises(pcklib.PckError):
            pcklib.read_pck(write(self.p("dup.pck"), make_pck([("a", b"1", 0), ("a", b"2", 0)])))
        self.assertEqual(tool("pck.py", "list", cases["bad magic"]).returncode, 1)

    def test_live_godot_export_matches_reader(self):
        g = godot_bin()
        if not g:
            notice("Godot 4.6 not found ($GODOT): skipping the live export/patch comparison (fixtures were still checked)")
            self.skipTest("no godot")
        proj = make_probe_project(self.p("proj"))
        export_pack(g, proj, "base.pck")
        write(os.path.join(proj, "data", "probe.json"), '{"probe":"changed"}\n')
        write(os.path.join(proj, "data", "added.json"), '{"a":1}\n')
        os.remove(os.path.join(proj, "data", "gone.json"))
        export_pack(g, proj, "patch.pck", patch="base.pck")
        patch, base = pcklib.read_pck(os.path.join(proj, "patch.pck")), pcklib.read_pck(os.path.join(proj, "base.pck"))
        self.assertEqual(pcklib.verify_entries(patch), [])
        ops = dict(pcklib.ops(patch, base))
        self.assertEqual(ops["data/probe.json"], "replace")
        self.assertEqual(ops["data/added.json"], "add")
        self.assertEqual(ops["data/gone.json"], "remove")
        self.assertEqual(pcklib.read_entry(patch, patch.by_path["data/added.json"]), b'{"a":1}\n')
        self.assertNotIn("project.binary", ops)


PROBE_PRESET = """[preset.0]
name="Windows Desktop"
platform="Windows Desktop"
runnable=true
export_filter="all_resources"
include_filter="build_info.json, ota_trust.pem"
exclude_filter=""
export_path="out/x.exe"
patch_delta_include_filters="*"
patch_delta_exclude_filters=""
script_export_mode=2
[preset.0.options]
binary_format/embed_pck=false
binary_format/architecture="x86_64"
"""


def make_probe_project(path):
    write(os.path.join(path, "project.godot"), 'config_version=5\n[application]\nconfig/name="OtaProbe"\n')
    write(os.path.join(path, "export_presets.cfg"), PROBE_PRESET)
    write(os.path.join(path, "VERSION"), "5\n")
    write(os.path.join(path, "data", "probe.json"), '{"probe":"base"}\n')
    write(os.path.join(path, "data", "gone.json"), '{"gone":true}\n')
    write(os.path.join(path, "boot.gd"), "extends Node\nfunc _ready():\n\tpass\n")
    g = godot_bin()
    subprocess.run([g, "--headless", "--path", path, "--import"], capture_output=True, timeout=300)
    return path


def export_pack(g, proj, name, patch=None, preset="Windows Desktop"):
    cmd = [g, "--headless", "--path", proj]
    cmd += ["--export-patch", preset, os.path.join(proj, name), "--patches", os.path.join(proj, patch)] if patch \
        else ["--export-pack", preset, os.path.join(proj, name)]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if not os.path.isfile(os.path.join(proj, name)):
        raise AssertionError("godot export failed:\n" + r.stdout[-800:] + r.stderr[-800:])


# ------------------------------------------------------------------------------------------------ bundles

class BundleBase(TmpCase):
    @classmethod
    def setUpClass(cls):
        cls._keys = tempfile.mkdtemp(prefix="ota-keys-")
        cls.key = os.path.join(cls._keys, "a.pem")
        cls.pub = genkey(cls.key)
        cls.key_b = os.path.join(cls._keys, "b.pem")
        cls.pub_b = genkey(cls.key_b)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._keys, True)

    BASE_FILES = {"scripts/a.gdc": b"A1", "scripts/b.gdc": b"B1", "data/c.json": b"C1", "project.binary": b"PB",
                  "ota_trust.pem": b"T", "scripts/save_manager.gdc": b"S1"}

    def packs(self, patch_files=None, name=""):
        base = pck_of(self.p(name + "base.pck"), self.BASE_FILES)
        patch = pck_of(self.p(name + "patch.pck"), patch_files if patch_files is not None else
                       {"scripts/a.gdc": b"A2", "data/d.json": b"D1", "scripts/b.gdc": None})
        return base, patch

    def bundle_args(self, patch, base, out_dir, seq=1, key=None, **over):
        a = {"platform": "windows", "native_version": 5, "base_commit": BASE40, "engine": ENGINE, "seq": seq,
             "source_commit": SRC40, "payload": patch, "base_pck": base, "out": out_dir, "key": key or self.key,
             "created_utc": T0}
        a.update(over)
        args = []
        for k, v in a.items():
            if v is not None:
                args += ["--" + k.replace("_", "-"), str(v)]
        return args

    def make(self, patch, base, out_dir, **kw):
        return tool("make_bundle.py", *self.bundle_args(patch, base, out_dir, **kw))

    def build(self, out_dir=None, seq=1, patch_files=None, **kw):
        out_dir = out_dir or self.p("chan")
        base, patch = self.packs(patch_files, name=f"s{seq}-")
        r = self.make(patch, base, out_dir, seq=seq, **kw)
        self.assertEqual(r.returncode, 0, out(r))
        self.base_pck = base
        return r.stdout.strip()

    def verify(self, path, *extra, pub=None):
        return tool("verify_bundle.py", path, "--pubkey", pub or self.pub, *extra)

    def good_expect(self):
        return ["--native-version", "5", "--platform", "windows", "--base-commit", BASE40, "--engine", ENGINE]

    def copy_bundle(self, src, name="tampered"):
        dst = self.p(name)
        shutil.copytree(src, dst)
        return dst

    def forge(self, dest, manifest_edit=None, files=None, base_files=None, key=None, patch_files=None):
        """A bundle NOT produced by make_bundle: any manifest content, signed with a real key, so the verifier's own
        checks (not the builder's refusals) are what is under test."""
        base, patch = self.packs(patch_files)
        os.makedirs(dest)
        m = {"format": 1, "product": "purgatory-dungeon", "platform": "windows", "native_version": 5,
             "base_commit": BASE40, "engine": ENGINE, "ota_api": 1, "payload_seq": 1,
             "label": "Purgatory Dungeon v5 update 1", "source_commit": SRC40, "created_utc": T0,
             "payload": {"file": "payload.pck", "size": os.path.getsize(patch), "sha256": otalib.sha256_file(patch)},
             "files": files if files is not None else [{"path": "data/d.json", "op": "add"}, {"path": "scripts/a.gdc", "op": "replace"},
                                                       {"path": "scripts/b.gdc", "op": "remove"}]}
        if manifest_edit:
            manifest_edit(m)
        shutil.copyfile(patch, os.path.join(dest, "payload.pck"))
        write(os.path.join(dest, "manifest.json"), otalib.canonical_json(m))
        otalib.sign_to_file(key or self.key, os.path.join(dest, "manifest.json"), os.path.join(dest, "manifest.sig"))
        return dest


class TestBundleRoundTrip(BundleBase):
    def test_round_trip_and_format(self):
        d = self.build()
        self.assertTrue(d.endswith("v5/windows/update-1"))
        self.assertEqual(sorted(os.listdir(d)), ["manifest.json", "manifest.sig", "payload.pck"])
        raw = rb(os.path.join(d, "manifest.json"))
        m = json.loads(raw)
        self.assertEqual(raw, (json.dumps(m, sort_keys=True, indent=2) + "\n").encode(), "deterministic JSON")
        self.assertEqual(m["format"], 1)
        self.assertEqual(m["product"], "purgatory-dungeon")
        self.assertEqual((m["platform"], m["native_version"], m["base_commit"], m["engine"], m["ota_api"], m["payload_seq"]),
                         ("windows", 5, BASE40, ENGINE, 1, 1))
        self.assertEqual(m["label"], "Purgatory Dungeon v5 update 1")
        self.assertEqual((m["source_commit"], m["created_utc"]), (SRC40, T0))
        self.assertEqual(m["files"], [{"op": "add", "path": "data/d.json"}, {"op": "replace", "path": "scripts/a.gdc"},
                                      {"op": "remove", "path": "scripts/b.gdc"}])
        payload = os.path.join(d, "payload.pck")
        self.assertEqual(m["payload"], {"file": "payload.pck", "size": os.path.getsize(payload), "sha256": otalib.sha256_file(payload)})
        # the signature, checked with the openssl CLI directly (not through otalib)
        sig = base64.b64decode(rb(os.path.join(d, "manifest.sig")), validate=True)
        write(self.p("sig.bin"), sig)
        r = run(["openssl", "dgst", "-sha256", "-verify", self.pub, "-signature", self.p("sig.bin"), os.path.join(d, "manifest.json")])
        self.assertEqual(r.returncode, 0, out(r))
        self.assertEqual(len(sig), 3072 // 8)
        # and it is PKCS#1 v1.5 with SHA-256: the recovered block is exactly the DigestInfo of sha256(manifest.json)
        r = subprocess.run(["openssl", "pkeyutl", "-verifyrecover", "-pubin", "-inkey", self.pub, "-in", self.p("sig.bin"),
                            "-pkeyopt", "rsa_padding_mode:pkcs1"], capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, bytes.fromhex("3031300d060960864801650304020105000420") + hashlib.sha256(raw).digest())

    def test_same_inputs_same_bytes(self):
        a = self.build(self.p("o1"))
        base, patch = self.packs(name="s1-")
        self.assertEqual(self.make(patch, base, self.p("o2")).returncode, 0)
        for f in ("manifest.json", "manifest.sig", "payload.pck"):
            self.assertEqual(rb(os.path.join(a, f)), rb(self.p("o2", "v5", "windows", "update-1", f)), f)

    def test_verify_update_and_channel(self):
        d = self.build()
        r = self.verify(d, *self.good_expect(), "--base-pck", self.base_pck, "--accept-guarded")
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("BUNDLE OK", r.stdout)
        self.assertIn("ops checked against the base pack", r.stdout)
        chan = self.p("chan")
        r = tool("channel.py", "merge", "--out", chan, "--key", self.key, "--generated-utc", T0)
        self.assertEqual(r.returncode, 0, out(r))
        ch = json.loads(rt(os.path.join(chan, "channel.json")))
        self.assertEqual(ch["generation"], 1)
        self.assertEqual(ch["updates"], [{"native_version": 5, "platform": "windows", "base_commit": BASE40, "seq": 1,
                                          "manifest": "v5/windows/update-1/manifest.json",
                                          "signature": "v5/windows/update-1/manifest.sig",
                                          "payload": "v5/windows/update-1/payload.pck"}])
        self.assertEqual(ch["revoked"], [])
        raw = rb(os.path.join(chan, "channel.json"))
        self.assertEqual(raw, (json.dumps(ch, sort_keys=True, indent=2) + "\n").encode())
        r = self.verify(chan, *self.good_expect(), "--base-pck", f"windows={self.base_pck}")
        self.assertEqual(r.returncode, 0, out(r))

    def test_real_godot_samples_round_trip(self):
        out_dir = self.p("real")
        r = self.make(os.path.join(FIX, "sample_patch.pck"), os.path.join(FIX, "sample_base.pck"), out_dir)
        self.assertEqual(r.returncode, 0, out(r))
        m = jload(os.path.join(out_dir, "v5", "windows", "update-1", "manifest.json"))
        self.assertEqual([(f["path"], f["op"]) for f in m["files"]],
                         [("data/new.json", "add"), ("data/probe.json", "replace"), ("later.gdc", "replace")])
        r = self.verify(r.stdout.strip(), *self.good_expect(), "--base-pck", os.path.join(FIX, "sample_base.pck"))
        self.assertEqual(r.returncode, 0, out(r))
        out2 = self.p("real2")
        r = self.make(os.path.join(FIX, "remove_patch.pck"), os.path.join(FIX, "remove_base.pck"), out2)
        self.assertEqual(r.returncode, 0, out(r))
        m = jload(os.path.join(out2, "v5", "windows", "update-1", "manifest.json"))
        self.assertEqual([(f["path"], f["op"]) for f in m["files"]], [("data/new.json", "add"), ("data/probe.json", "remove")])

    def test_android_platform(self):
        base, patch = self.packs()
        r = self.make(patch, base, self.p("an"), platform="android")
        self.assertEqual(r.returncode, 0, out(r))
        self.assertTrue(r.stdout.strip().endswith("v5/android/update-1"))
        self.assertEqual(self.verify(r.stdout.strip(), "--platform", "android").returncode, 0)
        self.assertEqual(self.verify(r.stdout.strip(), "--platform", "windows").returncode, 1)


class TestBundleRefusals(BundleBase):
    def refused(self, files, needle, **kw):
        base, patch = self.packs(files)
        out_dir = self.p("refuse-" + needle.replace(" ", "_")[:20])
        r = self.make(patch, base, out_dir, **kw)
        self.assertEqual(r.returncode, 1, out(r))
        self.assertIn(needle, r.stderr)
        self.assertFalse(os.path.exists(os.path.join(out_dir, "v5")), "nothing may be written when refusing")
        return r

    def test_protected_paths_in_the_pack(self):
        for path in ("project.binary", "scripts/ota/client.gdc", "scripts/ota/client.gd.remap", "ota_trust.pem",
                     "build_info.json", "addons/x/lib.so", "addons/x/x.gdextension", "export_presets.cfg"):
            self.refused({path: b"x"}, "protected path")

    def test_removing_a_protected_path_is_refused_too(self):
        self.refused({"project.binary": None}, "protected path")

    def test_escaping_paths(self):
        for path in ("../evil.gdc", "/abs/x", "user://x", "a/../b"):
            self.refused({path: b"x"}, "escape path")

    def test_guarded_needs_a_reason(self):
        self.refused({"scripts/save_manager.gdc": b"S2"}, "--accept-guarded")
        base, patch = self.packs({"scripts/save_manager.gdc": b"S2"})
        r = self.make(patch, base, self.p("g"), accept_guarded="save format unchanged")
        self.assertEqual(r.returncode, 0, out(r))
        bad = self.verify(r.stdout.strip())
        self.assertEqual(bad.returncode, 1)
        self.assertIn("guarded", bad.stdout)
        self.assertEqual(self.verify(r.stdout.strip(), "--accept-guarded").returncode, 0)

    def test_delta_and_empty_payloads(self):
        r = self.make(os.path.join(FIX, "delta_patch.pck"), os.path.join(FIX, "delta_base.pck"), self.p("d"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("delta", r.stderr)
        base, _ = self.packs()
        empty = write(self.p("empty.pck"), make_pck([]))
        r = self.make(empty, base, self.p("e"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("no files", r.stderr)

    def test_removal_of_a_file_the_base_lacks(self):
        self.refused({"data/never_existed.json": None}, "base pack does not contain")

    def test_corrupt_payload_is_refused(self):
        base, patch = self.packs()
        raw = bytearray(rb(patch))
        raw[0x70] ^= 1
        write(patch, bytes(raw))
        r = self.make(patch, base, self.p("c"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("inconsistent", r.stderr)

    def test_oversized_payload(self):
        base, _ = self.packs()
        big = self.p("big.pck")
        with open(big, "wb") as f:
            f.truncate(512 * 1024 * 1024 + 1)
        r = self.make(big, base, self.p("o"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("limit", r.stderr)
        self.assertFalse(os.path.exists(self.p("o", "v5")))

    def test_bad_inputs(self):
        base, patch = self.packs()
        for over, needle in ((dict(base_commit="abc"), "base commit"), (dict(source_commit="G" * 40), "source commit"),
                             (dict(platform="linux"), "platform"), (dict(seq=0), "seq"), (dict(native_version=0), "native version"),
                             (dict(engine="x"), "engine"), (dict(created_utc="yesterday"), "created-utc"),
                             (dict(engine="3.5.stable.official.abcdef"), "exported by Godot")):
            r = self.make(patch, base, self.p("bad"), **over)
            self.assertEqual(r.returncode, 1, over)
            self.assertIn(needle, r.stderr, over)

    def test_weak_or_wrong_keys(self):
        base, patch = self.packs()
        weak = self.p("weak.pem")
        genkey(weak, 2048)
        r = self.make(patch, base, self.p("w"), key=weak)
        self.assertEqual(r.returncode, 1)
        self.assertIn("RSA-2048", r.stderr)
        ec = self.p("ec.pem")
        subprocess.run(["openssl", "ecparam", "-genkey", "-name", "prime256v1", "-noout", "-out", ec], check=True, capture_output=True)
        r = self.make(patch, base, self.p("w2"), key=ec)
        self.assertEqual(r.returncode, 1)
        self.assertIn("RSA", r.stderr)
        r = self.make(patch, base, self.p("w3"), key=self.p("missing.pem"))
        self.assertEqual(r.returncode, 1)

    def test_duplicate_and_lower_seq(self):
        chan = self.p("chan")
        self.build(chan, seq=2)
        base, patch = self.packs(name="s2-")
        for seq in (2, 1):
            r = self.make(patch, base, chan, seq=seq)
            self.assertEqual(r.returncode, 1, f"seq {seq}")
            self.assertIn("not higher", r.stderr)
        r = self.make(patch, base, chan, seq=3)
        self.assertEqual(r.returncode, 0, out(r))
        self.assertTrue(os.path.isdir(os.path.join(chan, "v5", "windows", "update-2")), "update-2 must survive untouched")

    def test_seq_check_also_uses_channel_json(self):
        chan = self.p("chan")
        self.build(chan, seq=1)
        self.assertEqual(tool("channel.py", "merge", "--out", chan, "--key", self.key).returncode, 0)
        shutil.rmtree(os.path.join(chan, "v5", "windows", "update-1"))     # folder gone, index still lists it
        base, patch = self.packs(name="s1-")
        r = self.make(patch, base, chan, seq=1)
        self.assertEqual(r.returncode, 1)
        self.assertIn("not higher", r.stderr)

    def test_other_base_commit_in_the_same_native_build(self):
        chan = self.p("chan")
        self.build(chan, seq=1)
        base, patch = self.packs(name="s1-")
        r = self.make(patch, base, chan, seq=2, base_commit=OTHER40)
        self.assertEqual(r.returncode, 1)
        self.assertIn("another base commit", r.stderr)


class TestVerifyTampering(BundleBase):
    def setUp(self):
        super().setUp()
        self.d = self.build()
        self.expect = self.good_expect()

    def assertRejected(self, path, needle, *extra, pub=None):
        r = self.verify(path, *extra, pub=pub)
        self.assertEqual(r.returncode, 1, out(r))
        self.assertIn("BUNDLE REJECTED", r.stdout)
        self.assertIn(needle, r.stdout, out(r))

    def test_baseline_is_clean(self):
        self.assertEqual(self.verify(self.d, *self.expect, "--base-pck", self.base_pck).returncode, 0)

    def test_flipped_payload_byte(self):
        t = self.copy_bundle(self.d)
        pp = os.path.join(t, "payload.pck")
        raw = bytearray(rb(pp))
        raw[0x71] ^= 0x01
        write(pp, bytes(raw))
        self.assertRejected(t, "sha256 does not match")

    def test_truncated_and_extended_payload(self):
        for how in ("truncate", "extend"):
            t = self.copy_bundle(self.d, how)
            pp = os.path.join(t, "payload.pck")
            raw = rb(pp)
            write(pp, raw[:-10] if how == "truncate" else raw + b"\0" * 10)
            self.assertRejected(t, "payload.size")

    def test_flipped_manifest_byte(self):
        t = self.copy_bundle(self.d)
        mp = os.path.join(t, "manifest.json")
        raw = rb(mp)
        self.assertIn(b"1111", raw)
        write(mp, raw.replace(b"1111", b"1112", 1))
        self.assertRejected(t, "signature does NOT verify")

    def test_flipped_signature_byte(self):
        t = self.copy_bundle(self.d)
        sp = os.path.join(t, "manifest.sig")
        sig = bytearray(base64.b64decode(rb(sp)))
        sig[10] ^= 1
        write(sp, base64.b64encode(bytes(sig)))
        self.assertRejected(t, "signature does NOT verify")
        write(sp, b"not base64 !!")
        self.assertRejected(t, "base64")

    def test_missing_files(self):
        for name in ("manifest.json", "manifest.sig", "payload.pck"):
            t = self.copy_bundle(self.d, "m-" + name)
            os.remove(os.path.join(t, name))
            self.assertRejected(t, "missing")

    def test_wrong_key(self):
        self.assertRejected(self.d, "signature does NOT verify", pub=self.pub_b)
        forged = self.forge(self.p("forged-b"), key=self.key_b)
        self.assertRejected(forged, "signature does NOT verify")
        self.assertEqual(self.verify(forged, pub=self.pub_b).returncode, 0, "the forgery is fine for its own key")

    def test_compat_expectations(self):
        for flag, val, needle in (("--base-commit", OTHER40, "base commit"), ("--platform", "android", "platform"),
                                  ("--native-version", "6", "native version"), ("--engine", "4.7.stable.official.deadbeef", "engine"),
                                  ("--ota-api", "2", "ota_api")):
            self.assertRejected(self.d, needle, flag, val)

    def test_protected_path_forged_into_a_signed_pack(self):
        for path in ("project.binary", "scripts/ota/x.gdc", "ota_trust.pem"):
            files = {"data/ok.json": b"1", path: b"evil"}
            d = self.forge(self.p("forge-" + path.replace("/", "_")), patch_files=files,
                           files=[{"path": "data/ok.json", "op": "add"}, {"path": path, "op": "replace" if path in self.BASE_FILES else "add"}])
            self.assertRejected(d, "protected path")

    def test_escaping_path_forged(self):
        d = self.forge(self.p("forge-esc"), patch_files={"../x.gdc": b"1"}, files=[{"path": "../x.gdc", "op": "add"}])
        self.assertRejected(d, "escape path")

    def test_manifest_lists_protected_path_that_pack_lacks(self):
        d = self.forge(self.p("forge-lie"), files=[{"path": "data/d.json", "op": "add"}, {"path": "scripts/a.gdc", "op": "replace"},
                                                    {"path": "scripts/b.gdc", "op": "remove"}, {"path": "project.godot", "op": "replace"}])
        self.assertRejected(d, "protected path")
        self.assertRejected(d, "files[] and the pack directory differ")

    def test_files_vs_pack_directory(self):
        d = self.forge(self.p("forge-files"), files=[{"path": "data/d.json", "op": "add"}])
        self.assertRejected(d, "files[] and the pack directory differ")

    def test_wrong_ops(self):
        d = self.forge(self.p("forge-ops"), files=[{"path": "data/d.json", "op": "replace"}, {"path": "scripts/a.gdc", "op": "add"},
                                                   {"path": "scripts/b.gdc", "op": "remove"}])
        self.assertEqual(self.verify(d).returncode, 0, "without a base pack add/replace cannot be judged")
        self.assertRejected(d, "against the base pack it is 'add'", "--base-pck", self.base_pck)
        d = self.forge(self.p("forge-rm"), files=[{"path": "data/d.json", "op": "add"}, {"path": "scripts/a.gdc", "op": "remove"},
                                                  {"path": "scripts/b.gdc", "op": "remove"}])
        self.assertRejected(d, "disagrees with the pack's removal flag")

    def test_duplicate_paths_and_extra_keys(self):
        d = self.forge(self.p("forge-dup"), files=[{"path": "data/d.json", "op": "add"}, {"path": "data/d.json", "op": "add"}])
        self.assertRejected(d, "duplicate")
        d = self.forge(self.p("forge-extra"), manifest_edit=lambda m: m.update({"surprise": 1}))
        self.assertRejected(d, "manifest keys differ")
        d = self.forge(self.p("forge-fmt"), manifest_edit=lambda m: m.update({"format": 2}))
        self.assertRejected(d, "format must be 1")
        d = self.forge(self.p("forge-label"), manifest_edit=lambda m: m.update({"label": "Purgatory Dungeon vNext"}))
        self.assertRejected(d, "label")

    def test_oversized_payload_is_rejected_without_hashing(self):
        d = self.forge(self.p("forge-big"))
        with open(os.path.join(d, "payload.pck"), "wb") as f:
            f.truncate(512 * 1024 * 1024 + 1)

        def grow(m):
            m["payload"]["size"] = 512 * 1024 * 1024 + 1
        shutil.rmtree(d)
        d = self.forge(self.p("forge-big2"), manifest_edit=grow)
        with open(os.path.join(d, "payload.pck"), "wb") as f:
            f.truncate(512 * 1024 * 1024 + 1)
        self.assertRejected(d, "over the")

    def test_folder_must_match_manifest(self):
        wrong = self.p("v5", "windows", "update-9")
        shutil.copytree(self.d, wrong)
        self.assertRejected(wrong, "does not match the manifest")

    def test_trust_key_must_be_rsa(self):
        ec = self.p("ec.pem")
        subprocess.run(["openssl", "ecparam", "-genkey", "-name", "prime256v1", "-noout", "-out", ec], check=True, capture_output=True)
        ecpub = self.p("ecpub.pem")
        subprocess.run(["openssl", "pkey", "-in", ec, "-pubout", "-out", ecpub], check=True, capture_output=True)
        r = self.verify(self.d, pub=ecpub)
        self.assertEqual(r.returncode, 1)
        self.assertIn("RSA", out(r))

    def test_not_a_bundle(self):
        r = self.verify(self.tmp)
        self.assertEqual(r.returncode, 1)
        self.assertIn("neither an update folder", r.stdout)


class TestChannel(BundleBase):
    def merge(self, chan, key=None, *extra):
        return tool("channel.py", "merge", "--out", chan, "--key", key or self.key, *extra)

    def gen(self, chan):
        return jload(os.path.join(chan, "channel.json"))["generation"]

    def test_generation_is_monotonic_and_idempotent(self):
        chan = self.p("chan")
        self.build(chan, seq=1)
        self.assertEqual(self.merge(chan).returncode, 0)
        self.assertEqual(self.gen(chan), 1)
        r = self.merge(chan)
        self.assertIn("unchanged", r.stdout)
        self.assertEqual(self.gen(chan), 1, "no change, no new generation")
        self.build(chan, seq=2)
        self.assertEqual(self.merge(chan).returncode, 0)
        self.assertEqual(self.gen(chan), 2)
        ch = jload(os.path.join(chan, "channel.json"))
        self.assertEqual([u["seq"] for u in ch["updates"]], [1, 2])
        self.assertEqual(self.verify(chan, *self.good_expect()).returncode, 0)

    def test_revoke(self):
        chan = self.p("chan")
        self.build(chan, seq=1)
        self.build(chan, seq=2)
        self.merge(chan)
        args = ("revoke", "--out", chan, "--key", self.key, "--native-version", "5", "--platform", "windows", "--base-commit", BASE40)
        r = tool("channel.py", *args, "--seq", "2", "--generated-utc", T0)
        self.assertEqual(r.returncode, 0, out(r))
        ch = jload(os.path.join(chan, "channel.json"))
        self.assertEqual(ch["generation"], 2)
        self.assertEqual(ch["revoked"], [{"native_version": 5, "platform": "windows", "base_commit": BASE40, "seq": 2}])
        self.assertEqual(len(ch["updates"]), 2, "the update stays listed")
        self.assertEqual(self.verify(chan).returncode, 0)
        self.assertIn("already revoked", tool("channel.py", *args, "--seq", "2").stdout)
        self.assertEqual(self.gen(chan), 2)
        r = tool("channel.py", *args, "--seq", "7")
        self.assertEqual(r.returncode, 1)
        self.assertIn("not listed", r.stderr)
        # a later merge keeps the revocation and bumps the generation
        self.build(chan, seq=3)
        self.merge(chan)
        ch = jload(os.path.join(chan, "channel.json"))
        self.assertEqual((ch["generation"], len(ch["revoked"])), (3, 1))

    def test_signature_matches_exact_bytes(self):
        chan = self.p("chan")
        self.build(chan)
        self.merge(chan)
        sig = base64.b64decode(rb(os.path.join(chan, "channel.json.sig")))
        write(self.p("s.bin"), sig)
        r = run(["openssl", "dgst", "-sha256", "-verify", self.pub, "-signature", self.p("s.bin"), os.path.join(chan, "channel.json")])
        self.assertEqual(r.returncode, 0, out(r))

    def test_other_key_cannot_continue_the_channel(self):
        chan = self.p("chan")
        self.build(chan, seq=1)
        self.merge(chan)
        self.build(chan, seq=2)
        r = self.merge(chan, key=self.key_b)
        self.assertEqual(r.returncode, 1)
        self.assertRegex(r.stderr, "does not verify against this key|signature does not verify")

    def test_merge_refuses_lost_updates_and_foreign_bundles(self):
        chan = self.p("chan")
        self.build(chan, seq=1)
        self.build(chan, seq=2)
        self.merge(chan)
        shutil.rmtree(os.path.join(chan, "v5", "windows", "update-1"))
        r = self.merge(chan)
        self.assertEqual(r.returncode, 1)
        self.assertIn("missing", r.stderr)
        self.assertEqual(self.merge(chan, None, "--drop-missing").returncode, 0)
        self.assertEqual([u["seq"] for u in jload(os.path.join(chan, "channel.json"))["updates"]], [2])
        # a bundle signed by another key never enters the index
        other = self.p("other")
        base, patch = self.packs(name="o-")
        self.assertEqual(self.make(patch, base, other, key=self.key_b).returncode, 0)
        r = self.merge(other)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.merge(other, self.key_b).returncode, 0)

    def test_merge_detects_modified_payload(self):
        chan = self.p("chan")
        d = self.build(chan)
        write(os.path.join(d, "payload.pck"), b"x" + rb(os.path.join(d, "payload.pck"))[1:])
        r = self.merge(chan)
        self.assertEqual(r.returncode, 1)
        self.assertIn("size/sha256", r.stderr)

    def test_add_copies_platform_bundles(self):
        a, b, chan = self.p("a"), self.p("b"), self.p("chan")
        base, patch = self.packs()
        self.make(patch, base, a)
        self.make(patch, base, b, platform="android")
        r = self.merge(chan, None, "--add", a, "--add", b)
        self.assertEqual(r.returncode, 0, out(r))
        ch = jload(os.path.join(chan, "channel.json"))
        self.assertEqual(sorted(u["platform"] for u in ch["updates"]), ["android", "windows"])
        self.assertEqual(self.merge(chan, None, "--add", a).returncode, 0, "re-adding identical folders is fine")
        write(os.path.join(a, "v5", "windows", "update-1", "payload.pck"), b"changed")
        self.assertEqual(self.merge(chan, None, "--add", a).returncode, 1, "update folders are immutable")

    def test_replayed_lower_generation(self):
        chan = self.p("chan")
        self.build(chan, seq=1)
        self.merge(chan)
        old = self.p("channel-gen1.json")
        shutil.copyfile(os.path.join(chan, "channel.json"), old)
        old_sig = self.p("channel-gen1.json.sig")
        shutil.copyfile(os.path.join(chan, "channel.json.sig"), old_sig)
        self.build(chan, seq=2)
        self.merge(chan)
        self.assertEqual(self.gen(chan), 2)
        self.assertEqual(self.verify(chan, "--min-generation", "2").returncode, 0)
        self.assertEqual(self.verify(chan, "--previous-channel", old).returncode, 0, "newer than what the client saw")
        # the attacker serves the old (validly signed) index again, next to the new folders
        replay = self.p("replay")
        shutil.copytree(chan, replay)
        shutil.copyfile(old, os.path.join(replay, "channel.json"))
        shutil.copyfile(old_sig, os.path.join(replay, "channel.json.sig"))
        r = self.verify(replay, "--min-generation", "2")
        self.assertIn("lower than the required minimum 2", r.stdout)
        self.assertEqual(r.returncode, 1)
        r = self.verify(replay, "--previous-channel", os.path.join(chan, "channel.json"))
        self.assertIn("replay", r.stdout)
        self.assertEqual(r.returncode, 1)
        # same generation but different content
        forged = self.p("same-gen")
        shutil.copytree(chan, forged)
        ch = jload(os.path.join(forged, "channel.json"))
        ch["generated_utc"] = "2030-01-01T00:00:00Z"
        write(os.path.join(forged, "channel.json"), otalib.canonical_json(ch))
        otalib.sign_to_file(self.key, os.path.join(forged, "channel.json"), os.path.join(forged, "channel.json.sig"))
        r = self.verify(forged, "--previous-channel", os.path.join(chan, "channel.json"))
        self.assertIn("equals the previous one but the content differs", r.stdout)

    def forge_channel(self, chan, edit):
        dest = self.p("fc")
        shutil.copytree(chan, dest)
        ch = jload(os.path.join(dest, "channel.json"))
        edit(ch)
        write(os.path.join(dest, "channel.json"), otalib.canonical_json(ch))
        otalib.sign_to_file(self.key, os.path.join(dest, "channel.json"), os.path.join(dest, "channel.json.sig"))
        return dest

    def test_channel_consistency_failures(self):
        chan = self.p("chan")
        self.build(chan, seq=1)
        self.merge(chan)
        cases = (
            (lambda c: c["updates"].append(dict(c["updates"][0])), "twice"),
            (lambda c: c["updates"][0].update({"payload": "v5/windows/update-1/other.pck"}), "payload path"),
            (lambda c: c["updates"][0].update({"base_commit": OTHER40}), "disagrees with its manifest"),
            (lambda c: c["updates"].__setitem__(0, {**c["updates"][0], "seq": 4, "manifest": "v5/windows/update-4/manifest.json",
                                                    "signature": "v5/windows/update-4/manifest.sig", "payload": "v5/windows/update-4/payload.pck"}),
             "folder does not exist"),
            (lambda c: c["updates"].clear(), "not listed in channel.json"),
            (lambda c: c.update({"generation": 0}), "generation must be a positive integer"),
            (lambda c: c.update({"extra": 1}), "keys differ"),
            (lambda c: c["revoked"].append({"seq": 1}), "revoked entry malformed"),
        )
        for edit, needle in cases:
            d = self.forge_channel(chan, edit)
            r = self.verify(d)
            self.assertEqual(r.returncode, 1, needle)
            self.assertIn(needle, r.stdout)
            shutil.rmtree(d)

    def test_unsigned_or_tampered_channel(self):
        chan = self.p("chan")
        self.build(chan)
        self.merge(chan)
        t = self.copy_bundle(chan, "t1")
        raw = rb(os.path.join(t, "channel.json"))
        write(os.path.join(t, "channel.json"), raw.replace(b'"generation": 1', b'"generation": 9'))
        r = self.verify(t)
        self.assertEqual(r.returncode, 1)
        self.assertIn("channel.json: signature does NOT verify", r.stdout)
        os.remove(os.path.join(t, "channel.json.sig"))
        self.assertIn("channel.json.sig is missing", self.verify(t).stdout)
        r = self.verify(chan, pub=self.pub_b)
        self.assertEqual(r.returncode, 1)


# ------------------------------------------------------------------------------------------------ native check

class TestNativeCheck(BundleBase):
    FILES = {"scripts/a.gdc": b"A1", ".godot/imported/t.ctex": b"IMG", "build_info.json": b"{}", "data/c.json": b"C1"}

    def check(self, *args):
        return tool("native_check.py", *args)

    def test_windows_pck_and_zip(self):
        base = pck_of(self.p("base.pck"), self.FILES)
        native = pck_of(self.p("PurgatoryDungeon.pck"), dict(self.FILES, **{"build_info.json": b'{"real":1}'}))
        r = self.check("compare", "--platform", "windows", "--base-pck", base, "--native", self.tmp, "--allow", "build_info.json")
        self.assertEqual(r.returncode, 0, out(r))
        r = self.check("compare", "--platform", "windows", "--base-pck", base, "--native", self.p("PurgatoryDungeon.exe"))
        self.assertEqual(r.returncode, 1, "exe -> sibling pck; build_info.json differs when not allowed")
        self.assertIn("build_info.json", r.stdout)
        zp = self.p("rel.zip")
        with zipfile.ZipFile(zp, "w") as z:
            z.write(native, "PurgatoryDungeon.pck")
        self.assertEqual(self.check("compare", "--platform", "windows", "--base-pck", base, "--native", zp, "--allow", "build_info.json").returncode, 0)
        r = self.check("extract", "--platform", "windows", "--native", zp, "--path", "build_info.json", "--out", self.p("bi.json"))
        self.assertEqual(r.returncode, 0, out(r))
        self.assertEqual(rb(self.p("bi.json")), b'{"real":1}')

    def test_windows_differences(self):
        base = pck_of(self.p("base.pck"), self.FILES)
        changed = dict(self.FILES)
        changed["scripts/a.gdc"] = b"A-different"
        del changed["data/c.json"]
        changed["extra.txt"] = b"x"
        pck_of(self.p("PurgatoryDungeon.pck"), changed)
        r = self.check("compare", "--platform", "windows", "--base-pck", base, "--native", self.tmp, "--allow", "build_info.json")
        self.assertEqual(r.returncode, 1)
        self.assertIn("content differs from the native build: scripts/a.gdc", r.stdout)
        self.assertIn("missing in the native build: data/c.json", r.stdout)
        self.assertIn("only in the native build (not in base.pck): extra.txt", r.stdout)
        r = self.check("compare", "--platform", "windows", "--base-pck", base, "--native", self.tmp, "--allow", "build_info.json", "--warn-only")
        self.assertEqual(r.returncode, 0)

    def test_android_loose_assets_layout(self):
        base = pck_of(self.p("base.pck"), self.FILES)
        apk = self.p("app.apk")
        with zipfile.ZipFile(apk, "w") as z:
            z.writestr("classes.dex", b"dex")
            z.writestr("assets/scripts/a.gdc", b"A1")
            z.writestr("assets/godot/imported/t.ctex", b"IMG")
            z.writestr("assets/data/c.json", b"C1")
            z.writestr("assets/build_info.json", b'{"apk":1}')
        r = self.check("compare", "--platform", "android", "--base-pck", base, "--native", apk, "--allow", "build_info.json")
        self.assertEqual(r.returncode, 0, out(r))
        with zipfile.ZipFile(apk, "w") as z:
            z.writestr("assets/scripts/a.gdc", b"changed")
            z.writestr("assets/godot/imported/t.ctex", b"IMG")
            z.writestr("assets/data/c.json", b"C1")
            z.writestr("assets/build_info.json", b'{"apk":1}')
        r = self.check("compare", "--platform", "android", "--base-pck", base, "--native", apk, "--allow", "build_info.json")
        self.assertEqual(r.returncode, 1)
        self.assertIn("scripts/a.gdc", r.stdout)
        r = self.check("extract", "--platform", "android", "--native", apk, "--path", "build_info.json", "--out", self.p("bi.json"))
        self.assertEqual(rb(self.p("bi.json")), b'{"apk":1}')

    def test_android_single_pck_asset(self):
        base = pck_of(self.p("base.pck"), self.FILES)
        apk = self.p("app.apk")
        with zipfile.ZipFile(apk, "w") as z:
            z.write(base, "assets/main.pck")
        self.assertEqual(self.check("compare", "--platform", "android", "--base-pck", base, "--native", apk).returncode, 0)
        with zipfile.ZipFile(self.p("empty.apk"), "w") as z:
            z.writestr("classes.dex", b"dex")
        r = self.check("compare", "--platform", "android", "--base-pck", base, "--native", self.p("empty.apk"))
        self.assertEqual(r.returncode, 1)


# ------------------------------------------------------------------------------------------------ keys.sh

class TestKeysScript(TmpCase):
    def keys(self, *args, env=None, extra_env=None):
        e = {"OTA_KEY_DIR": self.p("store"), "RUNNER_TEMP": self.p("rt"), "GITHUB_REPOSITORY": "", "OTA_SIGNING_KEY_PEM_BASE64": "",
             "OTA_KEYS_NO_CREATE": "", "GITHUB_ENV": ""}
        e.update(extra_env or {})
        if env is not None:
            e = env
        return run(["bash", os.path.join(OTA, "keys.sh")] + list(args), env=e)

    def fingerprint(self, pub):
        der = subprocess.run(["openssl", "pkey", "-pubin", "-in", pub, "-outform", "DER"], capture_output=True, check=True).stdout
        return hashlib.sha256(der).hexdigest()

    def test_generate_then_reuse(self):
        r = self.keys(self.p("pub1.pem"))
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("source=generated", r.stdout)
        key = self.p("store", "ota-signing.key")
        self.assertTrue(os.path.isfile(key))
        self.assertEqual(os.stat(key).st_mode & 0o077, 0, "private key must be owner-only")
        self.assertIn("-----BEGIN PUBLIC KEY-----", rt(self.p("pub1.pem")))
        self.assertGreaterEqual(otalib.private_key_bits(key), 3072)
        before = rb(key)
        r = self.keys(self.p("pub2.pem"))
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("source=dir", r.stdout)
        self.assertEqual(rb(key), before, "idempotent: the stored key is reused, never regenerated")
        self.assertEqual(rt(self.p("pub1.pem")), rt(self.p("pub2.pem")))
        self.assertIn(self.fingerprint(self.p("pub1.pem")), r.stdout)
        self.assertEqual([n for n in os.listdir(self.p("store")) if n.startswith(".gen")], [], "no temp files left behind")

    def test_never_prints_the_key(self):
        r = self.keys(self.p("pub.pem"))
        key_text = rt(self.p("store", "ota-signing.key"))
        body = "".join(key_text.splitlines()[1:-1])
        for stream in (r.stdout, r.stderr):
            self.assertNotIn("PRIVATE KEY", stream)
            self.assertNotIn(body[:40], stream)

    def test_public_only(self):
        self.assertEqual(self.keys(self.p("full.pem")).returncode, 0)
        r = self.keys("--public-only", self.p("po.pem"))
        self.assertEqual(r.returncode, 0, out(r))
        self.assertEqual(rt(self.p("full.pem")), rt(self.p("po.pem")))
        self.assertTrue(os.path.isfile(self.p("store", "ota-signing.key")), "the local store itself is never deleted")

    def test_public_only_and_no_create_never_create(self):
        for args, env in ((("--public-only", self.p("x.pem")), None), (("--no-create", self.p("x.pem")), None),
                          ((self.p("x.pem"),), {"OTA_KEYS_NO_CREATE": "1"})):
            r = self.keys(*args, extra_env=env)
            self.assertEqual(r.returncode, 1, out(r))
            self.assertIn("creation is not allowed", out(r))
            self.assertFalse(os.path.exists(self.p("store", "ota-signing.key")))
            self.assertFalse(os.path.exists(self.p("x.pem")))

    def test_secret_takes_precedence_and_is_not_echoed(self):
        k = self.p("secret.pem")
        pub = genkey(k)
        b64 = base64.b64encode(rb(k)).decode()
        r = self.keys(self.p("s.pub"), extra_env={"OTA_SIGNING_KEY_PEM_BASE64": b64})
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("source=secret", r.stdout)
        self.assertEqual(rt(self.p("s.pub")), rt(pub))
        self.assertFalse(os.path.exists(self.p("store", "ota-signing.key")), "the local store is not touched when the secret is used")
        self.assertNotIn(b64[:40], out(r))
        self.assertNotIn("PRIVATE KEY", out(r))
        # public-only with the secret leaves no private copy behind
        r = self.keys("--public-only", self.p("s2.pub"), extra_env={"OTA_SIGNING_KEY_PEM_BASE64": b64})
        self.assertEqual(r.returncode, 0, out(r))
        self.assertEqual(rt(self.p("s2.pub")), rt(pub))
        leftovers = [f for dp, _, fs in os.walk(self.p("rt")) for f in fs if f.endswith(".key")]
        self.assertEqual(leftovers, [], "private key copy must be removed in --public-only mode")

    def test_invalid_secret_fails_without_leaking(self):
        junk = base64.b64encode(b"definitely not a key " * 5).decode()
        r = self.keys(self.p("j.pub"), extra_env={"OTA_SIGNING_KEY_PEM_BASE64": junk})
        self.assertEqual(r.returncode, 1)
        self.assertIn("not an RSA private key", r.stderr)
        self.assertNotIn(junk[:30], out(r))
        weak = self.p("weak.pem")
        genkey(weak, 2048)
        r = self.keys(self.p("j.pub"), extra_env={"OTA_SIGNING_KEY_PEM_BASE64": base64.b64encode(rb(weak)).decode()})
        self.assertEqual(r.returncode, 1)
        self.assertIn("RSA-2048", r.stderr)

    def test_no_source_and_usage(self):
        r = self.keys(self.p("n.pem"), extra_env={"OTA_KEY_DIR": ""})
        self.assertEqual(r.returncode, 1)
        self.assertIn("no key source", r.stderr)
        self.assertEqual(self.keys().returncode, 2)
        self.assertEqual(self.keys("--bogus", self.p("n.pem")).returncode, 2)

    def test_no_github_call_when_override_is_set(self):
        fake = self.p("bin")
        os.makedirs(fake)
        write(os.path.join(fake, "gh"), "#!/bin/sh\necho gh-was-called >&2\nexit 9\n")
        os.chmod(os.path.join(fake, "gh"), 0o755)
        r = self.keys(self.p("g.pem"), extra_env={"GITHUB_REPOSITORY": "o/r", "PATH": fake + os.pathsep + os.environ["PATH"]})
        self.assertEqual(r.returncode, 0, out(r))
        self.assertNotIn("gh-was-called", out(r))

    def test_parallel_first_runs_converge_on_one_key(self):
        def one(i):
            return self.keys(self.p(f"p{i}.pem"))
        with concurrent.futures.ThreadPoolExecutor(4) as ex:
            results = list(ex.map(one, range(4)))
        for r in results:
            self.assertEqual(r.returncode, 0, out(r))
        pubs = {rt(self.p(f"p{i}.pem")) for i in range(4)}
        self.assertEqual(len(pubs), 1, "every racer must end up with the same trust key")
        self.assertEqual(sum("source=generated" in r.stdout for r in results), 1, "exactly one racer creates the key")
        self.assertEqual(os.listdir(self.p("store")), ["ota-signing.key"])

    def test_sourced_exports_for_later_steps(self):
        env = {"OTA_KEY_DIR": self.p("store"), "RUNNER_TEMP": self.p("rt"), "GITHUB_ENV": self.p("ghenv"), "GITHUB_REPOSITORY": "",
               "OTA_SIGNING_KEY_PEM_BASE64": ""}
        e = dict(os.environ)
        e.update(env)
        script = f'source "{os.path.join(OTA, "keys.sh")}" "{self.p("src.pem")}" >/dev/null; echo "$OTA_PRIVATE_KEY_PATH|$OTA_KEY_SOURCE"'
        r = subprocess.run(["bash", "-c", script], env=e, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, out(r))
        self.assertEqual(r.stdout.strip(), f"{self.p('store', 'ota-signing.key')}|generated")
        ghenv = rt(self.p("ghenv"))
        self.assertIn("OTA_PRIVATE_KEY_PATH=" + self.p("store", "ota-signing.key"), ghenv)
        self.assertNotIn("PRIVATE KEY", ghenv)
        sig = otalib.sign_file(self.p("store", "ota-signing.key"), self.p("src.pem"))
        write(self.p("sig"), sig)
        r = run(["openssl", "dgst", "-sha256", "-verify", self.p("src.pem"), "-signature", self.p("sig"), self.p("src.pem")])
        self.assertEqual(r.returncode, 0, "the exported private key matches the public key written")


FAKE_GH = r'''#!/usr/bin/env python3
# A tiny stand-in for the gh CLI: just the release calls tools/ota/keys.sh makes (list, get, download, delete, create).
import json, os, shutil, subprocess, sys
D = os.environ["FAKE_GH_DIR"]
P = os.path.join(D, "state.json")
s = json.load(open(P)) if os.path.exists(P) else {"next": 1, "releases": [], "raced": False}
def save():
    json.dump(s, open(P, "w"))
def jq(expr, obj):
    r = subprocess.run(["jq", "-r", expr], input=json.dumps(obj), capture_output=True, text=True)
    if r.returncode:
        sys.stderr.write(r.stderr); sys.exit(1)
    sys.stdout.write(r.stdout)
def new_release(title, notes, assets):
    rid = s["next"]; s["next"] += 1
    rel = {"id": rid, "name": title, "draft": True, "body": notes, "assets": []}
    for spec in assets:
        path, _, label = spec.partition("#")
        aid = s["next"]; s["next"] += 1
        shutil.copyfile(path, os.path.join(D, "asset-%d" % aid))
        rel["assets"].append({"id": aid, "name": label or os.path.basename(path), "label": label})
    s["releases"].append(rel)
    return rid
a = sys.argv[1:]
with open(os.path.join(D, "calls.log"), "a") as f:
    f.write(" ".join(a) + "\n")
if a[0] == "api":
    expr, method, rest, i = None, "GET", [], 1
    while i < len(a):
        if a[i] == "--jq": expr = a[i + 1]; i += 2
        elif a[i] == "-H": i += 2
        elif a[i] == "-X": method = a[i + 1]; i += 2
        else: rest.append(a[i]); i += 1
    parts = rest[0].split("?")[0].split("/")          # repos OWNER REPO releases [assets] ID
    if parts[3:] == ["releases"]:
        jq(expr, s["releases"])
    elif parts[3:4] == ["releases"] and parts[4] == "assets":
        sys.stdout.buffer.write(open(os.path.join(D, "asset-" + parts[5]), "rb").read())
    elif parts[3:4] == ["releases"] and method == "DELETE":
        s["releases"] = [r for r in s["releases"] if str(r["id"]) != parts[4]]; save()
    elif parts[3:4] == ["releases"]:
        jq(expr, [r for r in s["releases"] if str(r["id"]) == parts[4]][0])
    else:
        sys.exit("fake gh: unsupported " + rest[0])
elif a[:2] == ["release", "create"]:
    title = notes = ""; assets = []; i = 3
    while i < len(a):
        if a[i] == "--title": title = a[i + 1]; i += 2
        elif a[i] == "--notes": notes = a[i + 1]; i += 2
        elif a[i] == "--repo": i += 2
        elif a[i].startswith("--"): i += 1
        else: assets.append(a[i]); i += 1
    if os.environ.get("FAKE_GH_RACE") and not s["raced"]:
        s["raced"] = True                                   # another job gets in just before this one
        new_release(title, "winner", [os.environ["FAKE_GH_WINNER_KEY"] + "#ota-signing.key"])
    new_release(title, notes, assets); save()
else:
    sys.exit("fake gh: unsupported " + " ".join(a))
'''


class TestKeysGitHubFlow(TmpCase):
    """tools/ota/keys.sh against a fake gh: first-run creation, reuse, public-only, no-create and the creation race."""

    def setUp(self):
        super().setUp()
        if not shutil.which("jq"):
            notice("jq not installed: skipping the keys.sh GitHub-flow tests")
            self.skipTest("no jq")
        self.bin = self.p("bin")
        self.gh = self.p("gh-state")
        os.makedirs(self.gh)
        write(os.path.join(self.bin, "gh"), FAKE_GH)
        os.chmod(os.path.join(self.bin, "gh"), 0o755)

    def keys(self, *args, extra=None):
        env = {"PATH": self.bin + os.pathsep + os.environ["PATH"], "FAKE_GH_DIR": self.gh, "GITHUB_REPOSITORY": "o/r",
               "OTA_KEY_DIR": "", "OTA_SIGNING_KEY_PEM_BASE64": "", "OTA_KEYS_NO_CREATE": "", "RUNNER_TEMP": self.p("rt"),
               "GITHUB_ENV": ""}
        env.update(extra or {})
        return run(["bash", os.path.join(OTA, "keys.sh")] + list(args), env=env)

    def state(self):
        return jload(os.path.join(self.gh, "state.json")) if os.path.exists(os.path.join(self.gh, "state.json")) else {"releases": []}

    def test_create_once_then_reuse(self):
        r = self.keys(self.p("a.pem"))
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("source=generated", r.stdout)
        st = self.state()
        self.assertEqual(len(st["releases"]), 1)
        rel = st["releases"][0]
        self.assertTrue(rel["draft"])
        self.assertEqual(rel["name"], "OTA signing key (do not delete)")
        self.assertEqual([a["name"] for a in rel["assets"]], ["ota-signing.key"])
        calls = rt(os.path.join(self.gh, "calls.log"))
        self.assertIn("release create ota-signing-key", calls)
        for stream in (r.stdout, r.stderr):
            self.assertNotIn("PRIVATE KEY", stream)
        r2 = self.keys(self.p("b.pem"))
        self.assertEqual(r2.returncode, 0, out(r2))
        self.assertIn("source=release", r2.stdout)
        self.assertEqual(len(self.state()["releases"]), 1, "reuse must not create a second key")
        self.assertEqual(rt(self.p("a.pem")), rt(self.p("b.pem")))
        self.assertEqual(rt(os.path.join(self.gh, "calls.log")).count("release create"), 1)

    def test_public_only_and_no_create_never_create(self):
        for args, extra in ((("--public-only", self.p("x.pem")), None), ((self.p("x.pem"),), {"OTA_KEYS_NO_CREATE": "1"})):
            r = self.keys(*args, extra=extra)
            self.assertEqual(r.returncode, 1, out(r))
            self.assertIn("not allowed to create", r.stderr)
            self.assertEqual(self.state()["releases"], [])
            self.assertNotIn("release create", rt(os.path.join(self.gh, "calls.log")) if os.path.exists(os.path.join(self.gh, "calls.log")) else "")
        # once a first job created it, build jobs can fetch the public half and keep no private copy
        self.assertEqual(self.keys(self.p("full.pem")).returncode, 0)
        r = self.keys("--public-only", self.p("po.pem"))
        self.assertEqual(r.returncode, 0, out(r))
        self.assertEqual(rt(self.p("full.pem")), rt(self.p("po.pem")))
        self.assertFalse(os.path.exists(self.p("rt", "ota-signing", "ota-signing.key")), "no private copy after --public-only")

    def test_creation_race_converges_on_the_lowest_release_id(self):
        winner = self.p("winner.pem")
        genkey(winner)
        r = self.keys(self.p("loser.pem"), extra={"FAKE_GH_RACE": "1", "FAKE_GH_WINNER_KEY": winner})
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("another job created the key first", r.stderr)
        self.assertIn("source=release", r.stdout)
        st = self.state()
        self.assertEqual(len(st["releases"]), 1, "the loser removes its own draft")
        self.assertEqual(st["releases"][0]["body"], "winner")
        self.assertEqual(rt(self.p("loser.pem")), rt(winner + ".pub"), "the loser ends up with the winner's trust key")

    def test_incomplete_release_is_not_used(self):
        # a draft that exists but has no key asset yet (creator still uploading) must fail loudly after retrying
        write(os.path.join(self.gh, "state.json"), json.dumps({"next": 5, "raced": False, "releases": [
            {"id": 4, "name": "OTA signing key (do not delete)", "draft": True, "body": "", "assets": []}]}))
        fast = self.p("bin", "sleep")
        write(fast, "#!/bin/sh\nexit 0\n")
        os.chmod(fast, 0o755)
        r = self.keys(self.p("i.pem"))
        self.assertEqual(r.returncode, 1, out(r))
        self.assertIn("no ota-signing.key asset", r.stderr)


# ------------------------------------------------------------------------------------------------ workflow / wiring

class TestWiring(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.yml = rt(os.path.join(ROOT, ".github", "workflows", "ota.yml"))

    def has(self, needle):
        self.assertTrue(needle in self.yml, f"ota.yml must contain {needle!r}")

    def lacks(self, needle):
        self.assertFalse(needle in self.yml, f"ota.yml must not contain {needle!r}")

    def test_triggers_and_jobs(self):
        y = self.yml
        for needle in ("branches-ignore:", "'promote/**'", "'release/**'", "needs: ota-validate",
                       "startsWith(github.ref, 'refs/heads/ota/v')", "--self-test", "OTA_CHANNEL_REPO", "OTA_PUBLISH_TOKEN"):
            self.has(needle)
        self.lacks("pull_request")
        self.assertRegex(y, r"(?m)^  ota-validate:")
        self.assertRegex(y, r"(?m)^  ota-publish:")
        self.assertRegex(y, r"(?m)^permissions:\n  contents: read\n")
        self.assertEqual(len(re.findall(r"(?m)^      contents: write", y)), 1, "contents: write only on the publish job")

    def test_never_touches_releases_or_tags(self):
        y = self.yml
        for bad in ("gh release create", "gh release edit", "gh release upload", "gh release delete", "--latest", "make_latest",
                    "--force", "--tags", "refs/tags/*:", "gh api -X DELETE", "gh api --method DELETE", "publish_release.sh"):
            self.lacks(bad)
        self.assertIsNone(re.search(r"\bgit tag (?!--list)", y), "no tag may be created")
        self.assertIsNone(re.search(r"\bgit push\b", y), "only `git -C channel-repo push` may push")
        for line in y.splitlines():
            if "gh release" in line:
                self.assertIn("gh release download", line, "OTA may only READ releases")
            if re.search(r"\bpush\b", line) and "git -C" in line:
                self.assertIn("git -C channel-repo push", line, "the only push is to the channel repository")

    def test_publish_is_a_dry_run_unless_configured(self):
        y = self.yml
        publish = y[y.index("  ota-publish:"):]
        for needle in ("OTA_KEYS_NO_CREATE", "not configured", "upload-artifact"):
            self.assertTrue(needle in publish, needle)
        self.assertRegex(publish, r"(?s)Publish to the channel repository.*?if: env\.OTA_CHANNEL_REPO != '' && env\.OTA_PUBLISH_TOKEN != ''")

    def test_yaml_structure(self):
        try:
            import yaml
        except ImportError:
            notice("PyYAML not installed: skipping the structural check of ota.yml (text checks still ran)")
            self.skipTest("no yaml")
        d = yaml.safe_load(self.yml)
        self.assertEqual(d[True]["push"]["branches-ignore"], ["promote/**", "release/**"])
        self.assertEqual(d["permissions"], {"contents": "read"})
        self.assertEqual(set(d["jobs"]), {"ota-validate", "ota-publish"})
        self.assertEqual(d["jobs"]["ota-publish"]["needs"], "ota-validate")
        self.assertIsNone(d["jobs"]["ota-validate"].get("permissions"), "validation needs nothing beyond the top-level read")
        self.assertEqual(d["jobs"]["ota-publish"]["permissions"], {"contents": "write"})
        self.assertFalse(d["jobs"]["ota-publish"]["concurrency"]["cancel-in-progress"], "never cancel a publication half way")
        allowed = {"actions/checkout@v4", "actions/cache@v4", "actions/upload-artifact@v4"}
        for job in d["jobs"].values():
            for step in job["steps"]:
                if "uses" in step:
                    self.assertIn(step["uses"], allowed)
        # the only steps allowed to write anywhere are gated on the owner's configuration
        gated = [s for s in d["jobs"]["ota-publish"]["steps"] if "channel-repo push" in s.get("run", "")]
        self.assertEqual(len(gated), 1)
        self.assertEqual(gated[0]["if"], "env.OTA_CHANNEL_REPO != '' && env.OTA_PUBLISH_TOKEN != ''")

    def test_run_tests_wiring(self):
        runner = rt(os.path.join(ROOT, "tests", "run_tests.sh"))
        self.assertTrue("tests/test_ota_tools.py" in runner)
        self.assertTrue("check_res_paths" in runner)

    def test_scripts_are_executable(self):
        for f in ("keys.sh", "build_ota.sh"):
            self.assertTrue(os.access(os.path.join(OTA, f), os.X_OK), f + " must be executable")


# ------------------------------------------------------------------------------------------------ build_ota.sh (needs Godot)

class TestBuildOta(TmpCase):
    """End to end on a tiny temporary repository: classification, export, patch, bundle, verification."""

    def sh(self, *args):
        env = {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        r = run(["git", "-C", self.repo] + list(args), env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip()

    def commit(self, msg):
        self.sh("add", "-A")
        self.sh("-c", "commit.gpgsign=false", "commit", "-q", "-m", msg)
        return self.sh("rev-parse", "HEAD")

    def setUp(self):
        super().setUp()
        self.godot = godot_bin()
        if not self.godot:
            notice("Godot 4.6 not found ($GODOT): skipping the build_ota.sh end-to-end test")
            self.skipTest("no godot")
        self.repo = self.p("repo")
        make_probe_project(self.repo)
        os.makedirs(os.path.join(self.repo, "tools"))
        shutil.copytree(OTA, os.path.join(self.repo, "tools", "ota"), ignore=shutil.ignore_patterns("__pycache__", "fixtures"))
        shutil.copyfile(os.path.join(ROOT, "tools", "release_tool.py"), os.path.join(self.repo, "tools", "release_tool.py"))
        write(os.path.join(self.repo, ".gitignore"), ".godot/\nbuild_info.json\nota_trust.pem\nout/\n*.pck\n")
        self.sh("init", "-q")
        self.base = self.commit("base")
        self.sh("tag", "v5")
        self.keydir = self.p("keys")

    def build(self, *args, seq=1, out_dir=None):
        env = {"OTA_KEY_DIR": self.keydir, "GITHUB_REPOSITORY": "", "OTA_SIGNING_KEY_PEM_BASE64": ""}
        r = run(["bash", os.path.join(self.repo, "tools", "ota", "keys.sh"), self.p("trust.pem")], env=env)
        self.assertEqual(r.returncode, 0, out(r))
        key = os.path.join(self.keydir, "ota-signing.key")
        e = dict(os.environ)
        e.update(env)
        return subprocess.run(["bash", os.path.join(self.repo, "tools", "ota", "build_ota.sh"), "--platform", "windows",
                               "--godot", self.godot, "--seq", str(seq), "--key", key, "--out", out_dir or self.p("out")] + list(args),
                              cwd=self.repo, env=e, capture_output=True, text=True, timeout=900)

    def test_real_update_end_to_end(self):
        write(os.path.join(self.repo, "data", "probe.json"), '{"probe":"updated"}\n')
        write(os.path.join(self.repo, "data", "added.json"), '{"a":1}\n')
        os.remove(os.path.join(self.repo, "data", "gone.json"))
        head = self.commit("update")
        r = self.build("--base-ref", "v5")
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("BUNDLE OK", r.stdout)
        d = self.p("out", "v5", "windows", "update-1")
        m = jload(os.path.join(d, "manifest.json"))
        self.assertEqual(m["base_commit"], self.base)
        self.assertEqual(m["source_commit"], head)
        self.assertEqual({f["path"]: f["op"] for f in m["files"]},
                         {"data/probe.json": "replace", "data/added.json": "add", "data/gone.json": "remove"})
        self.assertTrue(m["engine"].startswith("4.6."))
        ch = jload(self.p("out", "channel.json"))
        self.assertEqual(ch["generation"], 1)
        # the update number only goes up
        r = self.build("--base-ref", "v5", out_dir=self.p("out"))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not higher", out(r))
        # the worktrees are cleaned up
        self.assertEqual([l for l in self.sh("worktree", "list").splitlines()], [l for l in self.sh("worktree", "list").splitlines()[:1]])

    def test_apk_required_change_aborts(self):
        write(os.path.join(self.repo, "project.godot"), 'config_version=5\n[application]\nconfig/name="Changed"\n')
        self.commit("settings change")
        r = self.build("--base-ref", "v5")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("needs a new APK", out(r))
        self.assertFalse(os.path.exists(self.p("out", "v5")))

    def test_self_test_mode(self):
        env = {"OTA_PRIVATE_KEY_PATH": "/nonexistent", "OTA_SIGNING_KEY_PEM_BASE64": "ignored-in-self-test"}
        e = dict(os.environ)
        e.update(env)
        r = subprocess.run(["bash", os.path.join(self.repo, "tools", "ota", "build_ota.sh"), "--platform", "windows", "--self-test",
                            "--godot", self.godot, "--out", self.p("st")], cwd=self.repo, env=e, capture_output=True, text=True, timeout=900)
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("SELF-TEST PASSED", r.stdout)
        m = jload(self.p("st", "v5", "windows", "update-1", "manifest.json"))
        self.assertEqual(m["files"], [{"op": "add", "path": "data/ota_probe.json"}])
        self.assertFalse(os.path.exists(os.path.join(self.repo, "data", "ota_probe.json")), "the probe is created in the temp worktree only")


if __name__ == "__main__":
    unittest.main(verbosity=1)
