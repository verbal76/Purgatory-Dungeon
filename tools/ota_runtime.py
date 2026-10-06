#!/usr/bin/env python3
"""Native-runtime identity and compatibility gate for OTA publication (docs/OTA.md section 3).

The installed APK can only run OTA patches built for the runtime it contains. Anything that changes the native layer
(engine version, export presets and Android manifest settings, project settings, tools/android/build_apk.sh, the
bootstrap under scripts/boot/) cannot be delivered over the air. ota/boundary.json lists those inputs; this tool
fingerprints them and compares the result with the committed ota/runtime_lock.json.

  ota_runtime.py --check            exit 1 if the native layer changed without a bump (CI gate; also tests/run_tests.sh)
  ota_runtime.py --bump             increment RUNTIME_REVISION in scripts/boot/ota_config.gd and relock (a new APK is needed)
  ota_runtime.py --print [--json]   show runtime id, revision, engine and fingerprint (--platform android|windows)
  ota_runtime.py --relock           rewrite the lock WITHOUT bumping (only before any APK with this revision exists)
  ota_runtime.py --relock --provisional [--revision N]
                                    lock while an input is still missing (the lock is flagged and --check refuses it)
  common: --root DIR (another tree, e.g. a test fixture)  --boundary FILE  --config FILE (RUNTIME_REVISION source)

Runtime fingerprint = SHA-256 over "godot <GODOT_RELEASE>" and, for every resolved native input in sorted order,
"<path>\\n<length>\\n<bytes>\\n" (CRLF normalised to LF; the RUNTIME_REVISION number is normalised out of its own file,
so bumping it does not change what the number guards). Runtime id = "<platform>-godot-<engine major.minor.patch>-r<revision>",
e.g. android-godot-4.6.0-r1. Both are baked into build_info.json (tools/release_tool.py build-info) and named in every
manifest; the device refuses an OTA unless both match.

Exit status: 0 ok, 1 gate failed, 2 usage / unreadable input.
"""
import argparse
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "ota"))
import otalib  # noqa: E402
from otalib import OtaError  # noqa: E402

DEFAULT_ROOT = os.path.dirname(HERE)
LOCK_REL = "ota/runtime_lock.json"
CHANNEL_CONST = "CHANNEL"


def _const_re(name: str, value: str) -> "re.Pattern":
    # const NAME := value | const NAME: type = value | const NAME = value
    return re.compile(r"(?m)^[ \t]*const[ \t]+" + name + r"[ \t]*(?::[ \t]*[A-Za-z_]\w*[ \t]*=|:=|=)[ \t]*" + value)


def _norm(data: bytes) -> bytes:
    return data.replace(b"\r\n", b"\n")


class Tree:
    """The native layer of one source tree."""

    def __init__(self, root: str, boundary_path: str = "", config_override: str = ""):
        self.root = os.path.abspath(root)
        self.rules = otalib.load_boundary(boundary_path or os.path.join(self.root, "ota", "boundary.json"))
        src = self.rules["runtime_revision_source"]
        self.config_rel = config_override or src["file"]
        self.const = src["constant"]
        self.rev_re = _const_re(re.escape(self.const), r"(\d+)\b")

    def path(self, rel: str) -> str:
        return os.path.join(self.root, *rel.split("/"))

    def read(self, rel: str) -> bytes:
        try:
            with open(self.path(rel), "rb") as f:
                return f.read()
        except OSError as e:
            raise OtaError(f"cannot read {rel}: {e.strerror or e}")

    # -- inputs
    def resolve_inputs(self, allow_missing: bool = False):
        """(sorted list of root-relative files, [patterns that matched nothing])."""
        files, missing = set(), []
        for pat in self.rules["native_inputs"]:
            if not re.search(r"[*?]", pat):
                if os.path.isfile(self.path(pat)):
                    files.add(pat)
                else:
                    missing.append(pat)
                continue
            rx = otalib.glob_regex(pat)
            base = pat.split("*")[0].split("?")[0]
            base_dir = base.rsplit("/", 1)[0] if "/" in base else ""
            found = False
            for dp, dn, fn in os.walk(self.path(base_dir) if base_dir else self.root):
                dn[:] = [d for d in dn if d != ".git"]
                for f in fn:
                    rel = os.path.relpath(os.path.join(dp, f), self.root).replace(os.sep, "/")
                    if rx.match(rel):
                        files.add(rel)
                        found = True
            if not found:
                missing.append(pat)
        if missing and not allow_missing:
            raise OtaError("native input(s) missing in the tree: " + ", ".join(missing))
        return sorted(files), missing

    # -- values
    def revision(self) -> int:
        try:
            text = self.read(self.config_rel).decode("utf-8", "replace")
        except OtaError:
            raise OtaError(f"{self.config_rel} not found: it holds `const {self.const} := N` (the native layer)")
        found = self.rev_re.findall(text)
        if len(found) != 1:
            raise OtaError(f"{self.config_rel} must contain exactly one `const {self.const} := <integer>` (found {len(found)})")
        rev = int(found[0])
        if rev < 1:
            raise OtaError(f"{self.const} must be >= 1")
        return rev

    def channel(self) -> str:
        text = self.read(self.config_rel).decode("utf-8", "replace")
        found = _const_re(CHANNEL_CONST, r'"([^"]*)"').findall(text)
        if len(found) != 1:
            raise OtaError(f'{self.config_rel} must contain exactly one `const {CHANNEL_CONST} := "<channel>"`')
        if not otalib.CHANNEL_RE.match(found[0]):
            raise OtaError(f"channel {found[0]!r} is not a valid channel name")
        return found[0]

    def godot_release(self) -> str:
        eng = self.rules["engine_version_source"]
        text = self.read(eng["file"]).decode("utf-8", "replace")
        m = re.search(eng["regex"], text, re.M)
        if not m:
            raise OtaError(f"engine version not found in {eng['file']} (regex {eng['regex']})")
        return m.group(1)

    def engine(self) -> str:
        """major.minor.patch ('4.6' -> '4.6.0')."""
        parts = self.godot_release().split(".")
        parts += ["0"] * (3 - len(parts))
        return ".".join(parts[:3])

    def runtime_id(self, platform: str = "android", revision: int = 0) -> str:
        return f"{platform}-godot-{self.engine()}-r{revision or self.revision()}"

    def normalized(self, rel: str) -> bytes:
        """The bytes that are hashed: CRLF -> LF, and the revision number blanked in its own file."""
        data = _norm(self.read(rel))
        if rel == self.config_rel:
            text = data.decode("utf-8", "replace")
            data = self.rev_re.sub(lambda m: m.group(0)[: m.start(1) - m.start(0)] + "N", text).encode("utf-8")
        return data

    def file_digest(self, rel: str) -> str:
        return hashlib.sha256(self.normalized(rel)).hexdigest()

    def fingerprint(self, files=None) -> str:
        files = files if files is not None else self.resolve_inputs()[0]
        h = hashlib.sha256()
        h.update(f"godot {self.godot_release()}\n".encode())
        for rel in files:
            data = self.normalized(rel)
            h.update(f"{rel}\n{len(data)}\n".encode())
            h.update(data)
            h.update(b"\n")
        return h.hexdigest()

    # -- lock
    def lock_document(self, revision: int, provisional: bool = False) -> dict:
        files, missing = self.resolve_inputs(allow_missing=provisional)
        doc = {"runtime_revision": revision, "godot_version": self.godot_release(), "fingerprint": self.fingerprint(files),
               "files": files, "hashes": {f: self.file_digest(f) for f in files}}
        if provisional:
            doc["provisional"] = True
            doc["missing"] = missing
        return doc

    def read_lock(self) -> dict:
        p = self.path(LOCK_REL)
        if not os.path.isfile(p):
            raise OtaError(f"{LOCK_REL} not found (run `python3 tools/ota_runtime.py --relock` once and commit it)")
        lock = otalib.load_json_bytes(self.read(LOCK_REL), LOCK_REL)
        for key, typ in (("runtime_revision", int), ("godot_version", str), ("fingerprint", str), ("files", list)):
            if not isinstance(lock.get(key), typ):
                raise OtaError(f"{LOCK_REL}: field {key!r} missing or of the wrong type")
        return lock

    def write_lock(self, doc: dict) -> None:
        otalib.write_atomic(self.path(LOCK_REL), otalib.canonical_json(doc))


def identity(tree: Tree, platform: str) -> dict:
    rev = tree.revision()
    return {"runtime_id": tree.runtime_id(platform, rev), "runtime_revision": rev, "godot_version": tree.godot_release(),
            "engine": tree.engine(), "platform": platform, "runtime_fingerprint": tree.fingerprint(),
            "ota_channel": tree.channel()}


def check(tree: Tree) -> list:
    """Problems (strings); empty = the native layer equals the lock."""
    lock = tree.read_lock()
    if lock.get("provisional"):
        return [f"{LOCK_REL} is provisional (locked while {', '.join(lock.get('missing', [])) or 'an input'} did not exist yet); "
                "run `python3 tools/ota_runtime.py --relock` now that the native layer is complete and commit the result"]
    problems = []
    rev = tree.revision()
    if lock["runtime_revision"] != rev:
        problems.append(f"{tree.config_rel} says r{rev} but {LOCK_REL} says r{lock['runtime_revision']}")
    if lock["godot_version"] != tree.godot_release():
        problems.append(f"engine version is {tree.godot_release()} but the lock says {lock['godot_version']}")
    files, _ = tree.resolve_inputs()
    if files != lock["files"]:
        added, removed = sorted(set(files) - set(lock["files"])), sorted(set(lock["files"]) - set(files))
        if added:
            problems.append("native input(s) added since the lock: " + ", ".join(added))
        if removed:
            problems.append("native input(s) removed since the lock: " + ", ".join(removed))
    old = lock.get("hashes") if isinstance(lock.get("hashes"), dict) else {}
    for rel in files:
        if rel in old and old[rel] != tree.file_digest(rel):
            problems.append(f"native input changed: {rel}")
    if not problems and tree.fingerprint(files) != lock["fingerprint"]:
        problems.append("the native fingerprint differs from the lock")
    return problems


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--bump", action="store_true")
    mode.add_argument("--print", dest="show", action="store_true")
    mode.add_argument("--relock", action="store_true")
    ap.add_argument("--json", action="store_true", help="with --print: machine-readable output")
    ap.add_argument("--platform", default="android", choices=otalib.PLATFORMS)
    ap.add_argument("--root", default=DEFAULT_ROOT)
    ap.add_argument("--boundary", default="")
    ap.add_argument("--config", default="", help="root-relative file holding RUNTIME_REVISION (default: from ota/boundary.json)")
    ap.add_argument("--provisional", action="store_true")
    ap.add_argument("--revision", type=int, default=0, help="with --relock --provisional: revision to record when the config does not exist yet")
    a = ap.parse_args(argv)
    try:
        tree = Tree(a.root, a.boundary, a.config)
        if a.show:
            ident = identity(tree, a.platform)
            if a.json:
                print(json.dumps(ident, indent=2, sort_keys=True))
            else:
                for k in ("runtime_id", "runtime_revision", "godot_version", "engine", "runtime_fingerprint", "ota_channel"):
                    print(f"{k}={ident[k]}")
            return 0
        if a.bump:
            cur = tree.revision()
            text = tree.read(tree.config_rel).decode("utf-8")
            new = tree.rev_re.sub(lambda m: m.group(0)[: m.start(1) - m.start(0)] + str(cur + 1), text, count=1)
            otalib.write_atomic(tree.path(tree.config_rel), new.encode("utf-8"))
            tree.write_lock(tree.lock_document(cur + 1))
            print(f"runtime revision bumped to r{cur + 1} ({tree.runtime_id('android')}): build and install a new APK before publishing OTAs")
            return 0
        if a.relock:
            try:
                rev = tree.revision()
                if a.revision and a.revision != rev:
                    raise OtaError(f"--revision {a.revision} differs from {tree.config_rel} (r{rev}); edit the constant or use --bump")
            except OtaError:
                if not (a.provisional and a.revision >= 1):
                    raise
                rev = a.revision
            tree.write_lock(tree.lock_document(rev, provisional=a.provisional))
            note = "PROVISIONAL " if a.provisional else ""
            print(f"{note}lock rewritten (r{rev}); pre-release only: no APK with this revision was ever distributed")
            return 0
        problems = check(tree)
        if problems:
            print("NATIVE UPDATE REQUIRED / LOCK MISMATCH:")
            for p in problems:
                print("  -", p)
            if not any("provisional" in p for p in problems):
                print("These native-layer changes cannot reach installed APKs by OTA. If they are intended, run\n"
                      "`python3 tools/ota_runtime.py --bump`, commit, and ship a new numbered APK.")
            return 1
        print(f"runtime r{tree.revision()} unchanged (godot {tree.godot_release()}, fingerprint {tree.fingerprint()[:16]}...): OTA-compatible")
        return 0
    except OtaError as e:
        print(f"ota_runtime.py: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
