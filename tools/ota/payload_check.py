#!/usr/bin/env python3
"""Checks a patch pack with the independent PCK reader and writes the manifest's `files[]` (docs/OTA.md section 4).

  payload_check.py <payload.pck> --base <base.pck> [--boundary ota/boundary.json] --files-out files.json
                   [--report-out report.json] [--accept-guarded "reason"]

Refuses (exit 1, reasons on stderr): an unreadable or inconsistent pack, an empty patch, DELTA entries, encrypted entries,
paths that escape res://, any payload_protected / native-input path (APK required), guarded save/settings code without
--accept-guarded, a removal of a file the base does not hold (patch built against another base), and a pack larger than
`max_payload_bytes`. A pack above `warn_payload_bytes` (the 95 MiB git-host guard) is allowed but flagged in the report.
files.json is a JSON array of {"path", "op": "add"|"replace"|"remove"} sorted by path; paths are the pack's own names.
"""
import argparse
import json
import os
import sys

import otalib
import pck as pcklib
from otalib import OtaError


def check(payload: str, base: str, rules: dict, accept_guarded: str = "") -> tuple:
    """(files, report). Raises OtaError with every refusal reason joined by newlines."""
    try:
        patch, basepck = pcklib.read_pck(payload), pcklib.read_pck(base)
        bad = pcklib.verify_entries(patch)
        rows = pcklib.ops(patch, basepck)
    except pcklib.PckError as e:
        raise OtaError(str(e))
    problems = [f"payload entry fails its own md5: {b}" for b in bad]
    if not rows:
        problems.append("the patch is empty: nothing that ships changed since the base")
    size = os.path.getsize(payload)
    if size > rules["max_payload_bytes"]:
        problems.append(f"payload is {size} bytes, over the {rules['max_payload_bytes']} byte limit")
    protected, guarded = [], []
    for path, op in rows:
        e = patch.by_path[path]
        if e.delta:
            problems.append(f"{path}: DELTA entries are not allowed in OTA payloads (patch_delta_encoding must stay off)")
        if e.encrypted:
            problems.append(f"{path}: encrypted entries are not allowed in OTA payloads")
        kind, why = otalib.pack_violation(rules, path)
        if kind in ("escape", "protected"):
            (protected if kind == "protected" else problems).append(
                f"{path}: {'native/protected path (' + why + ') cannot ship over the air' if kind == 'protected' else why}")
        elif kind == "guarded":
            guarded.append(f"{path} ({why})")
    problems += protected
    if guarded and not accept_guarded.strip():
        problems.append("guarded save/settings code in the payload without --accept-guarded: " + ", ".join(guarded))
    if problems:
        raise OtaError("\n".join(problems))
    files = [{"path": p, "op": op} for p, op in rows]
    report = {"payload_size": size, "payload_sha256": otalib.sha256_file(payload), "file_count": len(files),
              "ops": {k: sum(1 for f in files if f["op"] == k) for k in ("add", "replace", "remove")},
              "guarded_accepted": accept_guarded.strip() or None, "guarded_paths": guarded,
              "engine": patch.engine_str, "git_host_guard_exceeded": size > rules["warn_payload_bytes"],
              "git_host_guard_bytes": rules["warn_payload_bytes"]}
    return files, report


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("payload")
    ap.add_argument("--base", required=True)
    ap.add_argument("--boundary", default="")
    ap.add_argument("--files-out", required=True)
    ap.add_argument("--report-out", default="")
    ap.add_argument("--accept-guarded", default="")
    a = ap.parse_args(argv)
    try:
        rules = otalib.load_boundary(a.boundary)
        files, report = check(a.payload, a.base, rules, a.accept_guarded)
    except OtaError as e:
        print("payload_check.py: REFUSED", file=sys.stderr)
        for line in str(e).splitlines():
            print("  -", line, file=sys.stderr)
        return 1
    otalib.write_atomic(a.files_out, otalib.canonical_json(files))
    if a.report_out:
        otalib.write_atomic(a.report_out, otalib.canonical_json(report))
    print(f"payload ok: {len(files)} file(s) ({report['ops']['add']} add, {report['ops']['replace']} replace, "
          f"{report['ops']['remove']} remove), {report['payload_size']} bytes, sha256 {report['payload_sha256']}")
    if report["git_host_guard_exceeded"]:
        print(f"WARNING: payload exceeds the {report['git_host_guard_bytes']} byte git-host guard (95 MiB): "
              "it cannot be mirrored to a git repository, only to release assets")
    return 0


if __name__ == "__main__":
    sys.exit(main())
