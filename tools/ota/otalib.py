#!/usr/bin/env python3
"""Shared helpers for the OTA build tooling (docs/OTA.md). Standard library + the `openssl` CLI only.

Not a command; imported by classify.py, native_check.py, publish_gates.py and tools/ota_runtime.py.
  * boundary     : ota/boundary.json is loaded and applied here (one implementation of the path matching)
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
REPO_ROOT = os.path.dirname(os.path.dirname(OTA_DIR))
BOUNDARY_REL = "ota/boundary.json"
BOUNDARY_PATH = os.path.join(REPO_ROOT, "ota", "boundary.json")

PRODUCT = "purgatory-dungeon"
PLATFORMS = ("android", "windows")
MIN_KEY_BITS = 3072

HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
CHANNEL_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")


class OtaError(Exception):
    """A refusal with a human-readable reason (printed, exit 1, never a traceback)."""


# ---------------------------------------------------------------- boundary

def parse_boundary(text: bytes, what: str = BOUNDARY_REL) -> dict:
    try:
        rules = json.loads(text.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as e:
        raise OtaError(f"cannot parse {what}: {e}")
    if not isinstance(rules, dict) or rules.get("format") != 1:
        raise OtaError(f"{what}: unsupported format")
    for sect in ("payload_protected", "guarded", "not_shipped"):
        s = rules.get(sect)
        if not isinstance(s, dict):
            raise OtaError(f"{what}: section '{sect}' missing")
        for key in ("exact", "prefixes", "suffixes"):
            if not isinstance(s.get(key), list) or not all(isinstance(x, str) and x for x in s[key]):
                raise OtaError(f"{what}: {sect}.{key} must be a list of non-empty strings")
    ni = rules.get("native_inputs")
    if not isinstance(ni, list) or not ni or not all(isinstance(x, str) and x for x in ni):
        raise OtaError(f"{what}: native_inputs must be a non-empty list of paths/globs")
    for key in ("max_payload_bytes", "warn_payload_bytes"):
        if not isinstance(rules.get(key), int) or rules[key] <= 0:
            raise OtaError(f"{what}: {key} missing")
    eng = rules.get("engine_version_source")
    if not isinstance(eng, dict) or not eng.get("file") or not eng.get("regex"):
        raise OtaError(f"{what}: engine_version_source {{file, regex}} missing")
    try:
        if re.compile(eng["regex"], re.M).groups < 1:
            raise OtaError(f"{what}: engine_version_source.regex needs one capture group")
    except re.error as e:
        raise OtaError(f"{what}: engine_version_source.regex is invalid: {e}")
    rv = rules.get("runtime_revision_source")
    if not isinstance(rv, dict) or not rv.get("file") or not re.fullmatch(r"[A-Z][A-Z0-9_]*", str(rv.get("constant", ""))):
        raise OtaError(f"{what}: runtime_revision_source {{file, constant}} missing")
    return rules


def load_boundary(path: str = "") -> dict:
    path = path or BOUNDARY_PATH
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        raise OtaError(f"cannot read the OTA boundary {path}: {e.strerror or e}")
    return parse_boundary(data, path)


def glob_regex(pattern: str):
    """'*' and '?' stay inside one path segment, '**' crosses '/'."""
    out, i = "", 0
    while i < len(pattern):
        c = pattern[i]
        if pattern.startswith("**", i):
            out += ".*"
            i += 2
            continue
        out += "[^/]*" if c == "*" else "[^/]" if c == "?" else re.escape(c)
        i += 1
    return re.compile("^" + out + "$")


def normalize_path(p: str) -> str:
    """Root-relative form used by every rule: no res:// prefix, no leading ./ ."""
    if p.startswith("res://"):
        p = p[len("res://"):]
    while p.startswith("./"):
        p = p[2:]
    return p


def native_input_match(rules: dict, path: str) -> str:
    """The native_inputs entry that names `path` ('' if none)."""
    path = normalize_path(path)
    for pat in rules["native_inputs"]:
        if glob_regex(pat).match(path):
            return pat
    return ""


def path_problem(p: str) -> str:
    """Non-empty reason when a path in a pack/manifest is not a plain relative res:// path
    (docs/OTA.md compatibility rule: nothing escapes res://: '..', absolute, user://)."""
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
    """(category, rule) for a path of the source tree: apk_required | not_shipped | guarded | safe.
    Native inputs win over everything (tools/android/build_apk.sh lives under the not-shipped tools/)."""
    path = normalize_path(path)
    ni = native_input_match(rules, path)
    if ni:
        return "apk_required", f"native input {ni}: runtime fingerprint would change"
    for cat, sect in (("not_shipped", "not_shipped"), ("apk_required", "payload_protected"), ("guarded", "guarded")):
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
        why = _match(rules["payload_protected"], name)
        if why:
            return "protected", why
    for name in pack_names(rules, path):
        ni = native_input_match(rules, name)
        if ni:
            return "protected", f"native input {ni}"
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


def public_key_der_sha256(pem: bytes) -> str:
    """SHA-256 of the DER SubjectPublicKeyInfo of a PEM public key (the fingerprint shown in logs)."""
    fd, path = tempfile.mkstemp(prefix="ota-pub-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(pem)
        der = _openssl(["pkey", "-pubin", "-in", path, "-outform", "DER"], "read the public key")
    finally:
        os.unlink(path)
    return hashlib.sha256(der).hexdigest()


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
    """manifest.json.sig: base64 of the raw signature, one line, no trailing newline."""
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
