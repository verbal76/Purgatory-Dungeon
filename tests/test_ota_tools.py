#!/usr/bin/env python3
"""Tests for the v7 OTA tooling (docs/OTA.md sections 3-6, 11, 12). Standard library + the openssl CLI (+ Godot 4.6 where noted).

  python3 tests/test_ota_tools.py [-v] [TestClass[.test_name]]

Covers: ota/boundary.json and path classification; the runtime fingerprint gate (tools/ota_runtime.py) on fixture trees;
tools/ota/classify.py against temporary git repositories; the independent PCK reader (real Godot 4.6 fixtures in
tools/ota/fixtures) and payload_check.py; native_check.py; the manifest maker and the inspector (tools/ota_make_manifest.gd,
tools/ota_inspect_pack.gd) with tamper cases, run against the REAL scripts/boot client when the tree has one and against the
stand-in of tests/ota_standin otherwise; the publisher's decisions (tools/ota/publish_gates.py) as pure logic and against a
local HTTP server; release_tool build-info / verify_package identity rules; keys.sh; the fault server of tests/ota_e2e.py;
tools/ota_build_payload.sh on a tiny repository; and static checks of ci.yml / ota-publish.yml / ota-tests.yml.
Tests that need the Godot 4.6 binary ($GODOT or /opt/godot/...) print a NOTICE and skip when it is absent (or when
OTA_TOOLS_NO_GODOT=1 is set, to run only the fast tests).
"""
import base64
import concurrent.futures
import hashlib
import http.server
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
import warnings
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OTA = os.path.join(ROOT, "tools", "ota")
TOOLS = os.path.join(ROOT, "tools")
TESTS = os.path.join(ROOT, "tests")
FIX = os.path.join(OTA, "fixtures")
for p in (OTA, TOOLS, TESTS):
    sys.path.insert(0, p)
sys.dont_write_bytecode = True
warnings.simplefilter("ignore", ResourceWarning)

import otalib  # noqa: E402
import pck as pcklib  # noqa: E402
import payload_check  # noqa: E402
import publish_gates as gates  # noqa: E402
import tool_project  # noqa: E402
import classify as classify_mod  # noqa: E402
import ota_runtime  # noqa: E402
import ota_e2e  # noqa: E402
import verify_package as vp  # noqa: E402
import artifact_gates  # noqa: E402

BASE40 = "1" * 40
SRC40 = "2" * 40
OTHER40 = "3" * 40
FP64 = "ab" * 32
NOTICES = []


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


def run(args, cwd=None, env=None, input_text=None, timeout=900):
    e = dict(os.environ)
    e.update(env or {})
    return subprocess.run(args, cwd=cwd, env=e, capture_output=True, text=True, input=input_text, timeout=timeout)


def tool(name, *args, cwd=None, env=None, base=OTA):
    return run([sys.executable, os.path.join(base, name)] + [str(a) for a in args], cwd=cwd, env=env)


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


GIT_ENV = {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


class TmpCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ota-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def p(self, *parts):
        return os.path.join(self.tmp, *parts)

    def git(self, repo, *args):
        r = run(["git", "-C", repo] + list(args), env=GIT_ENV)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip()

    def commit(self, repo, msg="c"):
        self.git(repo, "add", "-A")
        self.git(repo, "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", msg)
        return self.git(repo, "rev-parse", "HEAD")


# ------------------------------------------------------------------------------------------------ boundary

class TestBoundary(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rules = otalib.load_boundary()

    def cat(self, path):
        return otalib.classify_source(self.rules, path)[0]

    def test_shape_and_spec_content(self):
        r = self.rules
        self.assertEqual(r["max_payload_bytes"], 536870912)
        self.assertEqual(r["warn_payload_bytes"], 95 * 1024 * 1024, "the 95 MiB git-host guard")
        self.assertEqual(r["native_inputs"], ["project.godot", "export_presets.cfg", "scripts/boot/*.gd", "tools/android/build_apk.sh"])
        self.assertEqual(r["engine_version_source"]["file"], ".github/workflows/ci.yml")
        self.assertEqual(r["runtime_revision_source"], {"file": "scripts/boot/ota_config.gd", "constant": "RUNTIME_REVISION"})
        pp = r["payload_protected"]
        for need in ("project.godot", "project.binary", "export_presets.cfg", "build_info.json", "VERSION", "godot/extension_list.cfg"):
            self.assertIn(need, pp["exact"], need)
        for need in ("scripts/boot/", "android/"):
            self.assertIn(need, pp["prefixes"], need)
        for need in (".gdextension", ".so", ".dll", ".dylib"):
            self.assertIn(need, pp["suffixes"], need)
        self.assertEqual(set(r["guarded"]["exact"]), {"scripts/SettingsManager.gd", "scripts/save_manager.gd", "scripts/storage_paths.gd"})
        for key in ("tests/", "tools/", "docs/", ".github/"):
            self.assertIn(key, r["not_shipped"]["prefixes"], key)

    def test_classification_matrix(self):
        native = ("project.godot", "export_presets.cfg", "scripts/boot/ota_core.gd", "scripts/boot/ota_config.gd", "scripts/boot/diagnostics.gd",
                  "tools/android/build_apk.sh")
        for p in native:
            c, why = otalib.classify_source(self.rules, p)
            self.assertEqual(c, "apk_required", p)
            self.assertIn("runtime fingerprint would change", why, p)
        for p in ("scripts/boot/ota_core.gd.uid", "scripts/boot/sub/x.gd", "android/build/x.gradle", "VERSION", "build_info.json",
                  "ota/boundary.json", "ota/runtime_lock.json", "addons/x/y.gdextension", "addons/x/libx.so", "bin/x.dll", "bin/y.dylib",
                  ".godot/extension_list.cfg", "godot/extension_list.cfg", "project.binary"):
            self.assertEqual(self.cat(p), "apk_required", p)
        for p in ("scripts/save_manager.gd", "scripts/SettingsManager.gd", "scripts/storage_paths.gd"):
            self.assertEqual(self.cat(p), "guarded", p)
        for p in ("docs/OTA.md", "tests/test_x.gd", "tools/ota/classify.py", "tools/release_tool.py", ".github/workflows/ota-publish.yml",
                  "README.md", ".gitignore", "archive/old.gd", "production/x.png", ".claude/settings.json"):
            self.assertEqual(self.cat(p), "not_shipped", p)
        for p in ("scripts/enemy_manager.gd", "data/ota_probe.json", "scenes/MainMenu.tscn", "Music & background images/a.ogg",
                  "autoloads/GameClock.gd", "scripts/boot_extra.gd", "scripts/otaish.gd", "scripts/ota/a.gd", "characters/brute/b.tscn",
                  "scripts/save_schema.gd", "scripts/build_info.gd"):
            self.assertEqual(self.cat(p), "safe", p)

    def test_pack_paths(self):
        v = lambda p: otalib.pack_violation(self.rules, p)[0]  # noqa: E731
        for p in ("project.binary", "scripts/boot/ota_core.gdc", "scripts/boot/ota_core.gd.remap", "res://scripts/boot/x.gde",
                  "godot/extension_list.cfg", "x/y.so", "build_info.json", "VERSION", "project.godot", "android/x"):
            self.assertEqual(v(p), "protected", p)
        for p in ("../x", "/abs", "user://x", "a//b", "a/./b", "a\\b", "", "C:/x"):
            self.assertEqual(v(p), "escape", p)
        for p in ("scripts/save_manager.gdc", "scripts/save_manager.gd.remap", "scripts/SettingsManager.gd"):
            self.assertEqual(v(p), "guarded", p)
        for p in ("scripts/enemy_manager.gdc", "data/x.json", "godot/imported/a.ctex", "scripts/boot_extra.gdc"):
            self.assertEqual(v(p), "", p)

    def test_glob_semantics(self):
        rx = otalib.glob_regex("scripts/boot/*.gd")
        self.assertTrue(rx.match("scripts/boot/a.gd"))
        self.assertFalse(rx.match("scripts/boot/sub/a.gd"), "'*' never crosses '/'")
        self.assertFalse(rx.match("scripts/boot/a.gdc"))
        self.assertTrue(otalib.glob_regex("addons/**/x.so").match("addons/a/b/x.so"))
        self.assertTrue(otalib.glob_regex("a?.gd").match("ab.gd"))
        self.assertFalse(otalib.glob_regex("a.gd").match("axgd"), "regex metacharacters are escaped")

    def test_refuses_a_malformed_boundary(self):
        good = rb(otalib.BOUNDARY_PATH)
        otalib.parse_boundary(good)
        d = json.loads(good)
        for label, edit in (("format", lambda x: x.update(format=2)), ("native", lambda x: x.update(native_inputs=[])),
                            ("section", lambda x: x.pop("payload_protected")), ("list", lambda x: x["guarded"].update(exact="a")),
                            ("max", lambda x: x.pop("max_payload_bytes")), ("engine", lambda x: x.pop("engine_version_source")),
                            ("regex", lambda x: x["engine_version_source"].update(regex="(")),
                            ("revision", lambda x: x["runtime_revision_source"].update(constant="lower"))):
            e = json.loads(json.dumps(d))
            edit(e)
            with self.assertRaises(otalib.OtaError, msg=label):
                otalib.parse_boundary(json.dumps(e).encode())
        with self.assertRaises(otalib.OtaError):
            otalib.parse_boundary(b"{not json")


# ------------------------------------------------------------------------------------------------ runtime gate

CI_YML = 'env:\n  GODOT_VERSION: "4.6"\n  GODOT_RELEASE: "4.6-stable"\n'
CONFIG_GD = ('extends RefCounted\nconst RUNTIME_REVISION := 1\nconst CHANNEL := "dev"\nconst REPO := "o/r"\n'
             'const PUBLIC_KEY_PEM := """\n"""\n')


def make_runtime_tree(root, config=CONFIG_GD, ci=CI_YML):
    shutil.copytree(os.path.join(ROOT, "ota"), os.path.join(root, "ota"), ignore=shutil.ignore_patterns("runtime_lock.json"))
    write(os.path.join(root, ".github", "workflows", "ci.yml"), ci)
    write(os.path.join(root, "project.godot"), "config_version=5\n")
    write(os.path.join(root, "export_presets.cfg"), "[preset.0]\nname=\"Android\"\n")
    write(os.path.join(root, "tools", "android", "build_apk.sh"), "#!/bin/bash\necho build\n")
    write(os.path.join(root, "scripts", "boot", "ota_config.gd"), config)
    write(os.path.join(root, "scripts", "boot", "ota_core.gd"), "extends RefCounted\n")
    write(os.path.join(root, "scripts", "game.gd"), "extends Node\n")
    write(os.path.join(root, "data", "x.json"), "{}\n")
    write(os.path.join(root, "VERSION"), "7\n")


class TestRuntime(TmpCase):
    def setUp(self):
        super().setUp()
        self.t = self.p("tree")
        make_runtime_tree(self.t)

    def rt(self, *args, root=None):
        return tool("ota_runtime.py", "--root", root or self.t, *args, base=TOOLS)

    def ident(self, root=None):
        r = self.rt("--print", "--json", root=root)
        self.assertEqual(r.returncode, 0, out(r))
        return json.loads(r.stdout)

    def lock(self):
        r = self.rt("--relock")
        self.assertEqual(r.returncode, 0, out(r))

    def test_relock_then_check_passes(self):
        self.lock()
        r = self.rt("--check")
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("OTA-compatible", r.stdout)
        lock = jload(self.p("tree", "ota", "runtime_lock.json"))
        self.assertEqual(lock["runtime_revision"], 1)
        self.assertEqual(lock["godot_version"], "4.6")
        self.assertEqual(lock["files"], ["export_presets.cfg", "project.godot", "scripts/boot/ota_config.gd", "scripts/boot/ota_core.gd",
                                         "tools/android/build_apk.sh"])
        self.assertEqual(lock["fingerprint"], self.ident()["runtime_fingerprint"])
        self.assertRegex(lock["fingerprint"], r"^[0-9a-f]{64}$")
        self.assertEqual(set(lock["hashes"]), set(lock["files"]))

    def test_identity_format(self):
        i = self.ident()
        self.assertEqual(i["runtime_id"], "android-godot-4.6.0-r1")
        self.assertEqual((i["engine"], i["godot_version"], i["runtime_revision"], i["ota_channel"]), ("4.6.0", "4.6", 1, "dev"))
        self.assertEqual(json.loads(self.rt("--print", "--json", "--platform", "windows").stdout)["runtime_id"], "windows-godot-4.6.0-r1")
        r = self.rt("--print")
        self.assertIn("runtime_id=android-godot-4.6.0-r1", r.stdout)
        self.assertEqual(self.rt("--engine").stdout.strip(), "4.6")
        write(os.path.join(self.t, ".github", "workflows", "ci.yml"), 'env:\n  GODOT_RELEASE: "4.7.2-stable"\n')
        self.assertEqual(self.ident()["runtime_id"], "android-godot-4.7.2-r1")

    def test_native_input_change_fails(self):
        self.lock()
        for rel, add in (("project.godot", "[x]\n"), ("export_presets.cfg", "a=1\n"), ("scripts/boot/ota_core.gd", "# c\n"),
                         ("tools/android/build_apk.sh", "echo x\n")):
            path = os.path.join(self.t, *rel.split("/"))
            old = rb(path)
            write(path, old + add.encode())
            r = self.rt("--check")
            self.assertEqual(r.returncode, 1, rel + out(r))
            self.assertIn("native input changed: " + rel, r.stdout)
            self.assertIn("--bump", r.stdout)
            write(path, old)
            self.assertEqual(self.rt("--check").returncode, 0, "restoring the file restores the gate")

    def test_engine_change_fails(self):
        self.lock()
        write(os.path.join(self.t, ".github", "workflows", "ci.yml"), CI_YML.replace("4.6-stable", "4.7-stable"))
        r = self.rt("--check")
        self.assertEqual(r.returncode, 1)
        self.assertIn("engine version is 4.7", r.stdout)

    def test_added_or_removed_native_input_fails(self):
        self.lock()
        write(os.path.join(self.t, "scripts", "boot", "extra.gd"), "extends Node\n")
        r = self.rt("--check")
        self.assertEqual(r.returncode, 1)
        self.assertIn("added since the lock: scripts/boot/extra.gd", r.stdout)
        os.remove(os.path.join(self.t, "scripts", "boot", "extra.gd"))
        os.remove(os.path.join(self.t, "scripts", "boot", "ota_core.gd"))
        r = self.rt("--check")
        self.assertEqual(r.returncode, 1)
        self.assertIn("removed since the lock: scripts/boot/ota_core.gd", r.stdout)

    def test_content_only_change_keeps_the_fingerprint(self):
        before = self.ident()["runtime_fingerprint"]
        self.lock()
        write(os.path.join(self.t, "scripts", "game.gd"), "extends Node\nfunc x(): pass\n")
        write(os.path.join(self.t, "data", "new.json"), '{"a":1}\n')
        write(os.path.join(self.t, "scripts", "new_feature.gd"), "extends Node\n")
        write(os.path.join(self.t, "docs", "OTA.md"), "text\n")
        write(os.path.join(self.t, "scripts", "boot_notes.gd"), "extends Node\n")   # not under scripts/boot/
        self.assertEqual(self.ident()["runtime_fingerprint"], before)
        r = self.rt("--check")
        self.assertEqual(r.returncode, 0, out(r))

    def test_revision_is_normalised_out_of_its_own_file(self):
        fp = self.ident()["runtime_fingerprint"]
        cfg = os.path.join(self.t, "scripts", "boot", "ota_config.gd")
        write(cfg, rt(cfg).replace("RUNTIME_REVISION := 1", "RUNTIME_REVISION := 41"))
        i = self.ident()
        self.assertEqual((i["runtime_revision"], i["runtime_id"], i["runtime_fingerprint"]), (41, "android-godot-4.6.0-r41", fp),
                         "only the revision changed: same fingerprint, new runtime id")
        # but changing anything else in that file does change it
        write(cfg, rt(cfg).replace('CHANNEL := "dev"', 'CHANNEL := "stable"'))
        self.assertNotEqual(self.ident()["runtime_fingerprint"], fp)

    def test_editing_the_revision_without_bump_is_caught(self):
        self.lock()
        cfg = os.path.join(self.t, "scripts", "boot", "ota_config.gd")
        write(cfg, rt(cfg).replace("RUNTIME_REVISION := 1", "RUNTIME_REVISION := 2"))
        r = self.rt("--check")
        self.assertEqual(r.returncode, 1)
        self.assertIn("says r2 but ota/runtime_lock.json says r1", r.stdout)

    def test_bump_relocks_and_changes_only_the_revision(self):
        self.lock()
        fp = self.ident()["runtime_fingerprint"]
        r = self.rt("--bump")
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("r2", r.stdout)
        self.assertIn("RUNTIME_REVISION := 2", rt(os.path.join(self.t, "scripts", "boot", "ota_config.gd")))
        self.assertEqual(jload(os.path.join(self.t, "ota", "runtime_lock.json"))["runtime_revision"], 2)
        self.assertEqual(self.rt("--check").returncode, 0)
        i = self.ident()
        self.assertEqual((i["runtime_id"], i["runtime_fingerprint"]), ("android-godot-4.6.0-r2", fp))
        # a native change plus a bump is the intended path: the gate is green again
        write(os.path.join(self.t, "project.godot"), "config_version=5\n[x]\n")
        self.assertEqual(self.rt("--check").returncode, 1)
        self.assertEqual(self.rt("--bump").returncode, 0)
        self.assertEqual(self.rt("--check").returncode, 0)
        self.assertIn("RUNTIME_REVISION := 3", rt(os.path.join(self.t, "scripts", "boot", "ota_config.gd")))

    def test_line_endings_are_normalised(self):
        self.lock()
        p = os.path.join(self.t, "scripts", "boot", "ota_core.gd")
        write(p, rb(p).replace(b"\n", b"\r\n"))
        self.assertEqual(self.rt("--check").returncode, 0, "a CRLF checkout of the same text is the same runtime")

    def test_revision_constant_forms(self):
        for text, rev in (("const RUNTIME_REVISION := 7\n", 7), ("const RUNTIME_REVISION: int = 8\n", 8), ("const RUNTIME_REVISION = 9\n", 9)):
            write(os.path.join(self.t, "scripts", "boot", "ota_config.gd"), CONFIG_GD.replace("const RUNTIME_REVISION := 1\n", text))
            self.assertEqual(self.ident()["runtime_revision"], rev, text)
        cfg = os.path.join(self.t, "scripts", "boot", "ota_config.gd")
        for label, body in (("duplicate", CONFIG_GD + "const RUNTIME_REVISION := 2\n"), ("missing", CONFIG_GD.replace("const RUNTIME_REVISION := 1\n", "")),
                            ("zero", CONFIG_GD.replace(":= 1", ":= 0")), ("text", CONFIG_GD.replace(":= 1", ':= "x"'))):
            write(cfg, body)
            r = self.rt("--print", "--json")
            self.assertEqual(r.returncode, 2, label)
            self.assertIn("RUNTIME_REVISION", r.stderr, label)

    def test_channel_constant(self):
        cfg = os.path.join(self.t, "scripts", "boot", "ota_config.gd")
        write(cfg, CONFIG_GD.replace('"dev"', '"Bad Channel"'))
        r = self.rt("--print", "--json")
        self.assertEqual(r.returncode, 2)
        self.assertIn("not a valid channel", r.stderr)

    def test_missing_pieces_fail_with_a_hint(self):
        r = self.rt("--check")
        self.assertEqual(r.returncode, 2)
        self.assertIn("--relock", r.stderr)
        os.remove(os.path.join(self.t, "scripts", "boot", "ota_config.gd"))
        r = self.rt("--print")
        self.assertEqual(r.returncode, 2)
        self.assertIn("ota_config.gd", r.stderr)

    def test_provisional_lock_is_refused(self):
        os.remove(os.path.join(self.t, "scripts", "boot", "ota_config.gd"))
        os.remove(os.path.join(self.t, "scripts", "boot", "ota_core.gd"))
        r = self.rt("--relock")
        self.assertEqual(r.returncode, 2, "a plain relock needs every native input")
        r = self.rt("--relock", "--provisional", "--revision", "1")
        self.assertEqual(r.returncode, 0, out(r))
        lock = jload(os.path.join(self.t, "ota", "runtime_lock.json"))
        self.assertTrue(lock["provisional"])
        self.assertEqual(lock["missing"], ["scripts/boot/*.gd"])
        r = self.rt("--check")
        self.assertEqual(r.returncode, 1)
        self.assertIn("provisional", r.stdout)
        write(os.path.join(self.t, "scripts", "boot", "ota_config.gd"), CONFIG_GD)
        write(os.path.join(self.t, "scripts", "boot", "ota_core.gd"), "extends RefCounted\n")
        self.assertEqual(self.rt("--relock").returncode, 0)
        self.assertEqual(self.rt("--check").returncode, 0)
        self.assertNotIn("provisional", jload(os.path.join(self.t, "ota", "runtime_lock.json")))

    def test_deterministic(self):
        a = self.ident()["runtime_fingerprint"]
        t2 = self.p("tree2")
        make_runtime_tree(t2)
        self.assertEqual(self.ident(t2)["runtime_fingerprint"], a, "the fingerprint depends on content only, not on the checkout path")

    def test_committed_lock_matches_the_tree(self):
        """The repository's own lock: provisional until the native layer exists, then --check must pass."""
        cfg = os.path.join(ROOT, "scripts", "boot", "ota_config.gd")
        lock = jload(os.path.join(ROOT, "ota", "runtime_lock.json"))
        if not os.path.isfile(cfg):
            notice("scripts/boot/ota_config.gd does not exist yet (native layer not merged): the committed lock is provisional")
            self.assertTrue(lock.get("provisional"), "without the native layer the committed lock must say it is provisional")
            self.assertEqual(tool("ota_runtime.py", "--check", base=TOOLS).returncode, 1, "a provisional lock never passes the gate")
            return
        r = tool("ota_runtime.py", "--check", base=TOOLS)
        self.assertEqual(r.returncode, 0, "ota/runtime_lock.json is stale: run `python3 tools/ota_runtime.py --relock` (pre-release) or --bump\n" + out(r))
        self.assertNotIn("provisional", lock)


# ------------------------------------------------------------------------------------------------ classify

class TestClassify(TmpCase):
    FILES = {"project.godot": "a", "export_presets.cfg": "p", "VERSION": "7\n", "scripts/enemy.gd": "1", "scripts/boot/ota_core.gd": "c",
             "scripts/boot/ota_config.gd": "k", "tools/android/build_apk.sh": "b", "scripts/save_manager.gd": "s", "docs/a.md": "d",
             "data/x.json": "{}", "android/build.gradle": "g", ".github/workflows/ci.yml": CI_YML, "tests/t.gd": "t", "README.md": "r"}

    def setUp(self):
        super().setUp()
        self.repo = self.p("repo")
        for f, c in self.FILES.items():
            write(os.path.join(self.repo, f), c)
        shutil.copytree(os.path.join(ROOT, "ota"), os.path.join(self.repo, "ota"), ignore=shutil.ignore_patterns("runtime_lock.json"))
        self.git(self.repo, "init", "-q")
        self.base = self.commit(self.repo, "base")

    def classify(self, *args):
        return tool("classify.py", self.base, "HEAD", "--repo", self.repo, *args)

    def paths(self):
        j = json.loads(self.classify("--json").stdout)
        return {e["path"]: e for e in j["entries"]}, j

    def change(self, path, content="changed"):
        write(os.path.join(self.repo, path), content)
        self.commit(self.repo, "change " + path)

    def test_safe_change(self):
        self.change("scripts/enemy.gd")
        self.change("data/new.json", "{}")
        r = self.classify()
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("RESULT: OTA-safe", r.stdout)

    def test_nothing_shipped(self):
        self.change("docs/a.md")
        self.change("tests/t.gd")
        self.change(".github/workflows/other.yml", "x: 1\n")
        self.change("README.md")
        r = self.classify()
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("nothing that ships changed", r.stdout)

    def test_every_native_input_is_apk_required_with_the_reason(self):
        for path in ("project.godot", "export_presets.cfg", "scripts/boot/ota_core.gd", "scripts/boot/ota_config.gd", "scripts/boot/new_file.gd",
                     "tools/android/build_apk.sh"):
            with self.subTest(path=path):
                self.git(self.repo, "reset", "-q", "--hard", self.base)
                self.change(path, "different")
                r = self.classify()
                self.assertEqual(r.returncode, 10, out(r))
                self.assertIn("runtime fingerprint would change", r.stdout)
                self.assertIn(path, r.stdout)
                self.assertIn("APK REQUIRED", r.stdout)

    def test_engine_version_bump_is_apk_required(self):
        self.change(".github/workflows/ci.yml", CI_YML.replace("4.6-stable", "4.7-stable"))
        r = self.classify()
        self.assertEqual(r.returncode, 10, out(r))
        self.assertIn("engine version 4.6 -> 4.7", r.stdout)
        self.assertIn("runtime fingerprint would change", r.stdout)

    def test_other_ci_edits_are_not_shipped(self):
        self.change(".github/workflows/ci.yml", CI_YML + "# a comment\njobs: {}\n")
        self.assertEqual(self.classify().returncode, 0)

    def test_protected_and_boundary_edits(self):
        for path in ("VERSION", "android/build.gradle", "ota/boundary.json", "ota/runtime_lock.json", "libx/y.gdextension"):
            with self.subTest(path=path):
                self.git(self.repo, "reset", "-q", "--hard", self.base)
                self.change(path, "9\n")
                r = self.classify()
                self.assertEqual(r.returncode, 10, out(r))
                self.assertIn(path, r.stdout)

    def test_the_head_cannot_weaken_its_own_gate(self):
        """The boundary of the BASE decides: a commit that deletes a protection and the protected file together is still refused."""
        b = jload(os.path.join(self.repo, "ota", "boundary.json"))
        b["native_inputs"] = ["export_presets.cfg"]
        b["payload_protected"]["prefixes"] = ["android/"]
        write(os.path.join(self.repo, "ota", "boundary.json"), json.dumps(b))
        self.change("scripts/boot/ota_core.gd", "different")
        r = self.classify()
        self.assertEqual(r.returncode, 10, out(r))
        self.assertIn("ota/boundary.json", r.stdout)
        self.assertIn("scripts/boot/ota_core.gd", r.stdout)
        self.assertIn("base", json.loads(self.classify("--json").stdout)["boundary"])

    def test_base_without_a_boundary_uses_the_working_tree_file(self):
        self.git(self.repo, "rm", "-q", "-r", "ota")
        self.base = self.commit(self.repo, "no boundary at the base")
        self.change("scripts/enemy.gd")
        r = self.classify()
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("working tree", json.loads(self.classify("--json").stdout)["boundary"])

    def test_guarded(self):
        self.change("scripts/save_manager.gd")
        r = self.classify()
        self.assertEqual(r.returncode, 11, out(r))
        self.assertIn("--accept-guarded", r.stdout)
        r = self.classify("--accept-guarded", "schema unchanged")
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("guarded paths accepted: schema unchanged", r.stdout)
        self.change("project.godot")
        r = self.classify("--accept-guarded", "x")
        self.assertEqual(r.returncode, 10, "APK-required beats an accepted guard")

    def test_delete_and_rename(self):
        os.remove(os.path.join(self.repo, "scripts", "boot", "ota_core.gd"))
        self.commit(self.repo, "delete native")
        r = self.classify()
        self.assertEqual(r.returncode, 10, out(r))
        self.assertIn("D  scripts/boot/ota_core.gd", r.stdout)
        self.git(self.repo, "reset", "-q", "--hard", self.base)
        self.git(self.repo, "mv", "scripts/boot/ota_core.gd", "scripts/core_moved.gd")
        self.commit(self.repo, "rename out of the native dir")
        paths, j = self.paths()
        self.assertEqual(j["exit_code"], 10)
        self.assertEqual(paths["scripts/boot/ota_core.gd"]["category"], "apk_required", "the OLD name disappears from the native layer")
        self.assertEqual(paths["scripts/core_moved.gd"]["category"], "safe")
        self.git(self.repo, "reset", "-q", "--hard", self.base)
        self.git(self.repo, "mv", "scripts/enemy.gd", "scripts/enemy2.gd")
        os.remove(os.path.join(self.repo, "data", "x.json"))
        self.commit(self.repo, "safe rename + delete")
        self.assertEqual(self.classify().returncode, 0)

    def test_json_output_and_errors(self):
        self.change("scripts/enemy.gd")
        paths, j = self.paths()
        self.assertEqual((j["result"], j["exit_code"], j["counts"]["safe"]), ("ota_safe", 0, 1))
        self.assertEqual(j["base_sha"], self.base)
        r = tool("classify.py", "no-such-ref", "HEAD", "--repo", self.repo)
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

    def test_removal_sample(self):
        patch, base = pcklib.read_pck(self.fx("remove_patch.pck")), pcklib.read_pck(self.fx("remove_base.pck"))
        self.assertEqual(pcklib.ops(patch, base), [("data/new.json", "add"), ("data/probe.json", "remove")])
        rm = patch.by_path["data/probe.json"]
        self.assertTrue(rm.removal)
        self.assertEqual((rm.size, rm.md5, rm.flags), (0, "0" * 32, 2))
        self.assertEqual(pcklib.verify_entries(patch), [])
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
include_filter="build_info.json"
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


# ------------------------------------------------------------------------------------------------ payload_check

class TestPayloadCheck(TmpCase):
    BASE = {"scripts/a.gdc": b"A1", "scripts/b.gdc": b"B1", "data/c.json": b"C1", "project.binary": b"PB", "scripts/boot/ota_core.gdc": b"CORE",
            "scripts/save_manager.gdc": b"S1", "godot/imported/t.ctex": b"IMG"}

    def setUp(self):
        super().setUp()
        self.rules = otalib.load_boundary()
        self.base = pck_of(self.p("base.pck"), self.BASE)

    def check(self, files, accept="", rules=None):
        patch = pck_of(self.p("patch.pck"), files)
        return payload_check.check(patch, self.base, rules or self.rules, accept)

    def refused(self, files, needle, **kw):
        with self.assertRaises(otalib.OtaError) as cm:
            self.check(files, **kw)
        self.assertIn(needle, str(cm.exception))

    def test_ok_ops_and_report(self):
        files, report = self.check({"scripts/a.gdc": b"A2", "data/d.json": b"D1", "scripts/b.gdc": None})
        self.assertEqual(files, [{"path": "data/d.json", "op": "add"}, {"path": "scripts/a.gdc", "op": "replace"},
                                 {"path": "scripts/b.gdc", "op": "remove"}])
        self.assertEqual(report["ops"], {"add": 1, "replace": 1, "remove": 1})
        self.assertEqual(report["file_count"], 3)
        self.assertFalse(report["git_host_guard_exceeded"])
        self.assertEqual(report["payload_sha256"], otalib.sha256_file(self.p("patch.pck")))

    def test_protected_paths_are_refused_including_removals(self):
        for path in ("project.binary", "scripts/boot/ota_core.gdc", "scripts/boot/new.gdc", "build_info.json", "VERSION", "lib/x.so",
                     "addons/x.gdextension", "android/x"):
            self.refused({path: b"x", "scripts/a.gdc": b"A2"}, "cannot ship over the air")
        self.refused({"project.binary": None}, "project.binary")
        self.refused({"scripts/boot/ota_core.gdc": None}, "scripts/boot/ota_core.gdc")

    def test_escaping_paths(self):
        for path in ("../evil", "/abs/x", "user://x", "a//b"):
            self.refused({path: b"x"}, path)

    def test_guarded_needs_a_reason(self):
        self.refused({"scripts/save_manager.gdc": b"S2"}, "--accept-guarded")
        files, report = self.check({"scripts/save_manager.gdc": b"S2"}, accept="format unchanged")
        self.assertEqual(report["guarded_accepted"], "format unchanged")

    def test_empty_delta_and_missing_base_entries(self):
        self.refused({}, "empty")
        patch = write(self.p("delta.pck"), make_pck([("scripts/a.gdc", b"x", pcklib.FILE_DELTA)]))
        with self.assertRaises(otalib.OtaError) as cm:
            payload_check.check(patch, self.base, self.rules)
        self.assertIn("DELTA", str(cm.exception))
        self.refused({"nope.gdc": None}, "does not contain")

    def test_corrupt_pack(self):
        patch = pck_of(self.p("patch.pck"), {"scripts/a.gdc": b"A2"})
        raw = bytearray(rb(patch))
        raw[0x70] ^= 0xFF
        write(patch, bytes(raw))
        with self.assertRaises(otalib.OtaError) as cm:
            payload_check.check(patch, self.base, self.rules)
        self.assertIn("md5", str(cm.exception))
        with self.assertRaises(otalib.OtaError):
            payload_check.check(write(self.p("junk.pck"), b"nope"), self.base, self.rules)

    def test_size_limit_and_git_host_guard(self):
        small = dict(self.rules, max_payload_bytes=1000, warn_payload_bytes=300)
        _, report = self.check({"data/big.json": os.urandom(400)}, rules=small)
        self.assertTrue(report["git_host_guard_exceeded"], "over the 95 MiB guard (here 300 B) is flagged but allowed")
        self.refused({"data/big.json": os.urandom(2000)}, "byte limit", rules=small)

    def test_cli(self):
        patch = pck_of(self.p("patch.pck"), {"scripts/a.gdc": b"A2"})
        r = tool("payload_check.py", patch, "--base", self.base, "--files-out", self.p("files.json"), "--report-out", self.p("rep.json"))
        self.assertEqual(r.returncode, 0, out(r))
        self.assertEqual(jload(self.p("files.json")), [{"op": "replace", "path": "scripts/a.gdc"}])
        self.assertEqual(jload(self.p("rep.json"))["file_count"], 1)
        bad = pck_of(self.p("bad.pck"), {"project.binary": b"x"})
        r = tool("payload_check.py", bad, "--base", self.base, "--files-out", self.p("f2.json"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("REFUSED", r.stderr)
        self.assertFalse(os.path.exists(self.p("f2.json")), "no files.json for a refused payload")


# ------------------------------------------------------------------------------------------------ native check

class TestNativeCheck(TmpCase):
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

    @staticmethod
    def sparse_pck(files, flags=6):
        """A Godot 4.5+/4.6 sparse-bundle directory (assets/assets.sparsepck of the gradle export): header flags 6, file_base 0, offsets 0,
        no data - only path, size and md5 of files that live loose beside it."""
        hdr = struct.pack("<4sIIIIIQQ", b"GDPC", 3, 4, 6, 0, flags, 0, 104)
        hdr += b"\0" * (104 - len(hdr))
        d = bytearray(struct.pack("<I", len(files)))
        for path, data in files.items():
            raw = path.encode()
            raw += b"\0" * (-len(raw) % 4)
            d += struct.pack("<I", len(raw)) + raw + struct.pack("<QQ", 0, len(data)) + hashlib.md5(data).digest() + struct.pack("<I", 0)
        return bytes(hdr + d)

    def sparse_apk(self, files, listed=None, loose=None):
        apk = self.p("sparse.apk")
        with zipfile.ZipFile(apk, "w") as z:
            z.writestr("classes.dex", b"dex")
            z.writestr("assets/dexopt/baseline.prof", b"prof" * 40)
            z.writestr("assets/_cl_", b"x" * 120)
            z.writestr("assets/assets.sparsepck", self.sparse_pck(listed if listed is not None else files))
            for path, data in (loose if loose is not None else files).items():
                z.writestr("assets/" + path, data)
        return apk

    def test_android_sparse_bundle_layout(self):
        """Godot 4.6's gradle export: loose files under assets/ plus assets/assets.sparsepck, a directory with the files' md5s."""
        files = {"scripts/a.gdc": b"A1", "godot/imported/t.ctex": b"IMG", "build_info.json": b'{"apk":1}', "data/c.json": b"C1"}
        base = pck_of(self.p("base.pck"), dict(files, **{"build_info.json": b"{}"}))
        apk = self.sparse_apk(files)
        r = self.check("compare", "--platform", "android", "--base-pck", base, "--native", apk, "--allow", "build_info.json")
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("sparse-bundle directory of 4 files", r.stdout)
        self.assertNotIn("dexopt", r.stdout, "files outside the sparse directory are not part of the game")
        self.assertNotIn("_cl_", r.stdout)
        r = self.check("extract", "--platform", "android", "--native", apk, "--path", "build_info.json", "--out", self.p("bi.json"))
        self.assertEqual(r.returncode, 0, out(r))
        self.assertEqual(rb(self.p("bi.json")), b'{"apk":1}')
        # a different script is an error, a different import product is tolerated by prefix
        changed = dict(files, **{"scripts/a.gdc": b"A2", "godot/imported/t.ctex": b"IMG2"})
        apk = self.sparse_apk(changed)
        r = self.check("compare", "--platform", "android", "--base-pck", base, "--native", apk, "--allow", "build_info.json",
                       "--tolerate", "godot/imported/")
        self.assertEqual(r.returncode, 1)
        self.assertIn("content differs from the native build: scripts/a.gdc", r.stdout)
        self.assertNotIn("content differs from the native build: godot/imported", r.stdout)
        self.assertIn("1 byte-different but tolerated import product", r.stdout)
        # a game file listed in the directory but absent from the APK
        apk = self.sparse_apk(files, loose={k: v for k, v in files.items() if k != "data/c.json"})
        r = self.check("compare", "--platform", "android", "--base-pck", base, "--native", apk, "--allow", "build_info.json")
        self.assertEqual(r.returncode, 1)
        self.assertIn("contradicts its own sparse directory", r.stderr)
        # an asset the directory does not list is not a game file
        apk = self.sparse_apk(files, loose=dict(files, **{"extra.txt": b"x"}))
        r = self.check("compare", "--platform", "android", "--base-pck", base, "--native", apk, "--allow", "build_info.json")
        self.assertEqual(r.returncode, 0, out(r))
        self.assertNotIn("extra.txt", r.stdout)
        # the APK's bytes contradict the directory's md5
        apk = self.sparse_apk(files, listed=dict(files, **{"scripts/a.gdc": b"A9"}))
        r = self.check("compare", "--platform", "android", "--base-pck", base, "--native", apk, "--allow", "build_info.json")
        self.assertEqual(r.returncode, 1)
        self.assertIn("md5 differs from its sparse directory entry", r.stderr)

    def test_a_sparse_pack_is_never_a_payload_or_base(self):
        sp = write(self.p("assets.sparsepck"), self.sparse_pck({"a": b"1"}))
        with self.assertRaises(pcklib.PckError) as cm:
            pcklib.read_pck(sp)
        self.assertIn("sparse-bundle", str(cm.exception))
        pk = pcklib.read_pck(sp, allow_sparse=True)
        self.assertTrue(pk.sparse)
        self.assertEqual([(e.path, e.size) for e in pk.entries], [("a", 1)])
        with self.assertRaises(pcklib.PckError):
            pcklib.read_entry(pk, pk.entries[0])
        self.assertEqual(tool("payload_check.py", sp, "--base", pck_of(self.p("b.pck"), {"a": b"0"}), "--files-out", self.p("f.json")).returncode, 1)
        write(self.p("unknown.pck"), self.sparse_pck({"a": b"1"}, flags=0x16))
        with self.assertRaises(pcklib.PckError):
            pcklib.read_pck(self.p("unknown.pck"), allow_sparse=True)

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


# ------------------------------------------------------------------------------------------------ manifest maker + inspector (Godot)

class TestManifestTools(unittest.TestCase):
    """tools/ota_make_manifest.gd and tools/ota_inspect_pack.gd in a tiny project that holds the client's own scripts: the REAL
    scripts/boot when the tree has them, the tests/ota_standin stand-in otherwise (printed as a NOTICE)."""

    @classmethod
    def setUpClass(cls):
        cls.godot = godot_bin()
        if not cls.godot:
            notice("Godot 4.6 not found ($GODOT): skipping the manifest maker / inspector tests")
            raise unittest.SkipTest("no godot")
        cls.real_core = os.path.isfile(os.path.join(ROOT, "scripts", "boot", "ota_core.gd")) and not os.environ.get("OTA_TEST_STANDIN")
        if not cls.real_core:
            notice("scripts/boot/ota_core.gd does not exist yet: the manifest tools run against the tests/ota_standin stand-in client")
        cls.tmp = tempfile.mkdtemp(prefix="ota-manifest-")
        cls.proj = os.path.join(cls.tmp, "proj")
        tool_project.assemble(cls.proj, ROOT, standin=True, prefer_standin=bool(os.environ.get("OTA_TEST_STANDIN")))
        write(os.path.join(cls.proj, "print_rt.gd"),
              'extends SceneTree\nfunc _init():\n\tvar cfg: Script = load("res://scripts/boot/ota_config.gd")\n'
              '\tprint("RUNTIME_ID=", cfg.runtime_id("android"))\n\tprint("CHANNEL=", cfg.get_script_constant_map().get("CHANNEL", ""))\n\tquit()\n')
        tool_project.import_project(cls.godot, cls.proj)
        r = subprocess.run([cls.godot, "--headless", "--path", cls.proj, "-s", "res://print_rt.gd"], capture_output=True, text=True, timeout=120)
        m = re.search(r"^RUNTIME_ID=(.+)$", r.stdout, re.M)
        assert m, "cannot read the runtime id from ota_config.gd: " + r.stdout + r.stderr
        cls.rid = m.group(1).strip()
        cls.channel = re.search(r"^CHANNEL=(.*)$", r.stdout, re.M).group(1).strip() or "dev"
        cls.version = int(rt(os.path.join(ROOT, "VERSION")).strip())
        cls.key = os.path.join(cls.tmp, "a.pem")
        cls.pub = genkey(cls.key)
        cls.key_b = os.path.join(cls.tmp, "b.pem")
        cls.pub_b = genkey(cls.key_b)
        cls.bi = write(os.path.join(cls.tmp, "build_info.json"), json.dumps({
            "product": "Purgatory Dungeon", "public_version": cls.version, "release": True, "commit": BASE40, "ci_run": "1",
            "built_utc": "2026-10-05T00:00:00Z", "runtime_id": cls.rid, "runtime_fingerprint": FP64, "ota_channel": cls.channel}))
        base = {"scripts/a.gdc": b"A1", "scripts/b.gdc": b"B1", "data/c.json": b"C1", "project.binary": b"PB", "scripts/boot/ota_core.gdc": b"CORE"}
        cls.base_pck = pck_of(os.path.join(cls.tmp, "base.pck"), base)
        cls.patch = pck_of(os.path.join(cls.tmp, "patch.pck"), {"scripts/a.gdc": b"A2" * 50, "data/d.json": b"D1", "scripts/b.gdc": None})
        files, _ = payload_check.check(cls.patch, cls.base_pck, otalib.load_boundary())
        cls.files = write(os.path.join(cls.tmp, "files.json"), otalib.canonical_json(files))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(getattr(cls, "tmp", ""), True)

    def setUp(self):
        self.work = tempfile.mkdtemp(prefix="case-", dir=self.tmp)

    def w(self, name):
        return os.path.join(self.work, name)

    def gd(self, script, **args):
        cmd = [self.godot, "--headless", "--path", self.proj, "-s", "res://tools/" + script, "--"] + [f"{k}={v}" for k, v in args.items()]
        return subprocess.run(cmd, capture_output=True, text=True, timeout=300)

    def mm(self, **over):
        a = {"pck": self.patch, "out": self.w("manifest.json"), "seq": 3, "app_minor": 2, "sha": SRC40, "files": self.files, "build_info": self.bi,
             "url": "https://github.com/o/r/releases/download/ota-dev-000003/purgatory-dev-000003.pck", "platform": "android",
             "created_at": "2026-10-06T00:00:00Z", "run_id": "11", "run_number": "12", "run_attempt": "1", "run_url": "https://example.test/run/11"}
        a.update({k: v for k, v in over.items() if v is not None})
        for k in [k for k, v in over.items() if v is None]:
            a.pop(k, None)
        return self.gd("ota_make_manifest.gd", **a)

    def sign(self, manifest=None, sig=None, key=None):
        manifest, sig = manifest or self.w("manifest.json"), sig or self.w("manifest.json.sig")
        otalib.sign_to_file(key or self.key, manifest, sig)
        return sig

    def inspect(self, manifest=None, sig=None, pck=None, **over):
        a = {"manifest": manifest or self.w("manifest.json"), "sig": sig or self.w("manifest.json.sig"), "pck": pck or self.patch,
             "build_info": self.bi, "files": self.files, "pubkey": self.pub, "platform": "android", "expect_source_sha": SRC40, "expect_minor": 2}
        a.update({k: v for k, v in over.items() if v is not None})
        for k in [k for k, v in over.items() if v is None]:
            a.pop(k, None)
        return self.gd("ota_inspect_pack.gd", **a)

    def good(self):
        r = self.mm()
        self.assertIn("MANIFEST OK", r.stdout, out(r))
        self.sign()
        return jload(self.w("manifest.json"))

    def forge(self, edit, key=None):
        """A manifest changed in one way and signed by a real key, so the inspector's own checks are what is under test."""
        m = self.good()
        edit(m)
        write(self.w("manifest.json"), otalib.canonical_json(m))
        self.sign(key=key)

    def failed(self, r, pattern):
        self.assertIn("INSPECT FAILED", r.stdout, out(r))
        self.assertNotEqual(r.returncode, 0)
        self.assertRegex(r.stdout, pattern, out(r))

    # --- the maker
    def test_manifest_content(self):
        m = self.good()
        self.assertEqual(m["schema"], 1)
        self.assertEqual((m["channel"], m["ota_id"], m["seq"]), (self.channel, f"{self.channel}-000003", 3))
        self.assertEqual((m["source_sha"], m["base_source_sha"]), (SRC40, BASE40))
        self.assertEqual((m["runtime_id"], m["runtime_fingerprint"]), (self.rid, FP64))
        self.assertEqual((m["seq"], m["app_minor"]), (3, 2), "seq is the internal channel sequence, app_minor the owner-facing minor")
        self.assertEqual(m["game_version"], f"{self.version}.2", "game_version = <native_version>.<app_minor>, two parts, never derived from seq")
        self.assertRegex(m["game_version"], r"^\d+\.\d+$")
        self.assertEqual((m["native_version"], m["platform"], m["payload_kind"]), (self.version, "android", "patch"))
        self.assertEqual(m["pck_size"], os.path.getsize(self.patch))
        self.assertEqual(m["pck_sha256"], otalib.sha256_file(self.patch))
        self.assertIsInstance(m["minimum_bootstrap_version"], int)
        self.assertIsInstance(m["save_schema"], int)
        self.assertIsInstance(m["min_save_schema"], int)
        self.assertEqual(m["created_at"], "2026-10-06T00:00:00Z")
        self.assertEqual(m["build_run"], {"id": "11", "number": "12", "attempt": "1", "url": "https://example.test/run/11"})
        self.assertEqual(m["files"], [{"op": "add", "path": "data/d.json"}, {"op": "replace", "path": "scripts/a.gdc"}, {"op": "remove", "path": "scripts/b.gdc"}])
        self.assertEqual(set(m), {"schema", "channel", "ota_id", "seq", "source_sha", "runtime_id", "runtime_fingerprint", "minimum_bootstrap_version",
                                  "game_version", "app_minor", "save_schema", "min_save_schema", "pck_url", "pck_sha256", "pck_size", "created_at", "build_run",
                                  "payload_kind", "base_source_sha", "platform", "native_version", "files"}, "exactly the fields of docs/OTA.md section 5")

    def test_manifest_is_deterministic_and_sorted(self):
        self.mm()
        a = rb(self.w("manifest.json"))
        shutil.copyfile(self.w("manifest.json"), self.w("first.json"))
        os.remove(self.w("manifest.json"))
        self.mm()
        self.assertEqual(rb(self.w("manifest.json")), a, "same inputs and created_at -> same bytes")
        self.assertTrue(a.endswith(b"}\n"))
        keys = re.findall(r'^  "([a-z_0-9]+)":', a.decode(), re.M)
        self.assertEqual(keys, sorted(keys), "top-level keys are sorted")
        unsorted = write(self.w("unsorted.json"), json.dumps([{"path": "z.gdc", "op": "add"}, {"path": "a.gdc", "op": "replace"}]))
        self.assertIn("MANIFEST OK", self.mm(files=unsorted, out=self.w("m2.json")).stdout)
        self.assertEqual([f["path"] for f in jload(self.w("m2.json"))["files"]], ["a.gdc", "z.gdc"])

    def test_identity_from_arguments_instead_of_build_info(self):
        r = self.mm(build_info=None, runtime_id=self.rid, runtime_fingerprint=FP64, base_sha=BASE40, native_version=self.version, channel=self.channel)
        self.assertIn("MANIFEST OK", r.stdout, out(r))

    def test_maker_refusals(self):
        cases = [
            ("contradicts", dict(runtime_id="android-godot-4.6.0-r99")),
            ("contradicts", dict(runtime_fingerprint="0" * 64)),
            ("contradicts", dict(channel="stable")),
            ("contradicts", dict(base_sha=OTHER40)),
            ("40-hex", dict(sha="xyz")),
            ("files=", dict(files=self.w("missing.json"))),
            ("https", dict(url="http://example.com/x.pck")),
            ("positive integer", dict(seq=0)),
            ("app_minor", dict(app_minor=0)),
            ("app_minor", dict(app_minor="x")),
            ("app_minor", dict(app_minor="1.5")),
            ("missing argument", dict(app_minor=None)),
            ("not found", dict(pck=self.w("missing.pck"))),
            ("unknown: pass build_info", dict(build_info=None)),
            ("missing argument", dict(out="")),
        ]
        for needle, over in cases:
            with self.subTest(over=over):
                r = self.mm(**over)
                self.assertIn("MANIFEST FAIL", r.stdout, out(r))
                self.assertNotEqual(r.returncode, 0)
                self.assertIn(needle, r.stdout)
        for label, content in (("empty", "[]"), ("unknown op", '[{"path":"a","op":"rename"}]'), ("duplicate", '[{"path":"a","op":"add"},{"path":"a","op":"add"}]'),
                               ("not an array", '{"a":1}'), ("no op", '[{"path":"a"}]')):
            r = self.mm(files=write(self.w("f.json"), content), out=self.w("m3.json"))
            self.assertIn("MANIFEST FAIL", r.stdout, label)
        bad_bi = write(self.w("bi.json"), json.dumps(dict(jload(self.bi), runtime_id="android-godot-4.6.0-r99")))
        r = self.mm(build_info=bad_bi)
        self.assertIn("MANIFEST FAIL", r.stdout)
        self.assertIn("differs from the one this tree computes", r.stdout, "the baseline must agree with ota_config.gd")

    # --- the inspector
    def test_round_trip_is_accepted(self):
        self.good()
        r = self.inspect()
        self.assertIn("INSPECT OK", r.stdout, out(r))
        self.assertEqual(r.returncode, 0)
        self.assertIn(f"ota_id={self.channel}-000003", r.stdout)

    def test_self_identity_mode(self):
        self.good()
        r = self.inspect(build_info=None, self_identity="1")
        self.assertIn("INSPECT OK", r.stdout, out(r))
        r = self.inspect(build_info=None)
        self.failed(r, r"device identity unknown")

    def test_bad_signatures(self):
        self.good()
        raw = bytearray(base64.b64decode(rb(self.w("manifest.json.sig"))))
        raw[7] ^= 0xFF
        write(self.w("flipped.sig"), base64.b64encode(bytes(raw)))
        self.failed(self.inspect(sig=self.w("flipped.sig")), r"(?i)signature")
        write(self.w("junk.sig"), b"!!!not base64!!!")
        self.failed(self.inspect(sig=self.w("junk.sig")), r"(?i)signature")
        write(self.w("empty.sig"), b"")
        self.failed(self.inspect(sig=self.w("empty.sig")), r"(?i)signature")
        self.failed(self.inspect(pubkey=self.pub_b), r"(?i)signature")
        self.sign(key=self.key_b)
        self.failed(self.inspect(), r"(?i)signature")

    def test_tampered_manifest_after_signing(self):
        self.good()
        raw = bytearray(rb(self.w("manifest.json")))
        i = raw.index(b'"seq": 3')
        raw[i + 7] = ord("4")
        write(self.w("manifest.json"), bytes(raw))
        self.failed(self.inspect(), r"(?i)signature")

    def test_wrong_hash_or_size_of_the_package(self):
        self.good()
        raw = bytearray(rb(self.patch))
        raw[0x70] ^= 0xFF
        flipped = write(self.w("flipped.pck"), bytes(raw))
        self.failed(self.inspect(pck=flipped), r"(?i)sha-?256|hash")
        self.failed(self.inspect(pck=write(self.w("short.pck"), rb(self.patch)[:-16])), r"(?i)size")
        self.failed(self.inspect(pck=write(self.w("long.pck"), rb(self.patch) + b"\0" * 16)), r"(?i)size")
        self.forge(lambda m: m.update(pck_size=m["pck_size"] + 1))
        self.failed(self.inspect(), r"(?i)size")
        self.forge(lambda m: m.update(pck_sha256="0" * 64))
        self.failed(self.inspect(), r"(?i)sha-?256|hash")

    def test_wrong_runtime_fingerprint_channel_or_base(self):
        self.good()
        for label, bi_edit, pattern in (("runtime", {"runtime_id": "android-godot-4.6.0-r77"}, r"(?i)runtime"),
                                        ("fingerprint", {"runtime_fingerprint": "cd" * 32}, r"(?i)fingerprint"),
                                        ("channel", {"ota_channel": "stable"}, r"(?i)channel"),
                                        ("base", {"commit": OTHER40}, r"(?i)base")):
            bi = write(self.w(f"bi-{label}.json"), json.dumps(dict(jload(self.bi), **bi_edit)))
            self.failed(self.inspect(build_info=bi), pattern)
        self.forge(lambda m: m.update(runtime_id="android-godot-4.6.0-r77"))
        self.failed(self.inspect(), r"(?i)runtime")
        self.forge(lambda m: m.update(runtime_fingerprint="cd" * 32))
        self.failed(self.inspect(), r"(?i)fingerprint")
        self.forge(lambda m: m.update(base_source_sha=OTHER40))
        self.failed(self.inspect(), r"(?i)base")
        self.forge(lambda m: m.update(channel="stable", ota_id="stable-000003"))
        self.failed(self.inspect(), r"(?i)channel")

    def test_protected_paths_are_flagged(self):
        evil = pck_of(self.w("evil.pck"), {"scripts/a.gdc": b"A2", "scripts/boot/ota_core.gdc": b"EVIL", "project.binary": b"PB2"})
        files = write(self.w("evil.json"), json.dumps([{"path": "project.binary", "op": "add"}, {"path": "scripts/a.gdc", "op": "add"},
                                                       {"path": "scripts/boot/ota_core.gdc", "op": "add"}]))
        r = self.mm(pck=evil, files=files, out=self.w("evil-manifest.json"))
        self.assertIn("MANIFEST OK", r.stdout, "the maker builds what it is given; the inspector is the gate")
        self.sign(self.w("evil-manifest.json"), self.w("evil.sig"))
        r = self.inspect(manifest=self.w("evil-manifest.json"), sig=self.w("evil.sig"), pck=evil, files=files)
        self.failed(r, r"pack path scripts/boot/ota_core\.gdc: protected")
        self.assertRegex(r.stdout, r"pack path project\.binary: protected")
        for p in ("../x.gdc", "user://x.gdc"):
            esc = pck_of(self.w("esc.pck"), {p: b"x"})
            files = write(self.w("esc.json"), json.dumps([{"path": p, "op": "add"}]))
            self.mm(pck=esc, files=files, out=self.w("esc-manifest.json"))
            self.sign(self.w("esc-manifest.json"), self.w("esc.sig"))
            self.failed(self.inspect(manifest=self.w("esc-manifest.json"), sig=self.w("esc.sig"), pck=esc, files=files), r"(?i)escape|illegal")

    def test_manifest_files_must_equal_the_pack_directory(self):
        self.forge(lambda m: m["files"].append({"path": "data/ghost.json", "op": "add"}))
        self.failed(self.inspect(files=None), r"lists data/ghost\.json which the pack does not contain")
        self.forge(lambda m: m["files"].pop())
        self.failed(self.inspect(files=None), r"the pack contains scripts/b\.gdc which files\[\] does not list")
        self.forge(lambda m: m["files"][2].update(op="replace"))   # the removal marker listed as a write
        self.failed(self.inspect(files=None), r"is not a removal marker|is a removal marker|says")
        self.good()
        other = write(self.w("other.json"), json.dumps([{"path": "scripts/a.gdc", "op": "replace"}]))
        self.failed(self.inspect(files=other), r"differs from files\.json")

    def test_game_version_and_source_identity(self):
        self.forge(lambda m: m.update(game_version="9.9.9"))
        self.failed(self.inspect(), r"game_version 9\.9\.9 is not <native_version>\.<app_minor>")
        self.forge(lambda m: m.update(game_version=f"{self.version}.3"))      # derived from seq instead of app_minor
        self.failed(self.inspect(), r"game_version .* is not <native_version>\.<app_minor>")
        self.forge(lambda m: m.update(game_version=f"{self.version}.2.0"))    # the old three-part form
        self.failed(self.inspect(), r"game_version .* is not <native_version>\.<app_minor>")
        self.forge(lambda m: m.update(native_version=self.version + 1, game_version=f"{self.version + 1}.2"))
        self.failed(self.inspect(build_info=None, self_identity=None, runtime_id=self.rid, runtime_fingerprint=FP64, base_sha=BASE40, channel=self.channel),
                    r"native_version \d+ != VERSION")
        self.forge(lambda m: m.update(payload_kind="full"))
        self.failed(self.inspect(), r"(?i)payload.?kind")
        self.forge(lambda m: m.update(platform="windows"))
        self.failed(self.inspect(), r"(?i)platform")
        self.good()
        self.failed(self.inspect(expect_source_sha=OTHER40), r"source_sha .* != the expected")
        self.forge(lambda m: m.update(save_schema=m["save_schema"] + 5))
        r = self.inspect()
        self.failed(r, r"save_schema")

    def test_app_minor_is_required_whole_and_checked_against_the_publisher(self):
        self.good()
        self.assertIn("INSPECT OK", self.inspect().stdout)
        self.failed(self.inspect(expect_minor=3), r"app_minor 2 != the expected 3")
        self.failed(self.inspect(expect_minor="x"), r"app_minor 2 != the expected x")
        self.forge(lambda m: m.pop("app_minor"))
        self.failed(self.inspect(expect_minor=None), r"app_minor must be a whole number")
        for bad in (0, -1, 1.5, "2", None, True):
            self.forge(lambda m, b=bad: m.update(app_minor=b, game_version=f"{self.version}.2"))
            self.failed(self.inspect(expect_minor=None), r"app_minor|game_version")
        self.forge(lambda m: m.update(app_minor=5, game_version=f"{self.version}.5"))
        self.assertIn("INSPECT OK", self.inspect(expect_minor=5).stdout, "any whole minor is fine as long as it is the one the publisher assigned")
        self.failed(self.inspect(expect_minor=2), r"app_minor 5 != the expected 2")

    def test_ota_id_must_match_channel_and_seq(self):
        self.forge(lambda m: m.update(ota_id="dev-000009"))
        self.failed(self.inspect(), r"(?i)ota_id")

    def test_missing_files_and_arguments(self):
        r = self.gd("ota_inspect_pack.gd", manifest=self.w("nope.json"), sig=self.w("nope.sig"), pck=self.patch, build_info=self.bi, pubkey=self.pub)
        self.failed(r, r"(?i)manifest .* missing or empty")
        r = self.gd("ota_inspect_pack.gd", manifest=self.w("nope.json"))
        self.failed(r, r"missing argument")
        self.good()
        self.failed(self.inspect(pck=self.w("nope.pck")), r"(?i)package|pack|unreadable|not a PCK|cannot open")

    def test_runtime_id_of_the_config_matches_ota_runtime_py(self):
        if not self.real_core:
            notice("no real scripts/boot yet: the cross-check of ota_config.runtime_id() against tools/ota_runtime.py waits for the merge")
            self.skipTest("stand-in core")
        tree = ota_runtime.Tree(ROOT)
        self.assertEqual(self.rid, tree.runtime_id("android"), "scripts/boot/ota_config.gd runtime_id() and tools/ota_runtime.py disagree")
        self.assertEqual(self.channel, tree.channel())


# ------------------------------------------------------------------------------------------------ publisher decisions

class TestPublishGates(TmpCase):
    # --- branch / identity
    def test_branch_parsing(self):
        sha = "a" * 40
        self.assertEqual(gates.parse_branch(f"ota/dev/{sha}", sha), ("dev", sha))
        self.assertEqual(gates.parse_branch(f"refs/heads/ota/stable/{sha}", sha), ("stable", sha))
        self.assertEqual(gates.parse_branch(f"ota/dev-2/{sha}", sha)[0], "dev-2")
        for ref in ("ota/dev/main", f"ota/dev/{'a' * 39}", f"ota/dev/{'a' * 41}", f"ota/dev/{'A' * 40}", f"ota/Dev/{sha}", f"ota//{sha}",
                    f"feature/ota/dev/{sha}", f"ota/dev/{sha}/extra", sha, "ota/dev", f"ota/channel/{sha}", f"ota/1dev/{sha}"):
            with self.assertRaises(otalib.OtaError, msg=ref):
                gates.parse_branch(ref, sha)
        with self.assertRaises(otalib.OtaError) as cm:
            gates.parse_branch(f"ota/dev/{sha}", "b" * 40)
        self.assertIn("head commit", str(cm.exception))
        for bad_sha in ("", "abc", "G" * 40):
            with self.assertRaises(otalib.OtaError):
                gates.parse_branch(f"ota/dev/{sha}", bad_sha)

    def test_sequence_numbers_are_never_reused(self):
        self.assertEqual(gates.next_seq([], "dev"), 1)
        self.assertEqual(gates.next_seq(["ota-dev-000001", "ota-dev-000002"], "dev"), 3)
        self.assertEqual(gates.next_seq(["ota-dev-000001", "ota-dev-000007"], "dev"), 8, "gaps are not refilled")
        self.assertEqual(gates.next_seq(["ota-dev-000009", "ota-dev-000002"], "dev"), 10, "order does not matter")
        self.assertEqual(gates.next_seq(["ota-stable-000050", "ota-channel-dev", "v7", "ota-dev-2-000044", "ota-dev-0000099", "ota-dev-000x01"], "dev"), 1,
                        "other channels, the pointer tag and malformed tags are ignored")
        self.assertEqual(gates.next_seq(["ota-dev-2-000044"], "dev-2"), 45)
        self.assertEqual(gates.next_seq(["ota-dev-000003\n", " ota-dev-000004 "], "dev"), 5, "whitespace around tags is tolerated")
        # a deleted release whose tag remains still counts because the caller passes every tag; a sequence never goes backwards
        seqs = []
        tags = []
        for _ in range(5):
            n = gates.next_seq(tags, "dev")
            self.assertNotIn(n, seqs)
            seqs.append(n)
            tags.append(gates.RELEASE_TAG.format(channel="dev", seq=n))
        self.assertEqual(seqs, [1, 2, 3, 4, 5])

    def test_native_base_tag_is_derived_from_version(self):
        self.assertEqual(gates.native_base_tag("7\n"), {"tag": "v7", "version": 7})
        self.assertEqual(gates.native_base_tag(" 12 ", ""), {"tag": "v12", "version": 12})
        self.assertEqual(gates.native_base_tag("7", "v7")["tag"], "v7", "an agreeing override is fine")
        self.assertEqual(gates.native_base_tag("7", "  ")["tag"], "v7", "an empty variable means not set")
        for bad_override in ("v6", "v8", "7", "V7", "v7.1", "latest"):
            with self.assertRaises(otalib.OtaError, msg=bad_override) as cm:
                gates.native_base_tag("7", bad_override)
            self.assertIn("OTA_NATIVE_BASE_TAG", str(cm.exception))
        for bad_version in ("", "0", "-1", "7.1", "v7", "seven", "07", "7 8"):
            with self.assertRaises(otalib.OtaError, msg=bad_version):
                gates.native_base_tag(bad_version)
        vf = write(self.p("VERSION"), b"7\n")
        r = tool("publish_gates.py", "base-tag", "--version-file", vf)
        self.assertEqual(r.returncode, 0, out(r))
        self.assertEqual(r.stdout.split(), ["tag=v7", "version=7"])
        self.assertEqual(tool("publish_gates.py", "base-tag", "--version-file", vf, "--var", "v8").returncode, 1)
        self.assertEqual(tool("publish_gates.py", "base-tag", "--version-file", vf, "--var", "v7").returncode, 0)
        real = os.path.join(ROOT, "VERSION")
        if os.path.isfile(real):
            r = tool("publish_gates.py", "base-tag", "--version-file", real)
            self.assertEqual(r.returncode, 0, out(r))
            self.assertTrue(r.stdout.startswith("tag=v"))

    def test_native_release_must_be_published_and_carry_the_apk(self):
        good = {"tag_name": "v7", "name": "Purgatory Dungeon v7", "draft": False, "prerelease": False,
                "assets": [{"name": "Purgatory-Dungeon-v7.apk", "size": 330051232, "state": "uploaded"},
                           {"name": "Purgatory-Dungeon-v7-Windows.zip", "size": 5, "state": "uploaded"}]}
        self.assertEqual(gates.native_release_problems(good, "v7"), [])

        def broken(**kw):
            d = json.loads(json.dumps(good))
            d.update(kw)
            return d
        cases = {
            "draft": broken(draft=True), "prerelease": broken(prerelease=True), "title": broken(name="Purgatory Dungeon v7.1 (OTA #000001)"),
            "other tag": broken(tag_name="v6"), "no assets": broken(assets=[]),
            "other apk": broken(assets=[{"name": "Purgatory-Dungeon-v6.apk", "size": 5, "state": "uploaded"}]),
            "empty apk": broken(assets=[{"name": "Purgatory-Dungeon-v7.apk", "size": 0, "state": "uploaded"}]),
            "not uploaded": broken(assets=[{"name": "Purgatory-Dungeon-v7.apk", "size": 5, "state": "starter"}]),
            "twice": broken(assets=good["assets"][:1] * 2), "missing flags": {"tag_name": "v7", "name": "Purgatory Dungeon v7", "assets": good["assets"]},
        }
        for label, rel in cases.items():
            self.assertTrue(gates.native_release_problems(rel, "v7"), label)
        self.assertTrue(gates.native_release_problems([], "v7"))
        jf = write(self.p("rel.json"), json.dumps(good).encode())
        self.assertEqual(tool("publish_gates.py", "native-release", "--json", jf, "--tag", "v7").returncode, 0)
        jb = write(self.p("rel_bad.json"), json.dumps(cases["draft"]).encode())
        r = tool("publish_gates.py", "native-release", "--json", jb, "--tag", "v7")
        self.assertEqual(r.returncode, 1)
        self.assertIn("draft", r.stderr)
        # the APK's own build_info must agree with the tag it was found under
        info = {"commit": "a" * 40, "runtime_id": "android-godot-4.6.0-r1", "runtime_fingerprint": "b" * 64, "ota_channel": "dev", "public_version": 7}
        self.assertEqual(gates.baseline_identity(info, "dev", 7)["native_version"], 7)
        with self.assertRaises(otalib.OtaError) as cm:
            gates.baseline_identity(info, "dev", 8)
        self.assertIn("public_version 7", str(cm.exception))

    def test_source_repo_gate(self):
        """The release host is always this repository; when the app's baked REPO is known it must be the same repository."""
        self.assertEqual(gates.check_source_repo("verbal76/Purgatory-Dungeon"), "verbal76/Purgatory-Dungeon")
        self.assertEqual(gates.check_source_repo("Me/Src", "me/src"), "Me/Src", "case-insensitive, like GitHub")
        with self.assertRaises(otalib.OtaError) as cm:
            gates.check_source_repo("me/src", "me/elsewhere")
        self.assertIn("installed apps would look for updates in a repository this pipeline never publishes to", str(cm.exception))
        self.assertIn("scripts/boot/ota_config.gd", str(cm.exception))
        for bad in ("", "not a repo", "a/b/c", "noslash"):
            with self.assertRaises(otalib.OtaError, msg=bad):
                gates.check_source_repo(bad)
        self.assertFalse(hasattr(gates, "resolve_host"), "there is no second host to resolve")

    def test_public_repo_gate(self):
        self.assertEqual(gates.NOT_PUBLIC_REASON, "the source repository is not public, so devices cannot download releases anonymously")
        self.assertEqual(gates.public_verdict(200, {"private": False}), "")
        for status, obj in ((200, {"private": True}), (200, {}), (200, None), (200, []), (404, None), (403, {"message": "rate limit"}), (0, None)):
            why = gates.public_verdict(status, obj)
            self.assertTrue(why.startswith(gates.NOT_PUBLIC_REASON), (status, obj, why))
        self.assertIn("HTTP 404", gates.public_verdict(404, None))

        state = {"mode": "public", "calls": 0}

        def body(h):
            state["calls"] += 1
            if state["mode"] == "flaky" and state["calls"] == 1:
                h.send_response(500)
                h.send_header("Content-Length", "0")
                h.end_headers()
                return
            if h.path != "/repos/me/src":
                h.send_response(404)
                h.send_header("Content-Length", "0")
                h.end_headers()
                return
            if state["mode"] == "private":       # what GitHub answers an anonymous request for a private repository
                h.send_response(404)
                h.send_header("Content-Length", "0")
                h.end_headers()
                return
            data = json.dumps({"full_name": "me/src", "private": state["mode"] == "claims-private"}).encode()
            h.send_response(200)
            h.send_header("Content-Length", str(len(data)))
            h.end_headers()
            h.wfile.write(data)

        _, H, base = self.serve(body)
        env = {"GH_TOKEN": "ghp_secret", "GITHUB_TOKEN": "ghp_secret2"}
        old = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        self.addCleanup(lambda: [os.environ.pop(k) if v is None else os.environ.__setitem__(k, v) for k, v in old.items()])
        nosleep = lambda s: None  # noqa: E731
        state["mode"] = "public"
        self.assertEqual(gates.check_public("me/src", base, retries=1, sleep=nosleep), "")
        self.assertTrue(all(h["auth"] is None and h["cookie"] is None for h in H.seen), "the public check is anonymous: " + str(H.seen))
        self.assertEqual(H.seen[0]["path"], "/repos/me/src")
        state.update(mode="private", calls=0)
        self.assertTrue(gates.check_public("me/src", base, retries=2, delay=0, sleep=nosleep).startswith(gates.NOT_PUBLIC_REASON))
        state.update(mode="claims-private", calls=0)
        self.assertTrue(gates.check_public("me/src", base, retries=1, sleep=nosleep).startswith(gates.NOT_PUBLIC_REASON))
        state.update(mode="flaky", calls=0)
        self.assertEqual(gates.check_public("me/src", base, retries=3, delay=0, sleep=nosleep), "", "a transient 5xx is retried")
        self.assertEqual(gates.check_public("me/src", "http://127.0.0.1:9", retries=1, sleep=nosleep)[:len(gates.NOT_PUBLIC_REASON)], gates.NOT_PUBLIC_REASON,
                         "an unreachable API is a refusal, never a pass")

        # a rate-limited API falls back to the repository's own page (200 = public, 404 = private); no fallback for other failures of a 404
        def limited(h):
            h.send_response(403)
            h.send_header("Content-Length", "0")
            h.end_headers()

        def web_page(h):
            code = 200 if h.path == "/me/src" else 404
            h.send_response(code)
            h.send_header("Content-Length", "0")
            h.end_headers()
        _, _, api_base = self.serve(limited)
        _, W, web_base = self.serve(web_page)
        self.assertEqual(gates.check_public("me/src", api_base, retries=2, delay=0, sleep=nosleep, web=web_base), "", "public per the web page")
        self.assertTrue(W.seen and all(h["auth"] is None for h in W.seen))
        self.assertTrue(gates.check_public("me/other", api_base, retries=1, sleep=nosleep, web=web_base).startswith(gates.NOT_PUBLIC_REASON), "web 404 = private")
        self.assertTrue(gates.check_public("me/src", api_base, retries=1, sleep=nosleep).startswith(gates.NOT_PUBLIC_REASON), "no web fallback for a custom api")
        state.update(mode="private", calls=0)
        self.assertTrue(gates.check_public("me/src", base, retries=1, sleep=nosleep, web=web_base).startswith(gates.NOT_PUBLIC_REASON),
                        "an API 404 is final: the web page is never consulted to overrule it")
        # CLI: ok=1 / ok=0 + reason (exit 0 so the job can write its published:false receipt), exit 1 when REPO disagrees
        cfg = write(self.p("ota_config.gd"), b'const REPO := "me/src"\n')
        state.update(mode="public", calls=0)
        r = tool("publish_gates.py", "repo-gate", "--repo", "me/src", "--config", cfg, "--api", base, "--retries", "1", env=env)
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("ok=1", r.stdout.splitlines())
        self.assertIn("repo=me/src", r.stdout.splitlines())
        state.update(mode="private", calls=0)
        r = tool("publish_gates.py", "repo-gate", "--repo", "me/src", "--config", cfg, "--api", base, "--retries", "1", "--delay", "0", env=env)
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("ok=0", r.stdout.splitlines())
        self.assertIn("reason=" + gates.NOT_PUBLIC_REASON, r.stdout)
        other = write(self.p("other_config.gd"), b'const REPO := "me/Purgatory-Dungeon-Elsewhere"\n')
        state.update(mode="public", calls=0)
        r = tool("publish_gates.py", "repo-gate", "--repo", "me/src", "--config", other, "--api", base, "--retries", "1", env=env)
        self.assertEqual(r.returncode, 1, out(r))
        self.assertIn("installed apps would look", r.stderr)

    def test_baked_repo_of_the_native_layer(self):
        """The REPO compiled into the app is the one repository this pipeline publishes to (the native worker owns the file)."""
        cfg = os.path.join(ROOT, "scripts", "boot", "ota_config.gd")
        if not os.path.isfile(cfg):
            self.skipTest("native layer not merged")
        baked = str(gates.config_value(rt(cfg), "REPO"))
        if baked != "verbal76/Purgatory-Dungeon":
            notice(f"scripts/boot/ota_config.gd has REPO {baked!r}; the native worker must set it to the source repository verbal76/Purgatory-Dungeon (CI refuses otherwise)")
            return
        self.assertEqual(gates.check_source_repo("verbal76/Purgatory-Dungeon", baked), "verbal76/Purgatory-Dungeon")

    def test_fetch_pointer_cli(self):
        doc = gates.pointer_document("dev", "dev-000004", 4, "r", "https://h/m", "https://h/s", "2026-10-06T00:00:00Z", native_version=7, app_minor=3)
        state = {"status": 200, "body": otalib.canonical_json(doc)}

        def body(h):
            data = state["body"]
            h.send_response(state["status"])
            h.send_header("Content-Length", str(len(data)))
            h.end_headers()
            h.wfile.write(data)

        _, H, base = self.serve(body)
        url = base + "/releases/download/ota-channel-dev/latest.json"
        out_file = self.p("live.json")
        r = tool("publish_gates.py", "fetch-pointer", "--url", url, "--out", out_file, "--retries", "1")
        self.assertEqual(r.returncode, 0, out(r))
        self.assertEqual(json.loads(rb(out_file))["seq"], 4)
        self.assertIn("nocache=", H.seen[-1]["path"], "the live pointer is read past caches")
        self.assertTrue(all(h["auth"] is None for h in H.seen), "anonymous, like a device")
        os.remove(out_file)
        state.update(status=404, body=b"nope")
        r = tool("publish_gates.py", "fetch-pointer", "--url", url, "--out", out_file, "--retries", "1")
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("no pointer yet", r.stdout)
        self.assertFalse(os.path.exists(out_file), "no pointer, no file (next-minor then starts at 1)")
        state.update(status=500, body=b"boom")
        r = tool("publish_gates.py", "fetch-pointer", "--url", url, "--out", out_file, "--retries", "1")
        self.assertEqual(r.returncode, 1)
        self.assertIn("refusing to publish blind", r.stderr)
        state.update(status=200, body=b"{not json")
        self.assertEqual(tool("publish_gates.py", "fetch-pointer", "--url", url, "--out", out_file, "--retries", "1").returncode, 1)
        self.assertFalse(os.path.exists(out_file))

    # --- pointer
    def test_pointer_is_forward_only(self):
        self.assertTrue(gates.pointer_forward(None, 1))
        self.assertTrue(gates.pointer_forward(3, 4))
        self.assertFalse(gates.pointer_forward(3, 3), "never to seq == current")
        self.assertFalse(gates.pointer_forward(3, 2), "never backwards")
        r = tool("publish_gates.py", "pointer-decision", "--current-seq", "5", "--new-seq", "5")
        self.assertEqual(r.returncode, 1)
        self.assertIn("only moves forward", r.stderr)
        self.assertEqual(tool("publish_gates.py", "pointer-decision", "--current-seq", "none", "--new-seq", "1").returncode, 0)
        self.assertEqual(tool("publish_gates.py", "pointer-decision", "--current-seq", "4", "--new-seq", "5").returncode, 0)

    def test_pointer_document(self):
        d = gates.pointer_document("dev", "dev-000003", 3, "android-godot-4.6.0-r1", "https://h/m.json", "https://h/m.sig", "2026-10-06T00:00:00Z",
                                   native_version=7, app_minor=2)
        self.assertEqual(set(d), {"channel", "ota_id", "seq", "runtime_id", "manifest_url", "signature_url", "published_at", "native_version", "app_minor"})
        self.assertEqual((d["native_version"], d["app_minor"]), (7, 2))
        self.assertEqual(gates.parse_pointer(otalib.canonical_json(d))["seq"], 3)
        for bad in (dict(ota_id="dev-000004"), dict(channel="Bad"), dict(manifest_url="http://h/m.json"), dict(signature_url="ftp://x"),
                    dict(app_minor=0), dict(app_minor=-1), dict(native_version=0), dict(app_minor=True), dict(native_version="7")):
            args = dict(channel="dev", ota_id="dev-000003", seq=3, runtime_id="r", manifest_url="https://h/m", signature_url="https://h/s",
                        native_version=7, app_minor=1)
            args.update(bad)
            with self.assertRaises(otalib.OtaError, msg=bad):
                gates.pointer_document(**args)
        for bad in (b"not json", b"[]", json.dumps(dict(d, seq="3")).encode(), json.dumps({k: v for k, v in d.items() if k != "ota_id"}).encode(),
                    json.dumps({k: v for k, v in d.items() if k != "app_minor"}).encode(), json.dumps(dict(d, app_minor=0)).encode(),
                    json.dumps(dict(d, native_version=1.5)).encode()):
            with self.assertRaises(otalib.OtaError):
                gates.parse_pointer(bad)
        r = tool("publish_gates.py", "make-pointer", "--channel", "dev", "--ota-id", "dev-000003", "--seq", "3", "--runtime-id", "r",
                 "--manifest-url", "https://h/m", "--signature-url", "https://h/s", "--native-version", "7", "--app-minor", "2",
                 "--out", self.p("latest.json"))
        self.assertEqual(r.returncode, 0, out(r))
        self.assertEqual(jload(self.p("latest.json"))["ota_id"], "dev-000003")
        self.assertEqual((jload(self.p("latest.json"))["native_version"], jload(self.p("latest.json"))["app_minor"]), (7, 2))

    # --- the owner-facing minor (v7.1, v7.2 ...) is assigned from the live pointer
    def ptr(self, native, minor, seq):
        return gates.pointer_document("dev", f"dev-{seq:06d}", seq, "r", "https://h/m", "https://h/s", "2026-10-06T00:00:00Z",
                                      native_version=native, app_minor=minor)

    def test_minor_continuity(self):
        self.assertEqual(gates.next_minor(None, 7, 1), 1, "the first OTA on the v7 APK is v7.1")
        self.assertEqual(gates.owner_version(7, 1), "v7.1")
        self.assertEqual(gates.next_minor(self.ptr(7, 1, 1), 7, 2), 2, "the second is v7.2")
        self.assertEqual(gates.next_minor(self.ptr(7, 2, 2), 7, 3), 3)
        self.assertEqual(gates.next_minor(self.ptr(7, 9, 12), 7, 40), 10, "seq jumps (internal sequence) never change the minor arithmetic")
        self.assertEqual(gates.next_minor(self.ptr(7, 4, 9), 8, 10), 1, "a different native generation (v8 APK) resets to 1: v8.1")
        self.assertEqual(gates.owner_version(8, 1), "v8.1")
        self.assertEqual(gates.next_minor(self.ptr(7, 4, 9), 8), 1)
        # stale / duplicate publications are refused
        for pointer_seq in (5, 6):
            with self.assertRaises(otalib.OtaError, msg=pointer_seq):
                gates.next_minor(self.ptr(7, 3, pointer_seq), 7, 5)
        with self.assertRaises(otalib.OtaError):
            gates.next_minor(self.ptr(7, 1, 1), 7, 1)
        # an OTA for an OLDER native generation must not replace the pointer of a newer one
        with self.assertRaises(otalib.OtaError) as cm:
            gates.next_minor(self.ptr(8, 1, 3), 7, 4)
        self.assertIn("older APK v7", str(cm.exception))
        for bad in (0, -1, "7", None):
            with self.assertRaises(otalib.OtaError):
                gates.next_minor(None, bad)
        # two OTAs of one generation never share a minor, whatever the interleaving
        pointer, seen = None, []
        for seq in range(1, 8):
            m = gates.next_minor(pointer, 7, seq)
            self.assertNotIn(m, seen)
            seen.append(m)
            pointer = self.ptr(7, m, seq)
        self.assertEqual(seen, [1, 2, 3, 4, 5, 6, 7])
        # the owner-facing string is always <whole>.<whole>: the OTA path can never produce a bare vN (a real-APK number)
        for native in range(1, 12):
            for p in (None, self.ptr(native, 3, 4), self.ptr(max(1, native - 1), 3, 4)):
                self.assertRegex(gates.owner_version(native, gates.next_minor(p, native, 9)), r"^v\d+\.[1-9]\d*$")

    def test_next_minor_cli(self):
        write(self.p("latest.json"), otalib.canonical_json(self.ptr(7, 2, 2)))
        r = tool("publish_gates.py", "next-minor", "--native-version", "7", "--new-seq", "3", "--current", self.p("latest.json"))
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("app_minor=3", r.stdout)
        self.assertIn("owner_version=v7.3", r.stdout)
        r = tool("publish_gates.py", "next-minor", "--native-version", "8", "--new-seq", "3", "--current", self.p("latest.json"))
        self.assertIn("owner_version=v8.1", r.stdout)
        r = tool("publish_gates.py", "next-minor", "--native-version", "7", "--new-seq", "1")
        self.assertIn("owner_version=v7.1", r.stdout, "no pointer file = the first OTA")
        r = tool("publish_gates.py", "next-minor", "--native-version", "7", "--new-seq", "2", "--current", self.p("latest.json"))
        self.assertEqual(r.returncode, 1, "re-publishing an already-published seq keeps failing")
        self.assertIn("forward", r.stderr)
        write(self.p("bad.json"), b'{"channel": "dev"}')
        r = tool("publish_gates.py", "next-minor", "--native-version", "7", "--current", self.p("bad.json"))
        self.assertEqual(r.returncode, 1, "a pointer without app_minor is not guessed at")

    # --- anonymous reachability (a private host fails here)
    def serve(self, handler_body):
        class H(http.server.BaseHTTPRequestHandler):
            seen = []

            def log_message(self, *a):
                pass

            def do_GET(self):
                H.seen.append({"path": self.path, "auth": self.headers.get("Authorization"), "cookie": self.headers.get("Cookie")})
                handler_body(self)

        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        return srv, H, f"http://127.0.0.1:{srv.server_address[1]}"

    def test_anonymous_reachability_and_exact_bytes(self):
        data = os.urandom(5000)
        sha = hashlib.sha256(data).hexdigest()

        def body(h):
            if h.path == "/redirect":
                h.send_response(302)
                h.send_header("Location", "/real")
                h.end_headers()
            elif h.path in ("/real", "/direct"):
                h.send_response(200)
                h.send_header("Content-Length", str(len(data)))
                h.end_headers()
                h.wfile.write(data)
            elif h.path == "/wrong":
                h.send_response(200)
                h.send_header("Content-Length", str(len(data)))
                h.end_headers()
                h.wfile.write(data[:-1] + b"X")
            else:
                h.send_response(404)       # what GitHub answers an anonymous request for a PRIVATE repository's release asset
                h.send_header("Content-Length", "0")
                h.end_headers()

        _, H, base = self.serve(body)
        env = {"GH_TOKEN": "ghp_secret", "GITHUB_TOKEN": "ghp_secret2"}
        old = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        self.addCleanup(lambda: [os.environ.pop(k) if v is None else os.environ.__setitem__(k, v) for k, v in old.items()])
        nosleep = lambda s: None  # noqa: E731
        self.assertEqual(gates.check_anonymous([(base + "/direct", sha, len(data)), (base + "/redirect", sha, None)], retries=1, sleep=nosleep), [])
        self.assertTrue(all(s["auth"] is None and s["cookie"] is None for s in H.seen), "no credential may be sent: " + str(H.seen))
        probs = gates.check_anonymous([(base + "/private", sha, len(data))], retries=2, delay=0, sleep=nosleep)
        self.assertEqual(len(probs), 1)
        self.assertIn("not anonymously reachable (HTTP 404)", probs[0])
        self.assertIn("private", probs[0])
        probs = gates.check_anonymous([(base + "/wrong", sha, len(data))], retries=1, sleep=nosleep)
        self.assertIn("SHA-256", probs[0])
        probs = gates.check_anonymous([(base + "/direct", sha, len(data) + 1)], retries=1, sleep=nosleep)
        self.assertIn("bytes", probs[0])
        probs = gates.check_anonymous([("http://127.0.0.1:9/x", sha, None)], retries=1, sleep=nosleep)
        self.assertIn("HTTP 0", probs[0], "a refused connection is a refusal, not a pass")
        self.assertEqual(len([s for s in H.seen if s["path"] == "/private"]), 2, "retries cover CDN propagation")
        self.assertEqual(gates.anonymous_verdict([]), ["nothing to check"])
        # the CLI mirrors it with exit codes
        r = tool("publish_gates.py", "check-anonymous", "--retries", "1", "--expect", f"{base}/direct={sha}:{len(data)}", env=env)
        self.assertEqual(r.returncode, 0, out(r))
        r = tool("publish_gates.py", "check-anonymous", "--retries", "1", "--delay", "0", "--expect", f"{base}/private={sha}:{len(data)}", env=env)
        self.assertEqual(r.returncode, 1)
        self.assertIn("REFUSED", r.stderr)
        self.assertEqual(tool("publish_gates.py", "check-anonymous", "--expect", "nonsense").returncode, 1)

    def test_pointer_confirmation(self):
        doc = {"v": gates.pointer_document("dev", "dev-000004", 4, "r", "https://h/m", "https://h/s", "2026-10-06T00:00:00Z",
                                           native_version=7, app_minor=3)}

        def body(h):
            data = otalib.canonical_json(doc["v"])
            h.send_response(200)
            h.send_header("Content-Length", str(len(data)))
            h.end_headers()
            h.wfile.write(data)

        _, H, base = self.serve(body)
        nosleep = lambda s: None  # noqa: E731
        self.assertEqual(gates.pointer_confirm(base + "/latest.json", "dev", "dev-000004", retries=1, sleep=nosleep)["seq"], 4)
        self.assertIn("nocache=", H.seen[0]["path"], "the confirmation bypasses caches")
        with self.assertRaises(otalib.OtaError) as cm:
            gates.pointer_confirm(base + "/latest.json", "dev", "dev-000005", retries=2, sleep=nosleep)
        self.assertIn("serves dev/dev-000004 (app_minor 3), expected dev/dev-000005", str(cm.exception))
        with self.assertRaises(otalib.OtaError):
            gates.pointer_confirm(base + "/latest.json", "stable", "dev-000004", retries=1, sleep=nosleep)
        self.assertEqual(gates.pointer_confirm(base + "/latest.json", "dev", "dev-000004", retries=1, sleep=nosleep, expect_minor=3)["app_minor"], 3)
        with self.assertRaises(otalib.OtaError) as cm:
            gates.pointer_confirm(base + "/latest.json", "dev", "dev-000004", retries=1, sleep=nosleep, expect_minor=4)
        self.assertIn("app_minor 4", str(cm.exception))
        self.assertEqual(tool("publish_gates.py", "pointer-confirm", "--url", base + "/latest.json", "--channel", "dev", "--expect-id", "dev-000009",
                              "--retries", "1").returncode, 1)

    # --- signing key
    def test_key_match(self):
        ka, kb = self.p("a.pem"), self.p("b.pem")
        pub_a, pub_b = genkey(ka), genkey(kb)
        cfg = lambda pem: f'extends RefCounted\nconst PUBLIC_KEY_PEM := """\n{pem}"""\nconst REPO := "o/r"\nconst BOOTSTRAP_VERSION := 1\n'  # noqa: E731
        fp = gates.key_match(ka, cfg(rt(pub_a)))
        self.assertEqual(fp, otalib.public_key_der_sha256(rb(pub_a)))
        gates.key_match(ka, cfg(rt(pub_a).replace("\n", "\r\n")))           # formatting differences do not matter
        gates.key_match(ka, cfg("   " + rt(pub_a).strip() + "\n\n"))
        with self.assertRaises(otalib.OtaError) as cm:
            gates.key_match(kb, cfg(rt(pub_a)))
        self.assertIn("does not match the public key embedded in the APK", str(cm.exception))
        self.assertNotIn("PRIVATE", str(cm.exception))
        for bad in ("", "not a pem", "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n"):
            with self.assertRaises(otalib.OtaError, msg=bad):
                gates.key_match(ka, cfg(bad))
        with self.assertRaises(otalib.OtaError):
            gates.key_match(ka, "extends RefCounted\n")
        weak = self.p("weak.pem")
        subprocess.run(["openssl", "genrsa", "-out", weak, "2048"], check=True, capture_output=True)
        with self.assertRaises(otalib.OtaError) as cm:
            gates.key_match(weak, cfg(rt(pub_a)))
        self.assertIn("3072", str(cm.exception))
        write(self.p("ota_config.gd"), cfg(rt(pub_a)))
        r = tool("publish_gates.py", "key-match", "--key", ka, "--config", self.p("ota_config.gd"))
        self.assertEqual(r.returncode, 0, out(r))
        body = "".join(rt(ka).splitlines()[1:-1])
        self.assertNotIn("PRIVATE", out(r))
        self.assertNotIn(body[:30], out(r), "the key is never printed")
        r = tool("publish_gates.py", "key-match", "--key", kb, "--config", self.p("ota_config.gd"))
        self.assertEqual(r.returncode, 1)
        self.assertNotIn(body[:30], out(r))
        self.assertNotIn("PRIVATE", out(r))

    def test_config_value_forms(self):
        text = ('const RUNTIME_REVISION := 5\nconst CHANNEL: String = "dev"\nconst REPO = "o/r"\nconst BOOTSTRAP_VERSION: int = 2\n'
                'const PUBLIC_KEY_PEM := """\nPEM\n"""\n# const REPO := "commented/out"\n')
        self.assertEqual(gates.config_value(text, "RUNTIME_REVISION"), 5)
        self.assertEqual(gates.config_value(text, "CHANNEL"), "dev")
        self.assertEqual(gates.config_value(text, "REPO"), "o/r")
        self.assertEqual(gates.config_value(text, "BOOTSTRAP_VERSION"), 2)
        self.assertEqual(gates.config_value(text, "PUBLIC_KEY_PEM").strip(), "PEM")
        with self.assertRaises(otalib.OtaError):
            gates.config_value(text, "NOPE")

    # --- baseline and runtime
    def test_baseline_identity_and_runtime_gate(self):
        info = {"commit": BASE40, "runtime_id": "android-godot-4.6.0-r1", "runtime_fingerprint": FP64, "ota_channel": "dev", "public_version": 7}
        b = gates.baseline_identity(info, "dev")
        self.assertEqual((b["base_sha"], b["native_version"]), (BASE40, 7))
        for key in info:
            bad = dict(info)
            bad.pop(key)
            with self.assertRaises(otalib.OtaError, msg=key):
                gates.baseline_identity(bad)
        for edit in (dict(commit="abc"), dict(runtime_fingerprint="XYZ"), dict(runtime_id="android"), dict(public_version="7"), dict(ota_channel="Bad!")):
            with self.assertRaises(otalib.OtaError, msg=edit):
                gates.baseline_identity(dict(info, **edit))
        with self.assertRaises(otalib.OtaError) as cm:
            gates.baseline_identity(info, "stable")
        self.assertIn("never be offered", str(cm.exception))
        cur = {"runtime_id": info["runtime_id"], "runtime_fingerprint": FP64, "ota_channel": "dev"}
        self.assertEqual(gates.same_runtime(info, cur), [])
        for edit in (dict(runtime_id="android-godot-4.6.0-r2"), dict(runtime_fingerprint="cd" * 32), dict(ota_channel="stable")):
            probs = gates.same_runtime(info, dict(cur, **edit))
            self.assertTrue(probs and "new APK is required" in probs[-1], edit)
        write(self.p("bi.json"), json.dumps(info))
        write(self.p("cur.json"), json.dumps(dict(cur, runtime_fingerprint="cd" * 32)))
        r = tool("publish_gates.py", "same-runtime", "--baseline", self.p("bi.json"), "--current", self.p("cur.json"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("fingerprint differs", r.stderr)

    # --- receipt
    def full_receipt(self, **over):
        facts = dict(channel="dev", ota_id="dev-000003", seq=3, native_version=7, app_minor=2, source_sha=SRC40, base_source_sha=BASE40, native_base_tag="v7",
                     runtime_id="android-godot-4.6.0-r1", runtime_fingerprint=FP64, pck_sha256="1" * 64, pck_size=123,
                     manifest_sha256="2" * 64, signature_sha256="3" * 64, release_host="o/r", base_url="https://h/releases/download/ota-dev-000003",
                     anonymous_read_verified=True,
                     urls={"pck": "https://h/p", "manifest": "https://h/m", "signature": "https://h/s", "pointer": "https://h/l"},
                     run={"id": "9", "url": "https://h/run/9"}, suite={"mode": "own-run", "run_url": "https://h/run/9"})
        facts.update(over)
        return facts

    def test_receipt_shape(self):
        r = gates.make_receipt(True, True, True, "", **self.full_receipt())
        self.assertEqual(set(r), set(gates.RECEIPT_KEYS))
        self.assertEqual(gates.validate_receipt(r), "")
        for key in ("source_sha", "runtime_id", "runtime_fingerprint", "ota_id", "pck_sha256", "manifest_sha256", "published", "pointer_moved",
                    "native_version", "app_minor", "owner_version", "seq"):
            self.assertIn(key, r)
        self.assertEqual((r["native_version"], r["app_minor"], r["owner_version"], r["seq"], r["ota_id"]), (7, 2, "v7.2", 3, "dev-000003"),
                         "the three identities stay separate: native APK 7, owner-facing v7.2, OTA update dev-000003 / #000003")
        with self.assertRaises(otalib.OtaError):
            gates.make_receipt(True, True, True, "", **self.full_receipt(owner_version="v7.3"))
        with self.assertRaises(otalib.OtaError):
            gates.make_receipt(True, True, True, "", **self.full_receipt(app_minor=None))
        with self.assertRaises(otalib.OtaError):
            gates.make_receipt(True, True, True, "", **self.full_receipt(native_version=None))
        # unpublished: needs a reason, may lack everything else
        u = gates.make_receipt(False, False, False, "no OTA signing key is available", channel="dev", source_sha=SRC40)
        self.assertEqual((u["published"], u["pointer_moved"], u["release_created"], u["reason"]), (False, False, False, "no OTA signing key is available"))
        with self.assertRaises(otalib.OtaError):
            gates.make_receipt(False, False, False, "")
        # inconsistent claims are refused
        with self.assertRaises(otalib.OtaError):
            gates.make_receipt(True, True, True, "", **self.full_receipt(anonymous_read_verified=None))
        with self.assertRaises(otalib.OtaError):
            gates.make_receipt(True, True, True, "", **self.full_receipt(anonymous_read_verified=False))
        with self.assertRaises(otalib.OtaError):
            gates.make_receipt(True, False, True, "", **self.full_receipt())
        with self.assertRaises(otalib.OtaError):
            gates.make_receipt(False, True, False, "x", **self.full_receipt())
        with self.assertRaises(otalib.OtaError):
            gates.make_receipt(True, True, True, "", **self.full_receipt(pck_sha256=None))
        with self.assertRaises(otalib.OtaError):
            gates.make_receipt(True, True, True, "", **self.full_receipt(urls={"pointer": ""}))
        with self.assertRaises(otalib.OtaError):
            gates.make_receipt(False, False, False, "x", **self.full_receipt(source_sha="nothex"))
        with self.assertRaises(otalib.OtaError):
            gates.make_receipt(False, False, False, "x", bogus=1)
        bad = dict(r)
        bad.pop("urls")
        self.assertNotEqual(gates.validate_receipt(bad), "")
        # the receipt says how the full-suite requirement was met: in this run, or by a verified earlier green run (which it names)
        self.assertEqual(r["suite"], {"mode": "own-run", "run_url": "https://h/run/9"})
        reused = gates.make_receipt(True, True, True, "", **self.full_receipt(suite={"mode": "reused", "run_url": "https://h/run/8"}))
        self.assertEqual(reused["suite"]["mode"], "reused")
        for bad_suite in ({"mode": None, "run_url": None}, {"mode": "skipped", "run_url": "https://h/run/8"}, {"mode": "reused", "run_url": None},
                          {"mode": "reused", "run_url": "http://h/run/8"}):
            with self.assertRaises(otalib.OtaError, msg=str(bad_suite)):
                gates.make_receipt(True, True, True, "", **self.full_receipt(suite=bad_suite))
        self.assertIsNone(gates.make_receipt(False, False, False, "x", channel="dev")["suite"]["mode"], "an unpublished receipt may lack it")

    def test_receipt_cli(self):
        r = tool("publish_gates.py", "receipt", "--out", self.p("r.json"), "--published", "0", "--reason", "no key", "--channel", "dev",
                 "--source-sha", SRC40, "--run-id", "5")
        self.assertEqual(r.returncode, 0, out(r))
        d = jload(self.p("r.json"))
        self.assertEqual((d["published"], d["reason"], d["run"]["id"]), (False, "no key", "5"))
        self.assertEqual(gates.validate_receipt(d), "")
        r = tool("publish_gates.py", "receipt", "--out", self.p("r2.json"), "--published", "1")
        self.assertEqual(r.returncode, 1, "a published receipt without facts is refused")
        self.assertFalse(os.path.exists(self.p("r2.json")))
        r = tool("publish_gates.py", "receipt", "--out", self.p("r3.json"), "--published", "1", "--pointer-moved", "1", "--release-created", "1",
                 "--channel", "dev", "--ota-id", "dev-000003", "--seq", "3", "--native-version", "7", "--app-minor", "2",
                 "--source-sha", SRC40, "--runtime-id", "android-godot-4.6.0-r1",
                 "--runtime-fingerprint", FP64, "--pck-sha256", "1" * 64, "--pck-size", "9", "--manifest-sha256", "2" * 64,
                 "--signature-sha256", "3" * 64, "--pck-url", "https://h/p", "--manifest-url", "https://h/m", "--signature-url", "https://h/s",
                 "--pointer-url", "https://h/l", "--base-url", "https://h/b", "--anonymous-read-verified", "1",
                 "--suite-mode", "reused", "--suite-run-url", "https://h/run/8")
        self.assertEqual(r.returncode, 0, out(r))
        self.assertTrue(jload(self.p("r3.json"))["published"])
        self.assertEqual(jload(self.p("r3.json"))["suite"], {"mode": "reused", "run_url": "https://h/run/8"})
        self.assertEqual((jload(self.p("r3.json"))["owner_version"], jload(self.p("r3.json"))["app_minor"]), ("v7.2", 2))

    def test_branch_cli(self):
        sha = "c" * 40
        r = tool("publish_gates.py", "parse-branch", f"ota/dev/{sha}", sha)
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("channel=dev", r.stdout)
        r = tool("publish_gates.py", "parse-branch", "ota/dev/latest", sha)
        self.assertEqual(r.returncode, 1)
        self.assertIn("SHA-named", r.stderr)
        r = run([sys.executable, os.path.join(OTA, "publish_gates.py"), "next-seq", "dev"], input_text="ota-dev-000002\n")
        self.assertEqual(r.stdout.strip(), "3")


# ------------------------------------------------------------------------------------------------ release tool / package verification

class TestBuildInfoAndVerify(TmpCase):
    def test_build_info_bakes_the_runtime_identity(self):
        r = tool("release_tool.py", "build-info", self.p("bi.json"), "--commit", BASE40, "--run-id", "9", "--release",
                 "--runtime-id", "android-godot-4.6.0-r3", "--runtime-fingerprint", FP64, "--ota-channel", "dev", base=TOOLS)
        self.assertEqual(r.returncode, 0, out(r))
        d = jload(self.p("bi.json"))
        self.assertEqual((d["runtime_id"], d["runtime_fingerprint"], d["ota_channel"], d["commit"], d["release"]),
                         ("android-godot-4.6.0-r3", FP64, "dev", BASE40, True))
        self.assertEqual(d["public_version"], int(rt(os.path.join(ROOT, "VERSION")).strip()))
        for args in (["--runtime-id", "android-godot-4.6.0-r3"], ["--runtime-id", "x", "--runtime-fingerprint", FP64, "--ota-channel", "dev"],
                     ["--runtime-id", "android-godot-4.6.0-r3", "--runtime-fingerprint", "abc", "--ota-channel", "dev"],
                     ["--runtime-id", "android-godot-4.6.0-r3", "--runtime-fingerprint", FP64, "--ota-channel", "Bad Channel"]):
            r = tool("release_tool.py", "build-info", self.p("bad.json"), "--commit", BASE40, *args, base=TOOLS)
            self.assertNotEqual(r.returncode, 0, args)
        self.assertFalse(os.path.exists(self.p("bad.json")))

    def test_build_info_computes_the_identity_from_the_tree(self):
        if not os.path.isfile(os.path.join(ROOT, "scripts", "boot", "ota_config.gd")):
            r = tool("release_tool.py", "build-info", self.p("bi.json"), "--commit", BASE40, base=TOOLS)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("native runtime identity", out(r))
            notice("no scripts/boot/ota_config.gd yet: build-info refuses to ship a build without a runtime identity (computing it waits for the merge)")
            return
        r = tool("release_tool.py", "build-info", self.p("bi.json"), "--commit", BASE40, base=TOOLS)
        self.assertEqual(r.returncode, 0, out(r))
        ident = ota_runtime.identity(ota_runtime.Tree(ROOT), "android")
        d = jload(self.p("bi.json"))
        self.assertEqual((d["runtime_id"], d["runtime_fingerprint"], d["ota_channel"]), (ident["runtime_id"], ident["runtime_fingerprint"], ident["ota_channel"]))

    def names_ok(self, extra=(), bi=None, drop=()):
        names = ["scenes/StudioSplash.tscn", "scripts/studio_splash.gd", "scenes/MainMenu.tscn", "scripts/build_info.gd", "build_info.json",
                 "Hot_Attic_Games_Master_Logo_ALPHA_FINAL.png", "scripts/boot/ota_core.gd", "scripts/boot/ota_config.gd"]
        names = [n for n in names if n not in drop] + list(extra)
        info = {"public_version": 7, "release": True, "commit": BASE40, "runtime_id": "android-godot-4.6.0-r1", "runtime_fingerprint": FP64,
                "ota_channel": "dev"}
        info.update(bi or {})
        content = {"build_info.json": json.dumps(info).encode()}
        problems, notes = [], []
        vp.check_names(names, lambda n: content.get(n, b"x"), "PCK", 7, True, True, BASE40, problems, notes)
        return problems

    def test_package_checks(self):
        self.assertEqual(self.names_ok(), [])
        self.assertEqual(self.names_ok(drop=("scripts/boot/ota_core.gd", "scripts/boot/ota_config.gd")), [], "a build without the client is fine")
        for field in ("runtime_id", "runtime_fingerprint", "ota_channel"):
            probs = self.names_ok(bi={field: None})
            self.assertTrue(any(field in p for p in probs), field)
        self.assertTrue(any("runtime_fingerprint" in p for p in self.names_ok(bi={"runtime_fingerprint": "abc"})))
        for legacy in ("ota_trust.pem", "ota_channel.json", "scripts/ota/ota_core.gd"):
            self.assertTrue(any("first-generation" in p for p in self.names_ok(extra=[legacy])), legacy)
        for key in ("ota-signing.key", "secrets/x.p12", "a/release.keystore", "b/my.jks", "ota_signing_backup.bin"):
            self.assertTrue(any("key material" in p for p in self.names_ok(extra=[key])), key)
        names = ["scenes/StudioSplash.tscn", "scripts/studio_splash.gd", "scenes/MainMenu.tscn", "scripts/build_info.gd", "build_info.json",
                 "Hot_Attic_Games_Master_Logo_ALPHA_FINAL.png", "data/leak.txt"]
        problems, notes = [], []
        vp.check_names(names, lambda n: b"-----BEGIN PRIVATE KEY-----\nAAA" if n == "data/leak.txt" else json.dumps(
            {"public_version": 7, "runtime_id": "android-godot-4.6.0-r1", "runtime_fingerprint": FP64, "ota_channel": "dev"}).encode(),
            "PCK", 7, True, False, "", problems, notes)
        self.assertTrue(any("PRIVATE key material" in p for p in problems))

    def test_apk_build_requires_internet_when_the_client_is_present(self):
        text = rt(os.path.join(TOOLS, "android", "build_apk.sh"))
        self.assertIn("scripts/boot/ota_core.gd", text)
        self.assertIn("android.permission.INTERNET", text)
        self.assertNotIn("scripts/ota", text)
        self.assertNotIn("ota_trust", rt(os.path.join(TOOLS, "verify_apk.py")) + text)


# ------------------------------------------------------------------------------------------------ local end-to-end pieces

class TestE2eDriver(unittest.TestCase):
    def test_fault_server_selftest(self):
        self.assertEqual(ota_e2e.selftest_server(), [])

    def test_driver_lists_scenarios_and_needs_godot_for_the_rest(self):
        r = run([sys.executable, os.path.join(TESTS, "ota_e2e.py"), "--list"])
        self.assertEqual(r.returncode, 0, out(r))
        for name in ("no_network_start", "check_stage_apply_promote", "crash_loop", "supersede_and_rollback", "baseline_fallbacks", "fault_transport",
                     "fault_pointer", "fault_manifest", "pointer_lag", "cdn_redirect", "asset_origin"):
            self.assertIn(name, r.stdout)
        r = run([sys.executable, os.path.join(TESTS, "ota_e2e.py")])
        self.assertNotEqual(r.returncode, 0)

    def test_every_documented_fault_is_covered(self):
        src = rt(os.path.join(TESTS, "ota_e2e.py"))
        for fault in ("truncated-body", "wrong-bytes", "hang-pointer", "hang-manifest", "hang-package", "404-pointer", "404-manifest", "404-package",
                      "pointer-other-channel", "malformed-manifest", "bad-signature", "wrong-runtime", "wrong-fingerprint", "wrong-channel",
                      "wrong-base-sha", "stale", "crash", "pck-url-other-host", "pck-url-other-repo-path", "pointer-url-other-host",
                      "pointer-url-other-repo-path", "cdn-wrong-bytes", "cdn-truncated"):
            self.assertIn(fault, src, fault)
        self.assertIn("--ota-pointer=", src)
        self.assertIn("/releases/download/ota-channel-", src, "the server mirrors the same-repository Releases layout")
        self.assertIn("/objects/", src, "and the 302 hop to the signed objects URL")
        self.assertIn("lag_pointer", src)
        self.assertNotIn("github.com", src.replace("https://github.com/o/r", ""), "the driver never talks to GitHub")

    def test_probe_matches_the_contract(self):
        gd = rt(os.path.join(TESTS, "ota_e2e_probe.gd"))
        for needle in ("Boot", "report_ready", "diagnostics", "PROBE_PATCHED", "res://data/ota_probe.json"):
            self.assertIn(needle, gd)


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





# ------------------------------------------------------------------------------------------------ transport-neutral artifact gates

class FileServer:
    """Serves {path: bytes} anonymously from 127.0.0.1 and records the headers it was asked with."""

    def __init__(self, files):
        self.files, self.seen = dict(files), []
        me = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                me.seen.append({"path": self.path, "auth": self.headers.get("Authorization"), "cookie": self.headers.get("Cookie")})
                body = me.files.get(self.path)
                self.send_response(200 if body is not None else 404)
                data = body if body is not None else b"missing"
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.srv.server_address[1]}"

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


class TestArtifactGates(TmpCase):
    def setUp(self):
        super().setUp()
        self.key = self.p("k.pem")
        self.pub = genkey(self.key)
        self.pck = pck_of(self.p("purgatory-dev-000003.pck"), {"scripts/a.gdc": b"A" * 300})
        self.m = {"pck_size": os.path.getsize(self.pck), "pck_sha256": otalib.sha256_file(self.pck), "seq": 3}
        write(self.p("manifest.json"), otalib.canonical_json(self.m))
        otalib.sign_to_file(self.key, self.p("manifest.json"), self.p("manifest.json.sig"))
        self.files = [self.pck, self.p("manifest.json"), self.p("manifest.json.sig")]
        self.pem = rb(self.pub)

    def serve(self, **over):
        files = {"/" + os.path.basename(f): rb(f) for f in self.files}
        files.update(over)
        srv = FileServer(files)
        self.addCleanup(srv.close)
        return srv

    def verify(self, srv, files=None, pem=None):
        return artifact_gates.verify_anonymous(srv.base, {os.path.basename(f): f for f in (files or self.files)}, pem or self.pem,
                                               retries=1, delay=0, sleep=lambda s: None)

    # -- names
    def test_name_allowlist(self):
        self.assertEqual(artifact_gates.name_violations(["purgatory-dev-000003.pck", "manifest.json", "manifest.json.sig", "latest.json"]), [])
        self.assertEqual(artifact_gates.name_violations(["purgatory-dev-000003.pck"], "dev", 3), [])
        for bad in ("source.zip", "Purgatory-Dungeon-v7.apk", "ota-signing.pem", "purgatory-dev-3.pck", "purgatory-Dev-000003.pck", "manifest.json.bak",
                    "payload.pck", "README.md", "../manifest.json", "purgatory-dev-000003.pck.sig"):
            self.assertTrue(artifact_gates.name_violations([bad]), bad)
        self.assertTrue(artifact_gates.name_violations(["purgatory-dev-000004.pck"], "dev", 3), "another publication's pack")
        self.assertTrue(artifact_gates.name_violations(["purgatory-stable-000003.pck"], "dev", 3))
        self.assertEqual(tool("artifact_gates.py", "check-names", *self.files, "--channel", "dev", "--seq", "3").returncode, 0)
        r = tool("artifact_gates.py", "check-names", self.pck, write(self.p("extra.zip"), b"x"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("extra.zip", r.stderr)

    # -- secrets
    def test_secret_scan(self):
        clean = write(self.p("clean.json"), '{"a": 1}')
        key = write(self.p("sig.txt"), "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----")
        word = write(self.p("note.md"), "prose about a PRIVATE KEY")
        tok = write(self.p("pointer.json"), '{"x": "ghp_SuperSecretTokenValue123"}')
        self.assertEqual(artifact_gates.scan_file(clean), [])
        self.assertTrue(artifact_gates.scan_file(key))
        self.assertTrue(artifact_gates.scan_file(word), "small public files use the plain marker")
        self.assertEqual(artifact_gates.scan_file(tok), [])
        hits = artifact_gates.scan_file(tok, token="ghp_SuperSecretTokenValue123")
        self.assertEqual(len(hits), 1)
        self.assertNotIn("ghp_Super", hits[0], "the value is never echoed")
        pem = b"-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----\n"
        packs = {"clean": self.pck,
                 "bytes": pck_of(self.p("b.pck"), {"data/notes.txt": b"x" * 100 + pem}),
                 "name": pck_of(self.p("n.pck"), {"data/ota-signing.key": b"x"}),
                 "pemname": pck_of(self.p("p.pck"), {"certs/server.pem": b"public"})}
        self.assertEqual(artifact_gates.scan_pack_names(packs["clean"]) + artifact_gates.scan_file(packs["clean"], big=True), [])
        self.assertTrue(artifact_gates.scan_file(packs["bytes"], big=True))
        self.assertTrue(artifact_gates.scan_pack_names(packs["name"]))
        self.assertTrue(artifact_gates.scan_pack_names(packs["pemname"]))
        self.assertTrue(artifact_gates.scan_file(write(self.p("big.bin"), b"y" * ((8 << 20) - 20) + pem), big=True), "a marker split across read chunks is found")
        self.assertEqual(tool("artifact_gates.py", "scan-secrets", *self.files, "--pck", self.pck).returncode, 0)
        r = tool("artifact_gates.py", "scan-secrets", key)
        self.assertEqual(r.returncode, 1)
        self.assertNotIn("AAAA", out(r))
        r = tool("artifact_gates.py", "scan-secrets", tok, "--token-env", "T", env={"T": "ghp_SuperSecretTokenValue123"})
        self.assertEqual(r.returncode, 1)
        self.assertNotIn("ghp_Super", out(r))
        self.assertEqual(tool("artifact_gates.py", "scan-secrets", tok, "--token-env", "T", env={"T": ""}).returncode, 0)
        self.assertEqual(tool("artifact_gates.py", "scan-secrets", "--pck", packs["bytes"]).returncode, 1)
        self.assertEqual(tool("artifact_gates.py", "scan-secrets", self.p("missing")).returncode, 1)

    # -- immutability
    def test_published_artifacts_never_change_bytes(self):
        fresh = FileServer({})
        self.addCleanup(fresh.close)
        files = {os.path.basename(f): f for f in self.files}
        self.assertEqual(artifact_gates.immutability_problems(fresh.base, files), [], "nothing published yet: fine")
        same = self.serve()
        self.assertEqual(artifact_gates.immutability_problems(same.base, files), [], "identical bytes: a harmless re-run")
        other = self.serve(**{"/manifest.json": b"{\"seq\": 99}"})
        probs = artifact_gates.immutability_problems(other.base, files)
        self.assertEqual(len(probs), 1)
        self.assertIn("DIFFERENT bytes", probs[0])
        self.assertIn("immutable", probs[0])
        pck_changed = self.serve(**{"/purgatory-dev-000003.pck": b"tampered"})
        self.assertTrue(artifact_gates.immutability_problems(pck_changed.base, files))
        self.assertEqual(artifact_gates.immutability_problems(other.base, {"latest.json": write(self.p("latest.json"), b"{}")}), [],
                         "the pointer is the one mutable object")
        self.assertTrue(artifact_gates.immutability_problems("http://127.0.0.1:9", files), "an unreachable answer is not a pass")
        r = tool("artifact_gates.py", "immutable", "--base-url", other.base, *self.files)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(tool("artifact_gates.py", "immutable", "--base-url", fresh.base, *self.files).returncode, 0)

    # -- anonymous read-back
    def test_anonymous_read_back_with_signature(self):
        srv = self.serve()
        self.assertEqual(self.verify(srv), [])
        self.assertTrue(all(s["auth"] is None and s["cookie"] is None for s in srv.seen), "no credential is ever sent")
        # missing file (what a private host looks like to an anonymous client)
        gone = FileServer({})
        self.addCleanup(gone.close)
        probs = self.verify(gone)
        unreadable = [p for p in probs if "not anonymously readable" in p]
        self.assertEqual(len(unreadable), 3)
        self.assertTrue(all("HTTP 404" in p for p in unreadable))
        # wrong bytes, same size
        raw = bytearray(rb(self.pck))
        raw[200] ^= 0xFF
        probs = self.verify(self.serve(**{"/purgatory-dev-000003.pck": bytes(raw)}))
        self.assertTrue(any("different SHA-256" in p for p in probs))
        self.assertTrue(any("SHA-256 differs from the signed manifest" in p for p in probs))
        # wrong size
        probs = self.verify(self.serve(**{"/purgatory-dev-000003.pck": rb(self.pck) + b"x"}))
        self.assertTrue(any("bytes, published" in p for p in probs))
        # a signature that does not verify with the app's key (another key, flipped byte, garbage)
        other = self.p("other.pem")
        genkey(other)
        probs = self.verify(srv, pem=rb(other + ".pub"))
        self.assertTrue(any("does not verify with the public key compiled into the app" in p for p in probs))
        sig = bytearray(base64.b64decode(rb(self.p("manifest.json.sig"))))
        sig[5] ^= 0xFF
        write(self.p("flipped.sig"), base64.b64encode(bytes(sig)))
        flipped = [self.pck, self.p("manifest.json"), self.p("flipped.sig")]
        shutil.copyfile(self.p("flipped.sig"), self.p("m2.sig"))
        srv2 = FileServer({"/purgatory-dev-000003.pck": rb(self.pck), "/manifest.json": rb(self.p("manifest.json")), "/manifest.json.sig": rb(self.p("flipped.sig"))})
        self.addCleanup(srv2.close)
        probs = artifact_gates.verify_anonymous(srv2.base, {"purgatory-dev-000003.pck": self.pck, "manifest.json": self.p("manifest.json"),
                                                          "manifest.json.sig": self.p("flipped.sig")}, self.pem, retries=1, sleep=lambda s: None)
        self.assertTrue(any("signature" in p for p in probs), probs)
        # the manifest must describe the downloaded pack (signed lies are caught too)
        bad = dict(self.m, pck_size=self.m["pck_size"] + 1)
        write(self.p("manifest.json"), otalib.canonical_json(bad))
        otalib.sign_to_file(self.key, self.p("manifest.json"), self.p("manifest.json.sig"))
        probs = self.verify(self.serve())
        self.assertTrue(any("differs from the signed manifest" in p for p in probs))
        # the manifest and its signature are verified together
        probs = artifact_gates.verify_anonymous(srv.base, {"manifest.json": self.p("manifest.json")}, self.pem, retries=1, sleep=lambda s: None)
        self.assertTrue(any("together" in p for p in probs))

    def test_anonymous_read_back_cli_uses_the_key_of_the_config(self):
        srv = self.serve()
        cfg = write(self.p("ota_config.gd"), 'extends RefCounted\nconst PUBLIC_KEY_PEM := """\n' + rt(self.pub) + '"""\n')
        r = tool("artifact_gates.py", "verify-anonymous", "--base-url", srv.base, "--config", cfg, "--retries", "1", *self.files)
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("signature verified with the app's public key", r.stdout)
        other = self.p("other.pem")
        genkey(other)
        write(cfg, 'extends RefCounted\nconst PUBLIC_KEY_PEM := """\n' + rt(other + ".pub") + '"""\n')
        r = tool("artifact_gates.py", "verify-anonymous", "--base-url", srv.base, "--config", cfg, "--retries", "1", *self.files)
        self.assertEqual(r.returncode, 1)
        self.assertIn("REFUSED", r.stderr)
        r = tool("artifact_gates.py", "verify-anonymous", "--base-url", srv.base, "--retries", "1", *self.files)
        self.assertEqual(r.returncode, 1, "no key, no verification")

    def test_download_command_is_anonymous_and_exact(self):
        srv = self.serve()
        out_file = self.p("dl.pck")
        env = {"GH_TOKEN": "ghp_secret", "GITHUB_TOKEN": "ghp_secret2"}
        r = tool("artifact_gates.py", "download", "--url", srv.base + "/purgatory-dev-000003.pck", "--out", out_file, "--retries", "1", env=env)
        self.assertEqual(r.returncode, 0, out(r))
        self.assertEqual(rb(out_file), rb(self.pck))
        self.assertTrue(all(h["auth"] is None for h in srv.seen), "downloads carry no credential")
        os.remove(out_file)
        r = tool("artifact_gates.py", "download", "--url", srv.base + "/missing.pck", "--out", out_file, "--retries", "1", "--delay", "0", env=env)
        self.assertEqual(r.returncode, 1)
        self.assertIn("not anonymously downloadable (HTTP 404)", r.stderr)
        self.assertFalse(os.path.exists(out_file))

    def test_the_gates_know_no_transport(self):
        text = rt(os.path.join(OTA, "artifact_gates.py"))
        for needle in ("api.github.com", "GH_TOKEN", "gh release", "releases/download", "OTA_RELEASE_TOKEN", "verbal76"):
            self.assertNotIn(needle, text.replace("GitHub Releases `.../releases/download/<tag>`", ""), needle)

    # -- receipt
    def test_receipt_and_summary_lines(self):
        facts = TestPublishGates.full_receipt(self)
        r = gates.make_receipt(True, True, True, "", **facts)
        self.assertTrue(r["anonymous_read_verified"])
        self.assertEqual(r["base_url"], "https://h/releases/download/ota-dev-000003")
        u = gates.make_receipt(False, False, False, "no signing key", channel="dev", source_sha=SRC40, native_version=7, app_minor=2)
        self.assertIsNone(u["anonymous_read_verified"])
        lines = gates.summary_lines(r)
        self.assertEqual(lines[0], "Native APK: v7")
        self.assertEqual(lines[1], "Owner-facing running version: v7.2")
        self.assertEqual(lines[2], "OTA update id: #000003 (dev-000003)")
        self.assertTrue(lines[3].startswith("Runtime: android-godot-4.6.0-r1 / "))
        self.assertIn("Base URL: https://h/releases/download/ota-dev-000003", lines)
        self.assertIn("Anonymous read verified: yes", lines)
        self.assertIn("Test suite: ran in this publication run (https://h/run/9)", lines)
        self.assertIn("Published: yes", lines)
        ul = gates.summary_lines(u)
        self.assertIn("Anonymous read verified: no", ul)
        self.assertIn("Published: no (reason: no signing key)", ul)
        write(self.p("r.json"), otalib.canonical_json(r))
        cli = tool("publish_gates.py", "summary", self.p("r.json"))
        self.assertEqual(cli.stdout.strip().splitlines(), lines)
        self.assertNotRegex(" ".join(lines), r"ghp_|github_pat_|PRIVATE")


# ------------------------------------------------------------------------------------------------ workflows (static)

def wf(name):
    return rt(os.path.join(ROOT, ".github", "workflows", name))


def load_yaml(text):
    try:
        import yaml
    except ImportError:
        notice("PyYAML not installed: skipping the structural YAML assertions (the text assertions still ran)")
        return None
    return yaml.safe_load(text)


class TestPublishWorkflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.y = wf("ota-publish.yml")
        cls.d = load_yaml(cls.y)

    def pos(self, needle, start=0):
        i = self.y.find(needle, start)
        self.assertGreaterEqual(i, 0, f"ota-publish.yml must contain {needle!r}")
        return i

    def lacks(self, needle):
        self.assertFalse(needle in self.y, f"ota-publish.yml must not contain {needle!r}")

    def test_trigger_is_only_a_push_to_ota_branches(self):
        self.assertRegex(self.y, r"(?m)^on:\n  push:\n    branches:\n      - 'ota/\*\*'\n\npermissions:")
        for bad in ("workflow_dispatch", "pull_request", "schedule:", "repository_dispatch", "workflow_run", "tags:", "release:", "issue_comment"):
            self.lacks(bad)
        if self.d:
            self.assertEqual(self.d[True], {"push": {"branches": ["ota/**"]}})

    def test_branch_name_and_sha_gate_comes_first(self):
        first_gate = self.pos("python3 tools/ota/publish_gates.py parse-branch")
        self.assertLess(first_gate, self.pos("name: 02a"))
        self.assertLess(first_gate, self.pos("releases/tags/"))
        self.assertIn('"$REF_NAME" "$EVENT_SHA"', self.y)
        self.assertIn("REF_NAME: ${{ github.ref_name }}", self.y)
        self.assertIn("EVENT_SHA: ${{ github.sha }}", self.y)
        # attacker-controlled names are never interpolated into a script body
        for m in re.finditer(r"run: \|\n((?:          .*\n|\n)+)", self.y):
            self.assertNotIn("github.ref_name", m.group(1))
            self.assertNotIn("github.head_ref", m.group(1))

    def test_steps_run_in_the_documented_order(self):
        order = ["name: 01 Pin the exact commit", "name: 02a Gate the host", "name: 02b Resolve identity", "name: 02c Native baseline tag",
                 "name: 03 Native baseline",
                 "name: 04 Classify", "name: 05 Runtime gate", "name: 05b Look for a VERIFIED", "uses: ./.github/workflows/ota-tests.yml", "name: 07 Build the payload", "name: 07b Assign app_minor",
                 "name: 08 Build the manifest", "name: 09 Signing key", "name: 10 The key's public half", "name: 11 Sign",
                 "name: 12 Inspect", "name: 13 Create the immutable release", "name: 14 Re-download", "name: 15 Verify the published objects are ANONYMOUSLY",
                 "name: 16 Advance the channel pointer", "name: 17 Publication receipt"]
        last = -1
        for needle in order:
            i = self.pos(needle)
            self.assertGreater(i, last, f"{needle!r} is out of order")
            last = i

    def test_gates_are_wired_and_fail_closed(self):
        self.assertIn("python3 tools/ota/classify.py", self.y)
        self.assertIn("python3 tools/ota_runtime.py --check", self.y)
        self.assertIn("publish_gates.py same-runtime", self.y)
        self.assertIn("publish_gates.py baseline", self.y)
        self.assertIn("OTA_NATIVE_BASE_TAG", self.y)
        self.assertIn('releases/tags/$OTA_NATIVE_BASE_TAG"', self.y)
        self.assertIn("publish_gates.py native-release", self.y)
        self.assertIn("tools/ota_build_payload.sh", self.y)
        self.assertIn("--native-artifact", self.y, "the byte comparison with the shipped APK is part of the build")
        self.assertIn("ota_make_manifest.gd", self.y)
        self.assertIn("ota_inspect_pack.gd", self.y)
        self.assertGreaterEqual(self.y.count("-s res://tools/ota_inspect_pack.gd"), 2, "inspected before AND after publishing")
        self.assertIn("grep -q '^INSPECT OK'", self.y)
        self.assertIn("grep -q '^MANIFEST OK'", self.y)
        self.assertIn("python3 tools/ota/publish_gates.py next-seq", self.y)
        self.assertNotIn("continue-on-error", self.y, "no step may fail open")
        for m in re.finditer(r"(?m)^\s*set \+e", self.y):
            self.fail("set +e at " + str(m.start()))
        if self.d:
            jobs = self.d["jobs"]
            self.assertEqual(set(jobs), {"prepare", "tests", "publish"})
            self.assertEqual(jobs["tests"]["uses"], "./.github/workflows/ota-tests.yml")
            self.assertEqual(jobs["tests"]["with"], {"ref": "${{ needs.prepare.outputs.sha }}"}, "the suite runs on the pinned SHA, not on a branch name")
            self.assertEqual(jobs["publish"]["needs"], ["prepare", "tests"])
            self.assertEqual(jobs["tests"]["needs"], "prepare")
            self.assertIn("proceed == '1'", jobs["publish"]["if"])
            self.assertIn("ref: ${{ needs.prepare.outputs.sha }}", self.y)

    def test_signing_key_handling(self):
        key = self.pos("name: 09 Signing key")
        km = self.pos("publish_gates.py key-match")
        sign = self.pos("openssl dgst -sha256 -sign")
        self.assertLess(key, km)
        self.assertLess(km, sign, "the key must be proven to match the embedded public key BEFORE it signs anything")
        self.assertLess(sign, self.pos("name: 12 Inspect"))
        self.assertIn("OTA_SIGNING_KEY_PEM_BASE64: ${{ secrets.OTA_SIGNING_KEY_PEM_BASE64 }}", self.y)
        self.assertIn("source tools/ota/keys.sh --no-create", self.y, "the private draft release is read, never created")
        self.assertIn('OTA_KEYS_NO_CREATE: "1"', self.y)
        self.assertIn("ok=false", self.y)
        self.assertIn("NOT PUBLISHING", self.y, "a missing key ends in published=false")
        self.assertRegex(self.y, r"(?s)name: 10 .*?if: steps\.key\.outputs\.ok == 'true'")
        self.assertRegex(self.y, r"(?s)name: 11 Sign.*?if: steps\.key\.outputs\.ok == 'true'")
        self.assertIn("shred -u", self.y, "the key file is destroyed right after signing")
        self.assertIn("-sha256 -sign", self.y)
        # the key is never printed, copied or uploaded
        for bad in ("cat \"$OTA_PRIVATE_KEY_PATH\"", "cat $OTA_PRIVATE_KEY_PATH", "echo \"$OTA_SIGNING_KEY", "set -x", "set -o xtrace", "base64 \"$OTA_PRIVATE",
                    "upload-artifact@v4\n        with:\n          name: ota-key"):
            self.lacks(bad)
        art = self.y[self.pos("Upload the receipt"):]
        for bad in (".pem", ".key", "ota-signing", "OTA_PRIVATE"):
            self.assertNotIn(bad, art, f"{bad} must not be uploaded")
        self.assertNotRegex(self.y, r"(?m)^\s*echo .*\$OTA_PRIVATE_KEY_PATH")

    def test_publication_order_and_immutability(self):
        create = self.pos("name: 13 Create the immutable release")
        verify = self.pos("name: 14 Re-download")
        anon = self.pos("name: 15 Verify the published objects are ANONYMOUSLY")
        ptr = self.pos("name: 16 Advance the channel pointer")
        self.assertLess(create, verify)
        self.assertLess(verify, anon)
        self.assertLess(anon, ptr)
        step13 = self.y[create:verify]
        self.assertIn('gh release view "$TAG"', step13)
        self.assertIn("already exists", step13)
        self.assertIn("git/ref/tags/$TAG", step13, "an existing tag aborts, even without a release")
        self.assertIn("--latest=false", step13)
        self.assertIn('--target "$SHA"', step13)
        step14 = self.y[verify:anon]
        for needle in ("cmp ", "sha256sum", "ota_inspect_pack.gd", "artifact_gates.py download"):
            self.assertIn(needle, step14)
        self.assertNotIn("gh release download", step14, "the re-download is anonymous: it is what a phone does")
        self.assertNotIn("GH_TOKEN", step14)
        step15 = self.y[anon:ptr]
        self.assertIn("check-anonymous", step15)
        self.assertNotIn("GH_TOKEN", step15, "no credential reaches the anonymous check")
        self.assertIn("purgatory-$OTA_ID.pck", step15)
        step16 = self.y[ptr:self.pos("name: 17 Publication receipt")]
        self.assertLess(step16.index("pointer-decision"), step16.index("gh release upload"), "forward-only decision before the pointer moves")
        self.assertLess(step16.index("gh release upload"), step16.index("pointer-confirm"), "the live pointer is re-fetched after the move")
        self.assertIn("make-pointer", step16)
        self.assertIn("--expect-id", step16)
        self.assertIn("env -u GH_TOKEN", step16)
        self.assertIn("ota-channel-$CHANNEL", step16)
        self.assertEqual(self.y.count("gh release upload"), 1, "the only upload is latest.json")
        self.assertIn('"$OUT/latest.json" --repo "$GITHUB_REPOSITORY" --clobber', step16)
        self.assertEqual(self.y.count("--clobber"), 1, "clobber: the pointer upload only")

    def test_transport_neutral_gates_are_wired(self):
        step13 = self.y[self.pos("name: 13 Create the immutable release"):self.pos("name: 14 Re-download")]
        for needle in ("artifact_gates.py check-names", "artifact_gates.py scan-secrets", "--pck", "artifact_gates.py immutable"):
            self.assertIn(needle, step13, needle)
        self.assertLess(step13.index("artifact_gates.py immutable"), step13.index("gh release create"), "all gates run before anything is created")
        self.assertLess(step13.index("artifact_gates.py scan-secrets"), step13.index("gh release create"))
        step15 = self.y[self.pos("name: 15 Verify the published objects"):self.pos("name: 16 Advance the channel pointer")]
        self.assertIn("artifact_gates.py verify-anonymous", step15)
        self.assertIn("--config scripts/boot/ota_config.gd", step15, "the signature is checked with the public key compiled into the app")
        self.assertNotIn("GH_TOKEN", step15)
        step16 = self.y[self.pos("name: 16 Advance the channel pointer"):self.pos("name: 17 Publication receipt")]
        self.assertLess(step16.index("artifact_gates.py scan-secrets"), step16.index("gh release upload"))
        self.assertLess(step16.index("pointer-confirm"), step16.index("OTA_ANON_POINTER=1"))
        rec = self.y[self.pos("name: 17 Publication receipt"):]
        for needle in ("--anonymous-read-verified", "--base-url", "publish_gates.py summary", 'OTA_ANON_ARTIFACTS', 'OTA_ANON_POINTER'):
            self.assertIn(needle, rec, needle)
        self.assertNotIn("artifact_gates.py", rec)

    def test_no_release_or_tag_outside_the_ota_flow(self):
        for m in re.finditer(r"gh release (create|upload|edit|delete)\b[^\n]*", self.y):
            line = m.group(0)
            self.assertTrue('"$TAG"' in line or '"$PTAG"' in line, "release write outside the ota-* flow: " + line)
            self.assertNotRegex(line, r'create "?v[0-9]', "never a v<N> release")
        for m in re.finditer(r"--latest\b[^\s]*", self.y):
            self.assertEqual(m.group(0), "--latest=false", "nothing may be marked Latest")
        self.assertEqual(len(re.findall(r"gh release create", self.y)), 2, "the immutable release and (once) the pointer release")
        for bad in ("gh release edit", "gh release delete", "gh api -X DELETE", "gh api --method DELETE", "git push", "--tags", "refs/tags/v",
                    "publish_release.sh", "make_latest", "gh repo ", "gh secret", "gh variable", "gh auth", "git config", "workflow_dispatch"):
            self.lacks(bad)
        self.assertNotRegex(self.y, r"git tag (?!-l )", "tags may be listed, never created")
        self.assertNotRegex(self.y, r"(?m)tag:\s*v[0-9]")
        self.assertNotRegex(self.y, r'TAG="?v[0-9]')
        # tags are built only from the OTA id
        self.assertIn("tag=ota-$id", self.y)

    def test_owner_facing_versioning(self):
        """Whole numbers are real APKs, decimals are OTAs: the workflow assigns v<native>.<minor> from the live pointer and can
        never produce a bare v<N> release (or a v8) for an OTA."""
        minor = self.pos("name: 07b Assign app_minor")
        self.assertLess(self.pos("name: 07 Build the payload"), minor)
        self.assertLess(minor, self.pos("name: 08 Build the manifest"))
        step = self.y[minor:self.pos("name: 08 Build the manifest")]
        for needle in ("publish_gates.py next-minor", '--native-version "$NATIVE_VERSION"', '--new-seq "$SEQ"', "ota-channel-$CHANNEL", "livepointer",
                       'echo "APP_MINOR=', 'echo "OWNER_VERSION='):
            self.assertIn(needle, step, needle)
        manifest = self.y[self.pos("name: 08 Build the manifest"):self.pos("name: 09 Signing key")]
        self.assertIn('app_minor="$APP_MINOR"', manifest)
        self.assertGreaterEqual(self.y.count('expect_minor="$APP_MINOR"'), 2, "both inspections check the assigned minor")
        step16 = self.y[self.pos("name: 16 Advance the channel pointer"):self.pos("name: 17 Publication receipt")]
        for needle in ('--native-version "$NATIVE_VERSION" --app-minor "$APP_MINOR"', '--expect-minor "$APP_MINOR"', "next-minor"):
            self.assertIn(needle, step16, needle)
        self.assertIn('--native-version "$NATIVE_VERSION" --app-minor "${APP_MINOR:-0}"', self.y[self.pos("name: 17 Publication receipt"):])
        # release naming: "Purgatory Dungeon v7.K (OTA #000001)", notes carry the identities as separate lines
        step13 = self.y[self.pos("name: 13 Create"):self.pos("name: 14 Re-download")]
        self.assertIn('title="Purgatory Dungeon ${OWNER_VERSION} (OTA #$(printf \'%06d\' "$SEQ"))"', step13)
        for line in ('"Native APK: v${NATIVE_VERSION}"', '"Owner-facing running version: ${OWNER_VERSION}"', '"OTA update id: #$(printf \'%06d\' "$SEQ")"',
                     '"Native runtime: ${RUNTIME_ID} / ${RUNTIME_FINGERPRINT}"'):
            self.assertIn(line, step13, line)
        self.assertNotRegex(step13, r'"Native APK: v[^"]*\$\{OWNER_VERSION\}', "each identity on its own line")
        self.assertNotIn("update ${SEQ}", self.y)
        self.assertNotIn("· update", self.y)
        for m in re.finditer(r"--title\s+\"?([^\n]*)", self.y):
            self.assertNotRegex(m.group(1), r"^\"?Purgatory Dungeon v[0-9]+\"?\s", "an OTA release is never titled like an APK release (Purgatory Dungeon v<N>)")
        self.assertNotRegex(self.y, r"Purgatory Dungeon v[0-9]+(?![0-9.])[\"']", "no literal 'Purgatory Dungeon vN' title")
        self.assertNotRegex(self.y, r"NATIVE_VERSION\s*\+|\$\(\(\s*NATIVE_VERSION|native_version\s*\+\s*1", "the OTA workflow never increments the native generation (v8 needs a real APK)")
        self.assertNotIn("VERSION\" >", self.y.replace("OWNER_VERSION", "").replace("NATIVE_VERSION", ""), "the workflow never writes a VERSION file")
        self.assertNotIn("release_tool.py set", self.y)
        # native version comes only from the shipped baseline's build_info (public_version) via publish_gates baseline
        self.assertIn("native_version: ${{ steps.base.outputs.native_version }}", self.y)

    def test_least_privilege(self):
        self.assertRegex(self.y, r"(?m)^permissions:\n  contents: read\n")
        self.assertEqual(len(re.findall(r"(?m)^\s+contents: write", self.y)), 1, "contents: write on the publish job only")
        for bad in ("write-all", "id-token", "actions: write", "packages: write", "pull-requests: write", "issues: write", "security-events"):
            self.lacks(bad)
        if self.d:
            jobs = self.d["jobs"]
            self.assertEqual(jobs["prepare"]["permissions"], {"contents": "read", "actions": "read"}, "read-only: 05b lists earlier runs")
            self.assertEqual(jobs["tests"]["permissions"], {"contents": "read"})
            self.assertEqual(jobs["publish"]["permissions"], {"contents": "write"})
            self.assertFalse(self.d["concurrency"]["cancel-in-progress"], "never cancel a publication half way")
            self.assertEqual(self.d["concurrency"]["group"], "ota-publish")
            allowed = {"actions/checkout@v4", "actions/cache@v4", "actions/upload-artifact@v4"}
            for name, job in jobs.items():
                for step in job.get("steps", []):
                    if "uses" in step:
                        self.assertIn(step["uses"], allowed, f"{name}: only first-party, pinned-major actions")
        # the automatic token only; no PAT, no other secret but the signing key
        self.assertEqual(sorted(set(re.findall(r"secrets\.([A-Za-z0-9_]+)", self.y))), ["OTA_SIGNING_KEY_PEM_BASE64"])
        for bad in FORBIDDEN_TRANSPORT:
            self.lacks(bad)
        self.assertEqual(self.y.count("persist-credentials: false"), 2, "no checkout leaves the token in .git/config")
        self.assertEqual(self.y.count("uses: actions/checkout@v4"), 2)
        if self.d:
            holders = {}
            for name, job in self.d["jobs"].items():
                for step in job.get("steps", []):
                    env = step.get("env", {}) or {}
                    for k, v in env.items():
                        if "github.token" in str(v):
                            self.assertEqual(k, "GH_TOKEN", "the token is only ever exposed as GH_TOKEN")
                            holders.setdefault(name, []).append(step["name"].split(" ")[0])
                    self.assertFalse("env" in job and "github.token" in str(job["env"]), "never job-wide")
            # write token: only the steps that create / upload / clobber a release, plus the signing-key reader; reads are anonymous
            self.assertEqual(holders["publish"], ["09", "13", "16"])
            # the prepare job is contents: read; its two token steps only read releases of this repository
            self.assertEqual(holders["prepare"], ["02b", "03", "05b"])
            self.assertNotIn("tests", holders)
            self.assertEqual(set(self.d["env"]), {"OTA_NATIVE_BASE_TAG_OVERRIDE", "OTA_ACCEPT_GUARDED"}, "workflow-wide env holds plain variables only, never a token or secret")
            self.assertNotIn("secrets", str(self.d["env"]) + str(self.d.get("defaults")))
        self.assertIn("OTA_NATIVE_BASE_TAG_OVERRIDE: ${{ vars.OTA_NATIVE_BASE_TAG }}", self.y)
        self.assertNotIn("OTA_RELEASE_REPO", self.y)

    def test_native_baseline_is_derived_not_configured(self):
        """The owner creates nothing: the baseline tag is v<VERSION> of the pinned commit; the repository variable is only an optional,
        agreeing override. The release must be published and carry its APK, which is downloaded anonymously."""
        self.assertEqual(sorted(set(re.findall(r"vars\.([A-Za-z0-9_]+)", self.y))), ["OTA_ACCEPT_GUARDED", "OTA_NATIVE_BASE_TAG"], "the only variables, both optional")
        for needle in ("set the repository variable", "required)", "(required)"):
            self.lacks(needle)
        nbt = self.pos("name: 02c Native baseline tag")
        base = self.pos("name: 03 Native baseline")
        self.assertLess(self.pos("name: 02a Gate the host"), nbt)
        self.assertLess(nbt, base)
        step = self.y[nbt:base]
        self.assertIn('publish_gates.py base-tag --version-file VERSION --var "$OTA_NATIVE_BASE_TAG_OVERRIDE"', step)
        self.assertIn("id: nbt", step)
        self.assertIn('OTA_NATIVE_BASE_TAG=', step)
        self.assertNotIn("GH_TOKEN", step)
        step03 = self.y[base:self.pos("name: 04 Classify")]
        self.assertLess(step03.index("releases/tags/"), step03.index("native-release"))
        self.assertLess(step03.index("native-release"), step03.index("curl -fsSL"), "the release is validated before its APK is fetched")
        self.assertNotIn("gh release view", step03, "REST, not GraphQL: gh release view --json needs the GraphQL API")
        self.assertIn("--expect-native-version", step03)
        self.assertNotIn("gh release download", step03, "the baseline bytes are fetched anonymously, like a phone")
        self.assertIn('"$DL_BASE/$OTA_NATIVE_BASE_TAG/$apk"', step03)
        self.assertIn("native_tag: ${{ steps.nbt.outputs.tag }}", self.y)
        self.assertIn("OTA_NATIVE_BASE_TAG: ${{ needs.prepare.outputs.native_tag }}", self.y, "the publish job uses the derived tag")
        self.assertNotRegex(self.y, r"(?m)^\s*OTA_NATIVE_BASE_TAG: \$\{\{ vars\.", "the variable is never used directly")

    def test_receipt(self):
        step = self.y[self.pos("name: 17 Publication receipt"):]
        self.assertIn("if: always()", step.split("run:")[0])
        for flag in ("--published", "--pointer-moved", "--release-created", "--source-sha", "--runtime-id", "--runtime-fingerprint", "--ota-id",
                     "--pck-sha256", "--manifest-sha256", "--signature-sha256", "--pck-url", "--manifest-url", "--pointer-url"):
            self.assertIn(flag, step, flag)
        self.assertIn("GITHUB_STEP_SUMMARY", step)
        self.assertIn("actions/upload-artifact@v4", step)
        self.assertIn('[ "$JOB_STATUS" = "success" ] && [ "$moved" = "1" ] && published=1', step, "published only when the whole chain succeeded and the pointer moved")
        self.assertIn("OTA_POINTER_MOVED=1", self.y)
        self.assertLess(self.y.index("pointer-confirm"), self.y.index("OTA_POINTER_MOVED=1"), "pointer_moved is claimed only after the live confirmation")

    def test_the_host_is_always_this_public_repository(self):
        """Same-repository releases with the automatic token: no second repository, no variable that can redirect the pipeline."""
        gate = self.pos("name: 02a Gate the host")
        self.assertLess(self.pos("name: 01 Pin"), gate)
        self.assertLess(gate, self.pos("name: 02b Resolve identity"))
        self.assertLess(gate, self.pos("uses: ./.github/workflows/ota-tests.yml"), "the host gate runs before the test suite and before any build")
        step = self.y[gate:self.pos("name: 02b Resolve identity")]
        self.assertIn('publish_gates.py repo-gate --repo "$GITHUB_REPOSITORY" --config scripts/boot/ota_config.gd', step)
        self.assertNotIn("GH_TOKEN", step, "the visibility check is anonymous")
        self.assertIn("id: repo", step)
        self.assertIn("NOT PUBLISHING", step)
        self.assertIn("proceed: ${{ steps.repo.outputs.ok }}", self.y)
        self.assertIn("Receipt (prepare stage", self.y)
        self.assertIn("steps.repo.outputs.reason", self.y, "a private source / mismatching REPO ends in published=false with that reason")
        self.assertIn("published", self.y[self.pos("name: Receipt (prepare stage"):self.pos("name: Receipt (prepare stage") + 700])
        # every release operation targets $GITHUB_REPOSITORY and nothing else
        repos = set(re.findall(r'--repo\s+("?[^\s"]+"?)', self.y))
        self.assertEqual(repos, {'"$GITHUB_REPOSITORY"'}, repos)
        for m in re.finditer(r"repos/([^\s\"?]+)", self.y):
            self.assertTrue(m.group(1).startswith("$GITHUB_REPOSITORY/"), m.group(0))
        self.assertIn("DL_BASE: https://github.com/${{ github.repository }}/releases/download", self.y)
        hosts = set(re.findall(r"https://([A-Za-z0-9.-]+)", re.sub(r"(?m)^\s*#.*$", "", self.y)))
        self.assertEqual(hosts, {"github.com"}, "no other host is ever contacted")
        for m in re.finditer(r"https://github\.com/(.{0,40})", re.sub(r"(?m)^\s*#.*$", "", self.y)):
            self.assertTrue(m.group(1).startswith(("${{ github.repository }}/", "godotengine/godot-builds/")), m.group(0))
        self.assertEqual(re.findall(r"(?m)^\s+environment:", self.y), [], "no deployment environment")
        self.assertNotIn("steps.host", self.y)
        # gate message is the one the owner specified
        self.assertEqual(gates.NOT_PUBLIC_REASON, "the source repository is not public, so devices cannot download releases anonymously")

    def test_ota_releases_are_never_latest(self):
        """Latest is always the native 'Purgatory Dungeon vN' release: the OTA workflow creates ota-* releases with --latest=false
        and a pointer PRERELEASE, and never edits an existing release."""
        step13 = self.y[self.pos("name: 13 Create the immutable release"):self.pos("name: 14 Re-download")]
        creates = re.findall(r"gh release create [^\n]*", step13)
        self.assertEqual(len(creates), 1)
        self.assertIn('"$TAG"', creates[0])
        self.assertIn("--latest=false", creates[0])
        self.assertNotIn("--prerelease", creates[0], "the per-OTA release is a normal immutable release, only never Latest")
        self.assertIn('--target "$SHA"', creates[0])
        self.assertIn('--title "$title"', creates[0])
        step16 = self.y[self.pos("name: 16 Advance the channel pointer"):self.pos("name: 17 Publication receipt")]
        ptr = re.findall(r"gh release create [^\n]*", step16)
        self.assertEqual(len(ptr), 1)
        self.assertIn('"$PTAG"', ptr[0])
        self.assertIn("--prerelease", ptr[0])
        self.assertIn("--latest=false", ptr[0])
        self.assertIn('PTAG="ota-channel-$CHANNEL"', step16)
        self.assertIn("tag=ota-$id", self.y)
        self.assertIn("name: 13 Create the immutable release ota-<channel>-<seq>", self.y)
        for bad in ("--latest ", "--latest=true", "make_latest", "gh release edit", "gh release delete", "releases/latest"):
            self.lacks(bad)
        self.assertIn('title="Purgatory Dungeon ${OWNER_VERSION} (OTA #$(printf \'%06d\' "$SEQ"))"', step13)
        self.assertEqual(len(re.findall(r"--title", self.y)), 2)


class TestOtherWorkflows(unittest.TestCase):
    def test_reusable_test_workflow(self):
        y = wf("ota-tests.yml")
        d = load_yaml(y)
        self.assertRegex(y, r"(?m)^on:\n  workflow_call:\n    inputs:\n      ref:\n")
        for bad in ("push:", "pull_request", "workflow_dispatch", "schedule", "secrets.", "contents: write", "gh release", "upload-artifact"):
            self.assertNotIn(bad, y)
        self.assertIn("tests/run_tests.sh", y, "the FULL suite")
        self.assertNotIn("TEST_FILTER", y, "no subset")
        self.assertIn("ref: ${{ inputs.ref }}", y)
        self.assertIn('test "$(git rev-parse HEAD)" = "$WANT"', y)
        self.assertRegex(y, r"(?m)^permissions:\n  contents: read\n")
        if d:
            self.assertEqual(d["jobs"]["suite"]["permissions"], {"contents": "read"})

    def test_ci_has_no_ota_key_job_or_trust_anchor_steps(self):
        y = wf("ci.yml")
        for gone in ("ota-key", "OTA trust anchor", "ota_trust", "keys.sh", "OTA_PUB_B64", "pub_b64", "OTA_SIGNING_KEY"):
            self.assertNotIn(gone, y, gone)
        self.assertEqual(y.count("python3 tools/ota_runtime.py --check"), 2)
        d = load_yaml(y)
        if d:
            for job in ("validate-and-export", "android"):
                runs = [s.get("run", "") for s in d["jobs"][job]["steps"]]
                self.assertIn("python3 tools/ota_runtime.py --check", runs, job)
            self.assertNotIn("needs", d["jobs"]["validate-and-export"], "no longer waits for an ota-key job")
            self.assertEqual(d["jobs"]["android"]["needs"], "validate-and-export", "the APK is built only after the FULL suite is green (and waits for nothing else)")
            self.assertNotIn("ota-key", d["jobs"])
        # everything else is still there
        for keep in ("tools/release_tool.py check", "tests/run_tests.sh", "tools/verify_package.py", "tools/android/build_apk.sh", "tools/publish_release.sh",
                     "promote/", "android-signing-key"):
            self.assertIn(keep, y, keep)

    def test_nothing_else_publishes_ota_releases(self):
        for name in os.listdir(os.path.join(ROOT, ".github", "workflows")):
            if name in ("ota-publish.yml",):
                continue
            text = wf(name)
            self.assertNotRegex(text, r"gh release (create|upload)[^\n]*ota-", name)
            self.assertNotIn("ota-channel-", text.replace("ota-channel-dev", ""), name)

    def test_the_one_off_key_printer_is_gone(self):
        # it existed only to read the public half once so that it could be compiled into scripts/boot/ota_config.gd
        self.assertFalse(os.path.exists(os.path.join(ROOT, ".github", "workflows", "ota-pubkey.yml")))


# ------------------------------------------------------------------------------------------------ hygiene

FORBIDDEN_TRANSPORT = ("OTA_RELEASE_TOKEN", "OTA_RELEASE_REPO", "Purgatory-Dungeon-OTA", "github.io", "pages:", "id-token", "deploy-pages", "github-pages")


class TestHygiene(unittest.TestCase):
    NAMES = [r"scripts/ota/", r"ota_trust\.pem", r"ota_channel\.json", r"make_bundle", r"verify_bundle", r"\bchannel\.py\b", r"ota_rules\.json",
             r"build_ota\.sh", r"\bchannel\.json\b", r"\bOtaBoot\b", r"OtaUpdater=\"\*res://scripts/ota"]
    OWNED = ("tools/", ".github/", "ota/", "tests/ota_e2e.py", "tests/ota_e2e_probe.gd", "tests/ota_standin/")
    SELF = ("tests/test_ota_tools.py", "docs/OTA.md", "tools/verify_package.py")   # these name the removed files on purpose

    def tracked(self):
        r = run(["git", "-C", ROOT, "ls-files"], env=GIT_ENV)
        if r.returncode != 0:
            self.skipTest("not a git checkout")
        return [f for f in r.stdout.splitlines() if os.path.isfile(os.path.join(ROOT, f))]

    def test_no_reference_to_the_first_generation_names(self):
        native_merged = os.path.isfile(os.path.join(ROOT, "scripts", "boot", "ota_core.gd"))
        if not native_merged:
            notice("native layer not merged: scanning the tooling-owned files only; after the merge the whole tree must be clean")
        rx = re.compile("|".join(self.NAMES))
        hits = []
        for f in self.tracked():
            if f in self.SELF or f.endswith((".png", ".import", ".uid", ".pck", ".ogg", ".glb", ".ttf", ".wav", ".mp3", ".mp4", ".svg", ".ico", ".icns", ".jpg", ".webp")):
                continue
            if not native_merged and not f.startswith(self.OWNED):
                continue
            if f.startswith(("tools/ota/fixtures/", "archive/", "production/")):
                continue
            try:
                text = rt(os.path.join(ROOT, f))
            except (UnicodeDecodeError, OSError):
                continue
            for i, line in enumerate(text.splitlines(), 1):
                if rx.search(line):
                    hits.append(f"{f}:{i}: {line.strip()[:100]}")
        self.assertEqual(hits, [], "first-generation OTA names must not survive v7:\n" + "\n".join(hits[:25]))

    def test_no_second_repository_pages_or_pat_transport(self):
        """Transport is same-repository GitHub Releases with the automatic token: nothing in the owned files may name a second
        repository, a PAT secret, Pages or an OIDC/deployment permission."""
        hits = []
        for f in self.tracked():
            if not f.startswith(self.OWNED) or f in self.SELF or f.endswith((".png", ".pck", ".uid", ".import")) or f.startswith("tools/ota/fixtures/"):
                continue
            try:
                text = rt(os.path.join(ROOT, f))
            except (UnicodeDecodeError, OSError):
                continue
            for i, line in enumerate(text.splitlines(), 1):
                for bad in FORBIDDEN_TRANSPORT:
                    if bad in line:
                        hits.append(f"{f}:{i}: {bad}")
        self.assertEqual(hits, [], "same-repository Releases only:\n" + "\n".join(hits))
        for gone in ("tools/ota/site_gates.py",):
            self.assertFalse(os.path.exists(os.path.join(ROOT, gone)), gone)

    def test_no_old_version_scheme_in_the_tooling(self):
        """game_version is '<native>.<app_minor>' and releases are 'Purgatory Dungeon v7.K (OTA #...)': the three-part form derived
        from seq and the 'update N' title must not survive anywhere in the tooling."""
        rx = re.compile(r"· update|update \$\{?SEQ|<seq>\.0|<native_version>\.<seq>|%d\.%d\.0|\.\{seq\}\.0|seq\}\.0")
        hits = []
        for f in self.tracked():
            if not f.startswith(self.OWNED) or f in self.SELF or f.endswith((".png", ".pck", ".uid")) or f.startswith("tools/ota/fixtures/"):
                continue
            try:
                text = rt(os.path.join(ROOT, f))
            except (UnicodeDecodeError, OSError):
                continue
            hits += [f"{f}:{i}: {l.strip()[:100]}" for i, l in enumerate(text.splitlines(), 1) if rx.search(l)]
        self.assertEqual(hits, [], "old version scheme:\n" + "\n".join(hits))

    def test_the_first_generation_tooling_is_gone(self):
        for gone in ("tools/ota/make_bundle.py", "tools/ota/channel.py", "tools/ota/verify_bundle.py", "tools/ota/ota_rules.json", "tools/ota/build_ota.sh"):
            self.assertFalse(os.path.exists(os.path.join(ROOT, gone)), gone)
        lib = rt(os.path.join(OTA, "otalib.py"))
        for gone in ("update_rel_dir", "scan_updates", "UPDATE_DIR_RE", "ota_rules", "load_rules", "OTA_API"):
            self.assertNotIn(gone, lib, gone)

    def test_scripts_are_executable_and_wired(self):
        for rel in ("tools/ota_build_payload.sh", "tools/ota/keys.sh", "tools/ota/publish_gates.py", "tools/ota_runtime.py"):
            self.assertTrue(os.access(os.path.join(ROOT, rel), os.X_OK), rel + " must be executable")
        runner = rt(os.path.join(TESTS, "run_tests.sh"))
        self.assertIn("tests/test_ota_tools.py", runner)
        self.assertIn("check_res_paths", runner)
        for rel in ("tools/ota_make_manifest.gd", "tools/ota_inspect_pack.gd", "tools/ota_runtime.py", "tools/ota_build_payload.sh", "ota/boundary.json"):
            self.assertTrue(os.path.isfile(os.path.join(ROOT, rel)), rel)
        self.assertTrue(rt(os.path.join(TOOLS, "ota_build_payload.sh")).startswith("#!/usr/bin/env bash"))

    def test_no_key_material_is_committed(self):
        for f in self.tracked():
            low = f.lower()
            self.assertFalse(low.endswith((".key", ".p12", ".jks", ".keystore")) or "ota-signing" in low or "ota_signing" in low, f)
        for f in self.tracked():
            if f.startswith(self.OWNED) and not f.endswith((".pck", ".png")) and f not in self.SELF:
                try:
                    self.assertNotIn("PRIVATE KEY-----", rt(os.path.join(ROOT, f)), f)
                except UnicodeDecodeError:
                    pass


# ------------------------------------------------------------------------------------------------ ota_build_payload.sh (needs Godot)

class TestPayloadBuilder(TmpCase):
    """The real script on a tiny temporary repository: classification, export, patch, files[], limits."""

    def setUp(self):
        super().setUp()
        self.godot = godot_bin()
        if not self.godot:
            notice("Godot 4.6 not found ($GODOT): skipping the ota_build_payload.sh end-to-end tests")
            self.skipTest("no godot")
        self.repo = self.p("repo")
        make_probe_project(self.repo)
        shutil.copytree(OTA, os.path.join(self.repo, "tools", "ota"), ignore=shutil.ignore_patterns("__pycache__", "fixtures"))
        for f in ("release_tool.py", "ota_runtime.py", "ota_build_payload.sh"):
            shutil.copyfile(os.path.join(TOOLS, f), os.path.join(self.repo, "tools", f))
        os.chmod(os.path.join(self.repo, "tools", "ota_build_payload.sh"), 0o755)
        shutil.copytree(os.path.join(ROOT, "ota"), os.path.join(self.repo, "ota"), ignore=shutil.ignore_patterns("runtime_lock.json"))
        write(os.path.join(self.repo, ".github", "workflows", "ci.yml"), CI_YML)
        write(os.path.join(self.repo, "scripts", "boot", "ota_config.gd"), CONFIG_GD)       # a minimal native layer: the runtime identity needs it
        write(os.path.join(self.repo, "scripts", "boot", "ota_core.gd"), "extends RefCounted\n")
        write(os.path.join(self.repo, "tools", "android", "build_apk.sh"), "#!/bin/bash\n")
        write(os.path.join(self.repo, ".gitignore"), ".godot/\nbuild_info.json\nout/\n*.pck\n")
        self.git(self.repo, "init", "-q")
        self.base = self.commit(self.repo, "base")
        self.git(self.repo, "tag", "v5")

    def build(self, *args, out_dir=None):
        return subprocess.run(["bash", os.path.join(self.repo, "tools", "ota_build_payload.sh"), "--godot", self.godot, "--preset", "Windows Desktop",
                               "--out", out_dir or self.p("out")] + list(args), cwd=self.repo, env=dict(os.environ, **GIT_ENV),
                              capture_output=True, text=True, timeout=900)

    def test_real_update(self):
        write(os.path.join(self.repo, "data", "probe.json"), '{"probe":"updated"}\n')
        write(os.path.join(self.repo, "data", "added.json"), '{"a":1}\n')
        os.remove(os.path.join(self.repo, "data", "gone.json"))
        write(os.path.join(self.repo, "docs", "note.md"), "not shipped\n")
        head = self.commit(self.repo, "update")
        r = self.build("--base-sha", "v5", "--head-sha", "HEAD", "--emit-base")
        self.assertEqual(r.returncode, 0, out(r))
        o = self.p("out")
        self.assertEqual(sorted(os.listdir(o)), ["base.pck", "build_info.json", "classify.json", "files.json", "payload.pck", "payload_report.json"])
        files = jload(os.path.join(o, "files.json"))
        self.assertEqual({f["path"]: f["op"] for f in files}, {"data/probe.json": "replace", "data/added.json": "add", "data/gone.json": "remove"})
        rep = jload(os.path.join(o, "payload_report.json"))
        self.assertEqual((rep["head_sha"], rep["base_source_sha"], rep["native_version"], rep["self_test"]), (head, self.base, 5, False))
        self.assertEqual(rep["payload_sha256"], otalib.sha256_file(os.path.join(o, "payload.pck")))
        self.assertEqual(rep["native_comparison"], "not-compared")
        self.assertEqual(jload(os.path.join(o, "classify.json"))["result"], "ota_safe")
        bi = jload(os.path.join(o, "build_info.json"))
        self.assertEqual((bi["commit"], bi["public_version"]), (self.base, 5))
        self.assertEqual((bi["runtime_id"], bi["ota_channel"]), ("android-godot-4.6.0-r1", "dev"), "the baseline identity is baked into the build info")
        self.assertRegex(bi["runtime_fingerprint"], r"^[0-9a-f]{64}$")
        self.assertEqual(pcklib.verify_entries(pcklib.read_pck(os.path.join(o, "payload.pck"))), [])
        self.assertNotIn("build_info.json", {f["path"] for f in files}, "the identity file is identical in both packs and never patched")
        self.assertIn("WARNING: --native-artifact not given", r.stdout)
        # worktrees are cleaned up
        self.assertEqual(self.git(self.repo, "worktree", "list").count("\n"), 0)

    def test_pins_the_commit(self):
        write(os.path.join(self.repo, "data", "probe.json"), '{"probe":"one"}\n')
        one = self.commit(self.repo, "one")
        write(os.path.join(self.repo, "data", "probe.json"), '{"probe":"two"}\n')
        self.commit(self.repo, "two")
        r = self.build("--base-sha", "v5", "--head-sha", one)
        self.assertEqual(r.returncode, 0, out(r))
        self.assertEqual(jload(self.p("out", "payload_report.json"))["head_sha"], one, "the update is built from the named commit, not from HEAD")
        r = self.build("--base-sha", "v5", "--head-sha", "no-such-commit", out_dir=self.p("out2"))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("cannot resolve --head-sha", out(r))

    def test_apk_required_change_stops_with_exit_10(self):
        write(os.path.join(self.repo, "project.godot"), 'config_version=5\n[application]\nconfig/name="Changed"\n')
        self.commit(self.repo, "settings change")
        r = self.build("--base-sha", "v5")
        self.assertEqual(r.returncode, 10, out(r))
        self.assertIn("needs a new APK", out(r))
        self.assertIn("runtime fingerprint would change", out(r))
        self.assertFalse(os.path.exists(self.p("out", "payload.pck")))

    def test_guarded_change_stops_with_exit_11_unless_accepted(self):
        write(os.path.join(self.repo, "scripts", "save_manager.gd"), "extends Node\n")
        self.commit(self.repo, "guarded")
        r = self.build("--base-sha", "v5")
        self.assertEqual(r.returncode, 11, out(r))
        r = self.build("--base-sha", "v5", "--accept-guarded", "format unchanged", out_dir=self.p("out2"))
        self.assertEqual(r.returncode, 0, out(r))
        self.assertEqual(jload(self.p("out2", "payload_report.json"))["guarded_accepted"], "format unchanged")

    def test_refuses_bad_arguments(self):
        for args, needle in (([], "--base-sha is required"), (["--base-sha", "nope"], "cannot resolve --base-sha"),
                             (["--base-sha", "v5", "--native-check", "maybe"], "--native-check"), (["--self-test", "--base-sha", "v5"], "do not pass --base-sha")):
            r = subprocess.run(["bash", os.path.join(self.repo, "tools", "ota_build_payload.sh"), "--godot", self.godot, "--out", self.p("o")] + args,
                               cwd=self.repo, capture_output=True, text=True, timeout=120)
            self.assertNotEqual(r.returncode, 0, args)
            self.assertIn(needle, out(r))
        os.makedirs(self.p("busy"))
        write(self.p("busy", "x"), "x")
        r = self.build("--base-sha", "v5", out_dir=self.p("busy"))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("is not empty", out(r))

    def test_engine_must_match_the_project_pin(self):
        write(os.path.join(self.repo, ".github", "workflows", "ci.yml"), CI_YML.replace("4.6-stable", "4.5-stable"))
        self.commit(self.repo, "pin another engine")
        r = self.build("--base-sha", "v5")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("engine mismatch", out(r))

    def test_self_test_mode(self):
        env = dict(os.environ, **GIT_ENV, OTA_PRIVATE_KEY_PATH="/nonexistent", OTA_SIGNING_KEY_PEM_BASE64="ignored")
        r = subprocess.run(["bash", os.path.join(self.repo, "tools", "ota_build_payload.sh"), "--godot", self.godot, "--preset", "Windows Desktop",
                            "--self-test", "--out", self.p("st")], cwd=self.repo, env=env, capture_output=True, text=True, timeout=900)
        self.assertEqual(r.returncode, 0, out(r))
        self.assertIn("SELF-TEST PASSED", r.stdout)
        self.assertEqual(jload(self.p("st", "files.json")), [{"op": "add", "path": "data/ota_probe.json"}])
        self.assertTrue(jload(self.p("st", "payload_report.json"))["self_test"])
        self.assertFalse(os.path.exists(os.path.join(self.repo, "data", "ota_probe.json")), "the probe is created in the temp worktree only")
        self.assertFalse(os.path.exists(self.p("st", "base.pck")), "base.pck is only copied with --emit-base")
        self.assertEqual(os.listdir(self.p("st")).count("payload.pck"), 1)
        # no signing here, ever
        text = rt(os.path.join(TOOLS, "ota_build_payload.sh"))
        self.assertNotIn("openssl", text)
        self.assertNotIn("sign_file", text)


if __name__ == "__main__":
    unittest.main(verbosity=1)
