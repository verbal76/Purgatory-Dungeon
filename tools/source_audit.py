#!/usr/bin/env python3
"""One authoritative product history: lineage gate, base check and branch ledger (docs/SOURCE_OF_TRUTH.md).

Read-only: nothing here writes to the repository, fetches, or deletes a branch. Standard library only.

  python3 tools/source_audit.py lineage-gate --sha <commit> [--tag vN]   release gate: the commit descends from EVERY earlier release
                                                                         tag, the tag (if it exists) is this commit, VERSION agrees.
                                                                         exit 0 = OK, 1 = refused, 2 = cannot decide (shallow clone / tags missing)
  python3 tools/source_audit.py base-check [--ref HEAD]                  does this checkout descend from the latest release? (agents / worktrees)
  python3 tools/source_audit.py ledger [--auth REF] [--check] [--write FILE]
                                                                         every remote branch against the authoritative line: integrated, or
                                                                         UNMERGED (patches no commit of the line contains). --check exits 1
                                                                         when an unmerged branch is not accounted for in docs/source_authority.json.

A release is the set "tag vN + Windows package + Android APK"; they are all built from ONE commit (ci.yml stamps both with SOURCE_SHA).
The gate is what stops an outdated or side branch from publishing: such a commit does not contain the earlier release tags.
"""
import argparse
import json
import os
import re
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
RELEASE_TAG = re.compile(r"^v([1-9][0-9]*)$")
SHA = re.compile(r"^[0-9a-f]{40}$")


class Repo:
    def __init__(self, path: str = ROOT):
        self.path = path

    def git(self, *args: str, check: bool = True) -> str:
        p = subprocess.run(["git", "-C", self.path, *args], capture_output=True, text=True)
        if check and p.returncode != 0:
            raise RuntimeError(f"git {' '.join(args)}: {p.stderr.strip() or p.stdout.strip()}")
        return p.stdout.strip()

    def ok(self, *args: str) -> bool:
        return subprocess.run(["git", "-C", self.path, *args], capture_output=True).returncode == 0

    def is_shallow(self) -> bool:
        return self.git("rev-parse", "--is-shallow-repository", check=False) == "true"

    def resolve(self, ref: str) -> str:
        return self.git("rev-parse", "--verify", "--quiet", ref + "^{commit}", check=False)

    def is_ancestor(self, a: str, b: str) -> bool:
        return self.ok("merge-base", "--is-ancestor", a, b)

    def release_tags(self) -> dict:
        out = {}
        for t in self.git("tag", "--list", "v[0-9]*", check=False).split():
            m = RELEASE_TAG.match(t)
            if m:
                out[int(m.group(1))] = t
        return out

    def version(self) -> int:
        text = open(os.path.join(self.path, "VERSION"), encoding="utf-8").read().strip()
        if not re.fullmatch(r"[1-9][0-9]*", text):
            raise RuntimeError(f"VERSION must be a single positive integer (got {text!r})")
        return int(text)


# ── lineage gate ─────────────────────────────────────────────────────────────────────────────────────────────

def lineage_gate(repo: Repo, sha: str, tag: str = "") -> tuple:
    """Returns (exit_code, [messages])."""
    msgs = []
    commit = repo.resolve(sha)
    if not commit:
        return 2, [f"commit {sha} is not in this clone (fetch it)"]
    try:
        n = repo.version()
    except (RuntimeError, OSError) as e:
        return 1, [f"cannot read VERSION: {e}"]
    if tag and tag != f"v{n}":
        return 1, [f"tag {tag} does not match VERSION {n}: a release tag is v<VERSION>"]
    tags = repo.release_tags()
    # The release tags are the spine of the product: every earlier one must be present and be an ancestor of this commit.
    missing = [k for k in range(1, n) if k not in tags]
    if missing and repo.is_shallow():
        return 2, ["this clone is shallow and lacks release tags " + ", ".join(f"v{k}" for k in missing)
                   + ": fetch history first (git fetch --tags --unshallow --filter=blob:none)"]
    if missing:
        return 1, ["release tag(s) missing from the repository: " + ", ".join(f"v{k}" for k in missing)
                   + " (every earlier release must exist; fetch tags, or the numbering is broken)"]
    if repo.is_shallow():
        return 2, ["this clone is shallow: lineage cannot be proven (git fetch --tags --unshallow --filter=blob:none)"]
    bad = []
    for k in range(1, n):
        tip = repo.resolve(tags[k])
        if not tip or not repo.is_ancestor(tip, commit):
            bad.append(tags[k])
    if bad:
        msgs.append(f"commit {commit[:12]} does NOT contain release(s) {', '.join(bad)}: it comes from an outdated or side line of "
                    "development. A release must be built from the single authoritative history (docs/SOURCE_OF_TRUTH.md).")
        return 1, msgs
    if n in tags:
        existing = repo.resolve(tags[n])
        if existing != commit:
            return 1, [f"tag v{n} already points at {existing[:12]}, not {commit[:12]}: one number = one binary, never reused or moved"]
    msgs.append(f"lineage OK: {commit[:12]} contains all {n - 1} earlier release tag(s) (v1..v{n - 1}) and VERSION is {n}")
    return 0, msgs


# ── base check (agents and worktrees) ───────────────────────────────────────────────────────────────────────

def base_check(repo: Repo, ref: str = "HEAD") -> tuple:
    commit = repo.resolve(ref)
    if not commit:
        return 1, [f"{ref} does not resolve"]
    tags = repo.release_tags()
    if not tags:
        return 2, ["no release tags in this clone (fetch tags)"]
    k = max(tags)
    tip = repo.resolve(tags[k])
    if repo.is_ancestor(tip, commit):
        return 0, [f"base OK: {ref} ({commit[:12]}) descends from the latest release {tags[k]}"]
    return 1, [f"STALE BASE: {ref} ({commit[:12]}) does not contain the latest release {tags[k]}. Work from the authoritative line "
               "(docs/SOURCE_OF_TRUTH.md), not from this checkout: its history is outdated."]


# ── ledger ──────────────────────────────────────────────────────────────────────────────────────────────────

def load_authority(root: str = ROOT) -> dict:
    path = os.path.join(root, "docs", "source_authority.json")
    if not os.path.isfile(path):
        return {}
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def authoritative_ref(repo: Repo, explicit: str = "") -> tuple:
    """(ref, note). Explicit wins; else origin/<authoritative_branch> when it holds the latest release, else the declared interim line."""
    if explicit:
        return explicit, "given on the command line"
    auth = load_authority(repo.path)
    branch = auth.get("authoritative_branch", "main")
    tags = repo.release_tags()
    latest = repo.resolve(tags[max(tags)]) if tags else ""
    main_ref = f"origin/{branch}"
    if repo.resolve(main_ref) and (not latest or repo.is_ancestor(latest, repo.resolve(main_ref))):
        return main_ref, f"{main_ref} (the authoritative branch)"
    interim = auth.get("current_line", {}).get("branch", "")
    if interim and repo.resolve(f"origin/{interim}"):
        return f"origin/{interim}", f"origin/{interim} (interim: {main_ref} does not yet contain the latest release)"
    return "HEAD", "HEAD (no declared authoritative line found)"


def branch_rows(repo: Repo, auth_ref: str) -> list:
    rows = []
    refs = repo.git("for-each-ref", "--format=%(refname:short)", "refs/remotes/origin", check=False).split()
    for r in sorted(refs):
        if r == "origin/HEAD" or r == "origin":
            continue
        tip = repo.resolve(r)
        ahead = int(repo.git("rev-list", "--count", f"{auth_ref}..{r}", check=False) or 0)
        behind = int(repo.git("rev-list", "--count", f"{r}..{auth_ref}", check=False) or 0)
        unique = len([l for l in repo.git("cherry", auth_ref, r, check=False).splitlines() if l.startswith("+")])
        date = repo.git("log", "-1", "--format=%cs", r, check=False)
        subject = repo.git("log", "-1", "--format=%s", r, check=False)[:70]
        rows.append({"ref": r[len("origin/"):], "tip": tip[:7], "date": date, "ahead": ahead, "behind": behind, "unique": unique, "subject": subject})
    return rows


def classify(row: dict, accounted: dict) -> str:
    if row["ref"] in accounted:
        return "UNMERGED, accounted: " + accounted[row["ref"]]
    if row["unique"] == 0:
        return "integrated"
    return f"UNMERGED: {row['unique']} patch(es) not in the authoritative line"


def render_ledger(repo: Repo, auth_ref: str, note: str) -> tuple:
    auth = load_authority(repo.path)
    accounted = auth.get("accounted_unmerged", {})
    rows = branch_rows(repo, auth_ref)
    lines = [f"Authoritative line for this ledger: {note} @ {repo.resolve(auth_ref)[:12]}", "",
             "| Branch | Tip | Date | Ahead | Behind | Disposition |", "|---|---|---|---|---|---|"]
    unaccounted = 0
    for row in rows:
        disp = classify(row, accounted)
        if disp.startswith("UNMERGED:"):
            unaccounted += 1
        lines.append(f"| `{row['ref']}` | {row['tip']} | {row['date']} | {row['ahead']} | {row['behind']} | {disp} |")
    return "\n".join(lines), unaccounted


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=ROOT)
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("lineage-gate")
    g.add_argument("--sha", required=True)
    g.add_argument("--tag", default="")
    b = sub.add_parser("base-check")
    b.add_argument("--ref", default="HEAD")
    lg = sub.add_parser("ledger")
    lg.add_argument("--auth", default="")
    lg.add_argument("--check", action="store_true")
    lg.add_argument("--write", default="")
    a = ap.parse_args()
    repo = Repo(a.repo)
    if a.cmd == "lineage-gate":
        code, msgs = lineage_gate(repo, a.sha, a.tag)
    elif a.cmd == "base-check":
        code, msgs = base_check(repo, a.ref)
    else:
        ref, note = authoritative_ref(repo, a.auth)
        text, unaccounted = render_ledger(repo, ref, note)
        if a.write:
            open(a.write, "w", encoding="utf-8").write(text + "\n")
        msgs = [text]
        code = 1 if (a.check and unaccounted) else 0
        if a.check and unaccounted:
            msgs.append(f"LEDGER CHECK FAILED: {unaccounted} branch(es) hold work the authoritative line lacks and are not accounted for in "
                        "docs/source_authority.json (integrate them, or record why not)")
    for m in msgs:
        print(m)
    return code


if __name__ == "__main__":
    sys.exit(main())
