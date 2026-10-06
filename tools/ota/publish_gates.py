#!/usr/bin/env python3
"""The decisions of .github/workflows/ota-publish.yml as small, testable commands (docs/OTA.md sections 5, 6, 11).
Every command fails closed: a non-zero exit stops the job before anything becomes visible to devices.

  publish_gates.py parse-branch REF_NAME SHA            ota/<channel>/<40-hex> whose head commit IS that sha -> channel
  publish_gates.py next-seq CHANNEL < tags              highest ota-<channel>-NNNNNN in the tag list + 1 (never reused)
  publish_gates.py host --this-repo R [--var V] [--token-present 0|1] [--config ota_config.gd]
                                                        the release host repository and whether it may be written
  publish_gates.py key-match --key PRIVATE.pem --config scripts/boot/ota_config.gd
                                                        the signing key's public half == PUBLIC_KEY_PEM (fingerprints only)
  publish_gates.py make-pointer --channel C --ota-id ID --seq N --runtime-id R --manifest-url U --signature-url U
                                --native-version N --app-minor K --out F
  publish_gates.py next-minor --native-version N [--current latest.json] [--new-seq S]
                                                        app_minor of this OTA from the LIVE pointer: same native generation ->
                                                        pointer.app_minor + 1, otherwise 1 (v7.1, v7.2 ... v8.1); refuses a pointer
                                                        that is not strictly behind this publication
  publish_gates.py pointer-decision --current-seq N|none --new-seq N     forward only: exit 1 unless new > current
  publish_gates.py pointer-confirm --url U --channel C --expect-id ID    the live pointer serves the intended OTA
  publish_gates.py check-anonymous --expect URL=SHA256[:SIZE] ...        every URL is readable WITHOUT credentials, with
                                                        exactly the published bytes (a private host fails here)
  publish_gates.py receipt --out F [--published 0|1] [--pointer-moved 0|1] [--reason TEXT] [fact options]
                                                        the publication receipt (shape checked by validate_receipt)
  publish_gates.py summary receipt.json                 the receipt as separate lines (native APK, running version, OTA id, runtime, base URL ...)
  (artifact_gates.py: transport-neutral name allowlist, secret scan, immutability and anonymous read-back gates)
  publish_gates.py baseline BUILD_INFO.json [--channel C]
                                                        validate the shipped baseline's build_info.json and print its identity
  publish_gates.py same-runtime --baseline BUILD_INFO.json --current RUNTIME.json
                                                        the commit's runtime (ota_runtime.py --print --json) == the baseline's
  publish_gates.py config-value FILE CONSTANT          a string/int constant of scripts/boot/ota_config.gd
Standard library + the openssl CLI only. Network access happens only in pointer-confirm and check-anonymous.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

import otalib
from otalib import OtaError

BRANCH_RE = re.compile(r"^ota/([a-z][a-z0-9-]{0,31})/([0-9a-f]{40})$")
RESERVED_CHANNELS = ("channel",)
POINTER_TAG = "ota-channel-{channel}"
RELEASE_TAG = "ota-{channel}-{seq:06d}"
LOCAL_HOSTS = ("127.0.0.1", "localhost", "::1")


# ---------------------------------------------------------------- pure logic

def parse_branch(ref_name: str, sha: str) -> tuple:
    """(channel, sha) for `ota/<channel>/<40-hex>` when `sha` (github.sha) is that exact commit; else OtaError."""
    ref_name = ref_name[len("refs/heads/"):] if ref_name.startswith("refs/heads/") else ref_name
    m = BRANCH_RE.match(ref_name)
    if not m:
        raise OtaError(f"branch {ref_name!r} is not ota/<channel>/<full 40-hex sha>; only an explicitly SHA-named branch may publish "
                       "(a moving branch name could publish an unreviewed commit)")
    channel, named = m.groups()
    if channel in RESERVED_CHANNELS:
        raise OtaError(f"channel name {channel!r} is reserved")
    if not otalib.HEX40.match(sha or ""):
        raise OtaError(f"github.sha {sha!r} is not a full 40-hex commit id")
    if sha != named:
        raise OtaError(f"the branch names commit {named} but its head commit is {sha}: refusing (publish exactly the named commit)")
    return channel, sha


def next_seq(tags, channel: str) -> int:
    """highest published ota-<channel>-NNNNNN + 1; numbers are never reused (drafts/prereleases count: pass every tag)."""
    rx = re.compile(r"^ota-" + re.escape(channel) + r"-(\d{6})$")
    best = 0
    for t in tags:
        m = rx.match(str(t).strip())
        if m:
            best = max(best, int(m.group(1)))
    return best + 1


def resolve_host(this_repo: str, var: str = "", token_present: bool = False, baked_repo: str = "") -> dict:
    """The release host. Default: this repository. A different repository needs OTA_RELEASE_TOKEN. When the app's baked REPO is
    known it must equal the host (the device builds its URLs from it). Returns {repo, same_repo, ok, reason}."""
    repo = (var or "").strip() or this_repo
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise OtaError(f"OTA_RELEASE_REPO {repo!r} is not owner/name")
    same = repo.lower() == this_repo.lower()
    out = {"repo": repo, "same_repo": same, "ok": True, "reason": ""}
    if not same and not token_present:
        out.update(ok=False, reason=f"release host {repo} differs from this repository and the secret OTA_RELEASE_TOKEN is not set (unconfigured host)")
    if baked_repo and baked_repo.lower() != repo.lower():
        raise OtaError(f"the installed app looks for updates in {baked_repo} (REPO in scripts/boot/ota_config.gd) but the release host is "
                       f"{repo}: devices would never see this update")
    return out


def release_url(repo: str, tag: str, asset: str) -> str:
    return f"https://github.com/{repo}/releases/download/{tag}/{asset}"


def pointer_document(channel: str, ota_id: str, seq: int, runtime_id: str, manifest_url: str, signature_url: str,
                     published_at: str = "", native_version: int = 0, app_minor: int = 0) -> dict:
    if not otalib.CHANNEL_RE.match(channel):
        raise OtaError(f"bad channel {channel!r}")
    if ota_id != f"{channel}-{seq:06d}":
        raise OtaError(f"ota_id {ota_id} does not match channel {channel} / seq {seq}")
    for u in (manifest_url, signature_url):
        if not u.startswith("https://"):
            raise OtaError(f"pointer URLs must be https (got {u})")
    for name, v in (("native_version", native_version), ("app_minor", app_minor)):
        if not isinstance(v, int) or isinstance(v, bool) or v < 1:
            raise OtaError(f"{name} must be a whole number >= 1 (got {v!r})")
    return {"channel": channel, "ota_id": ota_id, "seq": seq, "runtime_id": runtime_id, "manifest_url": manifest_url,
            "signature_url": signature_url, "published_at": published_at or otalib.utc_now(),
            "native_version": native_version, "app_minor": app_minor}


def owner_version(native_version: int, app_minor: int) -> str:
    """The owner-facing running version: 'v7.1' = the first OTA on the v7 APK. Whole numbers are real APKs, decimals are OTAs."""
    return f"v{native_version}.{app_minor}"


def next_minor(pointer, native_version: int, new_seq: int = 0) -> int:
    """The app_minor of the OTA being published, derived from the LIVE pointer (never from a counter the workflow could lose):
    pointer.app_minor + 1 when the pointer names this same native generation, otherwise 1 (no pointer yet, or the first OTA on a
    new APK generation). Refuses a pointer that is not strictly behind this publication: seq forward-only, and never an OTA for an
    older native generation than the one the pointer serves. Two OTAs of one native generation can therefore never share a minor."""
    if not isinstance(native_version, int) or native_version < 1:
        raise OtaError(f"native_version must be a whole number >= 1 (got {native_version!r})")
    if pointer is None:
        return 1
    if new_seq and not pointer_forward(pointer["seq"], new_seq):
        raise OtaError(f"the pointer is at seq {pointer['seq']}; this publication (seq {new_seq}) would not move it forward")
    if pointer["native_version"] > native_version:
        raise OtaError(f"the pointer already serves native generation v{pointer['native_version']}; "
                       f"an OTA for the older APK v{native_version} must not replace it")
    if pointer["native_version"] == native_version:
        return pointer["app_minor"] + 1
    return 1


def pointer_forward(current_seq, new_seq: int) -> bool:
    """Forward only: the pointer may be created or moved to a strictly higher seq, never to <= the current one."""
    return current_seq is None or new_seq > int(current_seq)


def parse_pointer(data: bytes) -> dict:
    d = otalib.load_json_bytes(data, "latest.json")
    if not isinstance(d, dict):
        raise OtaError("latest.json is not a JSON object")
    for k, t in (("channel", str), ("ota_id", str), ("seq", int), ("runtime_id", str), ("manifest_url", str),
                 ("signature_url", str), ("published_at", str), ("native_version", int), ("app_minor", int)):
        if not isinstance(d.get(k), t) or isinstance(d.get(k), bool):
            raise OtaError(f"latest.json: field {k!r} missing or of the wrong type")
    if d["native_version"] < 1 or d["app_minor"] < 1:
        raise OtaError("latest.json: native_version and app_minor must be >= 1")
    return d


def anonymous_verdict(results) -> list:
    """results: [{url, status, sha256, size, expect_sha256, expect_size}] -> list of refusal reasons ([] = all reachable)."""
    problems = []
    for r in results:
        if r.get("status") != 200:
            problems.append(f"{r['url']}: not anonymously reachable (HTTP {r.get('status')}); a private or missing host cannot serve devices")
        elif r.get("expect_size") is not None and r.get("size") != r["expect_size"]:
            problems.append(f"{r['url']}: anonymous download is {r.get('size')} bytes, published {r['expect_size']}")
        elif r.get("sha256") != r.get("expect_sha256"):
            problems.append(f"{r['url']}: anonymous download has SHA-256 {r.get('sha256')}, published {r.get('expect_sha256')}")
    if not results:
        problems.append("nothing to check")
    return problems


RECEIPT_KEYS = ("schema", "published", "pointer_moved", "release_created", "reason", "channel", "ota_id", "seq", "native_version",
                "app_minor", "owner_version", "source_sha",
                "base_source_sha", "native_base_tag", "runtime_id", "runtime_fingerprint", "pck_sha256", "pck_size",
                "manifest_sha256", "signature_sha256", "urls", "release_host", "base_url", "anonymous_read_verified", "run", "created_at")


def make_receipt(published: bool, pointer_moved: bool, release_created: bool, reason: str = "", **facts) -> dict:
    r = {k: None for k in RECEIPT_KEYS}
    r.update({"schema": 1, "published": bool(published), "pointer_moved": bool(pointer_moved),
              "release_created": bool(release_created), "reason": reason or None, "created_at": otalib.utc_now(),
              "urls": {"pck": None, "manifest": None, "signature": None, "pointer": None}, "run": {"id": None, "url": None}})
    for k, v in facts.items():
        if k == "urls":
            r["urls"].update(v)
        elif k == "run":
            r["run"].update(v)
        elif k in r:
            r[k] = v
        else:
            raise OtaError(f"unknown receipt field {k}")
    if r["native_version"] and r["app_minor"] and not r["owner_version"]:
        r["owner_version"] = owner_version(r["native_version"], r["app_minor"])
    problem = validate_receipt(r)
    if problem:
        raise OtaError("receipt: " + problem)
    return r


def summary_lines(r: dict) -> list:
    """The receipt as separate human lines (job summary): the three identities are never merged into one string."""
    def yn(v):
        return "yes" if v else "no"
    nv = r.get("native_version")
    seq = r.get("seq")
    return [
        f"Native APK: {'v%d' % nv if nv else 'unknown'}",
        f"Owner-facing running version: {r.get('owner_version') or 'unknown'}",
        f"OTA update id: {('#%06d' % seq) if seq else 'unknown'}" + (f" ({r['ota_id']})" if r.get("ota_id") else ""),
        f"Runtime: {r.get('runtime_id') or 'unknown'} / {r.get('runtime_fingerprint') or 'unknown'}",
        f"Base URL: {r.get('base_url') or 'unknown'}",
        f"Anonymous read verified: {yn(r.get('anonymous_read_verified'))}",
        f"Pointer moved: {yn(r.get('pointer_moved'))}",
        f"Published: {yn(r.get('published'))}" + ("" if r.get("published") else f" (reason: {r.get('reason')})"),
    ]


def validate_receipt(r: dict) -> str:
    """'' when the receipt has the documented shape and is internally consistent."""
    if set(r) != set(RECEIPT_KEYS):
        return f"fields differ from the schema: {sorted(set(r) ^ set(RECEIPT_KEYS))}"
    for k in ("published", "pointer_moved", "release_created"):
        if not isinstance(r[k], bool):
            return f"{k} must be a boolean"
    if r["published"] and not (r["pointer_moved"] and r["release_created"]):
        return "published implies the release was created and the pointer moved"
    if r["pointer_moved"] and not r["release_created"]:
        return "the pointer cannot move without a created release"
    if not r["published"] and not r["reason"]:
        return "an unpublished receipt must say why (reason)"
    if r["anonymous_read_verified"] is not None and not isinstance(r["anonymous_read_verified"], bool):
        return "anonymous_read_verified must be a boolean"
    if r["published"] and r["anonymous_read_verified"] is not True:
        return "a published receipt needs anonymous_read_verified (every artifact and the pointer were read back without credentials)"
    if r["published"]:
        for k in ("channel", "ota_id", "seq", "native_version", "app_minor", "owner_version", "source_sha", "runtime_id", "runtime_fingerprint", "pck_sha256", "pck_size",
                  "manifest_sha256", "signature_sha256"):
            if r[k] in (None, ""):
                return f"a published receipt needs {k}"
        for k in ("pck", "manifest", "signature", "pointer"):
            if not r["urls"].get(k):
                return f"a published receipt needs urls.{k}"
    if r["owner_version"] is not None and r["owner_version"] != owner_version(r["native_version"] or 0, r["app_minor"] or 0):
        return "owner_version must be v<native_version>.<app_minor>"
    for k, rx in (("source_sha", otalib.HEX40), ("base_source_sha", otalib.HEX40), ("runtime_fingerprint", otalib.HEX64),
                  ("pck_sha256", otalib.HEX64), ("manifest_sha256", otalib.HEX64), ("signature_sha256", otalib.HEX64)):
        if r[k] is not None and not rx.match(str(r[k])):
            return f"{k} is not a lowercase hex hash"
    return ""


def baseline_identity(info: dict, channel: str = "") -> dict:
    """The identity of the SHIPPED native build from its build_info.json (docs/OTA.md section 3)."""
    out = {"base_sha": info.get("commit"), "runtime_id": info.get("runtime_id"),
           "runtime_fingerprint": info.get("runtime_fingerprint"), "ota_channel": info.get("ota_channel"),
           "native_version": info.get("public_version")}
    if not isinstance(out["base_sha"], str) or not otalib.HEX40.match(out["base_sha"]):
        raise OtaError("the baseline's build_info.json has no valid 'commit' (40-hex native source SHA)")
    if not isinstance(out["runtime_id"], str) or not re.fullmatch(r"[a-z]+-godot-[0-9]+\.[0-9]+\.[0-9]+-r[1-9][0-9]*", out["runtime_id"]):
        raise OtaError("the baseline's build_info.json has no valid runtime_id (it predates the v7 runtime identity?)")
    if not isinstance(out["runtime_fingerprint"], str) or not otalib.HEX64.match(out["runtime_fingerprint"]):
        raise OtaError("the baseline's build_info.json has no valid runtime_fingerprint")
    if not isinstance(out["ota_channel"], str) or not otalib.CHANNEL_RE.match(out["ota_channel"]):
        raise OtaError("the baseline's build_info.json has no valid ota_channel")
    if not isinstance(out["native_version"], int) or out["native_version"] < 1:
        raise OtaError("the baseline's build_info.json has no valid public_version")
    if channel and out["ota_channel"] != channel:
        raise OtaError(f"the installed app follows channel {out['ota_channel']!r}, not {channel!r}: an OTA for {channel!r} would never be offered to it")
    return out


def same_runtime(baseline: dict, current: dict) -> list:
    """Problems when the commit being published does not have the runtime the installed build has."""
    problems = []
    for key, label in (("runtime_id", "runtime id"), ("runtime_fingerprint", "runtime fingerprint"), ("ota_channel", "OTA channel")):
        if baseline.get(key) != current.get(key):
            problems.append(f"{label} differs: installed build {baseline.get(key)!r}, this commit {current.get(key)!r}")
    if problems:
        problems.append("the native layer changed since the installed build (a new APK is required), so this commit cannot ship over the air")
    return problems


# ---------------------------------------------------------------- key / config

def config_value(text: str, name: str):
    """The value of `const NAME := "x"` / `const NAME: String = \"\"\"...\"\"\"` / `const NAME := 3` in ota_config.gd."""
    pre = r"(?m)^[ \t]*const[ \t]+" + re.escape(name) + r"[ \t]*(?::[ \t]*[A-Za-z_]\w*[ \t]*=|:=|=)[ \t]*"
    m = re.search(pre + r'"""(.*?)"""', text, re.S)
    if m:
        return m.group(1)
    m = re.search(pre + r'"([^"\n]*)"', text)
    if m:
        return m.group(1)
    m = re.search(pre + r"(-?\d+)\b", text)
    if m:
        return int(m.group(1))
    raise OtaError(f"constant {name} not found in the config")


def _pem_to_der_sha256(pem_text: str) -> str:
    return otalib.public_key_der_sha256(pem_text.strip().encode() + b"\n")


def key_match(key_path: str, config_text: str) -> str:
    """SHA-256 (DER) of the public key when the private key's public half equals PUBLIC_KEY_PEM, else OtaError. Never prints key material."""
    otalib.private_key_bits(key_path)
    derived = otalib.public_key_der_sha256(otalib.public_key_pem(key_path))
    embedded = config_value(config_text, "PUBLIC_KEY_PEM")
    if not isinstance(embedded, str) or "BEGIN PUBLIC KEY" not in embedded:
        raise OtaError("PUBLIC_KEY_PEM in scripts/boot/ota_config.gd is empty or not a PEM public key")
    try:
        have = _pem_to_der_sha256(embedded)
    except OtaError:
        raise OtaError("PUBLIC_KEY_PEM in scripts/boot/ota_config.gd cannot be parsed as an RSA public key")
    if have != derived:
        raise OtaError(f"the signing key does not match the public key embedded in the APK (key {derived[:16]}..., app {have[:16]}...): "
                       "an update signed with it would be rejected by every device")
    return derived


# ---------------------------------------------------------------- network (anonymous)

def _opener(url: str):
    host = urllib.parse.urlparse(url).hostname or ""
    handlers = [urllib.request.ProxyHandler({})] if host in LOCAL_HOSTS else []
    return urllib.request.build_opener(*handlers)


def fetch_anonymous(url: str, timeout: int = 60):
    """(status, body bytes) with NO credentials (no Authorization header, no token), following redirects."""
    req = urllib.request.Request(url, headers={"User-Agent": "purgatory-ota-gate/1", "Cache-Control": "no-cache"})
    try:
        with _opener(url).open(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, b""
    except (urllib.error.URLError, OSError, ValueError) as e:
        return 0, str(e).encode()


def check_anonymous(expect, retries: int = 5, delay: float = 5.0, sleep=time.sleep) -> list:
    """expect: [(url, sha256, size|None)]. Retries for CDN propagation; returns refusal reasons ([] = fine)."""
    problems = []
    for attempt in range(max(1, retries)):
        results = []
        for url, sha, size in expect:
            status, body = fetch_anonymous(url)
            results.append({"url": url, "status": status, "sha256": hashlib.sha256(body).hexdigest() if status == 200 else None,
                            "size": len(body) if status == 200 else None, "expect_sha256": sha, "expect_size": size})
        problems = anonymous_verdict(results)
        if not problems:
            return []
        if attempt + 1 < retries:
            sleep(delay * (attempt + 1))
    return problems


def pointer_confirm(url: str, channel: str, expect_id: str, retries: int = 6, delay: float = 5.0, sleep=time.sleep,
                    expect_minor: int = 0) -> dict:
    last = "never fetched"
    for attempt in range(max(1, retries)):
        sep = "&" if "?" in url else "?"
        status, body = fetch_anonymous(f"{url}{sep}nocache={int(time.time() * 1000)}")
        if status == 200:
            try:
                d = parse_pointer(body)
                if d["channel"] == channel and d["ota_id"] == expect_id and (not expect_minor or d["app_minor"] == expect_minor):
                    return d
                last = (f"the live pointer serves {d['channel']}/{d['ota_id']} (app_minor {d['app_minor']}), "
                        f"expected {channel}/{expect_id}" + (f" (app_minor {expect_minor})" if expect_minor else ""))
            except OtaError as e:
                last = str(e)
        else:
            last = f"HTTP {status}"
        if attempt + 1 < retries:
            sleep(delay * (attempt + 1))
    raise OtaError(f"pointer {url} does not serve the intended OTA {expect_id}: {last}")


# ---------------------------------------------------------------- CLI

def _flag(v: str) -> bool:
    if v in ("1", "true", "True"):
        return True
    if v in ("0", "false", "False", ""):
        return False
    raise OtaError(f"expected 0/1, got {v!r}")


def _cmd_expect(spec: str):
    url, _, rest = spec.rpartition("=")
    sha, _, size = rest.partition(":")
    if not url or not otalib.HEX64.match(sha) or (size and not size.isdigit()):
        raise OtaError(f"--expect must be URL=SHA256[:SIZE], got {spec!r}")
    return url, sha, int(size) if size else None


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("parse-branch")
    p.add_argument("ref_name")
    p.add_argument("sha")
    p = sub.add_parser("next-seq")
    p.add_argument("channel")
    p = sub.add_parser("host")
    p.add_argument("--this-repo", required=True)
    p.add_argument("--var", default="")
    p.add_argument("--token-present", default="0")
    p.add_argument("--config", default="")
    p = sub.add_parser("key-match")
    p.add_argument("--key", required=True)
    p.add_argument("--config", required=True)
    p = sub.add_parser("make-pointer")
    for k in ("channel", "ota-id", "runtime-id", "manifest-url", "signature-url", "out"):
        p.add_argument("--" + k, required=True)
    p.add_argument("--seq", type=int, required=True)
    p.add_argument("--native-version", type=int, required=True)
    p.add_argument("--app-minor", type=int, required=True)
    p = sub.add_parser("next-minor")
    p.add_argument("--native-version", type=int, required=True)
    p.add_argument("--new-seq", type=int, default=0)
    p.add_argument("--current", default="", help="the live pointer's latest.json (absent/empty path = no pointer yet)")
    p = sub.add_parser("pointer-decision")
    p.add_argument("--current-seq", required=True)
    p.add_argument("--new-seq", type=int, required=True)
    p = sub.add_parser("pointer-confirm")
    p.add_argument("--url", required=True)
    p.add_argument("--channel", required=True)
    p.add_argument("--expect-id", required=True)
    p.add_argument("--expect-minor", type=int, default=0)
    p.add_argument("--retries", type=int, default=6)
    p.add_argument("--delay", type=float, default=5.0)
    p = sub.add_parser("check-anonymous")
    p.add_argument("--expect", action="append", required=True)
    p.add_argument("--retries", type=int, default=5)
    p.add_argument("--delay", type=float, default=5.0)
    p = sub.add_parser("receipt")
    p.add_argument("--out", required=True)
    p.add_argument("--published", default="0")
    p.add_argument("--pointer-moved", default="0")
    p.add_argument("--release-created", default="0")
    p.add_argument("--reason", default="")
    for k in ("channel", "ota-id", "source-sha", "base-source-sha", "native-base-tag", "runtime-id", "runtime-fingerprint",
              "pck-sha256", "manifest-sha256", "signature-sha256", "release-host", "run-id", "run-url", "pck-url",
              "manifest-url", "signature-url", "pointer-url"):
        p.add_argument("--" + k, default="")
    p.add_argument("--anonymous-read-verified", default="")
    p.add_argument("--base-url", default="")
    p.add_argument("--seq", type=int, default=0)
    p.add_argument("--native-version", type=int, default=0)
    p.add_argument("--app-minor", type=int, default=0)
    p.add_argument("--pck-size", type=int, default=0)
    p = sub.add_parser("summary")
    p.add_argument("receipt")
    p = sub.add_parser("baseline")
    p.add_argument("build_info")
    p.add_argument("--channel", default="")
    p = sub.add_parser("same-runtime")
    p.add_argument("--baseline", required=True)
    p.add_argument("--current", required=True)
    p = sub.add_parser("config-value")
    p.add_argument("file")
    p.add_argument("constant")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "parse-branch":
            channel, sha = parse_branch(a.ref_name, a.sha)
            print(f"channel={channel}\nsha={sha}")
        elif a.cmd == "next-seq":
            print(next_seq(sys.stdin.read().split(), a.channel))
        elif a.cmd == "host":
            baked = ""
            if a.config:
                baked = str(config_value(otalib.read_bytes(a.config).decode("utf-8"), "REPO"))
            h = resolve_host(a.this_repo, a.var, _flag(a.token_present), baked)
            print(f"repo={h['repo']}\nsame_repo={'1' if h['same_repo'] else '0'}\nok={'1' if h['ok'] else '0'}\nreason={h['reason']}")
        elif a.cmd == "key-match":
            fp = key_match(a.key, otalib.read_bytes(a.config).decode("utf-8"))
            print(f"signing key matches the public key embedded in the APK (SHA-256 {fp})")
        elif a.cmd == "make-pointer":
            doc = pointer_document(a.channel, a.ota_id, a.seq, a.runtime_id, a.manifest_url, a.signature_url,
                                   native_version=a.native_version, app_minor=a.app_minor)
            otalib.write_atomic(a.out, otalib.canonical_json(doc))
            print(f"pointer document for {a.ota_id} written to {a.out}")
        elif a.cmd == "next-minor":
            cur = None
            if a.current and os.path.isfile(a.current):
                cur = parse_pointer(otalib.read_bytes(a.current))
            minor = next_minor(cur, a.native_version, a.new_seq)
            print(f"app_minor={minor}\nowner_version={owner_version(a.native_version, minor)}")
        elif a.cmd == "pointer-decision":
            cur = None if a.current_seq in ("none", "") else int(a.current_seq)
            if not pointer_forward(cur, a.new_seq):
                print(f"REFUSED: the pointer is at seq {cur}; it only moves forward (new seq {a.new_seq})", file=sys.stderr)
                return 1
            print(f"forward: {cur} -> {a.new_seq}")
        elif a.cmd == "pointer-confirm":
            d = pointer_confirm(a.url, a.channel, a.expect_id, a.retries, a.delay, expect_minor=a.expect_minor)
            print(f"the live pointer serves {d['ota_id']} (seq {d['seq']}, {owner_version(d['native_version'], d['app_minor'])})")
        elif a.cmd == "check-anonymous":
            problems = check_anonymous([_cmd_expect(e) for e in a.expect], a.retries, a.delay)
            if problems:
                for pr in problems:
                    print("REFUSED:", pr, file=sys.stderr)
                return 1
            print(f"{len(a.expect)} published object(s) are anonymously reachable with the exact published bytes")
        elif a.cmd == "receipt":
            facts = {"channel": a.channel or None, "ota_id": a.ota_id or None, "seq": a.seq or None, "native_version": a.native_version or None,
                     "base_url": a.base_url or None,
                     "anonymous_read_verified": None if a.anonymous_read_verified == "" else _flag(a.anonymous_read_verified),
                     "app_minor": a.app_minor or None, "source_sha": a.source_sha or None,
                     "base_source_sha": a.base_source_sha or None, "native_base_tag": a.native_base_tag or None,
                     "runtime_id": a.runtime_id or None, "runtime_fingerprint": a.runtime_fingerprint or None,
                     "pck_sha256": a.pck_sha256 or None, "pck_size": a.pck_size or None, "manifest_sha256": a.manifest_sha256 or None,
                     "signature_sha256": a.signature_sha256 or None, "release_host": a.release_host or None,
                     "urls": {"pck": a.pck_url or None, "manifest": a.manifest_url or None, "signature": a.signature_url or None,
                              "pointer": a.pointer_url or None},
                     "run": {"id": a.run_id or None, "url": a.run_url or None}}
            r = make_receipt(_flag(a.published), _flag(a.pointer_moved), _flag(a.release_created), a.reason, **facts)
            otalib.write_atomic(a.out, otalib.canonical_json(r))
            print(json.dumps(r, indent=2, sort_keys=True))
        elif a.cmd == "summary":
            print("\n".join(summary_lines(otalib.load_json_bytes(otalib.read_bytes(a.receipt), a.receipt))))
        elif a.cmd == "baseline":
            b = baseline_identity(otalib.load_json_bytes(otalib.read_bytes(a.build_info), a.build_info), a.channel)
            for k in ("base_sha", "runtime_id", "runtime_fingerprint", "ota_channel", "native_version"):
                print(f"{k}={b[k]}")
        elif a.cmd == "same-runtime":
            problems = same_runtime(otalib.load_json_bytes(otalib.read_bytes(a.baseline), a.baseline),
                                    otalib.load_json_bytes(otalib.read_bytes(a.current), a.current))
            if problems:
                for pr in problems:
                    print("REFUSED:", pr, file=sys.stderr)
                return 1
            print("runtime identity equals the installed build's")
        elif a.cmd == "config-value":
            print(config_value(otalib.read_bytes(a.file).decode("utf-8"), a.constant))
    except OtaError as e:
        print(f"publish_gates.py: {a.cmd}: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
