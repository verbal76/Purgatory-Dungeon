#!/usr/bin/env python3
"""Transport-neutral gates for what is about to be (or was just) published as an OTA (docs/OTA.md sections 6 and 11).

Nothing here knows GitHub, a repository, a token or a particular host: a "base URL" is any place that serves the artifact files by
name (GitHub Releases `.../releases/download/<tag>`, Pages, a plain web server, the local fake server of the tests). All network
reads are ANONYMOUS (no Authorization header, no cookies), because phones read anonymously.

  artifact_gates.py check-names FILE... [--channel C --seq N]
        every file name must be purgatory-<channel>-<seq:06d>.pck, manifest.json, manifest.json.sig or latest.json
  artifact_gates.py scan-secrets FILE... [--pck PACK] [--token-env VAR]
        refuse PEM private-key markers (and the value of VAR, if set) in everything about to be published; the pack's file names and
        bytes are scanned too. Hits are named by file; the value is never printed
  artifact_gates.py immutable --base-url U FILE...
        an already-published file may never change bytes: refuse when U/<name> serves different bytes than FILE (404 = new = fine,
        identical = a harmless re-run, anything else = indeterminate = refused)
  artifact_gates.py download --url U --out F [--retries N]
        anonymous download with retries (the re-download of a published artifact; 404 is retried for propagation, then refused)
  artifact_gates.py verify-anonymous --base-url U FILE... [--config scripts/boot/ota_config.gd | --pubkey PEM]
        read every file back from U without credentials and require the exact size and SHA-256, the manifest signature to verify
        with the public key compiled into the app, and the manifest's pck_size / pck_sha256 to describe the downloaded pack
Standard library + the openssl CLI only. Exit 0 ok, 1 refused.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import time

import otalib
import publish_gates as pg
from otalib import OtaError

ARTIFACT_FIXED = ("manifest.json", "manifest.json.sig", "latest.json")
PCK_NAME = re.compile(r"^purgatory-([a-z][a-z0-9-]{0,31})-(\d{6})\.pck$")
# The markers are assembled from pieces so that this file never contains the literal text it scans for
# (tests/test_ota_tools.py keeps "no private-key marker anywhere in the repository" strict for everything else).
_PRIV = b"PRIV" + b"ATE KEY"
PEM_PRIVATE = re.compile(rb"-----BEGIN [A-Z ]{0,20}" + _PRIV + rb"-----")
KEY_NAME = re.compile(r"(\.pem|\.key|\.p12|\.pfx|\.jks|\.keystore)$|ota-signing|ota_signing")


# ---------------------------------------------------------------- names

def name_violations(names, channel: str = "", seq: int = 0) -> list:
    """Problems for artifact file names (basenames). With channel+seq the pack must be exactly purgatory-<channel>-<seq:06d>.pck."""
    bad = []
    for n in names:
        m = PCK_NAME.match(n)
        if n in ARTIFACT_FIXED:
            continue
        if not m:
            bad.append(f"artifact {n!r} is not an allowed name (purgatory-<channel>-<seq:06d>.pck, manifest.json, manifest.json.sig, latest.json)")
        elif channel and seq and n != f"purgatory-{channel}-{seq:06d}.pck":
            bad.append(f"artifact {n!r} does not belong to this publication (expected purgatory-{channel}-{seq:06d}.pck)")
    return bad


# ---------------------------------------------------------------- secrets

def scan_bytes(data: bytes, what: str, token: str = "", strict_marker: bool = False) -> list:
    """Small public files use the plain private-key marker; large packs the precise PEM header. The value is never in the message."""
    hits = []
    if (PEM_PRIVATE.search(data) if strict_marker else _PRIV in data):
        hits.append(f"{what}: contains a PEM private-key marker")
    if token and token.encode() in data:
        hits.append(f"{what}: contains a secret token value")
    return hits


def scan_file(path: str, token: str = "", big: bool = False) -> list:
    if not big:
        return scan_bytes(otalib.read_bytes(path), os.path.basename(path), token)
    hits, tail, seen = [], b"", set()
    try:
        with open(path, "rb") as f:
            while True:
                chunk = f.read(8 << 20)
                if not chunk:
                    break
                data = tail + chunk
                for h in scan_bytes(data, os.path.basename(path), token, strict_marker=True):
                    if h not in seen:
                        seen.add(h)
                        hits.append(h)
                tail = data[-96:]
    except OSError as e:
        raise OtaError(f"cannot read {path}: {e.strerror or e}")
    return hits


def scan_pack_names(path: str) -> list:
    import pck as pcklib
    try:
        names = [e.path for e in pcklib.read_pck(path).entries]
    except pcklib.PckError as e:
        raise OtaError(str(e))
    return [f"pack file {n!r} looks like key material" for n in names if KEY_NAME.search(n.lower())]


# ---------------------------------------------------------------- anonymous reads

def _fetch(url: str, retries: int, delay: float, sleep, want_ok=(200,)):
    status, body = 0, b""
    for attempt in range(max(1, retries)):
        status, body = pg.fetch_anonymous(url)
        if status in want_ok or (status == 404 and 404 in want_ok) or attempt + 1 >= retries:
            break
        sleep(delay * (attempt + 1))
    return status, body


def immutability_problems(base_url: str, files: dict, retries: int = 1, delay: float = 0.0, sleep=time.sleep) -> list:
    """files: {name: local path}. An already-published artifact may never change bytes."""
    problems = []
    for name, path in sorted(files.items()):
        if name == "latest.json":
            continue                      # the pointer is the one mutable object
        status, body = pg.fetch_anonymous(base_url.rstrip("/") + "/" + name)
        if status == 404:
            continue
        if status != 200:
            problems.append(f"{name}: cannot tell whether it is already published (anonymous HTTP {status}); refusing rather than risk overwriting")
        elif hashlib.sha256(body).hexdigest() != otalib.sha256_file(path):
            problems.append(f"{name}: already published at {base_url} with DIFFERENT bytes; published OTA artifacts are immutable")
    return problems


def verify_anonymous(base_url: str, files: dict, pubkey_pem: bytes, retries: int = 5, delay: float = 5.0, sleep=time.sleep) -> list:
    """Reads every file back WITHOUT credentials: exact size + SHA-256, manifest signature with `pubkey_pem`, and the manifest's
    pck_size / pck_sha256 against the downloaded pack. Returns refusal reasons ([] = verified)."""
    problems, got = [], {}
    for name, path in sorted(files.items()):
        status, body = _fetch(base_url.rstrip("/") + "/" + name, retries, delay, sleep)
        if status != 200:
            problems.append(f"{name}: not anonymously readable at {base_url} (HTTP {status})")
            continue
        got[name] = body
        want = otalib.read_bytes(path)
        if len(body) != len(want):
            problems.append(f"{name}: anonymous download is {len(body)} bytes, published {len(want)}")
        elif hashlib.sha256(body).hexdigest() != hashlib.sha256(want).hexdigest():
            problems.append(f"{name}: anonymous download has a different SHA-256 than the published file")
    if "manifest.json" in got and "manifest.json.sig" in got:
        with tempfile.TemporaryDirectory(prefix="ota-verify-") as d:
            mp, kp = os.path.join(d, "manifest.json"), os.path.join(d, "pub.pem")
            with open(mp, "wb") as f:
                f.write(got["manifest.json"])
            with open(kp, "wb") as f:
                f.write(pubkey_pem)
            try:
                ok = otalib.verify_signature(kp, mp, otalib.sig_decode(got["manifest.json.sig"]))
            except OtaError as e:
                ok = False
                problems.append(f"manifest.json.sig: {e}")
            if not ok and not any(p.startswith("manifest.json.sig:") for p in problems):
                problems.append("manifest.json: the anonymously downloaded signature does not verify with the public key compiled into the app")
        try:
            m = json.loads(got["manifest.json"].decode("utf-8"))
            pck = next((n for n in got if PCK_NAME.match(n)), "")
            if pck:
                if m.get("pck_size") != len(got[pck]):
                    problems.append(f"{pck}: size {len(got[pck])} differs from the signed manifest ({m.get('pck_size')})")
                if m.get("pck_sha256") != hashlib.sha256(got[pck]).hexdigest():
                    problems.append(f"{pck}: SHA-256 differs from the signed manifest")
        except (ValueError, UnicodeDecodeError):
            problems.append("manifest.json: the anonymously downloaded manifest is not valid JSON")
    elif files and ("manifest.json" in files or "manifest.json.sig" in files):
        problems.append("the manifest and its signature must be verified together")
    return problems


# ---------------------------------------------------------------- CLI

def _files(paths) -> dict:
    out = {}
    for p in paths:
        n = os.path.basename(p)
        if n in out:
            raise OtaError(f"two artifacts are named {n!r}")
        out[n] = p
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("check-names")
    p.add_argument("files", nargs="+")
    p.add_argument("--channel", default="")
    p.add_argument("--seq", type=int, default=0)
    p = sub.add_parser("scan-secrets")
    p.add_argument("files", nargs="*")
    p.add_argument("--pck", default="")
    p.add_argument("--token-env", default="")
    p = sub.add_parser("immutable")
    p.add_argument("files", nargs="+")
    p.add_argument("--base-url", required=True)
    p = sub.add_parser("download")
    p.add_argument("--url", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--retries", type=int, default=5)
    p.add_argument("--delay", type=float, default=5.0)
    p = sub.add_parser("verify-anonymous")
    p.add_argument("files", nargs="+")
    p.add_argument("--base-url", required=True)
    p.add_argument("--config", default="")
    p.add_argument("--pubkey", default="")
    p.add_argument("--retries", type=int, default=5)
    p.add_argument("--delay", type=float, default=5.0)
    a = ap.parse_args(argv)
    try:
        problems = []
        if a.cmd == "check-names":
            problems = name_violations([os.path.basename(f) for f in a.files], a.channel, a.seq)
            ok = f"{len(a.files)} artifact name(s) allowed"
        elif a.cmd == "scan-secrets":
            token = os.environ.get(a.token_env, "") if a.token_env else ""
            for f in a.files:
                problems += scan_file(f, token)
            if a.pck:
                problems += scan_pack_names(a.pck) + scan_file(a.pck, token, big=True)
            ok = f"secret scan clean: {len(a.files)} file(s){' + the pack' if a.pck else ''}"
        elif a.cmd == "download":
            status, body = _fetch(a.url, a.retries, a.delay, time.sleep)
            if status != 200:
                raise OtaError(f"{a.url} is not anonymously downloadable (HTTP {status})")
            otalib.write_atomic(a.out, body)
            ok = f"downloaded {a.url} ({len(body)} bytes) anonymously"
        elif a.cmd == "immutable":
            problems = immutability_problems(a.base_url, _files(a.files))
            ok = "no already-published artifact changes"
        else:
            if a.pubkey:
                pem = otalib.read_bytes(a.pubkey)
            elif a.config:
                pem = str(pg.config_value(otalib.read_bytes(a.config).decode("utf-8"), "PUBLIC_KEY_PEM")).strip().encode() + b"\n"
            else:
                raise OtaError("--config scripts/boot/ota_config.gd or --pubkey PEM is required")
            problems = verify_anonymous(a.base_url, _files(a.files), pem, a.retries, a.delay)
            ok = f"{len(a.files)} artifact(s) read back anonymously: exact size + SHA-256, signature verified with the app's public key"
        if problems:
            for pr in problems:
                print("REFUSED:", pr, file=sys.stderr)
            return 1
        print(ok)
    except OtaError as e:
        print(f"artifact_gates.py: {a.cmd}: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
