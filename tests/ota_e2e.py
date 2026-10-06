#!/usr/bin/env python3
"""Local end-to-end OTA proof (docs/OTA.md sections 5-8, 11): the REAL packaged game against a local server that mirrors the
GitHub Releases layout and can inject faults. No network beyond 127.0.0.1; nothing is published, pushed or tagged.

  tests/ota_e2e.py <godot-binary> [--only NAME[,NAME...]] [--list] [--keep]
  tests/ota_e2e.py <godot-binary> --build-only [--standin]     # build chain only (no device runs)
  tests/ota_e2e.py --server-selftest                           # fault server only (needs no Godot)

HOW IT WORKS
  1. A throwaway RSA key is generated. A detached worktree of HEAD gets ONE extra commit whose scripts/boot/ota_config.gd
     embeds that key's public half (the device must trust the key the server signs with); nothing else changes and no ref moves.
  2. tools/ota_build_payload.sh --self-test --preset "Windows Desktop" --emit-base builds, from that commit, the baseline pack
     (base.pck: the "installed native build", runnable on a desktop) and a real cumulative patch (data/ota_probe.json), with
     the very same code CI uses. More OTAs against the same baseline are patch exports from the kept import tree.
  3. tools/ota_make_manifest.gd (real OtaCore) writes each manifest, openssl signs it (RSA-3072 SHA-256), and the OtaSite serves
     /releases/download/<tag>/<asset> plus the pointer /releases/download/ota-channel-<channel>/latest.json.
  4. The packaged game runs headless: `godot --headless --main-pack base.pck -- --ota-enable --ota-root=DIR --ota-pointer=URL
     --ota-platform=android ...` (test hooks of scripts/boot, non-template builds only). `game` runs add --ota-quit-after-check;
     `probe` runs use tests/ota_e2e_probe.gd to see what the mounted game sees. The device's state is read from DIR/state.json
     through ONE adapter (class State): adjust it if the native layer names its fields differently.
  5. Scenarios (see --list): no-network start, check -> stage, restart applies, health promotion, supersede, crash-loop abandon +
     fallback, rollback, blacklist, baseline fallback (disable/enable, corrupted stored package) and every failure case: truncated
     body, wrong bytes, hang, 404, stale pointer, pointer for another channel, malformed manifest, bad signature, wrong runtime,
     wrong fingerprint, wrong channel, wrong base sha. The player's save slots must be byte-identical after every scenario.

NEEDS the native layer (scripts/boot/*, autoload Boot) merged into the tree: until then only --server-selftest and
--build-only --standin can run (that is what tests/test_ota_tools.py exercises). Full run: ~25-40 min, ~10 GB of temp space
(two project imports, ~40 headless launches). Exit status 0 only if every check passed.
"""
import argparse
import base64
import hashlib
import http.server
import json
import os
import re
import shutil
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PROBE = os.path.join(ROOT, "tests", "ota_e2e_probe.gd")
sys.path.insert(0, os.path.join(ROOT, "tools", "ota"))
import otalib  # noqa: E402
import tool_project  # noqa: E402

PRESET = "Windows Desktop"
CHANNEL = "dev"
FAILS = []
CHECKS = 0


def check(cond, label):
    global CHECKS
    CHECKS += 1
    if not cond:
        FAILS.append(label)
        print("  FAIL:", label, flush=True)
    else:
        print("  ok:  ", label, flush=True)


# ================================================================================================ the server

class Fault:
    __slots__ = ("suffix", "mode", "arg", "once")

    def __init__(self, suffix, mode, arg=None, once=False):
        self.suffix, self.mode, self.arg, self.once = suffix, mode, arg, once


class _Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _reply(self, code, body=b"", head=False, declared=None):
        self.send_response(code)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body) if declared is None else declared))
        self.send_header("Connection", "close")
        self.end_headers()
        if not head:
            self.wfile.write(body)

    def _serve(self, head):
        site = self.server.site
        path = self.path.split("?", 1)[0]
        fault = site._match(path)
        site.log.append({"method": "HEAD" if head else "GET", "path": path, "fault": fault.mode if fault else None,
                         "auth": self.headers.get("Authorization"), "time": time.time()})
        self.close_connection = True
        body = site.files.get(path)
        mode = fault.mode if fault else ""
        if mode == "hang":
            site._stop.wait(float(fault.arg or 120))
            return
        if mode == "404" or body is None:
            return self._reply(404, b"not found", head)
        if mode.startswith("status:"):
            return self._reply(int(mode.split(":")[1]), b"fault", head)
        if mode == "empty":
            return self._reply(200, b"", head)
        if mode == "wrong_bytes":
            b = bytearray(body)
            if b:
                b[len(b) // 2] ^= 0xFF
            return self._reply(200, bytes(b), head)
        if mode == "truncate":
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            if not head:
                self.wfile.write(body[: max(1, len(body) // 2)])
                self.wfile.flush()
                try:
                    self.connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            return
        self._reply(200, body, head)

    def do_GET(self):
        self._serve(False)

    def do_HEAD(self):
        self._serve(True)


class _Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class OtaSite:
    """Mirrors GitHub Releases: /releases/download/<tag>/<asset>, plus transport faults chosen per path suffix.
    Fault modes: truncate | wrong_bytes | hang[,arg=seconds] | 404 | status:NNN | empty."""

    def __init__(self):
        self.files, self.faults, self.log = {}, [], []
        self._stop = threading.Event()
        self._srv = _Server(("127.0.0.1", 0), _Handler)
        self._srv.site = self
        self.port = self._srv.server_address[1]
        self.base = f"http://127.0.0.1:{self.port}"
        self._thread = threading.Thread(target=self._srv.serve_forever, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        self._srv.shutdown()
        self._srv.server_close()

    def _match(self, path):
        for f in list(self.faults):
            if path.endswith(f.suffix):
                if f.once:
                    self.faults.remove(f)
                return f
        return None

    def url(self, tag, asset):
        return f"{self.base}/releases/download/{tag}/{asset}"

    def pointer_url(self, channel=CHANNEL):
        return self.url(f"ota-channel-{channel}", "latest.json")

    def publish(self, tag, assets):
        for name, data in assets.items():
            self.files[f"/releases/download/{tag}/{name}"] = data

    def set_pointer(self, doc, channel=CHANNEL):
        data = doc if isinstance(doc, bytes) else otalib.canonical_json(doc)
        self.files[f"/releases/download/ota-channel-{channel}/latest.json"] = data

    def unpublish(self, tag):
        for p in [p for p in self.files if p.startswith(f"/releases/download/{tag}/")]:
            del self.files[p]

    def fault(self, suffix, mode, arg=None, once=False):
        self.faults.append(Fault(suffix, mode, arg, once))

    def clear_faults(self):
        self.faults.clear()

    def requests(self, contains=""):
        return [r for r in self.log if contains in r["path"]]


def selftest_server():
    """Proves the server and every fault mode with a plain HTTP client. Returns a list of failure strings."""
    fails = []
    site = OtaSite()
    try:
        data = bytes(range(256)) * 40

        def get(path, timeout=5):
            try:
                with urllib.request.urlopen(urllib.request.Request(site.base + path), timeout=timeout) as r:
                    return r.status, r.read()
            except urllib.error.HTTPError as e:
                return e.code, b""

        site.publish("ota-dev-000001", {"purgatory-dev-000001.pck": data, "manifest.json": b"{}", "manifest.json.sig": b"c2ln"})
        site.set_pointer({"channel": "dev", "ota_id": "dev-000001", "seq": 1})
        p = "/releases/download/ota-dev-000001/purgatory-dev-000001.pck"
        st, b = get(p)
        if (st, b) != (200, data):
            fails.append("plain GET of a published asset")
        if get("/releases/download/ota-dev-000002/x")[0] != 404:
            fails.append("unknown asset must be 404")
        if json.loads(get("/releases/download/ota-channel-dev/latest.json")[1])["ota_id"] != "dev-000001":
            fails.append("pointer document")
        site.fault("purgatory-dev-000001.pck", "wrong_bytes")
        st, b = get(p)
        if not (st == 200 and len(b) == len(data) and b != data):
            fails.append("wrong_bytes must keep the length and change the content")
        site.clear_faults()
        site.fault(".pck", "truncate")
        try:
            st, b = get(p)
            fails.append("truncate must break the transfer (got %d bytes)" % len(b))
        except Exception:  # noqa: BLE001  (IncompleteRead / connection reset)
            pass
        site.clear_faults()
        site.fault(".pck", "404")
        if get(p)[0] != 404:
            fails.append("404 fault")
        site.clear_faults()
        site.fault(".pck", "status:503")
        if get(p)[0] != 503:
            fails.append("status fault")
        site.clear_faults()
        site.fault("latest.json", "empty")
        if get("/releases/download/ota-channel-dev/latest.json") != (200, b""):
            fails.append("empty fault")
        site.clear_faults()
        site.fault(".pck", "hang", 30)
        t0 = time.time()
        try:
            get(p, timeout=1)
            fails.append("hang must not answer")
        except Exception:  # noqa: BLE001
            if time.time() - t0 > 5:
                fails.append("hang test took too long")
        site.clear_faults()
        site.fault(".pck", "404", once=True)
        if get(p)[0] != 404 or get(p) != (200, data):
            fails.append("a once-fault must apply exactly once")
        site.clear_faults()
        site.set_pointer({"channel": "dev", "ota_id": "dev-000000", "seq": 0})
        if json.loads(get("/releases/download/ota-channel-dev/latest.json")[1])["seq"] != 0:
            fails.append("the pointer can be replaced (stale pointer)")
        site.unpublish("ota-dev-000001")
        if get(p)[0] != 404:
            fails.append("unpublish")
        if not site.requests("purgatory-dev-000001.pck") or any(r["auth"] for r in site.log):
            fails.append("request log / no credentials expected")
    finally:
        site.stop()
    return fails


# ================================================================================================ the build chain

def sh(cmd, **kw):
    kw.setdefault("capture_output", True)
    kw.setdefault("text", True)
    return subprocess.run(cmd, **kw)


def git(repo, *args, check_rc=True):
    env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="e2e", GIT_AUTHOR_EMAIL="e2e@localhost",
               GIT_COMMITTER_NAME="e2e", GIT_COMMITTER_EMAIL="e2e@localhost")
    r = sh(["git", "-C", repo] + list(args), env=env)
    if check_rc and r.returncode != 0:
        raise SystemExit("git %s failed: %s" % (" ".join(args[:2]), r.stderr.strip()))
    return r.stdout.strip()


class Ota:
    """One built OTA: its signed manifest, signature and pack, ready to publish to an OtaSite."""

    def __init__(self, seq, ota_id, tag, pck_path, manifest_bytes, sig_bytes, variant):
        self.seq, self.ota_id, self.tag, self.pck_path = seq, ota_id, tag, pck_path
        self.manifest_bytes, self.sig_bytes, self.variant = manifest_bytes, sig_bytes, variant
        self.manifest = json.loads(manifest_bytes)
        self.asset = f"purgatory-{ota_id}.pck"

    def assets(self):
        with open(self.pck_path, "rb") as f:
            return {self.asset: f.read(), "manifest.json": self.manifest_bytes, "manifest.json.sig": self.sig_bytes}


class Chain:
    def __init__(self, work, godot, standin):
        self.work, self.godot, self.standin = work, godot, standin
        self.key = os.path.join(work, "key.pem")
        self.pub = os.path.join(work, "pub.pem")
        self.src = os.path.join(work, "src")
        self.toolproj = os.path.join(work, "toolproj")
        self.payload = os.path.join(work, "payload1")
        self.otas = {}

    # -- build
    def build(self):
        sh(["openssl", "genrsa", "-out", self.key, "3072"], check=True)
        sh(["openssl", "pkey", "-in", self.key, "-pubout", "-out", self.pub], check=True)
        git(ROOT, "worktree", "add", "--detach", "--quiet", self.src, "HEAD")
        self._embed_key()
        git(self.src, "add", "-A")
        git(self.src, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "e2e: throwaway OTA key")
        print("== e2e commit %s (HEAD + throwaway public key%s)" % (git(self.src, "rev-parse", "HEAD")[:12], ", stand-in client" if self.standin else ""), flush=True)
        env = dict(os.environ, TMPDIR=self.work)
        r = sh(["bash", os.path.join(self.src, "tools", "ota_build_payload.sh"), "--godot", self.godot, "--self-test", "--preset", PRESET,
                "--emit-base", "--keep-temp", "--out", self.payload], env=env, cwd=self.src)
        sys.stdout.write("\n".join(r.stdout.splitlines()[-14:]) + "\n")
        if r.returncode != 0:
            sys.stderr.write(r.stderr[-3000:])
            raise SystemExit("ota_build_payload.sh --self-test failed")
        self.env = json.load(open(os.path.join(self.payload, "build_env.json")))
        self.base_pck = os.path.join(self.payload, "base.pck")
        self.build_info = os.path.join(self.payload, "build_info.json")
        self.head_tree = self.env["head_tree"]
        self.bi = json.load(open(self.build_info))
        tool_project.assemble(self.toolproj, self.src, self.standin)
        tool_project.import_project(self.godot, self.toolproj)

    def _embed_key(self):
        cfg = os.path.join(self.src, "scripts", "boot", "ota_config.gd")
        if self.standin and not os.path.isfile(os.path.join(ROOT, "scripts", "boot", "ota_core.gd")):
            os.makedirs(os.path.dirname(cfg), exist_ok=True)
            for rel in ("scripts/boot/ota_config.gd", "scripts/boot/ota_core.gd"):
                shutil.copyfile(os.path.join(ROOT, "tests", "ota_standin", *rel.split("/")), os.path.join(self.src, *rel.split("/")))
            if not os.path.isfile(os.path.join(self.src, "scripts", "save_schema.gd")):
                shutil.copyfile(os.path.join(ROOT, "tests", "ota_standin", "scripts", "save_schema.gd"), os.path.join(self.src, "scripts", "save_schema.gd"))
        if not os.path.isfile(cfg):
            raise SystemExit("scripts/boot/ota_config.gd is missing: the native layer is not merged (use --standin for the build chain only)")
        pem = open(self.pub).read().strip()
        text = open(cfg, encoding="utf-8").read()
        new, n = re.subn(r'(const\s+PUBLIC_KEY_PEM\s*(?::\s*\w+\s*)?:?=\s*)"""(.*?)"""', lambda m: m.group(1) + '"""' + pem + '\n"""', text, flags=re.S)
        if n != 1:
            raise SystemExit("could not replace PUBLIC_KEY_PEM in ota_config.gd (expected exactly one triple-quoted constant)")
        open(cfg, "w", encoding="utf-8").write(new)

    # -- OTAs
    def make_ota(self, seq, variant=None, channel=CHANNEL):
        """Builds, signs and returns OTA <seq>. Seq 1 uses the self-test payload; others export a new patch from the kept tree."""
        ota_id = "%s-%06d" % (channel, seq)
        tag = "ota-" + ota_id
        variant = seq if variant is None else variant
        d = os.path.join(self.work, "ota-%d" % seq)
        os.makedirs(d, exist_ok=True)
        pck, files = os.path.join(d, "payload.pck"), os.path.join(d, "files.json")
        if seq == 1 and variant == 1:
            shutil.copyfile(os.path.join(self.payload, "payload.pck"), pck)
            shutil.copyfile(os.path.join(self.payload, "files.json"), files)
        else:
            probe = os.path.join(self.head_tree, "data", "ota_probe.json")
            open(probe, "w").write('{\n  "ota_self_test": true,\n  "variant": %d\n}\n' % variant)
            sh([self.godot, "--headless", "--path", self.head_tree, "--import"], timeout=600)
            r = sh([self.godot, "--headless", "--path", self.head_tree, "--export-patch", PRESET, pck, "--patches", self.base_pck], timeout=900)
            if not os.path.isfile(pck):
                raise SystemExit("export-patch for OTA %d failed: %s" % (seq, (r.stdout + r.stderr)[-800:]))
            r = sh([sys.executable, os.path.join(ROOT, "tools", "ota", "payload_check.py"), pck, "--base", self.base_pck,
                    "--boundary", os.path.join(self.src, "ota", "boundary.json"), "--files-out", files])
            if r.returncode != 0:
                raise SystemExit("payload_check refused OTA %d: %s" % (seq, r.stderr))
        asset = os.path.join(d, f"purgatory-{ota_id}.pck")
        shutil.copyfile(pck, asset)
        manifest = os.path.join(d, "manifest.json")
        return self._manifest_and_sign(d, asset, files, seq, tag, channel, variant, ota_id, manifest)

    def _ota_commit(self, seq):
        """The commit an OTA is 'published from'. It must differ from the baseline commit (an OTA whose source is the commit the app
        was built from is, correctly, reported as 'up to date'), so each seq gets its own commit in the throwaway worktree."""
        shas = self.__dict__.setdefault("_ota_shas", {})
        if seq not in shas:
            git(self.src, "-c", "commit.gpgsign=false", "-c", "user.name=e2e", "-c", "user.email=e2e@invalid", "commit", "-q", "--allow-empty",
                "-m", "e2e: source commit of OTA %d" % seq)
            shas[seq] = git(self.src, "rev-parse", "HEAD")
        return shas[seq]

    def _manifest_and_sign(self, d, asset, files, seq, tag, channel, variant, ota_id, manifest, site_base="http://127.0.0.1:0"):
        self.site_base = getattr(self, "site_base", site_base)
        url = f"{self.site_base}/releases/download/{tag}/purgatory-{ota_id}.pck"
        r = sh([self.godot, "--headless", "--path", self.toolproj, "-s", "res://tools/ota_make_manifest.gd", "--",
                f"pck={asset}", f"out={manifest}", f"seq={seq}", f"sha={self._ota_commit(seq)}", f"url={url}", f"files={files}",
                f"build_info={self.build_info}", f"channel={channel}", "platform=android", "created_at=2026-10-06T00:00:00Z",
                "run_id=e2e", "run_number=1", "run_attempt=1", "run_url="], timeout=300)
        if "MANIFEST OK" not in r.stdout:
            raise SystemExit("ota_make_manifest.gd failed: " + (r.stdout + r.stderr)[-800:])
        sig = os.path.join(d, "manifest.json.sig")
        otalib.sign_to_file(self.key, manifest, sig)
        return Ota(seq, ota_id, tag, asset, open(manifest, "rb").read(), open(sig, "rb").read(), variant)

    def forge(self, ota, edit=None, key=None, raw=None):
        """A manifest that differs from `ota`'s in the way `edit(dict)` says, signed with our key (or `key`); `raw` replaces the
        bytes entirely (malformed manifests). Returns (manifest_bytes, sig_bytes)."""
        if raw is not None:
            data = raw
        else:
            m = json.loads(ota.manifest_bytes)
            edit(m)
            data = otalib.canonical_json(m)
        tmp = os.path.join(self.work, "forge.json")
        open(tmp, "wb").write(data)
        return data, otalib.sig_encode(otalib.sign_file(key or self.key, tmp))

    def cleanup(self):
        git(ROOT, "worktree", "prune", check_rc=False)
        for t in ("base", "head"):
            p = os.path.join(self.env["tmp"], t) if getattr(self, "env", None) else ""
            if p and os.path.isdir(p):
                git(self.src, "worktree", "remove", "--force", p, check_rc=False)
        git(ROOT, "worktree", "remove", "--force", self.src, check_rc=False)


# ================================================================================================ the device

def ids_of(v):
    if not v:
        return set()
    if isinstance(v, str):
        return {v}
    if isinstance(v, dict):
        i = v.get("ota_id") or v.get("id")
        return {i} if i else set()
    if isinstance(v, (list, tuple)):
        out = set()
        for x in v:
            out |= ids_of(x)
        return out
    return set()


class State:
    """The ONLY place that knows how the native layer lays out DIR/state.json (docs/OTA.md section 8). Fields read:
    current / previous / pending / ready (an OTA id, or an object holding ota_id) and bad (list of ids)."""

    def __init__(self, root):
        self.root = root

    def raw(self):
        p = os.path.join(self.root, "state.json")
        try:
            return json.load(open(p))
        except (OSError, ValueError):
            return {}

    def ids(self, name):
        return ids_of(self.raw().get(name))

    def staged(self):
        return self.ids("pending") | self.ids("ready")

    def all_known(self):
        return self.ids("current") | self.ids("previous") | self.staged()

    def leftovers(self):
        found = []
        for dp, _, fn in os.walk(self.root):
            found += [os.path.join(dp, f) for f in fn if ".incoming" in f or f.endswith(".part") or f.endswith(".tmp")]
        return found


class Device:
    def __init__(self, ctx, name):
        self.ctx, self.name = ctx, name
        self.root = os.path.join(ctx.work, "device-" + name)
        shutil.rmtree(self.root, ignore_errors=True)
        os.makedirs(self.root)
        self.state = State(self.root)


def tree_hash(path):
    h = hashlib.sha256()
    for dp, dn, fn in sorted(os.walk(path)):
        dn.sort()
        for f in sorted(fn):
            p = os.path.join(dp, f)
            h.update(os.path.relpath(p, path).encode())
            h.update(open(p, "rb").read())
    return h.hexdigest()


class Ctx:
    def __init__(self, chain, site):
        self.chain, self.site, self.work = chain, site, chain.work
        self.godot = chain.godot
        self.saves = os.path.join(self.work, "saves")
        self.dead = "http://127.0.0.1:9/releases/download/ota-channel-dev/latest.json"   # nothing listens: "no network"
        self.pointer = site.pointer_url()
        self.otas = {}

    def make_saves(self):
        d = os.path.join(self.saves, "saves")
        shutil.rmtree(self.saves, ignore_errors=True)
        os.makedirs(d)
        for i in range(3):
            open(os.path.join(d, "slot_%d.json" % i), "w").write(json.dumps({"name": "Hero%d" % i, "meta_currency": 7 * i}))
        open(os.path.join(self.saves, "settings.json"), "w").write('{"master_volume": 0.5}')
        self.saves_hash = self.save_hash()

    def save_hash(self):
        """The slots only: the game itself rewrites settings.json / last_slot.json at every start."""
        return tree_hash(os.path.join(self.saves, "saves"))

    def saves_intact(self, label):
        check(self.save_hash() == self.saves_hash, "save slots byte-identical " + label)

    def publish(self, ota, pointer=True):
        self.site.publish(ota.tag, ota.assets())
        if pointer:
            self.point_to(ota)

    def point_to(self, ota, **over):
        doc = {"channel": CHANNEL, "ota_id": ota.ota_id, "seq": ota.seq, "runtime_id": ota.manifest["runtime_id"],
               "manifest_url": self.site.url(ota.tag, "manifest.json"), "signature_url": self.site.url(ota.tag, "manifest.json.sig"),
               "published_at": "2026-10-06T00:00:00Z"}
        doc.update(over)
        self.site.set_pointer(doc)

    def otaflags(self, dev, pointer, extra=()):
        return ["--ota-enable", "--ota-root=" + dev.root, "--ota-pointer=" + (pointer or self.dead), "--ota-platform=android",
                "--ota-channel=" + CHANNEL] + list(extra)

    def _run(self, cmd, timeout):
        env = dict(os.environ, PURGATORY_SAVE_ROOT=self.saves)
        t0 = time.time()
        try:
            r = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout)
            out, rc = r.stdout + r.stderr, r.returncode
        except subprocess.TimeoutExpired as e:
            out, rc = ((e.stdout or b"").decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")), -999
        return {"raw": out, "rc": rc, "secs": time.time() - t0, "script_errors": "SCRIPT ERROR" in out}

    def game(self, dev, pointer=None, extra=(), timeout=240):
        """The real game (splash -> menu) with the check enabled; it quits after the check (--ota-quit-after-check)."""
        r = self._run([self.godot, "--headless", "--main-pack", self.chain.base_pck, "--"] + self.otaflags(dev, pointer, ["--ota-quit-after-check"] + list(extra)), timeout)
        r["timed_out"] = r["rc"] == -999
        return r

    def probe(self, dev, mode="plain", secs=None, pointer=None, extra=(), timeout=240):
        user = [mode] + ([str(secs)] if secs is not None else []) + self.otaflags(dev, pointer, extra)
        r = self._run([self.godot, "--headless", "--main-pack", self.chain.base_pck, "--script", PROBE, "--"] + user, timeout)
        for key in ("PROBE_BOOT", "PROBE_RAW", "PROBE_PATCHED", "PROBE_VARIANT", "PROBE_DIAG"):
            m = re.search(r"^%s=(.*)$" % key, r["raw"], re.M)
            r[key] = m.group(1).strip() if m else None
        r["patched"] = (r["PROBE_PATCHED"] or "").lower() == "true"
        r["variant"] = int(r["PROBE_VARIANT"]) if (r["PROBE_VARIANT"] or "").lstrip("-").isdigit() else None
        return r


# ================================================================================================ scenarios

SCENARIOS = []


def scenario(fn):
    SCENARIOS.append(fn)
    return fn


def staged_device(c, name, ota):
    """A device that has downloaded `ota` (pending) but not started it yet."""
    d = Device(c, name)
    c.publish(ota)
    c.game(d, c.pointer)
    return d


@scenario
def no_network_start(c):
    """The game never needs a connection to start."""
    d = Device(c, "offline")
    r = c.probe(d, "plain", pointer=c.dead)
    check(r["PROBE_BOOT"] == "present" and not r["script_errors"], "the Boot autoload is present and no script errors on a start without network")
    check(not r["patched"], "no OTA stored: the embedded baseline runs")
    g = c.game(d, c.dead)
    check(not g["script_errors"] and not g["timed_out"], "the real game starts and ends its check offline without script errors (%.0fs)" % g["secs"])
    check(not d.state.all_known(), "offline check leaves the OTA state empty (%s)" % sorted(d.state.all_known()))
    c.saves_intact("after the offline start")


@scenario
def check_stage_apply_promote(c):
    """check -> stage, restart applies, health promotion."""
    ota = c.otas[1]
    d = Device(c, "happy")
    c.publish(ota)
    g = c.game(d, c.pointer)
    check(ota.ota_id in d.state.staged(), "a check downloads, verifies and stages %s (state: %s)" % (ota.ota_id, d.state.raw()))
    check(not d.state.leftovers(), "no partial download left behind (%s)" % d.state.leftovers())
    check(len(c.site.requests(ota.asset)) >= 1, "the package was downloaded from the Releases layout")
    r = c.probe(d, "plain", pointer=c.dead)
    check(r["patched"] and r["variant"] == ota.variant, "the next cold start mounts the staged pack (variant %s)" % r["variant"])
    check(not r["script_errors"], "no script errors with the OTA mounted")
    r = c.probe(d, "stay", 9, pointer=c.dead)
    check(r["patched"], "the OTA runs on its second start")
    check(ota.ota_id in d.state.ids("current"), "ready + 5 s of running promotes PENDING to CURRENT (state: %s)" % d.state.raw())
    r = c.probe(d, "plain", pointer=c.dead)
    check(r["patched"], "the confirmed OTA mounts at every cold start, offline")
    g = c.game(d, c.pointer)
    gets = [x for x in c.site.requests(ota.asset) if x["method"] == "GET"]
    check(len(gets) == 1, "an up-to-date device does not download the package again (%d GETs)" % len(gets))
    c.saves_intact("through stage / apply / promote")


@scenario
def supersede_and_rollback(c):
    """OTA 2 replaces OTA 1 (cumulative); rollback returns to OTA 1; the rolled-back id is never reinstalled."""
    o1, o2 = c.otas[1], c.otas[2]
    d = staged_device(c, "supersede", o1)
    c.probe(d, "plain", pointer=c.dead)
    c.probe(d, "stay", 9, pointer=c.dead)
    c.publish(o2)
    c.game(d, c.pointer)
    check(o2.ota_id in d.state.staged(), "OTA 2 is staged next to the running OTA 1")
    r = c.probe(d, "stay", 9, pointer=c.dead)
    check(r["patched"] and r["variant"] == o2.variant, "OTA 2 supersedes OTA 1 (variant %s)" % r["variant"])
    check(o2.ota_id in d.state.ids("current") and o1.ota_id in d.state.ids("previous"), "OTA 2 is CURRENT and OTA 1 PREVIOUS (state: %s)" % d.state.raw())
    c.probe(d, "plain", pointer=c.dead, extra=["--ota-action=rollback"])
    r = c.probe(d, "plain", pointer=c.dead)
    check(r["patched"] and r["variant"] == o1.variant, "after a rollback OTA 1 runs again (variant %s)" % r["variant"])
    check(o2.ota_id in d.state.ids("bad"), "the rolled-back OTA is blacklisted (bad: %s)" % sorted(d.state.ids("bad")))
    before = len([x for x in c.site.requests(o2.asset) if x["method"] == "GET"])
    c.game(d, c.pointer)
    after = len([x for x in c.site.requests(o2.asset) if x["method"] == "GET"])
    check(after == before, "a blacklisted id is never downloaded again")
    c.saves_intact("through supersede / rollback")


@scenario
def crash_loop(c):
    """An OTA that never reaches boot health gets two starts; the third abandons it, blacklists it and falls back."""
    ota = c.otas[1]
    d = staged_device(c, "crash", ota)
    r1 = c.probe(d, "plain", pointer=c.dead)
    r2 = c.probe(d, "plain", pointer=c.dead)
    r3 = c.probe(d, "plain", pointer=c.dead)
    check(r1["patched"] and r2["patched"], "an unconfirmed OTA gets two starts")
    check(not r3["patched"], "the third start abandons it and runs the embedded baseline")
    check(ota.ota_id in d.state.ids("bad"), "the abandoned OTA is blacklisted (bad: %s)" % sorted(d.state.ids("bad")))
    n = len(c.site.requests(ota.asset))
    c.game(d, c.pointer)
    check(len(c.site.requests(ota.asset)) == n, "a blacklisted OTA is not downloaded again even though the pointer still names it")
    c.saves_intact("through the crash loop")


@scenario
def baseline_fallbacks(c):
    """Boot baseline / re-enable; a stored package that fails re-verification falls back without the network."""
    ota = c.otas[1]
    d = staged_device(c, "baseline", ota)
    c.probe(d, "plain", pointer=c.dead)
    c.probe(d, "stay", 9, pointer=c.dead)
    c.probe(d, "plain", pointer=c.dead, extra=["--ota-action=disable"])
    r = c.probe(d, "plain", pointer=c.dead)
    check(not r["patched"], "'boot baseline' (disable) runs the embedded game")
    c.probe(d, "plain", pointer=c.dead, extra=["--ota-action=enable"])
    r = c.probe(d, "plain", pointer=c.dead)
    check(r["patched"], "re-enabling OTA returns to the confirmed OTA")
    pcks = [os.path.join(dp, f) for dp, _, fn in os.walk(d.root) for f in fn if f.endswith(".pck")]
    check(len(pcks) >= 1, "the verified package is stored on the device")
    for p in pcks:
        b = bytearray(open(p, "rb").read())
        b[len(b) // 2] ^= 0xFF
        open(p, "wb").write(b)
    r = c.probe(d, "plain", pointer=c.dead)
    check(not r["patched"] and not r["script_errors"], "a stored package that no longer verifies is dropped; the baseline runs")
    c.saves_intact("through the baseline fallbacks")


def rejected(c, name, setup, expect_bad=False, hang=False):
    """A fresh device meets a bad server: nothing may be staged or activated, no partial file stays, saves stay identical."""
    d = Device(c, name)
    c.site.clear_faults()
    c.site.log.clear()
    ota = c.otas[1]
    setup(ota)
    g = c.game(d, c.pointer, timeout=200 if hang else 120)
    check(not g["script_errors"], "[%s] no script errors during the failed check" % name)
    check(not d.state.staged() and not d.state.ids("current"), "[%s] nothing is staged or activated (state: %s)" % (name, d.state.raw()))
    check(not d.state.leftovers(), "[%s] no partial download remains (%s)" % (name, d.state.leftovers()))
    if expect_bad:
        check(ota.ota_id in d.state.ids("bad"), "[%s] a hash mismatch on a full-size download is blacklisted" % name)
    r = c.probe(d, "plain", pointer=c.dead)
    check(not r["patched"], "[%s] the game still runs the embedded baseline" % name)
    c.site.clear_faults()
    c.saves_intact("after " + name)


@scenario
def fault_transport(c):
    """Transport faults: truncated body, wrong bytes, hangs, 404s, server errors."""
    o = c.otas[1]
    rejected(c, "truncated-body", lambda ota: (c.publish(ota), c.site.fault(ota.asset, "truncate")))
    rejected(c, "wrong-bytes", lambda ota: (c.publish(ota), c.site.fault(ota.asset, "wrong_bytes")), expect_bad=True)
    rejected(c, "hang-pointer", lambda ota: (c.publish(ota), c.site.fault("latest.json", "hang", 40)), hang=True)
    rejected(c, "hang-manifest", lambda ota: (c.publish(ota), c.site.fault("manifest.json", "hang", 40)), hang=True)
    rejected(c, "hang-package", lambda ota: (c.publish(ota), c.site.fault(o.asset, "hang", 1000)), hang=True)
    rejected(c, "404-pointer", lambda ota: (c.publish(ota), c.site.fault("latest.json", "404")))
    rejected(c, "404-manifest", lambda ota: (c.publish(ota), c.site.fault("manifest.json", "404")))
    rejected(c, "404-package", lambda ota: (c.publish(ota), c.site.fault(o.asset, "404")))
    rejected(c, "server-error", lambda ota: (c.publish(ota), c.site.fault("manifest.json", "status:503")))


@scenario
def fault_pointer(c):
    """Pointer faults: other channel, malformed document, stale pointer (no downgrade)."""
    o1, o2 = c.otas[1], c.otas[2]

    def other_channel(ota):
        c.publish(ota)
        c.point_to(ota, channel="stable", ota_id="stable-000001")
    rejected(c, "pointer-other-channel", other_channel)

    def malformed_pointer(ota):
        c.publish(ota)
        c.site.set_pointer(b"{ this is not json")
    rejected(c, "pointer-malformed", malformed_pointer)
    # a stale pointer must not downgrade a device that already runs OTA 2
    d = staged_device(c, "stale", o2)
    c.probe(d, "plain", pointer=c.dead)
    c.probe(d, "stay", 9, pointer=c.dead)
    c.publish(o1, pointer=False)
    c.point_to(o1)
    c.game(d, c.pointer)
    r = c.probe(d, "plain", pointer=c.dead)
    check(r["patched"] and r["variant"] == o2.variant, "a stale pointer (older OTA) never downgrades the device")
    check(o1.ota_id not in d.state.staged(), "the older OTA is not staged")
    c.saves_intact("through the pointer faults")


@scenario
def fault_manifest(c):
    """Manifest faults: malformed, bad/foreign signature, wrong runtime/fingerprint/channel/base, protected path, size/hash lies."""
    def with_forged(edit=None, raw=None, key=None):
        def setup(ota):
            c.site.publish(ota.tag, ota.assets())
            c.point_to(ota)
            data, sig = c.chain.forge(ota, edit, key, raw)
            c.site.publish(ota.tag, {"manifest.json": data, "manifest.json.sig": sig})
        return setup
    rejected(c, "malformed-manifest", with_forged(raw=b"{ not json at all"))
    rejected(c, "bad-signature", lambda ota: (c.publish(ota), c.site.publish(ota.tag, {"manifest.json.sig": base64.b64encode(b"\x00" * 384)})))

    def flipped_sig(ota):
        c.publish(ota)
        s = bytearray(base64.b64decode(ota.sig_bytes))
        s[10] ^= 0xFF
        c.site.publish(ota.tag, {"manifest.json.sig": base64.b64encode(bytes(s))})
    rejected(c, "flipped-signature", flipped_sig)
    other = os.path.join(c.work, "other-key.pem")
    sh(["openssl", "genrsa", "-out", other, "3072"], check=True)
    rejected(c, "signed-by-another-key", with_forged(lambda m: m.update(seq=m["seq"]), key=other))
    rejected(c, "wrong-runtime", with_forged(lambda m: m.update(runtime_id="android-godot-4.6.0-r99")))
    rejected(c, "wrong-fingerprint", with_forged(lambda m: m.update(runtime_fingerprint="0" * 64)))
    rejected(c, "wrong-channel", with_forged(lambda m: m.update(channel="stable", ota_id="stable-%06d" % m["seq"])))
    rejected(c, "wrong-base-sha", with_forged(lambda m: m.update(base_source_sha="f" * 40)))
    rejected(c, "protected-path-in-manifest", with_forged(lambda m: m["files"].append({"path": "scripts/boot/ota_core.gdc", "op": "replace"})))
    rejected(c, "pack-size-lie", with_forged(lambda m: m.update(pck_size=m["pck_size"] + 1)))
    rejected(c, "pack-hash-lie", with_forged(lambda m: m.update(pck_sha256="0" * 64)), expect_bad=False)


# ================================================================================================ main

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("godot", nargs="?", default="")
    ap.add_argument("--only", default="")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--build-only", action="store_true")
    ap.add_argument("--standin", action="store_true", help="build chain only: use the stand-in client of tests/ota_standin")
    ap.add_argument("--server-selftest", action="store_true")
    a = ap.parse_args()
    if a.list:
        for s in SCENARIOS:
            print("%-26s %s" % (s.__name__, (s.__doc__ or "").strip().splitlines()[0] if s.__doc__ else ""))
        return 0
    if a.server_selftest:
        fails = selftest_server()
        for f in fails:
            print("FAIL:", f)
        print("server self-test:", "FAILED" if fails else "passed")
        return 1 if fails else 0
    if not a.godot:
        ap.error("the godot binary is required")
    godot = shutil.which(a.godot) or os.path.abspath(a.godot)
    if a.standin and not a.build_only:
        ap.error("--standin cannot run device scenarios (the stand-in client is not an autoload); use --build-only")
    work = tempfile.mkdtemp(prefix="ota-e2e-")
    chain = Chain(work, godot, a.standin)
    site = OtaSite()
    chain.site_base = site.base
    rc = 1
    try:
        chain.build()
        ctx = Ctx(chain, site)
        ctx.otas[1] = chain.make_ota(1)
        ctx.otas[2] = chain.make_ota(2)
        print("== built OTA 1 (%s, %d files) and OTA 2 against the same baseline %s" % (ctx.otas[1].ota_id, len(ctx.otas[1].manifest["files"]), chain.bi["commit"][:12]))
        if a.build_only:
            check(ctx.otas[1].manifest["base_source_sha"] == chain.bi["commit"], "manifest base_source_sha is the baseline commit")
            check(ctx.otas[1].manifest["runtime_id"] == chain.bi["runtime_id"], "manifest runtime_id is the baseline's")
            check(ctx.otas[2].manifest["seq"] == 2 and ctx.otas[2].manifest["game_version"].endswith(".2.0"), "OTA 2 manifest identity")
            r = sh([godot, "--headless", "--path", chain.toolproj, "-s", "res://tools/ota_inspect_pack.gd", "--",
                    f"manifest={os.path.join(work, 'ota-1', 'manifest.json')}", f"sig={os.path.join(work, 'ota-1', 'manifest.json.sig')}",
                    f"pck={ctx.otas[1].pck_path}", f"build_info={chain.build_info}", f"files={os.path.join(work, 'ota-1', 'files.json')}",
                    f"pubkey={chain.pub}", "platform=android"] + (["self_identity=1"] if a.standin else []), timeout=300)
            check("INSPECT OK" in r.stdout, "the inspector accepts OTA 1 (%s)" % (r.stdout.strip().splitlines() or ["?"])[-1])
        else:
            wanted = [s for s in SCENARIOS if not a.only or s.__name__ in a.only.split(",")]
            ctx.make_saves()
            for s in wanted:
                print("\n== %s: %s" % (s.__name__, (s.__doc__ or "").strip().splitlines()[0] if s.__doc__ else ""), flush=True)
                site.clear_faults()
                s(ctx)
            ctx.saves_intact("after ALL scenarios")
        print("\nota_e2e: %d checks, %d failures" % (CHECKS, len(FAILS)))
        for f in FAILS:
            print("  FAILED:", f)
        rc = 1 if FAILS else 0
    finally:
        site.stop()
        if not a.keep:
            try:
                chain.cleanup()
            except Exception:  # noqa: BLE001
                pass
            shutil.rmtree(work, ignore_errors=True)
        else:
            print("kept:", work)
    return rc


if __name__ == "__main__":
    sys.exit(main())
