#!/usr/bin/env python3
"""Maintains the signed channel index (channel.json + channel.json.sig) of an OTA channel directory.

  channel.py merge  --out <channel dir> --key <rsa private pem> [--add <bundle root>]... [--drop-missing]
                    [--generated-utc T]
        indexes every <out>/v<N>/<platform>/update-<K>/ bundle (after checking its manifest signature with
        this key, payload size/sha256 and that names match the manifest), keeps the previous `revoked` list
        and raises `generation` by one. --add first copies the update folders of other bundle roots (for
        example the artifacts of the per-platform jobs) into --out; an existing folder must be identical.
        Nothing changes (and the generation stays) when the resulting index equals the current one.
  channel.py revoke --out <dir> --key <pem> --native-version N --platform P --base-commit C --seq K
        adds the kill-switch entry {native_version, platform, base_commit, seq} to `revoked`, bumps the
        generation and re-signs. The update stays listed; devices stop using it at their next launch.

Shapes are exactly docs/OTA.md "channel.json". Output is deterministic JSON (sorted keys, 2-space indent,
trailing newline) and the signature is over the exact bytes written. A previous channel.json that does not
verify against --key is refused (never continue a channel signed by another key).
"""
import argparse
import os
import shutil
import sys
import tempfile

import otalib
from otalib import OtaError


def _pub_for(key: str) -> str:
    """Writes the key's public half to a temp file (removed by the caller via the returned dir)."""
    d = tempfile.mkdtemp(prefix="ota-pub-")
    path = os.path.join(d, "pub.pem")
    otalib.write_atomic(path, otalib.public_key_pem(key))
    return path


def load_channel(out: str, pub: str):
    """The current channel dict (signature checked) or None when the channel is new."""
    path = os.path.join(out, "channel.json")
    if not os.path.isfile(path):
        return None
    sigp = path + ".sig"
    if not os.path.isfile(sigp):
        raise OtaError(f"{path} exists without {os.path.basename(sigp)}")
    if not otalib.verify_signature(pub, path, otalib.sig_decode(otalib.read_bytes(sigp))):
        raise OtaError(f"existing {path} does not verify against this key; refusing to continue a channel signed by another key")
    ch = otalib.load_json_bytes(otalib.read_bytes(path), "channel.json")
    gen = ch.get("generation")
    if ch.get("format") != otalib.FORMAT or ch.get("product") != otalib.PRODUCT or not isinstance(gen, int) or gen < 1:
        raise OtaError("existing channel.json has an unexpected shape")
    return ch


def write_channel(out: str, key: str, ch: dict) -> None:
    path = os.path.join(out, "channel.json")
    otalib.write_atomic(path, otalib.canonical_json(ch))
    otalib.sign_to_file(key, path, path + ".sig")


def copy_bundles(out: str, roots: list) -> int:
    n = 0
    for root in roots:
        found = otalib.scan_updates(root)
        if not found:
            raise OtaError(f"--add {root}: no v<N>/<platform>/update-<K> folders found")
        for u in found:
            dest = os.path.join(out, *u["rel"].split("/"))
            if os.path.exists(dest):
                for name in ("manifest.json", "manifest.sig", "payload.pck"):
                    if otalib.read_bytes(os.path.join(u["dir"], name)) != otalib.read_bytes(os.path.join(dest, name)):
                        raise OtaError(f"{u['rel']} already exists in {out} with different content; update folders are immutable")
                continue
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copytree(u["dir"], dest)
            n += 1
    return n


def index_updates(out: str, pub: str) -> list:
    entries = []
    for u in otalib.scan_updates(out):
        mp = os.path.join(u["dir"], "manifest.json")
        sp = os.path.join(u["dir"], "manifest.sig")
        pp = os.path.join(u["dir"], "payload.pck")
        for p in (mp, sp, pp):
            if not os.path.isfile(p):
                raise OtaError(f"{u['rel']}: {os.path.basename(p)} is missing")
        if not otalib.verify_signature(pub, mp, otalib.sig_decode(otalib.read_bytes(sp))):
            raise OtaError(f"{u['rel']}: manifest signature does not verify with this key")
        m = otalib.load_json_bytes(otalib.read_bytes(mp), u["rel"] + "/manifest.json")
        pl = m.get("payload") or {}
        if (m.get("native_version"), m.get("platform"), m.get("payload_seq")) != (u["native_version"], u["platform"], u["seq"]):
            raise OtaError(f"{u['rel']}: manifest says v{m.get('native_version')}/{m.get('platform')}/update-{m.get('payload_seq')}")
        if not otalib.HEX40.match(str(m.get("base_commit", ""))):
            raise OtaError(f"{u['rel']}: manifest base_commit is not 40 hex")
        if pl.get("size") != os.path.getsize(pp) or pl.get("sha256") != otalib.sha256_file(pp):
            raise OtaError(f"{u['rel']}: payload.pck does not match the manifest size/sha256")
        entries.append({"native_version": u["native_version"], "platform": u["platform"],
                        "base_commit": m["base_commit"], "seq": u["seq"],
                        "manifest": u["rel"] + "/manifest.json", "signature": u["rel"] + "/manifest.sig",
                        "payload": u["rel"] + "/payload.pck"})
    entries.sort(key=lambda e: (e["native_version"], e["platform"], e["base_commit"], e["seq"]))
    return entries


def _ident(e: dict) -> tuple:
    return (e["native_version"], e["platform"], e["base_commit"], e["seq"])


def merge(out: str, key: str, adds=(), drop_missing: bool = False, generated_utc: str = "") -> dict:
    otalib.private_key_bits(key)
    pubp = _pub_for(key)
    try:
        if adds:
            copy_bundles(out, list(adds))
        prev = load_channel(out, pubp)
        updates = index_updates(out, pubp)
        if not updates:
            raise OtaError(f"no update bundles found under {out}")
        revoked = list(prev["revoked"]) if prev else []
        if prev:
            have = {_ident(e) for e in updates}
            lost = [u for u in prev.get("updates", []) if _ident(u) not in have]
            if lost and not drop_missing:
                raise OtaError("the previous channel lists updates whose folders are missing: "
                               + ", ".join(f"v{u['native_version']}/{u['platform']}/update-{u['seq']}" for u in lost)
                               + " (pass --drop-missing to remove them on purpose)")
            if prev.get("updates", []) == updates:
                print(f"channel unchanged (generation {prev['generation']})")
                return prev
        ch = {"format": otalib.FORMAT, "product": otalib.PRODUCT,
              "generation": (prev["generation"] + 1) if prev else 1,
              "generated_utc": generated_utc or otalib.utc_now(),
              "updates": updates, "revoked": sorted(revoked, key=_ident)}
        if generated_utc and not otalib.UTC_RE.match(generated_utc):
            raise OtaError("generated-utc must look like 2026-10-05T19:00:00Z")
        write_channel(out, key, ch)
        print(f"channel.json generation {ch['generation']}: {len(updates)} update(s), {len(ch['revoked'])} revoked")
        return ch
    finally:
        shutil.rmtree(os.path.dirname(pubp), ignore_errors=True)


def revoke(out: str, key: str, native_version: int, platform: str, base_commit: str, seq: int,
           generated_utc: str = "") -> dict:
    otalib.private_key_bits(key)
    pubp = _pub_for(key)
    try:
        prev = load_channel(out, pubp)
        if prev is None:
            raise OtaError(f"{out} has no channel.json to revoke from")
        target = {"native_version": native_version, "platform": platform, "base_commit": base_commit, "seq": seq}
        if _ident(target) not in {_ident(u) for u in prev.get("updates", [])}:
            raise OtaError("that update is not listed in the channel (check native version, platform, base commit and seq)")
        if _ident(target) in {_ident(r) for r in prev.get("revoked", [])}:
            print("already revoked; channel unchanged")
            return prev
        if generated_utc and not otalib.UTC_RE.match(generated_utc):
            raise OtaError("generated-utc must look like 2026-10-05T19:00:00Z")
        ch = dict(prev)
        ch["revoked"] = sorted(list(prev.get("revoked", [])) + [target], key=_ident)
        ch["generation"] = prev["generation"] + 1
        ch["generated_utc"] = generated_utc or otalib.utc_now()
        write_channel(out, key, ch)
        print(f"revoked v{native_version}/{platform}/update-{seq}; channel.json generation {ch['generation']}")
        return ch
    finally:
        shutil.rmtree(os.path.dirname(pubp), ignore_errors=True)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("merge")
    m.add_argument("--out", required=True)
    m.add_argument("--key", required=True)
    m.add_argument("--add", action="append", default=[], metavar="BUNDLE_ROOT")
    m.add_argument("--drop-missing", action="store_true")
    m.add_argument("--generated-utc", default="")
    r = sub.add_parser("revoke")
    r.add_argument("--out", required=True)
    r.add_argument("--key", required=True)
    r.add_argument("--native-version", required=True, type=int)
    r.add_argument("--platform", required=True)
    r.add_argument("--base-commit", required=True)
    r.add_argument("--seq", required=True, type=int)
    r.add_argument("--generated-utc", default="")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "merge":
            merge(a.out, a.key, a.add, a.drop_missing, a.generated_utc)
        else:
            revoke(a.out, a.key, a.native_version, a.platform, a.base_commit, a.seq, a.generated_utc)
    except OtaError as e:
        print(f"channel.py: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
