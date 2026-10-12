# One game, one history: source of truth, platform builds and branch recovery

Permanent engineering policy for this repository (owner directive, 2026-10-12). It applies to every change, build and release. The short form
lives in `CLAUDE.md`; this page is the full rule, how it is enforced, and how to check it yourself.

> We are not developing an Android game and a Windows game. We are developing **ONE GAME** that runs on Android and Windows.
> One authoritative codebase. One integrated development history. Multiple build targets. No silent platform divergence. No forgotten completed work.

## 1. Single source of truth

- There is ONE authoritative history. Every platform build, every OTA and every release derives from a commit in it.
- One codebase is not one binary. The mechanism in this project (GDScript on Godot 4.6, no new engine or build system):
  - the same scripts, scenes and data for every target; platform differences are small, named, gated branches (below);
  - one export preset per tracked target (`export_presets.cfg`: "Windows Desktop", "Android"; the native Linux preset is added to a scratch copy by `tools/build.py`) built from the same commit by one workflow (`ci.yml`, manual);
  - one version number (`VERSION`) for all targets of a release.
- A fix made for one platform is evaluated against every platform before it is called done. No platform may silently fall behind.

### Where platform-specific code is allowed (and nowhere else)

| Difference | Where | Gate |
|---|---|---|
| Touch controls, phone layout, haptics | `scripts/touch/`, `TouchControls` | `TouchControls.is_touch_platform()` (Windows unchanged) |
| Over-the-air updates | `scripts/boot/`, `ota/`, `tools/ota/` | Android-only native layer; `docs/OTA.md` |
| Phone render scale / MSAA | `project.godot` `.android` overrides | feature tag |
| Steam Deck (controller glyphs, Graphics Quality default, Deck detection) | `scripts/controller_glyphs.gd`, `glyph_prompt.gd`, `graphics_quality.gd`, `steam_deck.gd` | `SteamDeck.is_deck()`; docs/STEAM_DECK.md |
| Storage location | `scripts/storage_paths.gd` | `OS` checks |

Anything else that differs between platforms is a defect unless it is added to this table with its reason.

## 2. Branches are workspaces, not products

- Feature, repair, experiment and agent-worktree branches are allowed. Each must start from the authoritative line, have one purpose, and be integrated
  (after validation) or consciously retired. Platform names in a branch name give no licence to keep a separate version of the game.
- A release is only ever built from a commit that **descends from every earlier release** (the lineage gate, section 4).
- Parallel agents never keep independent copies of the application. An agent that is handed a worktree checks its base first:
  `python3 tools/source_audit.py base-check` (exit 1 = "STALE BASE": stop, the checkout is not on the authoritative line).
- No branch is deleted because it looks obsolete. `docs/BRANCH_LEDGER.md` accounts for every branch, tag and recoverable commit.

### The authoritative line

`docs/source_authority.json` names it. `main` is the intended authoritative branch. While `origin/main` lags (it still points at the old v2.5 upload snapshot),
the file names the **interim line**, a branch that contains `main`, every release tag, every OTA tag and every other branch. Moving `main` is an owner action
(it is the default branch): fast-forward it to the interim line (pull request #1), then delete `current_line` from the file. Nothing else needs to change.

## 3. Branch recovery

`tools/source_audit.py ledger [--auth REF] [--check]` (read-only) lists every remote branch against the authoritative line: **integrated** (all its commits are
reachable from, or patch-equivalent to, the line) or **UNMERGED** (n patches the line lacks). `--check` fails when an unmerged branch is not recorded in
`accounted_unmerged` in `docs/source_authority.json` with the reason. `tests/test_source_of_truth.py` runs the same check in any clone that has the other
branches. Findings of the 2026-10-12 audit, and the classification of every discovered item, are in `docs/BRANCH_LEDGER.md`.

## 4. Release lineage gate and provenance

`python3 tools/source_audit.py lineage-gate --sha <commit> --tag vN` (the v1-v8 release gate) refuses unless `VERSION` is N, every earlier release tag exists and is an ancestor of the commit, and
tag `vN`, if it exists, points at this very commit. Exit 2 means "cannot decide" (shallow clone, tags missing): a failure, never a pass.
Every numbered build runs `python3 tools/build_gate.py source` first thing in `ci.yml` (the manual build workflow): the commit being built is the checked-out one, it is reachable from the authoritative
line (`docs/source_authority.json`, read from the TRUSTED workflow commit, never from the commit being judged), it contains every release tag, and the workflow commit is on that line too.
A stale or side branch can therefore neither build nor publish. `build_gate.py number` refuses a consumed or non-monotonic build number, and a build's tag is `build-NN`, never moved.

Every build records where it came from, in `build_info.json` (shipped inside the game, `scripts/build_info.gd`) and `BUILD_INFO.txt` / `ANDROID_BUILD_INFO.txt` next to
the artifact: `commit` (full SHA), `source_ref` (branch or tag), `public_version`, `platform`, `engine`, `build_config`, `built_utc`, `ci_run`, the runtime id and fingerprint,
the package checksums and the Godot version. `tools/verify_package.py --sha` ties the exported package to that commit.

### Coordinated multiplatform releases

The APK, the Windows package and the Linux package of one build come from ONE `ci.yml` run, built from the same `source_sha` with the same build number; `assemble` rejects a part built from another
commit or number, and `publish` re-verifies the assembled set before creating the release, so a release cannot mix commits. If one platform fails the run stops there: a
different source revision is never substituted. Platform packaging and signing are the only per-platform steps.

## 5. OTA and native releases

The validated OTA architecture is unchanged (`docs/OTA.md`). An OTA is published from an exact commit (`ota/<channel>/<40-hex sha>`), classified against its native
baseline (`ota/boundary.json`, `tools/ota/classify.py`) and gated by the runtime fingerprint; OTA tags and releases are ancestors of this history. OTA delivery never
creates a second history. Not every change is OTA-compatible: `project.godot`, `export_presets.cfg`, `scripts/boot/**`, `ota/**` need a new APK.

## 6. Enforcement (what stops a violation, and what proves it)

| Rule | Enforced by | Proven by |
|---|---|---|
| A build is on the authoritative line and descends from all earlier releases; numbers are never reused | `build_gate.py source` / `number` in `ci.yml` `gate` (and again in `publish`) | `tests/test_build_gate.py`, `tests/test_source_of_truth.py` (throwaway repositories: side branch, stale snapshot, unrelated history, moved tag, shallow clone) |
| Every platform build is stamped with the one source commit and build number | `--commit "$SOURCE_SHA"` / `--build-number` in `build_info.json`; `assemble` checks every part | `tests/test_source_of_truth.py`, `tests/test_build_gate.py` (workflow wiring) |
| Provenance recorded | `release_tool.py build-info --ref --platform --engine` | `tests/test_source_of_truth.py` |
| Nothing left behind | `source_audit.py ledger --check`, `docs/source_authority.json` | `tests/test_source_of_truth.py` (full clones) |
| The rule is discoverable | `CLAUDE.md`, this page, `docs/BRANCH_LEDGER.md` | `tests/test_source_of_truth.py` (policy files) |
| The suite really ran | `tests/run_tests.sh` fails a stage that exits non-zero or prints `SCRIPT ERROR`; the python stages print a NOTICE when a check cannot run in a single-branch clone | `tests/run_tests.sh` |

CI checks out a single commit, so the whole-repository branch audit cannot run there: it prints a visible NOTICE and the build gate (which fetches full history) does the part that matters at build time. Run the full audit in a normal clone before a release.

## 7. Not allowed without the owner

Publishing APKs, EXEs or other artifacts; deploying an OTA; triggering production publishing; deleting a branch; rewriting shared history; merging into `main` or another
protected production branch; touching another repository; redesigning the game; restoring uncertain or deliberately removed features; changing signing or release credentials.
Anything destructive, irreversible, or that materially changes established behaviour: stop and ask.

## 8. Checklist for a developer or agent

1. `git fetch --tags` then `python3 tools/source_audit.py base-check` (your checkout descends from the latest release).
2. Work on a short-lived branch from the authoritative line; keep it small; integrate it when validated.
3. `tests/run_tests.sh`, `python3 tools/ota_runtime.py --check`, `python3 tools/ota/classify.py <base> HEAD` as in `CLAUDE.md`.
4. Before a build: `python3 tools/source_audit.py ledger --check` in a full clone; the build workflow runs `tools/build_gate.py source` and `number` itself.
