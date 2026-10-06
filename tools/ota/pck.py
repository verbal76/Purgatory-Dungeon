#!/usr/bin/env python3
"""Independent, dependency-free reader for Godot 4.6 PCK files (pack format version 3).

Written from real packs (godot --export-pack / --export-patch), NOT from the engine's own loader, so it
can act as a second opinion on what a patch pack really contains.

  pck.py list   <pck> [--base <base.pck>] [--json] [--no-verify]
                 one line per directory entry: op  path  size  md5  [flags]
                 op is add | replace | remove against --base; without a base: write | remove
  pck.py verify <pck>
                 re-hash every stored file against the md5 in the directory (exit 1 on any mismatch)

Layout (little endian), as observed on 4.6.stable:
  header   magic "GDPC" | u32 format (3) | u32 engine major, minor, patch | u32 pack flags
           | u64 file_base | u64 dir_offset | 16 x u32 reserved | zero padding to a 16 byte boundary
           pack flags: bit0 encrypted directory (unsupported here), bit1 offsets relative to the pack start
  files    stored back to back, each starting on a 16 byte boundary (relative to file_base)
  dir      at dir_offset: u32 count, then per file:
           u32 path_len (= name length + 0..3 NUL bytes so it is a multiple of 4) | path bytes
           | u64 offset (from file_base) | u64 size | 16 byte md5 | u32 file flags
           file flags: bit0 encrypted, bit1 REMOVAL (patch packs: delete this path from the base; size 0,
           md5 all zero), bit2 DELTA (content is a binary delta against the base file)
  The md5 is of the bytes stored in the pack (for a DELTA entry: of the delta, not of the final file).
Paths carry no "res://" prefix in 4.6 packs; one is stripped if present.
"""
import argparse
import hashlib
import json
import signal
import struct
import sys

MAGIC = b"GDPC"
FORMAT_VERSION = 3
PACK_DIR_ENCRYPTED = 1
PACK_REL_FILEBASE = 2
PACK_SPARSE_BUNDLE = 4     # Godot 4.5+: directory only; the file data lives OUTSIDE the pack (Android: loose under assets/)
FILE_ENCRYPTED = 1
FILE_REMOVAL = 2
FILE_DELTA = 4
KNOWN_PACK_FLAGS = PACK_DIR_ENCRYPTED | PACK_REL_FILEBASE
KNOWN_FILE_FLAGS = FILE_ENCRYPTED | FILE_REMOVAL | FILE_DELTA
MAX_FILES = 5_000_000
MAX_PATH_BYTES = 65536
ZERO_MD5 = "0" * 32
HEADER_FIXED = 40          # up to and including dir_offset
HEADER_RESERVED = 16 * 4


class PckError(Exception):
    pass


class Entry:
    __slots__ = ("path", "offset", "size", "md5", "flags")

    def __init__(self, path, offset, size, md5, flags):
        self.path, self.offset, self.size, self.md5, self.flags = path, offset, size, md5, flags

    @property
    def removal(self):
        return bool(self.flags & FILE_REMOVAL)

    @property
    def encrypted(self):
        return bool(self.flags & FILE_ENCRYPTED)

    @property
    def delta(self):
        return bool(self.flags & FILE_DELTA)

    def flag_names(self):
        return [n for bit, n in ((FILE_ENCRYPTED, "encrypted"), (FILE_REMOVAL, "removal"), (FILE_DELTA, "delta"))
                if self.flags & bit]


class Pck:
    def __init__(self, path, size):
        self.path = path
        self.file_size = size
        self.format = 0
        self.engine = (0, 0, 0)
        self.flags = 0
        self.file_base = 0
        self.dir_offset = 0
        self.entries = []
        self.by_path = {}
        self.sparse = False

    @property
    def engine_str(self):
        return "%d.%d.%d" % self.engine


def _u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def _u64(b, o):
    return struct.unpack_from("<Q", b, o)[0]


def read_pck(path: str, allow_sparse: bool = False) -> Pck:
    """Parses and structurally validates a pack; raises PckError on anything malformed.

    A sparse-bundle pack (flag 4) is only a directory (path, size, md5) of files stored elsewhere: Godot's Android gradle export writes
    assets/assets.sparsepck next to the loose project files. It is refused unless `allow_sparse` (then `pck.sparse` is set, entries
    carry offset 0 and no data can be read from the pack itself); an update payload is never allowed to be one."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        raise PckError(f"cannot read {path}: {e.strerror or e}")
    n = len(data)
    pck = Pck(path, n)
    if n < HEADER_FIXED + HEADER_RESERVED:
        raise PckError("file is too small to be a PCK")
    if data[:4] != MAGIC:
        raise PckError("not a PCK (bad magic; embedded or encrypted packs are not supported)")
    pck.format = _u32(data, 4)
    if pck.format != FORMAT_VERSION:
        raise PckError(f"unsupported PCK format version {pck.format} (only {FORMAT_VERSION} is supported)")
    pck.engine = (_u32(data, 8), _u32(data, 12), _u32(data, 16))
    pck.flags = _u32(data, 20)
    if pck.flags & PACK_SPARSE_BUNDLE:
        if not allow_sparse:
            raise PckError("sparse-bundle pack (a directory of files stored outside the pack) is not supported here")
        pck.sparse = True
    if pck.flags & ~(KNOWN_PACK_FLAGS | PACK_SPARSE_BUNDLE):
        raise PckError(f"unknown pack flags 0x{pck.flags:x}")
    if pck.flags & PACK_DIR_ENCRYPTED:
        raise PckError("encrypted pack directory is not supported")
    pck.file_base = _u64(data, 24)          # packs here start at byte 0, so relative == absolute
    pck.dir_offset = _u64(data, 32)
    if not pck.sparse and (pck.file_base < HEADER_FIXED + HEADER_RESERVED or pck.file_base > n):
        raise PckError(f"file_base {pck.file_base} outside the file")
    if pck.dir_offset < (HEADER_FIXED + HEADER_RESERVED if pck.sparse else pck.file_base) or pck.dir_offset + 4 > n:
        raise PckError(f"directory offset {pck.dir_offset} outside the file")
    p = pck.dir_offset
    count = _u32(data, p)
    p += 4
    if count > MAX_FILES:
        raise PckError(f"implausible file count {count}")
    for i in range(count):
        if p + 4 > n:
            raise PckError(f"directory entry {i} is truncated")
        plen = _u32(data, p)
        p += 4
        if plen % 4 != 0:
            raise PckError(f"entry {i}: path length {plen} is not padded to a multiple of 4")
        if plen > MAX_PATH_BYTES or p + plen + 8 + 8 + 16 + 4 > n:
            raise PckError(f"entry {i}: path/entry runs past the end of the file")
        raw = data[p:p + plen]
        p += plen
        name = raw.rstrip(b"\x00")
        if plen - len(name) > 3:
            raise PckError(f"entry {i}: more than 3 padding bytes after the path")
        if b"\x00" in name:
            raise PckError(f"entry {i}: NUL inside the path")
        try:
            name = name.decode("utf-8")
        except UnicodeDecodeError:
            raise PckError(f"entry {i}: path is not valid UTF-8")
        if name.startswith("res://"):
            name = name[len("res://"):]
        off, size = _u64(data, p), _u64(data, p + 8)
        md5 = data[p + 16:p + 32].hex()
        flags = _u32(data, p + 32)
        p += 36
        if flags & ~KNOWN_FILE_FLAGS:
            raise PckError(f"entry {name!r}: unknown file flags 0x{flags:x}")
        if name in pck.by_path:
            raise PckError(f"duplicate path in the directory: {name!r}")
        e = Entry(name, 0 if pck.sparse else pck.file_base + off, size, md5, flags)
        if e.removal:
            if size != 0:
                raise PckError(f"removal entry {name!r} has a non-zero size")
        elif not pck.sparse and (e.offset + size > n or e.offset < pck.file_base):
            raise PckError(f"entry {name!r}: data (offset {e.offset}, size {size}) lies outside the file")
        pck.entries.append(e)
        pck.by_path[name] = e
    return pck


def read_entry(pck: Pck, entry: Entry) -> bytes:
    if entry.removal:
        return b""
    if pck.sparse:
        raise PckError(f"{entry.path!r}: a sparse-bundle pack holds no file data")
    with open(pck.path, "rb") as f:
        f.seek(entry.offset)
        data = f.read(entry.size)
    if len(data) != entry.size:
        raise PckError(f"entry {entry.path!r}: short read")
    return data


def verify_entries(pck: Pck) -> list:
    """Problems (strings) found by re-hashing every stored file; empty list = all md5s match."""
    problems = []
    if pck.sparse:
        return ["sparse-bundle pack: the file data is not in the pack, nothing to re-hash"]
    with open(pck.path, "rb") as f:
        for e in pck.entries:
            if e.removal:
                if e.md5 != ZERO_MD5:
                    problems.append(f"{e.path}: removal entry carries a non-zero md5")
                continue
            if e.encrypted:
                problems.append(f"{e.path}: encrypted entry cannot be verified")
                continue
            f.seek(e.offset)
            h = hashlib.md5()
            left = e.size
            while left > 0:
                chunk = f.read(min(left, 1 << 20))
                if not chunk:
                    break
                h.update(chunk)
                left -= len(chunk)
            if left > 0 or h.hexdigest() != e.md5:
                problems.append(f"{e.path}: md5 of the stored bytes differs from the directory ({e.md5})")
    return problems


def ops(pck: Pck, base: Pck = None) -> list:
    """[(path, op)] sorted by path. Against a base: add | replace | remove (a removal of a path the base does
    not hold raises PckError: the patch would be built against a different base). Without: write | remove."""
    out = []
    for e in sorted(pck.entries, key=lambda x: x.path):
        if e.removal:
            if base is not None:
                be = base.by_path.get(e.path)
                if be is None or be.removal:
                    raise PckError(f"removal of {e.path!r}, which the base pack does not contain")
            out.append((e.path, "remove"))
        elif base is None:
            out.append((e.path, "write"))
        else:
            be = base.by_path.get(e.path)
            out.append((e.path, "replace" if be is not None and not be.removal else "add"))
    return out


def _cmd_list(a) -> int:
    pck = read_pck(a.pck)
    base = read_pck(a.base) if a.base else None
    rows = []
    for path, op in ops(pck, base):
        e = pck.by_path[path]
        rows.append({"path": path, "op": op, "size": e.size, "md5": e.md5, "flags": e.flag_names()})
    problems = [] if a.no_verify else verify_entries(pck)
    if a.json:
        print(json.dumps({"format": pck.format, "engine": pck.engine_str, "files": rows, "problems": problems},
                         indent=2, sort_keys=True))
    else:
        print(f"{pck.path}: PCK format {pck.format}, Godot {pck.engine_str}, {len(rows)} entries")
        for r in rows:
            fl = (" [" + ",".join(r["flags"]) + "]") if r["flags"] else ""
            print(f"{r['op']:8} {r['path']}  {r['size']}  {r['md5']}{fl}")
        for p in problems:
            print("MISMATCH:", p)
    return 1 if problems else 0


def _cmd_verify(a) -> int:
    pck = read_pck(a.pck)
    problems = verify_entries(pck)
    for p in problems:
        print("MISMATCH:", p)
    print(f"{a.pck}: {len(pck.entries)} entries, {'all md5s match' if not problems else str(len(problems)) + ' problem(s)'}")
    return 1 if problems else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    ls = sub.add_parser("list")
    ls.add_argument("pck")
    ls.add_argument("--base", default="")
    ls.add_argument("--json", action="store_true")
    ls.add_argument("--no-verify", action="store_true")
    vf = sub.add_parser("verify")
    vf.add_argument("pck")
    a = ap.parse_args(argv)
    try:
        return _cmd_list(a) if a.cmd == "list" else _cmd_verify(a)
    except PckError as e:
        print(f"pck.py: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    if hasattr(signal, "SIGPIPE"):
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)      # `pck.py list ... | head` must not traceback
    sys.exit(main())
