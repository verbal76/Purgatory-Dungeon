#!/usr/bin/env python3
"""Shared helpers for the OTA build tooling (docs/OTA.md). Standard library + the `openssl` CLI only.

Not a command; imported by classify.py, make_bundle.py, channel.py, verify_bundle.py, native_check.py.
  * path rules   : tools/ota/ota_rules.json is loaded and applied here (one implementation of the matching)
  * JSON         : deterministic writer (sorted keys, 2-space indent, trailing newline) and a strict reader
  * crypto       : RSA PKCS#1 v1.5 / SHA-256 signing and verification through `openssl dgst`
                   (the private key is only ever passed to openssl by path and is never printed)
"""
import base64
import datetime
import hashlib
import json
import os
import re
import subprocess
import tempfile

OTA_DIR = os.path.dirname(os.path.abspath(__file__))
RULES_PATH = os.path.join(OTA_DIR, "ota_rules.json")

PRODUCT = "purgatory-dungeon"
FORMAT = 1
OTA_API = 1
PLATFORMS = ("android", "windows")
MIN_KEY_BITS = 3072

HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
ENGINE_RE = re.compile(r"^[0-9A-Za-z._+-]{3,64}$")


class OtaError(Exception):
    """A refusal with a human-readable reason (printed, exit 1, never a traceback)."""


# ---------------------------------------------------------------- rules

def load_rules(path: str = "") -> dict:
    path = path or RULES_PATH
    try:
        with open(path, encoding="utf-8") as f:
            rules = json.load(f)
    except (OSError, ValueError) as e:
        raise OtaError(f"cannot read OTA rules {path}: {e}")
    if rules.get("format") != 1:
        raise OtaError("ota_rules.json: unsupported format")
    for sect in ("protected", "guarded", "not_shipped"):
        s = rules.get(sect)
        if not isinstance(s, dict):
            raise OtaError(f"ota_rules.json: section '{sect}' missing")
        for key in ("exact", "prefixes", "suffixes"):
            if not isinstance(s.get(key), list) or not all(isinstance(x, str) and x for x in s[key]):
                raise OtaError(f"ota_rules.json: {sect}.{key} must be a list of non-empty strings")
    if not isinstance(rules.get("max_payload_bytes"), int) or rules["max_payload_bytes"] <= 0:
        raise OtaError("ota_rules.json: max_payload_bytes missing")
    return rules


def normalize_path(p: str) -> str:
    """Root-relative form used by every rule: no res:// prefix, no leading ./ ."""
    if p.startswith("res://"):
        p = p[len("res://"):]
    while p.startswith("./"):
        p = p[2:]
    return p


def path_problem(p: str) -> str:
    """Non-empty reason when a path in a pack/manifest is not a plain relative res:// path
    (docs/OTA.md compatibility rule 5: nothing escapes res://: '..', absolute, user://)."""
    if not p:
        return "empty path"
    if "\x00" in p or "\\" in p:
        return "path contains a NUL or backslash"
    if p.startswith("/"):
        return "absolute path"
    if ":" in p:
        return "path contains ':' (user://, drive letters and other schemes are not allowed)"
    parts = p.split("/")
    if any(x in ("", ".", "..") for x in parts):
        return "path has an empty, '.' or '..' segment"
    return ""


def _match(section: dict, path: str) -> str:
    """Describes the first rule of `section` that matches `path`, or ''."""
    if path in section["exact"]:
        return f"exact {path}"
    for p in section["prefixes"]:
        if path.startswith(p):
            return f"prefix {p}"
    for s in section["suffixes"]:
        if path.endswith(s):
            return f"suffix {s}"
    return ""


def pack_names(rules: dict, path: str) -> list:
    """The raw pack name plus the source name it was produced from ('a.gd.remap'/'a.gdc' -> 'a.gd')."""
    path = normalize_path(path)
    names = [path]
    al = rules.get("pack_aliases", {})
    for suf in al.get("strip_suffixes", []):
        if path.endswith(suf) and len(path) > len(suf):
            names.append(path[: -len(suf)])
    for suf, repl in al.get("map_suffixes", {}).items():
        if path.endswith(suf) and len(path) > len(suf):
            names.append(path[: -len(suf)] + repl)
    return names


def classify_source(rules: dict, path: str):
    """(category, rule) for a path of the git tree: not_shipped | apk_required | guarded | safe."""
    path = normalize_path(path)
    for cat, sect in (("not_shipped", "not_shipped"), ("apk_required", "protected"), ("guarded", "guarded")):
        why = _match(rules[sect], path)
        if why:
            return cat, why
    return "safe", "default"


def pack_violation(rules: dict, path: str):
    """(kind, rule) for a path inside a pack: kind is 'escape' | 'protected' | 'guarded' | ''."""
    bad = path_problem(normalize_path(path))
    if bad:
        return "escape", bad
    for name in pack_names(rules, path):
        why = _match(rules["protected"], name)
        if why:
            return "protected", why
    for name in pack_names(rules, path):
        why = _match(rules["guarded"], name)
        if why:
            return "guarded", why
    return "", ""


# ---------------------------------------------------------------- JSON / files

def canonical_json(obj) -> bytes:
    return (json.dumps(obj, sort_keys=True, indent=2) + "\n").encode("utf-8")


def _no_dupes(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise ValueError(f"duplicate key {k!r}")
        d[k] = v
    return d


def load_json_bytes(data: bytes, what: str = "JSON"):
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=_no_dupes)
    except (ValueError, UnicodeDecodeError) as e:
        raise OtaError(f"{what} is not valid JSON: {e}")


def read_bytes(path: str) -> bytes:
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError as e:
        raise OtaError(f"cannot read {path}: {e.strerror or e}")


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    except OSError as e:
        raise OtaError(f"cannot read {path}: {e.strerror or e}")
    return h.hexdigest()


def write_atomic(path: str, data: bytes) -> None:
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, 0o644)          # everything written here is public channel content (never a private key)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------- openssl

def _openssl(args, what: str, input_bytes: bytes = None) -> bytes:
    try:
        r = subprocess.run(["openssl"] + args, input=input_bytes, capture_output=True)
    except FileNotFoundError:
        raise OtaError("the openssl CLI is required (not found on PATH)")
    if r.returncode != 0:
        raise OtaError(f"openssl failed to {what}: {r.stderr.decode('utf-8', 'replace').strip()[:300]}")
    return r.stdout


def private_key_bits(key_path: str) -> int:
    """Bit size of an RSA private key; refuses anything that is not RSA >= 3072 bits."""
    if not os.path.isfile(key_path):
        raise OtaError(f"signing key not found: {key_path}")
    text = _openssl(["rsa", "-in", key_path, "-noout", "-text"], "read the signing key (must be an RSA private key)")
    m = re.search(rb"Private-Key: \((\d+) bit", text)
    if not m:
        raise OtaError("signing key is not an RSA private key")
    bits = int(m.group(1))
    if bits < MIN_KEY_BITS:
        raise OtaError(f"signing key is RSA-{bits}; OTA requires RSA-{MIN_KEY_BITS} or larger")
    return bits


def public_key_pem(key_path: str) -> bytes:
    return _openssl(["pkey", "-in", key_path, "-pubout"], "derive the public key")


def check_public_key(pub_path: str) -> int:
    if not os.path.isfile(pub_path):
        raise OtaError(f"public key not found: {pub_path}")
    text = _openssl(["pkey", "-pubin", "-in", pub_path, "-noout", "-text"], "read the public key")
    m = re.search(rb"(?:RSA )?Public-Key: \((\d+) bit", text)
    if not m or b"Modulus" not in text:
        raise OtaError("trust key is not an RSA public key")
    return int(m.group(1))


def sign_file(key_path: str, data_path: str) -> bytes:
    """Raw RSA PKCS#1 v1.5 / SHA-256 signature of the file's exact bytes."""
    private_key_bits(key_path)
    return _openssl(["dgst", "-sha256", "-sign", key_path, data_path], "sign")


def verify_signature(pub_path: str, data_path: str, sig: bytes) -> bool:
    fd, sigfile = tempfile.mkstemp(prefix="ota-sig-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(sig)
        r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub_path, "-signature", sigfile, data_path],
                           capture_output=True)
        return r.returncode == 0 and b"Verified OK" in r.stdout
    except FileNotFoundError:
        raise OtaError("the openssl CLI is required (not found on PATH)")
    finally:
        os.unlink(sigfile)


def sig_encode(sig: bytes) -> bytes:
    """manifest.sig / channel.json.sig: base64 of the raw signature, one line, no trailing newline."""
    return base64.b64encode(sig)


def sig_decode(text: bytes) -> bytes:
    try:
        return base64.b64decode(b"".join(text.split()), validate=True)
    except ValueError:
        raise OtaError("signature file is not valid base64")


def sign_to_file(key_path: str, data_path: str, sig_path: str) -> None:
    write_atomic(sig_path, sig_encode(sign_file(key_path, data_path)))


def fail(msg: str):
    raise OtaError(msg)


# ---------------------------------------------------------------- bundle directory layout

UPDATE_DIR_RE = re.compile(r"^update-([1-9][0-9]*)$")


def update_rel_dir(native_version: int, platform: str, seq: int) -> str:
    return f"v{native_version}/{platform}/update-{seq}"


def scan_updates(root: str) -> list:
    """Every `<root>/v<N>/<platform>/update-<seq>/` directory as dicts (native_version, platform, seq, rel, dir)."""
    found = []
    try:
        vdirs = sorted(os.listdir(root))
    except OSError:
        return found
    for vd in vdirs:
        m = re.fullmatch(r"v([1-9][0-9]*)", vd)
        if not m or not os.path.isdir(os.path.join(root, vd)):
            continue
        for plat in sorted(os.listdir(os.path.join(root, vd))):
            pdir = os.path.join(root, vd, plat)
            if plat not in PLATFORMS or not os.path.isdir(pdir):
                continue
            for ud in sorted(os.listdir(pdir)):
                um = UPDATE_DIR_RE.match(ud)
                if um and os.path.isdir(os.path.join(pdir, ud)):
                    found.append({"native_version": int(m.group(1)), "platform": plat, "seq": int(um.group(1)),
                                  "rel": f"{vd}/{plat}/{ud}", "dir": os.path.join(pdir, ud)})
    return found
