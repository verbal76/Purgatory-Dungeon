#!/usr/bin/env python3
"""Builds one signed OTA update bundle exactly as docs/OTA.md specifies.

  make_bundle.py --platform android|windows --native-version N --base-commit <40 hex> --engine <string>
                 --seq K --source-commit <40 hex> --payload <patch.pck> --base-pck <base.pck>
                 --out <dir> --key <rsa private pem> [--created-utc T] [--label L] [--accept-guarded REASON]

Writes  <out>/v<N>/<platform>/update-<K>/{manifest.json, manifest.sig, payload.pck}  and prints the directory.
  * files[] comes from the payload's own directory (tools/ota/pck.py): add/replace is decided against
    --base-pck, removals come from the pack's removal flags
  * manifest.json is deterministic (sorted keys, 2-space indent, trailing newline); manifest.sig is the
    base64 of `openssl dgst -sha256 -sign` (RSA PKCS#1 v1.5) over those exact bytes
Refuses (exit 1, nothing written): a protected path or a path escaping res:// in the pack (rules:
tools/ota/ota_rules.json), guarded paths without --accept-guarded, encrypted/delta entries, an md5 mismatch
inside the pack, an empty patch, a payload over 512 MiB, a key that is not RSA >= 3072, and a seq that is not
higher than every existing update of the same base (an update number is never reused or overwritten).
The channel index is a separate step: tools/ota/channel.py.
"""
import argparse
import os
import shutil
import sys
import tempfile

import otalib
import pck as pcklib
from otalib import OtaError


def existing_seqs(out: str, native_version: int, platform: str):
    """({seq: base_commit} of update dirs under out/vN/platform, highest seq listed by an existing channel.json)."""
    seqs = {}
    for u in otalib.scan_updates(out):
        if u["native_version"] == native_version and u["platform"] == platform:
            base = ""
            mpath = os.path.join(u["dir"], "manifest.json")
            if os.path.isfile(mpath):
                try:
                    base = str(otalib.load_json_bytes(otalib.read_bytes(mpath), "manifest").get("base_commit", ""))
                except OtaError:
                    base = ""
            seqs[u["seq"]] = base
    return seqs


def channel_seqs(out: str, native_version: int, platform: str, base_commit: str) -> list:
    path = os.path.join(out, "channel.json")
    if not os.path.isfile(path):
        return []
    ch = otalib.load_json_bytes(otalib.read_bytes(path), "channel.json")
    return [int(u.get("seq", 0)) for u in ch.get("updates", [])
            if u.get("native_version") == native_version and u.get("platform") == platform
            and u.get("base_commit") == base_commit]


def check_inputs(platform, native_version, base_commit, engine, seq, source_commit, created_utc):
    if platform not in otalib.PLATFORMS:
        raise OtaError(f"platform must be one of {', '.join(otalib.PLATFORMS)}")
    if not isinstance(native_version, int) or native_version < 1:
        raise OtaError("native version must be a positive integer")
    if not isinstance(seq, int) or seq < 1:
        raise OtaError("seq must be a positive integer")
    if not otalib.HEX40.match(base_commit or ""):
        raise OtaError("base commit must be 40 lowercase hex characters")
    if not otalib.HEX40.match(source_commit or ""):
        raise OtaError("source commit must be 40 lowercase hex characters")
    if not otalib.ENGINE_RE.match(engine or ""):
        raise OtaError("engine must look like 4.6.stable.official.89cea1439")
    if not otalib.UTC_RE.match(created_utc):
        raise OtaError("created-utc must look like 2026-10-05T19:00:00Z")


def payload_files(payload: str, base_pck: str, rules: dict, accept_guarded: str, engine: str) -> list:
    """files[] for the manifest after every pack-level refusal."""
    try:
        pack = pcklib.read_pck(payload)
        base = pcklib.read_pck(base_pck)
        if pack.engine[:2] != base.engine[:2]:
            raise OtaError(f"payload engine {pack.engine_str} differs from the base pack engine {base.engine_str}")
        if not engine.startswith("%d.%d." % pack.engine[:2]):
            raise OtaError(f"payload was exported by Godot {pack.engine_str} but --engine is {engine}")
        bad = pcklib.verify_entries(pack)
        if bad:
            raise OtaError("payload is internally inconsistent: " + "; ".join(bad[:5]))
        listing = pcklib.ops(pack, base)
    except pcklib.PckError as e:
        raise OtaError(f"payload.pck rejected: {e}")
    if not listing:
        raise OtaError("the payload contains no files; there is nothing to update")
    refusals, guarded = [], []
    for path, op in listing:
        e = pack.by_path[path]
        if e.encrypted:
            refusals.append(f"{path}: encrypted entries are not supported")
        if e.delta:
            refusals.append(f"{path}: delta-encoded entries are not supported (export with patch_delta_encoding=false)")
        kind, why = otalib.pack_violation(rules, path)
        if kind in ("escape", "protected"):
            refusals.append(f"{path}: {kind} path ({why})")
        elif kind == "guarded":
            guarded.append(f"{path} ({why})")
    if refusals:
        raise OtaError("refusing to build; the pack contains paths that must never ship over the air:\n  "
                       + "\n  ".join(refusals))
    if guarded and not accept_guarded.strip():
        raise OtaError("the pack touches guarded save/settings code; pass --accept-guarded \"<reason>\":\n  "
                       + "\n  ".join(guarded))
    return [{"path": p, "op": o} for p, o in listing]


def build_bundle(*, platform, native_version, base_commit, engine, seq, source_commit, payload, base_pck,
                 out, key, created_utc="", label="", accept_guarded="", rules=None) -> str:
    rules = rules or otalib.load_rules()
    created_utc = created_utc or otalib.utc_now()
    check_inputs(platform, native_version, base_commit, engine, seq, source_commit, created_utc)
    # cheapest refusal first: never read or hash an oversized file
    try:
        size = os.path.getsize(payload)
    except OSError as e:
        raise OtaError(f"cannot read payload {payload}: {e.strerror or e}")
    if size > rules["max_payload_bytes"]:
        raise OtaError(f"payload is {size} bytes; the limit is {rules['max_payload_bytes']} (512 MiB)")
    if size == 0:
        raise OtaError("payload is empty")
    otalib.private_key_bits(key)
    files = payload_files(payload, base_pck, rules, accept_guarded, engine)

    seqs = existing_seqs(out, native_version, platform)
    other_bases = sorted({b for b in seqs.values() if b and b != base_commit})
    if other_bases:
        raise OtaError(f"{out}/v{native_version}/{platform} already holds updates for another base commit "
                       f"({other_bases[0][:12]}); one native build has exactly one base commit")
    prior = [s for s, b in seqs.items() if b == base_commit] + channel_seqs(out, native_version, platform, base_commit)
    if prior and seq <= max(prior):
        raise OtaError(f"seq {seq} is not higher than the existing update {max(prior)} of this base; "
                       "update numbers only go up and are never reused")
    rel = otalib.update_rel_dir(native_version, platform, seq)
    final = os.path.join(out, *rel.split("/"))
    if os.path.exists(final):
        raise OtaError(f"{final} already exists; refusing to overwrite a published update")

    manifest = {
        "format": otalib.FORMAT, "product": otalib.PRODUCT, "platform": platform,
        "native_version": native_version, "base_commit": base_commit, "engine": engine,
        "ota_api": otalib.OTA_API, "payload_seq": seq,
        "label": label or f"Purgatory Dungeon v{native_version} update {seq}",
        "source_commit": source_commit, "created_utc": created_utc,
        "payload": {"file": "payload.pck", "size": size, "sha256": otalib.sha256_file(payload)},
        "files": files,
    }
    os.makedirs(out, exist_ok=True)
    stage = tempfile.mkdtemp(prefix=".stage-", dir=out)
    try:
        mpath = os.path.join(stage, "manifest.json")
        otalib.write_atomic(mpath, otalib.canonical_json(manifest))
        otalib.sign_to_file(key, mpath, os.path.join(stage, "manifest.sig"))
        shutil.copyfile(payload, os.path.join(stage, "payload.pck"))
        # prove the signature with the key's own public half before anything becomes visible
        pub = os.path.join(stage, ".pub.pem")
        otalib.write_atomic(pub, otalib.public_key_pem(key))
        sig = otalib.sig_decode(otalib.read_bytes(os.path.join(stage, "manifest.sig")))
        if not otalib.verify_signature(pub, mpath, sig):
            raise OtaError("internal error: the fresh signature does not verify")
        os.unlink(pub)
        os.chmod(stage, 0o755)
        os.makedirs(os.path.dirname(final), exist_ok=True)
        os.rename(stage, final)
    except BaseException:
        shutil.rmtree(stage, ignore_errors=True)
        raise
    return final


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--platform", required=True)
    ap.add_argument("--native-version", required=True, type=int)
    ap.add_argument("--base-commit", required=True)
    ap.add_argument("--engine", required=True)
    ap.add_argument("--seq", required=True, type=int)
    ap.add_argument("--source-commit", required=True)
    ap.add_argument("--payload", required=True)
    ap.add_argument("--base-pck", required=True, help="the pack the native build shipped (decides add vs replace)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--key", required=True, help="RSA private key PEM (never printed)")
    ap.add_argument("--created-utc", default="", help="override the timestamp (reproducible tests)")
    ap.add_argument("--label", default="")
    ap.add_argument("--accept-guarded", default="", metavar="REASON")
    ap.add_argument("--rules", default="")
    a = ap.parse_args(argv)
    try:
        d = build_bundle(platform=a.platform, native_version=a.native_version, base_commit=a.base_commit,
                         engine=a.engine, seq=a.seq, source_commit=a.source_commit, payload=a.payload,
                         base_pck=a.base_pck, out=a.out, key=a.key, created_utc=a.created_utc, label=a.label,
                         accept_guarded=a.accept_guarded, rules=otalib.load_rules(a.rules))
    except OtaError as e:
        print(f"make_bundle.py: {e}", file=sys.stderr)
        return 1
    print(d)
    return 0


if __name__ == "__main__":
    sys.exit(main())
