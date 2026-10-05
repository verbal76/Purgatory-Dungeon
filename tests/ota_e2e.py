#!/usr/bin/env python3
"""End-to-end OTA device simulation (docs/OTA.md "Validation").

Builds a REAL update with the production chain (tools/ota/build_ota.sh --self-test: HEAD is its own native base plus a
synthetic probe change, throwaway signing key), serves the resulting channel over local HTTP, and then drives the REAL
packaged game (the exact base.pck the update was built against, run headless with the real OtaBoot/OtaUpdater autoloads)
through the whole life cycle in separate processes, exactly as a phone would see it:

  download -> staged only (never hot-applied) -> restart applies it -> confirmation -> next launches
  failure paths: corrupt payload, tampered manifest, unreachable channel, wrong platform, crash loop -> automatic rollback,
                 remote revocation (kill switch) -> rollback, replayed channel index, --no-ota escape hatch
  save protection: the save folder is byte-identical before and after every scenario.

usage: tests/ota_e2e.py <godot-binary> [--platform windows|android] [--keep] [--reuse <kept work dir>]
Needs: git, python3, openssl, the Godot 4.6 binary (+ export templates for the platform preset) and ~15 GB free disk.
Takes several minutes (two project imports + about twenty headless launches). Nothing is published or pushed.
"""
import argparse
import hashlib
import http.server
import json
import os
import re
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PROBE = os.path.join(ROOT, "tests", "ota_e2e_probe.gd")
FAILS = []
CHECKS = 0


def check(cond, label):
    global CHECKS
    CHECKS += 1
    if not cond:
        FAILS.append(label)
        print("  FAIL:", label)
    else:
        print("  ok:  ", label)


def tree_hash(path):
    h = hashlib.sha256()
    for dp, dn, fn in sorted(os.walk(path)):
        dn.sort()
        for f in sorted(fn):
            p = os.path.join(dp, f)
            h.update(os.path.relpath(p, path).encode())
            h.update(open(p, "rb").read())
    return h.hexdigest()


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


def serve(directory):
    """Static HTTP server on an ephemeral localhost port. Returns (server, base_url)."""
    handler = lambda *a, **k: Quiet(*a, directory=directory, **k)   # noqa: E731
    srv = socketserver.TCPServer(("127.0.0.1", 0), handler)
    srv.allow_reuse_address = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, "http://127.0.0.1:%d/" % srv.server_address[1]


class Device:
    """One simulated phone: its own OTA root, sharing one save folder."""

    def __init__(self, ctx, name):
        self.ctx = ctx
        self.root = os.path.join(ctx["work"], "device-" + name)
        shutil.rmtree(self.root, ignore_errors=True)

    def state(self):
        p = os.path.join(self.root, "state.json")
        return json.load(open(p)) if os.path.isfile(p) else {}

    def launch(self, mode, channel=None, platform=None, extra_env=None, extra_args=None):
        env = dict(os.environ)
        env.update({
            "PURGATORY_SAVE_ROOT": self.ctx["saves"],
            "PURGATORY_OTA_ROOT": self.root,
            "PURGATORY_OTA_PLATFORM": platform or self.ctx["platform"],
        })
        env.pop("PURGATORY_NO_OTA", None)
        if channel:
            env["PURGATORY_OTA_CHANNEL_URL"] = channel
        else:
            env.pop("PURGATORY_OTA_CHANNEL_URL", None)
        env.update(extra_env or {})
        cmd = [self.ctx["godot"], "--headless", "--main-pack", self.ctx["base_pck"], "--script", PROBE, "--", mode] + (extra_args or [])
        r = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=300)
        out = r.stdout + r.stderr
        res = {"raw": out, "rc": r.returncode}
        for key in ("PROBE_PATCHED", "OTA_STATUS", "FOOTER", "PROBE_RAW", "CONFIRMED"):
            m = re.search(r"^%s=(.*)$" % key, out, re.M)
            res[key] = m.group(1).strip() if m else None
        st = res["OTA_STATUS"] or ""
        for k in ("active", "pending", "known_good", "rolled_back"):
            m = re.search(r"\b%s=(\d+)" % k, st)
            res[k] = int(m.group(1)) if m else None
        m = re.search(r"reason=(.*?) confirmed=", st)
        res["reason"] = m.group(1) if m else ""
        m = re.search(r"last_error=(.*)$", st)
        res["last_error"] = m.group(1) if m else ""
        res["patched"] = res["PROBE_PATCHED"] == "True"
        res["script_errors"] = "SCRIPT ERROR" in out
        return res


def reuse(args):
    """--reuse <kept work dir from an earlier --keep run>: skip the (slow) build and re-run the device scenarios."""
    work = os.path.abspath(args.reuse)
    tmp = next((os.path.join(work, d) for d in sorted(os.listdir(work)) if d.startswith("build-ota.")), "")
    bundle = os.path.join(work, "bundle")
    ctx = {"work": work, "godot": args.godot, "platform": args.platform, "bundle": bundle,
           "base_pck": os.path.join(tmp, "base.pck"), "key": os.path.join(tmp, "keys", "ota-signing.key"),
           "saves": os.path.join(work, "saves"), "tmp": tmp}
    shutil.rmtree(ctx["saves"], ignore_errors=True)
    ch = json.load(open(os.path.join(bundle, "channel.json")))
    ctx["entry"] = ch["updates"][0]
    ctx["generation"] = ch["generation"]
    return ctx


def build(args):
    if args.reuse:
        return reuse(args)
    work = tempfile.mkdtemp(prefix="ota-e2e-")
    bundle = os.path.join(work, "bundle")
    print("== building a real update with tools/ota/build_ota.sh --self-test (%s) in %s" % (args.platform, work))
    env = dict(os.environ, TMPDIR=work)
    r = subprocess.run([os.path.join(ROOT, "tools/ota/build_ota.sh"), "--platform", args.platform, "--self-test", "--godot", args.godot,
                        "--out", bundle, "--keep-temp"], env=env, capture_output=True, text=True, cwd=ROOT)
    sys.stdout.write("\n".join(r.stdout.splitlines()[-25:]) + "\n")
    if r.returncode != 0:
        sys.stderr.write(r.stderr[-3000:])
        raise SystemExit("build_ota.sh --self-test failed")
    m = re.search(r"temp kept at (\S+)", r.stdout)
    if not m:
        raise SystemExit("could not find the kept temp directory in the build output")
    tmp = m.group(1)
    ctx = {"work": work, "godot": args.godot, "platform": args.platform, "bundle": bundle,
           "base_pck": os.path.join(tmp, "base.pck"), "key": os.path.join(tmp, "keys", "ota-signing.key"),
           "saves": os.path.join(work, "saves"), "tmp": tmp}
    for need in ("base_pck", "key"):
        if not os.path.isfile(ctx[need]):
            raise SystemExit("missing %s: %s" % (need, ctx[need]))
    ch = json.load(open(os.path.join(bundle, "channel.json")))
    ctx["entry"] = ch["updates"][0]
    ctx["generation"] = ch["generation"]
    return ctx


def make_saves(ctx):
    d = os.path.join(ctx["saves"], "saves")
    os.makedirs(d, exist_ok=True)
    for i in range(3):
        open(os.path.join(d, "slot_%d.json" % i), "w").write(json.dumps({"name": "Hero%d" % i, "meta_currency": 7 * i}))
    open(os.path.join(ctx["saves"], "settings.json"), "w").write('{"master_volume": 0.5}')
    return tree_hash(ctx["saves"])


def tampered_copy(ctx, name, mutate):
    d = os.path.join(ctx["work"], "chan-" + name)
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(ctx["bundle"], d)
    mutate(d)
    return d


def flip(path, at=100):
    b = bytearray(open(path, "rb").read())
    b[at] ^= 0xFF
    open(path, "wb").write(b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("godot")
    ap.add_argument("--platform", default="windows", choices=["windows", "android"])
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--reuse", default="", help="work dir kept by an earlier --keep run (skips the build)")
    args = ap.parse_args()
    args.godot = os.path.abspath(args.godot) if os.path.exists(args.godot) else shutil.which(args.godot) or args.godot
    ctx = build(args)
    saves_before = make_saves(ctx)
    srv, url = serve(ctx["bundle"])
    servers = [srv]
    try:
        entry = ctx["entry"]
        seqdir = os.path.dirname(entry["manifest"])

        print("\n== 1. a fresh install runs the native build")
        d = Device(ctx, "happy")
        r = d.launch("plain", channel=None)
        check(not r["script_errors"], "no script errors on a clean launch")
        check(not r["patched"] and r["OTA_STATUS"] and r["OTA_STATUS"].startswith("none"), "no update stored -> native build, status none (%s)" % r["OTA_STATUS"])

        print("\n== 2. a check downloads and stages the update but never changes the running game")
        r = d.launch("check", channel=url)
        check(r["pending"] == 1 and r["OTA_STATUS"].startswith("pending"), "update 1 downloaded and verified -> pending (%s)" % r["OTA_STATUS"])
        check(not r["patched"], "the running game is NOT changed by a download (applies only at restart)")
        check("restart to apply" in (r["FOOTER"] or ""), "footer tells the player to restart (%s)" % r["FOOTER"])
        check(os.path.isfile(os.path.join(d.root, "slots", "1", "payload.pck")), "verified slot exists on the device")
        check(not os.path.isdir(os.path.join(d.root, "staging")) or not os.listdir(os.path.join(d.root, "staging")), "staging is cleaned up")
        check(d.state().get("generation") == ctx["generation"], "channel generation recorded (%s)" % d.state().get("generation"))

        print("\n== 3. restart: the update is mounted and visible to the game")
        r = d.launch("plain", channel=None)
        check(r["patched"], "the patched data file is what the game reads after the restart (%s)" % r["PROBE_RAW"])
        check(r["active"] == 1 and "unconfirmed" in r["OTA_STATUS"], "update 1 active, not yet confirmed (%s)" % r["OTA_STATUS"])
        check((r["FOOTER"] or "").endswith("update 1"), "footer shows the running update (%s)" % r["FOOTER"])
        check(not r["script_errors"], "no script errors with the update mounted")
        check(os.path.isdir(os.path.join(d.root, "backups")) and len(os.listdir(os.path.join(d.root, "backups"))) == 1, "a save backup was taken before the first activation")

        print("\n== 4. confirmation, then steady state")
        r = d.launch("confirm", channel=None)
        check(r["patched"] and r["CONFIRMED"] == "True", "the healthy window confirms the update")
        check(d.state().get("known_good") == 1 and d.state().get("boot_attempts") == 0, "state: known_good=1, attempts reset")
        for i in range(3):
            r = d.launch("plain", channel=None)
            check(r["patched"] and r["active"] == 1 and "unconfirmed" not in r["OTA_STATUS"], "confirmed update mounts on launch %d" % (i + 1))
        r = d.launch("check", channel=url)
        check(r["pending"] == 0 and r["last_error"] == "", "nothing newer on the channel -> no new download (%s)" % r["last_error"])

        print("\n== 5. crash loop: an update that never reaches a healthy menu is rolled back automatically")
        d = Device(ctx, "crash")
        d.launch("check", channel=url)
        r1 = d.launch("plain")
        r2 = d.launch("plain")
        r3 = d.launch("plain")
        check(r1["patched"] and r2["patched"], "the update gets two launches")
        check(not r3["patched"] and r3["rolled_back"] == 1 and "crash loop" in r3["reason"], "third launch falls back to the native build (%s / %s)" % (r3["OTA_STATUS"], r3["reason"]))
        check("rolled back" in (r3["FOOTER"] or ""), "footer says so (%s)" % r3["FOOTER"])
        check(os.path.isdir(os.path.join(d.root, "quarantine")) and os.listdir(os.path.join(d.root, "quarantine")), "the failed update is quarantined for diagnosis")
        r4 = d.launch("check", channel=url)
        check(r4["pending"] == 0, "a rolled-back update is never downloaded again")

        print("\n== 6. corrupt payload on the channel")
        bad = tampered_copy(ctx, "payload", lambda c: flip(os.path.join(c, seqdir, "payload.pck"), 200))
        s, burl = serve(bad)
        servers.append(s)
        d = Device(ctx, "badpayload")
        r = d.launch("check", channel=burl)
        check(r["pending"] == 0 and r["last_error"] != "", "corrupt payload is rejected (%s)" % r["last_error"])
        r = d.launch("plain")
        check(not r["patched"] and not os.path.isdir(os.path.join(d.root, "slots", "1")), "device keeps running the native build, nothing staged")

        print("\n== 7. tampered manifest / wrong key")
        bad = tampered_copy(ctx, "manifest", lambda c: flip(os.path.join(c, entry["manifest"]), 30))
        s, burl = serve(bad)
        servers.append(s)
        d = Device(ctx, "badmanifest")
        r = d.launch("check", channel=burl)
        check(r["pending"] == 0 and "signature" in r["last_error"], "tampered manifest rejected (%s)" % r["last_error"])
        bad = tampered_copy(ctx, "channel", lambda c: flip(os.path.join(c, "channel.json"), 30))
        s, burl = serve(bad)
        servers.append(s)
        r = Device(ctx, "badchannel").launch("check", channel=burl)
        check(r["pending"] == 0 and "signature" in r["last_error"], "tampered channel index rejected (%s)" % r["last_error"])

        print("\n== 8. unreachable channel, wrong platform, disabled")
        d = Device(ctx, "offline")
        r = d.launch("check", channel="http://127.0.0.1:9/")
        check(r["pending"] == 0 and "unreachable" in r["last_error"] and not r["patched"], "unreachable channel leaves the game untouched (%s)" % r["last_error"])
        other = "android" if ctx["platform"] == "windows" else "windows"
        d = Device(ctx, "otherplatform")
        r = d.launch("check", channel=url, platform=other)
        check(r["pending"] == 0, "an update for the other platform is never taken (%s)" % r["last_error"])
        d = Device(ctx, "noota")
        d.launch("check", channel=url)
        r = d.launch("plain", extra_env={"PURGATORY_NO_OTA": "1"})
        check(not r["patched"] and "disabled" in (r["OTA_STATUS"] or ""), "PURGATORY_NO_OTA=1 skips the update for that launch (%s)" % r["OTA_STATUS"])
        r = d.launch("plain", extra_args=["--no-ota"])
        check(not r["patched"] and "disabled" in (r["OTA_STATUS"] or ""), "--no-ota skips the update for that launch")
        r = d.launch("plain")
        check(r["patched"], "the update is still there for the next normal launch")

        print("\n== 9. remote revocation (kill switch) and replay protection")
        d = Device(ctx, "revoke")
        d.launch("check", channel=url)
        d.launch("plain")
        d.launch("confirm")
        revoked = tampered_copy(ctx, "revoked", lambda c: None)
        rc = subprocess.run([sys.executable, os.path.join(ROOT, "tools/ota/channel.py"), "revoke", "--out", revoked, "--key", ctx["key"],
                             "--native-version", str(entry["native_version"]), "--platform", entry["platform"],
                             "--base-commit", entry["base_commit"], "--seq", str(entry["seq"])], capture_output=True, text=True)
        check(rc.returncode == 0, "channel.py revoke produced a new signed index (%s)" % rc.stderr.strip()[-200:])
        s, rurl = serve(revoked)
        servers.append(s)
        r = d.launch("check", channel=rurl)
        check(1 in d.state().get("revoked", []), "the device learned the revocation (%s)" % d.state().get("revoked"))
        r = d.launch("plain")
        check(not r["patched"] and r["rolled_back"] == 1 and "revoked" in r["reason"], "revoked update stops being used at the next launch (%s)" % r["reason"])
        check(d.state().get("generation", 0) > ctx["generation"], "generation advanced")
        r = d.launch("check", channel=url)   # an attacker / stale CDN serves the OLD signed index
        check("replayed" in r["last_error"] or "backwards" in r["last_error"], "an older (replayed) signed index is refused (%s)" % r["last_error"])
        r = d.launch("plain")
        check(not r["patched"], "the replay did not resurrect the revoked update")

        print("\n== 10. save protection")
        check(tree_hash(ctx["saves"]) == saves_before, "the save folder is byte-identical after every scenario above")
    finally:
        for s in servers:
            s.shutdown()
    print("\nota_e2e: %d checks, %d failures" % (CHECKS, len(FAILS)))
    if not args.keep:
        subprocess.run(["git", "worktree", "prune"], cwd=ROOT)
        for t in ("base", "head"):
            subprocess.run(["git", "worktree", "remove", "--force", os.path.join(ctx["tmp"], t)], cwd=ROOT, capture_output=True)
        shutil.rmtree(ctx["work"], ignore_errors=True)
    else:
        print("kept:", ctx["work"])
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
