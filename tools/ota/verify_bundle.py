#!/usr/bin/env python3
"""Independent verifier for OTA bundles: the CI "is this bundle sane" gate, also usable on a downloaded bundle.

  verify_bundle.py <update dir | channel dir> --pubkey ota_trust.pem
        [--native-version N] [--platform P] [--base-commit C] [--engine E] [--ota-api 1]
        [--base-pck [platform=]base.pck]... [--accept-guarded] [--min-generation G] [--previous-channel old/channel.json]

An UPDATE directory (contains manifest.json) is checked on its own. A CHANNEL directory (contains
channel.json) is checked as a whole: the index and every update it lists, plus update folders that exist but are
not listed. Nothing here shares code with the builder except the path rules and the PCK reader.

Checks: manifest.sig verifies with the public key (openssl, RSA PKCS#1 v1.5 / SHA-256) over the exact manifest
bytes; manifest shape (exact key set, types, label); payload.pck size and sha256 equal the manifest and are
<= 512 MiB; files[] equals the pack's own directory (paths, removals vs removal flags, add/replace vs
--base-pck); every md5 inside the pack matches its content; no protected path, no path escaping res://, no
encrypted/delta entry, guarded paths only with --accept-guarded; compat fields equal the expected values;
folder names equal the manifest; for a channel: signature, shape, canonical paths, no duplicates, consistency
with each manifest, `generation` not below --min-generation / --previous-channel (replay), same generation =>
same bytes.
Exit 0 and "BUNDLE OK" when clean; otherwise every problem is printed as "FAIL: ..." and the exit status is 1.
"""
import argparse
import os
import re
import sys

import otalib
import pck as pcklib
from otalib import OtaError

MANIFEST_KEYS = {"format", "product", "platform", "native_version", "base_commit", "engine", "ota_api",
                 "payload_seq", "label", "source_commit", "created_utc", "payload", "files"}
ENTRY_KEYS = {"native_version", "platform", "base_commit", "seq", "manifest", "signature", "payload"}
REVOKED_KEYS = {"native_version", "platform", "base_commit", "seq"}


def _int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


class Report:
    def __init__(self):
        self.problems, self.notes = [], []

    def fail(self, msg: str):
        self.problems.append(msg)

    def note(self, msg: str):
        self.notes.append(msg)


def _read_sig_and_check(pub, data_path, sig_path, what, rep) -> bool:
    try:
        sig = otalib.sig_decode(otalib.read_bytes(sig_path))
        if not otalib.verify_signature(pub, data_path, sig):
            rep.fail(f"{what}: signature does NOT verify with the trust key")
            return False
        return True
    except OtaError as e:
        rep.fail(f"{what}: {e}")
        return False


def verify_update(d: str, pub: str, rep: Report, rules: dict, expect: dict, base_pcks: dict,
                  accept_guarded: bool, label: str = ""):
    """Verifies one update folder. Returns the manifest dict (or None when unreadable)."""
    name = label or d
    mp, sp, pp = (os.path.join(d, n) for n in ("manifest.json", "manifest.sig", "payload.pck"))
    missing = [n for n, p in (("manifest.json", mp), ("manifest.sig", sp), ("payload.pck", pp)) if not os.path.isfile(p)]
    if missing:
        rep.fail(f"{name}: missing {', '.join(missing)}")
        return None
    _read_sig_and_check(pub, mp, sp, f"{name}/manifest", rep)
    try:
        m = otalib.load_json_bytes(otalib.read_bytes(mp), f"{name}/manifest.json")
    except OtaError as e:
        rep.fail(str(e))
        return None
    if not isinstance(m, dict):
        rep.fail(f"{name}: manifest is not a JSON object")
        return None
    keys = set(m)
    if keys != MANIFEST_KEYS:
        rep.fail(f"{name}: manifest keys differ from the spec (missing {sorted(MANIFEST_KEYS - keys)}, unexpected {sorted(keys - MANIFEST_KEYS)})")
        return None
    if m["format"] != 1 or not _int(m["format"]):
        rep.fail(f"{name}: format must be 1")
    if m["product"] != otalib.PRODUCT:
        rep.fail(f"{name}: product must be {otalib.PRODUCT}")
    if m["platform"] not in otalib.PLATFORMS:
        rep.fail(f"{name}: unknown platform {m['platform']!r}")
    if not _int(m["native_version"]) or m["native_version"] < 1:
        rep.fail(f"{name}: native_version must be a positive integer")
    if not _int(m["payload_seq"]) or m["payload_seq"] < 1:
        rep.fail(f"{name}: payload_seq must be a positive integer")
    for k in ("base_commit", "source_commit"):
        if not (isinstance(m[k], str) and otalib.HEX40.match(m[k])):
            rep.fail(f"{name}: {k} must be 40 lowercase hex characters")
    if not (isinstance(m["engine"], str) and otalib.ENGINE_RE.match(m["engine"])):
        rep.fail(f"{name}: engine string is malformed")
    if not (isinstance(m["created_utc"], str) and otalib.UTC_RE.match(m["created_utc"])):
        rep.fail(f"{name}: created_utc is malformed")
    if m["label"] != f"Purgatory Dungeon v{m['native_version']} update {m['payload_seq']}":
        rep.fail(f"{name}: label {m['label']!r} does not follow 'Purgatory Dungeon v<N> update <K>'")
    if m["ota_api"] != expect.get("ota_api", otalib.OTA_API) or not _int(m["ota_api"]):
        rep.fail(f"{name}: ota_api is {m['ota_api']!r}, expected {expect.get('ota_api', otalib.OTA_API)}")

    # compat fields against the expected native build
    for k, label_ in (("native_version", "native version"), ("platform", "platform"),
                      ("base_commit", "base commit"), ("engine", "engine")):
        want = expect.get(k)
        if want not in (None, "") and m[k] != want:
            rep.fail(f"{name}: {label_} is {m[k]!r} but this build expects {want!r}")

    # location must agree with the manifest
    norm = os.path.normpath(os.path.abspath(d)).split(os.sep)
    if len(norm) >= 3 and re.fullmatch(r"update-[1-9][0-9]*", norm[-1]) and re.fullmatch(r"v[1-9][0-9]*", norm[-3]):
        if (norm[-3], norm[-2], norm[-1]) != (f"v{m['native_version']}", m["platform"], f"update-{m['payload_seq']}"):
            rep.fail(f"{name}: folder {'/'.join(norm[-3:])} does not match the manifest "
                     f"(v{m['native_version']}/{m['platform']}/update-{m['payload_seq']})")

    # payload
    pl = m["payload"]
    if not isinstance(pl, dict) or set(pl) != {"file", "size", "sha256"}:
        rep.fail(f"{name}: payload must have exactly file, size, sha256")
        return m
    if pl["file"] != "payload.pck":
        rep.fail(f"{name}: payload.file must be 'payload.pck'")
    actual = os.path.getsize(pp)
    if not _int(pl["size"]) or pl["size"] != actual:
        rep.fail(f"{name}: payload.size {pl['size']!r} != file size {actual}")
    if actual > rules["max_payload_bytes"]:
        rep.fail(f"{name}: payload is {actual} bytes, over the {rules['max_payload_bytes']} limit")
        return m                                  # never hash or parse an oversized file
    if not (isinstance(pl["sha256"], str) and otalib.HEX64.match(pl["sha256"])):
        rep.fail(f"{name}: payload.sha256 is malformed")
    elif otalib.sha256_file(pp) != pl["sha256"]:
        rep.fail(f"{name}: payload.pck sha256 does not match the manifest (file corrupted or replaced)")

    # files[] against the pack's own directory
    files = m["files"]
    if not isinstance(files, list) or not all(isinstance(f, dict) and set(f) == {"path", "op"} for f in files):
        rep.fail(f"{name}: files[] must be a list of {{path, op}}")
        return m
    paths = [f["path"] for f in files]
    if len(set(paths)) != len(paths):
        rep.fail(f"{name}: files[] contains duplicate paths")
    for f in files:
        if f["op"] not in ("add", "replace", "remove") or not isinstance(f["path"], str):
            rep.fail(f"{name}: files[] entry {f!r} is malformed")
            continue
        kind, why = otalib.pack_violation(rules, f["path"])
        if kind in ("escape", "protected"):
            rep.fail(f"{name}: files[] lists a {kind} path {f['path']!r} ({why})")
        elif kind == "guarded" and not accept_guarded:
            rep.fail(f"{name}: files[] touches guarded path {f['path']!r} ({why}); needs --accept-guarded")
    try:
        pack = pcklib.read_pck(pp)
    except pcklib.PckError as e:
        rep.fail(f"{name}: payload.pck is not a valid PCK: {e}")
        return m
    if not m["engine"].startswith("%d.%d." % pack.engine[:2]):
        rep.fail(f"{name}: payload was exported by Godot {pack.engine_str}, manifest engine is {m['engine']}")
    for p in pcklib.verify_entries(pack):
        rep.fail(f"{name}: pack content check: {p}")
    base = None
    bp = base_pcks.get(m["platform"]) or base_pcks.get("*")
    if bp:
        try:
            base = pcklib.read_pck(bp)
        except pcklib.PckError as e:
            rep.fail(f"{name}: base pack unreadable: {e}")
    in_pack = {e.path: e for e in pack.entries}
    if set(paths) != set(in_pack):
        extra = sorted(set(in_pack) - set(paths))[:5]
        gone = sorted(set(paths) - set(in_pack))[:5]
        rep.fail(f"{name}: files[] and the pack directory differ (in pack only {extra}, in manifest only {gone})")
    for f in files:
        e = in_pack.get(f["path"]) if isinstance(f.get("path"), str) else None
        if e is None:
            continue
        if e.encrypted or e.delta:
            rep.fail(f"{name}: {f['path']} is {'/'.join(e.flag_names())}, which OTA does not support")
        if (f["op"] == "remove") != e.removal:
            rep.fail(f"{name}: {f['path']}: op {f['op']!r} disagrees with the pack's removal flag ({e.removal})")
        elif base is not None:
            be = base.by_path.get(f["path"])
            want = "remove" if e.removal else ("replace" if be is not None and not be.removal else "add")
            if e.removal and (be is None or be.removal):
                rep.fail(f"{name}: {f['path']}: removal of a path the base pack does not contain")
            elif f["op"] != want:
                rep.fail(f"{name}: {f['path']}: op is {f['op']!r} but against the base pack it is {want!r}")
    if not files:
        rep.fail(f"{name}: update contains no files")
    rep.note(f"{name}: v{m['native_version']} {m['platform']} update {m['payload_seq']}: {len(files)} file(s), "
             f"{actual} bytes" + ("" if base is None else ", ops checked against the base pack"))
    return m


def verify_channel(root: str, pub: str, rep: Report, rules: dict, expect: dict, base_pcks: dict,
                   accept_guarded: bool, min_generation: int, previous: str):
    cp = os.path.join(root, "channel.json")
    sp = cp + ".sig"
    if not os.path.isfile(sp):
        rep.fail("channel.json.sig is missing")
        return
    sig_ok = _read_sig_and_check(pub, cp, sp, "channel.json", rep)
    try:
        raw = otalib.read_bytes(cp)
        ch = otalib.load_json_bytes(raw, "channel.json")
    except OtaError as e:
        rep.fail(str(e))
        return
    if not isinstance(ch, dict) or set(ch) != {"format", "product", "generation", "generated_utc", "updates", "revoked"}:
        rep.fail("channel.json keys differ from the spec")
        return
    if ch["format"] != 1 or ch["product"] != otalib.PRODUCT:
        rep.fail("channel.json format/product are wrong")
    gen = ch["generation"]
    if not _int(gen) or gen < 1:
        rep.fail("channel.json generation must be a positive integer")
        return
    if not (isinstance(ch["generated_utc"], str) and otalib.UTC_RE.match(ch["generated_utc"])):
        rep.fail("channel.json generated_utc is malformed")
    if min_generation and gen < min_generation:
        rep.fail(f"channel generation {gen} is lower than the required minimum {min_generation} (replayed/stale index)")
    if previous:
        try:
            praw = otalib.read_bytes(previous)
            pch = otalib.load_json_bytes(praw, "previous channel.json")
            pg = pch.get("generation")
            if not _int(pg):
                rep.fail("previous channel.json has no generation")
            elif gen < pg:
                rep.fail(f"channel generation {gen} is lower than the previous channel's {pg} (replay)")
            elif gen == pg and praw != raw:
                rep.fail(f"channel generation {gen} equals the previous one but the content differs")
        except OtaError as e:
            rep.fail(f"previous channel: {e}")
    if not isinstance(ch["updates"], list) or not isinstance(ch["revoked"], list):
        rep.fail("channel.json updates/revoked must be lists")
        return
    seen, listed = set(), set()
    for u in ch["updates"]:
        if not isinstance(u, dict) or set(u) != ENTRY_KEYS:
            rep.fail(f"channel update entry malformed: {u!r}")
            continue
        ident = (u["native_version"], u["platform"], u["base_commit"], u["seq"])
        if ident in seen:
            rep.fail(f"channel lists v{u['native_version']}/{u['platform']}/update-{u['seq']} twice")
        seen.add(ident)
        if not (_int(u["native_version"]) and _int(u["seq"]) and u["platform"] in otalib.PLATFORMS):
            rep.fail(f"channel entry has bad native_version/seq/platform: {u!r}")
            continue
        rel = otalib.update_rel_dir(u["native_version"], u["platform"], u["seq"])
        listed.add(rel)
        for k, fn in (("manifest", "manifest.json"), ("signature", "manifest.sig"), ("payload", "payload.pck")):
            if u[k] != f"{rel}/{fn}":
                rep.fail(f"channel entry {rel}: {k} path {u[k]!r} is not {rel}/{fn}")
        d = os.path.join(root, *rel.split("/"))
        if not os.path.isdir(d):
            rep.fail(f"channel entry {rel}: folder does not exist")
            continue
        applies = all(expect.get(k) in (None, "") or u[k] == expect[k] for k in ("platform", "native_version"))
        sub_expect = dict(expect) if applies else {"ota_api": expect.get("ota_api", otalib.OTA_API)}
        m = verify_update(d, pub, rep, rules, sub_expect, base_pcks, accept_guarded, rel)
        if m is not None:
            if (m["native_version"], m["platform"], m["base_commit"], m["payload_seq"]) != ident:
                rep.fail(f"channel entry {rel} disagrees with its manifest (native_version/platform/base_commit/seq)")
    for r in ch["revoked"]:
        if not isinstance(r, dict) or set(r) != REVOKED_KEYS:
            rep.fail(f"channel revoked entry malformed: {r!r}")
        elif (r["native_version"], r["platform"], r["base_commit"], r["seq"]) not in seen:
            rep.note(f"revoked entry {r!r} refers to an update the channel no longer lists")
    for u in otalib.scan_updates(root):
        if u["rel"] not in listed:
            rep.fail(f"update folder {u['rel']} exists but is not listed in channel.json")
    rep.note(f"channel.json generation {gen}: {len(ch['updates'])} update(s), {len(ch['revoked'])} revoked"
             + ("" if sig_ok else " (UNSIGNED/INVALID)"))


def _parse_base(values: list) -> dict:
    out = {}
    for v in values:
        plat, sep, path = v.partition("=")
        if sep and plat in otalib.PLATFORMS:
            out[plat] = path
        else:
            out["*"] = v
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("path", help="an update folder (has manifest.json) or a channel folder (has channel.json)")
    ap.add_argument("--pubkey", required=True, help="the trust anchor: RSA public key PEM (ota_trust.pem)")
    ap.add_argument("--native-version", type=int)
    ap.add_argument("--platform", default="")
    ap.add_argument("--base-commit", default="")
    ap.add_argument("--engine", default="")
    ap.add_argument("--ota-api", type=int, default=otalib.OTA_API)
    ap.add_argument("--base-pck", action="append", default=[], metavar="[PLATFORM=]PATH")
    ap.add_argument("--accept-guarded", action="store_true")
    ap.add_argument("--min-generation", type=int, default=0)
    ap.add_argument("--previous-channel", default="")
    ap.add_argument("--rules", default="")
    a = ap.parse_args(argv)
    rep = Report()
    try:
        rules = otalib.load_rules(a.rules)
        bits = otalib.check_public_key(a.pubkey)
        if bits < otalib.MIN_KEY_BITS:
            rep.fail(f"trust key is RSA-{bits}; expected >= {otalib.MIN_KEY_BITS}")
        expect = {"native_version": a.native_version, "platform": a.platform, "base_commit": a.base_commit,
                  "engine": a.engine, "ota_api": a.ota_api}
        base_pcks = _parse_base(a.base_pck)
        if os.path.isfile(os.path.join(a.path, "channel.json")) or os.path.isfile(os.path.join(a.path, "channel.json.sig")):
            verify_channel(a.path, a.pubkey, rep, rules, expect, base_pcks, a.accept_guarded,
                           a.min_generation, a.previous_channel)
        elif os.path.isfile(os.path.join(a.path, "manifest.json")) or os.path.isfile(os.path.join(a.path, "payload.pck")):
            verify_update(a.path, a.pubkey, rep, rules, expect, base_pcks, a.accept_guarded)
        else:
            rep.fail(f"{a.path} is neither an update folder (manifest.json) nor a channel folder (channel.json)")
    except OtaError as e:
        rep.fail(str(e))
    for n in rep.notes:
        print("note:", n)
    for p in rep.problems:
        print("FAIL:", p)
    if rep.problems:
        print(f"BUNDLE REJECTED ({len(rep.problems)} problem(s))")
        return 1
    print("BUNDLE OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
