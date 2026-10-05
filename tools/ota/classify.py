#!/usr/bin/env python3
"""Decides whether the changes between two git refs can ship over the air (docs/OTA.md).

  classify.py <base_ref> [<head_ref>=HEAD] [--accept-guarded "reason"] [--json] [--repo DIR]

Runs `git diff --name-status -M` between the refs and puts every changed path (both sides of a rename,
deletions included) into one of the categories of tools/ota/ota_rules.json:
  safe          replaceable inside the pack (the default)
  apk_required  project.godot, export presets, android/, OTA client, native code, version files...
  guarded       save/settings code: OTA only with --accept-guarded "<reason>"
  not_shipped   tools/, tests/, docs/, *.md ... never exported, ignored

Exit status:  0 OTA-safe (or no shipped file changed)   10 APK required (offending paths + rules printed)
              11 guarded paths touched without --accept-guarded   2 usage / git error
"""
import argparse
import json
import subprocess
import sys

import otalib

EXIT_OK, EXIT_APK, EXIT_GUARDED, EXIT_ERROR = 0, 10, 11, 2


def git(repo: str, *args: str) -> bytes:
    try:
        r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True)
    except FileNotFoundError:
        raise otalib.OtaError("git not found on PATH")
    if r.returncode != 0:
        raise otalib.OtaError("git " + " ".join(args[:2]) + " failed: " + r.stderr.decode("utf-8", "replace").strip())
    return r.stdout


def resolve(repo: str, ref: str) -> str:
    try:
        return git(repo, "rev-parse", "--verify", "--quiet", ref + "^{commit}").decode().strip()
    except otalib.OtaError:
        raise otalib.OtaError(f"cannot resolve {ref!r} to a commit (is the tag/branch fetched?)")


def changes(repo: str, base: str, head: str) -> list:
    """[(status, path, old_path|None)] from `git diff --name-status -z -M base head`."""
    raw = git(repo, "diff", "--name-status", "-z", "-M", "--no-ext-diff", base, head)
    parts = raw.decode("utf-8", "surrogateescape").split("\0")
    out, i = [], 0
    while i < len(parts) and parts[i]:
        st = parts[i]
        if st[0] in "RC":
            out.append((st[0], parts[i + 2], parts[i + 1]))
            i += 3
        else:
            out.append((st[0], parts[i + 1], None))
            i += 2
    return out


def classify(rules: dict, diff: list) -> list:
    entries = []
    for status, path, old in diff:
        cat, why = otalib.classify_source(rules, path)
        entries.append({"path": path, "status": status, "old_path": old, "category": cat, "rule": why})
        if status == "R" and old:
            # the old name disappears from the pack/tree as well
            ocat, owhy = otalib.classify_source(rules, old)
            entries.append({"path": old, "status": "D", "old_path": None, "category": ocat, "rule": owhy,
                            "renamed_to": path})
    return entries


def verdict(entries: list, accept_guarded: str) -> tuple:
    cats = {e["category"] for e in entries}
    if "apk_required" in cats:
        return "apk_required", EXIT_APK
    if "guarded" in cats and not accept_guarded:
        return "guarded_not_accepted", EXIT_GUARDED
    if "guarded" in cats:
        return "ota_safe_guarded_accepted", EXIT_OK
    if "safe" in cats:
        return "ota_safe", EXIT_OK
    return "nothing_shipped_changed", EXIT_OK


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("base_ref")
    ap.add_argument("head_ref", nargs="?", default="HEAD")
    ap.add_argument("--accept-guarded", default="", metavar="REASON",
                    help="allow guarded (save/settings) paths; the reason is recorded in the output")
    ap.add_argument("--json", action="store_true", help="print the result as JSON instead of the summary")
    ap.add_argument("--repo", default=".", help="git working directory (default: current)")
    ap.add_argument("--rules", default="", help="alternative ota_rules.json (tests)")
    a = ap.parse_args(argv)
    try:
        rules = otalib.load_rules(a.rules)
        base_sha, head_sha = resolve(a.repo, a.base_ref), resolve(a.repo, a.head_ref)
        entries = classify(rules, changes(a.repo, base_sha, head_sha))
    except otalib.OtaError as e:
        print(f"classify.py: {e}", file=sys.stderr)
        return EXIT_ERROR
    reason = a.accept_guarded.strip()
    result, code = verdict(entries, reason)
    counts = {c: sum(1 for e in entries if e["category"] == c) for c in ("safe", "apk_required", "guarded", "not_shipped")}
    if a.json:
        print(json.dumps({"base": a.base_ref, "head": a.head_ref, "base_sha": base_sha, "head_sha": head_sha,
                          "result": result, "exit_code": code, "counts": counts, "entries": entries,
                          "accept_guarded": reason or None}, indent=2, sort_keys=True))
        return code
    print(f"OTA classification {base_sha[:12]}..{head_sha[:12]} ({a.base_ref}..{a.head_ref}): {len(entries)} changed path(s)")
    print("  " + ", ".join(f"{k}={v}" for k, v in counts.items()))
    for cat, title in (("apk_required", "APK REQUIRED"), ("guarded", "GUARDED"), ("safe", "OTA-safe"), ("not_shipped", "not shipped (ignored)")):
        rows = [e for e in entries if e["category"] == cat]
        if not rows:
            continue
        if cat != "not_shipped":
            print(f"{title}:")
            limit = None if cat != "safe" else 40
            for e in rows[:limit]:
                extra = f" (renamed from {e['old_path']})" if e.get("old_path") else (f" (renamed to {e['renamed_to']})" if e.get("renamed_to") else "")
                print(f"  {e['status']}  {e['path']}{extra}   [{e['rule']}]")
            if limit and len(rows) > limit:
                print(f"  ... and {len(rows) - limit} more")
        else:
            print(f"{title}: {len(rows)} path(s)")
    if result == "apk_required":
        print("RESULT: APK REQUIRED - this change set cannot ship over the air; it needs the next numbered native build.")
    elif result == "guarded_not_accepted":
        print('RESULT: guarded paths touched. Re-run with --accept-guarded "<reason>" if the update stays readable by the previous code.')
    elif result == "ota_safe_guarded_accepted":
        print(f"RESULT: OTA-safe, guarded paths accepted: {reason}")
    elif result == "ota_safe":
        print("RESULT: OTA-safe")
    else:
        print("RESULT: nothing that ships changed (OTA-safe, no payload needed)")
    return code


if __name__ == "__main__":
    sys.exit(main())
