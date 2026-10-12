# Hot Attic Games master standard v2.0: compliance audit, scorecard and work queue

Audit date 2026-10-12, source line `ccr-5f32885a-gvu16v` (PR #1, draft). Native APK 8, running 8.5, OTA #000007, runtime `android-godot-4.6.0-r2`, fingerprint
`d9c885429105d863a83ebd4a12a9410374baf57be264865878318d105e98acd8`: **unchanged by this audit** (`python3 tools/ota_runtime.py --check`). Nothing was published, merged,
tagged or built on GitHub Actions. Evidence is the repository and local runs; physical Steam Deck, Android, Windows GPU and Linux hardware tests did **not** occur.

Status words: PASS (met, with evidence), PARTIAL, FAIL, UNVERIFIED (cannot be shown without hardware / an owner artifact), BLOCKED (needs a credential or owner decision), N/A.
Work classes: GREEN (safe, autonomous), YELLOW (autonomous with a regression test), RED (owner decision or a native change: documented, not done).

## Scorecard (30 categories)

| # | Category (standard section) | Status | Evidence / gap |
|---|---|---|---|
| 1 | One authoritative source line (6) | PARTIAL | policy, lineage gate, ledger, `base-check` exist and are tested; `origin/main` still lags (owner: fast-forward via PR #1, RED-1) |
| 2 | Branch recovery / ledger (6) | PASS | `docs/BRANCH_LEDGER.md`, `source_audit.py ledger --check`; no branch deleted |
| 3 | Android build (5) | PASS | CI APK pipeline, signed with the persistent key, qualified; not rebuilt locally (no SDK/key here) |
| 4 | Windows build (5) | PASS | exported and verified locally and by CI; the package no longer carries the ~300 MB of unused media after the `.gdignore` change (pass 4) |
| 5 | Native Linux build (5) | PARTIAL | `tools/build.py --platform linux` builds, verifies, boots headless (also inside an empty network namespace); an explicit-dispatch `linux` job exists in `ci.yml` (never run: a dispatch needs the workflow on the default branch); no tracked preset (RED-3); not run on hardware |
| 6 | One build number, one SHA (6) | PASS | `VERSION`, lineage gate, `SOURCE_SHA` in CI; `build.py` stamps one SHA on all targets |
| 7 | Artifact naming (7) | PASS (pass 5) | owner decision 2026-10-12: future builds are `Purgatory Dungeon Build NN APK.apk / EXE.zip / Linux.tar.gz` + `build-manifest.json` + `checksums.sha256`; v1-v8 keep their names; enforced by `build.py`, `build_gate.py`, `verify_package.py` |
| 8 | GitHub Releases library (8) | PASS in source (never run) | the guarded `publish` job creates tag `build-NN` and the release with the five standard files; `local_only` creates nothing; v1-v8 untouched |
| 9 | Manual coordinated build workflow (9) | PASS in source, hosted run pending (pass 5) | `ci.yml` = "Build (manual)": `workflow_dispatch` only, inputs platform / source_sha / build_number / destination (default `local_only`), gate -> validate -> windows/linux/android -> assemble -> publish (github_releases only); policy tests + actionlint; the hosted run is recorded in the pass-5 section |
| 10 | No accidental publication (9, 20) | PASS (pass 5) | tag / `release/v*` / `promote/**` publication was REMOVED; builds start only by manual dispatch; the one remaining push-triggered publisher is `ota-publish.yml` (an `ota/<channel>/<sha>` branch, owner-authorised, unchanged, asserted by `test_build_workflow.py`) |
| 11 | Update architecture (10) | PASS | signed OTA + native baseline + runtime fingerprint + rollback (`docs/OTA.md`); Android only; Windows/Linux = new package (SteamPipe pending, RED-6) |
| 12 | Publishing separation (10) | PASS | release, OTA, Steam are separate actions; `build.py` has no publish path (tested) |
| 13 | Save schema, safe writes (11) | PASS in source, native release only (pass 5) | `schema_version` 1, unknown keys and newer schemas preserved, session backups; `test_save_schema` (40 checks). (earlier text:) | atomic temp+rename for profile, settings, last slot and now codex; **no save schema version field, no backup of the previous good file** (RED-5) |
| 14 | Corruption handling (11) | PASS in source (pass 5) | unreadable bytes preserved, recovery from the previous session's backup or a complete interrupted temp file. (earlier text:) | a corrupt slot loads a fresh default profile and, found in pass 4, the quit / background path then saved over the unreadable file; fixed: the bytes are now kept as `profile_N.save.unreadable` (`test_save_manager`). Still no schema version and no automatic restore (RED-5) |
| 15 | Steam Cloud (11) | BLOCKED | no Steam App ID, no Steamworks plugin; hardware-specific settings (graphics level) live in settings.json, which a cloud sync must exclude (design note in Q-9) |
| 16 | Controller completeness (12.1) | PASS (software) | every menu reachable by pad (`test_controller_nav`, 35 checks); remap not disturbed; physical pad on a Deck UNVERIFIED |
| 17 | On-screen keyboard (12.2) | PARTIAL | the in-game pad keyboard works (tested); the Steam floating keyboard (`ShowFloatingGamepadTextInput`) is **pending**, needs Steamworks/App ID (BLOCKED, RED-6) |
| 18 | Mixed input (12.3) | PASS (software) | mouse motion no longer flips glyphs; light stick brush ignored (`test_input_desktop`); mouse look and stick look measured adding up for both classes (`test_mixed_look`). Real trackpad / gyro on a Deck: UNVERIFIED |
| 19 | Camera sensitivity calibration (12.4) | N/A (optional) | default `0.0025` rad/px (= 0.143 deg/px) is not Valve's 0.022 deg/px; the recommendation is optional and the established feel is kept; no change |
| 20 | Display and aspect ratios (12.5) | PASS (software) | menus rendered at 1280x800, 1920x1200, 2560x1080 and the in-run HUD, pause, death and win screens at 2560x1080: no clipping. One overlap found and fixed (run-start banner over the pause title, `test_toast_pause`) |
| 21 | Graphics API (12.6) | UNVERIFIED | Windows uses D3D12 (Proton via vkd3d-proton), Linux native is Vulkan (booted on llvmpipe only); Vulkan-on-Windows is an owner/native decision (RED-7) |
| 22 | Codecs (12.7) | PASS | the game plays no video; audio is OGG/WAV/MP3 decoded by Godot on every platform; the unreferenced MP4 is excluded from Android/Linux |
| 23 | Graphics settings (12.8) | PASS | Quality / Balanced / Cool-Battery with "(Recommended)" per device, never locked, stored in settings.json, no gameplay or physics change. (No literal "Automatic" entry: the recommended level is the automatic default.) |
| 24 | Offline play (12.9) | PASS (software) | only the Android OTA updater uses a network class (`test_offline.py`); the native Linux package launched to the main menu inside an empty network namespace with a fresh save root. Fresh Steam account offline first launch and cloud resync: UNVERIFIED (no Steam) |
| 25 | No external launcher (12.10) | PASS | straight into splash and menu |
| 26 | Steam Deck performance (12.11) | UNVERIFIED | never measured on hardware; 800p Balanced default built; headless CPU numbers only |
| 27 | Stability / suspend-resume (12.12) | UNVERIFIED | cold start, clean quit and 12 s boot tested headless; suspend, resume, focus loss, reconnect not exercised (game does not pause on focus loss: owner decision) |
| 28 | Glyph library (13) | PASS | approved library integrated, four pad families + key caps, provenance + CC0 evidence; Menu/View derived from the library sprite sheet; no hand-drawn glyph remains |
| 29 | Branding / studio splash (17) | PASS | `test_studio_splash`, release gate `REQUIRE_STUDIO_LOGO` |
| 30 | Licensing / testing & CI efficiency (18-19) | PARTIAL | glyphs, fonts, Kenney verified; music, SFX, models, props, skyboxes UNVERIFIED (`docs/THIRD_PARTY_ASSETS.md`, RED-8); tests broad, CI economical, one run per SHA |

## Work queue

| ID | Requirement | Evidence | Prio | Class | Effort | Status |
|---|---|---|---|---|---|---|
| Q-1 | Glyph library integration, no hand-drawn art | `assets/ui/glyphs`, `tools/import_glyph_library.py`, 72 + 35 + 243 checks | P1 | GREEN | M | **Done** (6eb8ceb, 7c4590c) |
| Q-2 | Mixed-input prompt stability | `test_input_desktop` | P1 | YELLOW | S | **Done** (7c4590c) |
| Q-3 | Local three-platform build tool with manifest + checksums, exact-commit export | `tools/build.py`, `tests/test_build_tool.py`; Windows and Linux built and verified | P1 | GREEN | M | **Done** (f05896f, 9929b2f, 1ebf0f3) |
| Q-4 | Codex lore missing from every packaged build | native Linux boot warning; PCK listing; `test_codex_save` | P0 | YELLOW | S | **Done** (ea48550); not shipped until the next release/OTA the owner authorises |
| Q-5 | Atomic codex write; graphics names + Recommended marker | `test_codex_save` | P2 | YELLOW | S | **Done** (ae8c4c0) |
| Q-6 | Hosted manual workflow (inputs platform/source_sha/build_number/destination), manifests + checksums on the Release, Linux asset | `ci.yml` dispatch inputs per platform now exist (Q-7); the one workflow with a `destination` and Release attachment remains | P1 | RED (release publication path) | L | **Deferred**: `ci.yml` is validated by `tests/test_ota_workflows.py` and a release path change deserves the owner's eye; proposal in "Proposals" |
| Q-7 | Linux CI template install + verify step | `ci.yml` job `linux`, tested statically (`test_build_tool.py`) | P2 | GREEN | S | **Done** (never executed on GitHub: needs the owner to dispatch it once the workflow is on `main`) |
| Q-8 | Documentation set (PLATFORM_SUPPORT, THIRD_PARTY_ASSETS; UPDATES and STEAM_HARDWARE_CHECKLIST map to existing pages) | this commit | P2 | GREEN | S | **Done** |
| Q-9 | Steam Cloud design: exclude `settings.json` graphics keys from sync; sync `saves/` + codex only | design note below | P2 | BLOCKED | M | Pending App ID |
| Q-10 | Test simultaneous mouse + stick camera accumulation | `tests/test_mixed_look.gd` | P2 | YELLOW | M | **Done** |
| Q-11 | Render in-run HUD at 21:9 | `tests/deck_game_shots` at 2560x1080 | P3 | GREEN | S | **Done** (found and fixed the banner overlap) |

### RED (documented, not done)

- **RED-1** Fast-forward `main` to this line (PR #1): protected default branch.
- **RED-2** Artifact/release naming: standard `Purgatory Dungeon Build NN ...` against the owner's `Purgatory Dungeon v<N>` convention (CLAUDE.md, docs/RELEASES.md, tests). Tool supports both; the owner picks.
- **RED-3** Tracked Linux export preset: changes `export_presets.cfg` and therefore the native fingerprint (a new APK generation). The scratch-preset approach avoids it.
- ~~RED-4~~ **Resolved in pass 4 without a preset change**: the unreferenced skyboxes, video and night-sky texture are hidden from Godot with `.gdignore` (moved, not deleted), so no preset edit or fingerprint bump was needed.
- ~~RED-5~~ **Implemented in pass 5** (owner authorised the backward-compatible save protection): `schema_version`, session backups, future-schema protection, recovery; ships only in the next native release (below). Touches `save_manager.gd` / `storage_paths.gd` (guarded files, the save format): needs a migration plan and the owner's approval; test with real saves first.
- **RED-6** Steamworks (GodotSteam plugin, App ID): Steam keyboard, Steam Cloud, SteamPipe uploads.
- **RED-7** Windows renderer d3d12 -> vulkan (native, owner decision, already parked).
- **RED-8** Remove or license UNVERIFIED assets; supply receipts.
- Not authorised and not attempted: any GitHub Release, OTA, Steam or Play upload, hosted build, history rewrite, branch deletion, merge.

### Proposal for Q-6 (needs review before it is written into `ci.yml`)

A `workflow_dispatch` input set `platform (android|windows|linux|all)`, `source_sha`, `build_number`, `destination (github_releases|local_only)`; steps: lineage gate on the
SHA, number-uniqueness check against existing tags, the test suite, `python3 tools/build.py` for the chosen platforms (Android through the existing signed job), attach
`build-manifest.json` and `checksums.sha256`, publish only when `destination == github_releases`. Cost: one hosted run per authorised build; no push trigger.

## Required documents (standard section 19) mapped to this repository

| Standard | Here |
|---|---|
| CLAUDE.md | `CLAUDE.md` |
| docs/PLATFORM_SUPPORT.md | `docs/PLATFORM_SUPPORT.md` (new) |
| docs/UPDATES.md | `docs/OTA.md` (Android) + `docs/PLATFORM_SUPPORT.md` (Windows/Linux: new package, SteamPipe pending); not duplicated |
| docs/RELEASES.md | `docs/RELEASES.md` |
| docs/STEAM_HARDWARE_CHECKLIST.md | `docs/STEAM_DECK.md` |
| docs/BRANCH_LEDGER.md | `docs/BRANCH_LEDGER.md` |
| docs/THIRD_PARTY_ASSETS.md | `docs/THIRD_PARTY_ASSETS.md` (new) |

## Pass 4 (post-audit correction pass, source line head `bbe8b58` at the start)

**PR #1 verification.** Open, draft, base `main` (`f0eaa47`), mergeable state clean, 289 commits, no reviews or comments. The one CI run on `bbe8b58` (`CI` run 100, event
`pull_request`) concluded **skipped**, all four jobs (`validate-and-export`, `android`, `publish`, `promote`): the workflow's own rule skips draft PRs. "No failing checks"
therefore meant **no hosted validation at all**; the only evidence for these commits is the local suite. Added `tools/preflight.sh` (Godot-free gate, ~15 s) so a push can be
checked cheaply without Actions minutes; the full suite stays `tests/run_tests.sh`.

**Workflow exposure review.** A push to `ccr-5f32885a-gvu16v` matches no `ci.yml` trigger that publishes. Publication needs a `v<N>` tag, a `release/v<N>` branch or a `promote/**`
branch: deliberate release refs, not touched. The standard asks that pushes and tags never publish automatically; the owner's documented flow (docs/RELEASES.md) is exactly a tag
push, so changing it is a release-process redesign (RED-9, recommendation: keep the tag as the authorisation, because a tag is an explicit human act and the lineage gate and tests run first;
add a required-reviewer environment on the `publish` job if a second confirmation is wanted).

**RED recommendations (Section N of the first report).**

| Decision | Recommendation (evidence) | Class |
|---|---|---|
| Artifact naming `Purgatory Dungeon v<N>` vs `Purgatory Dungeon Build NN` | Keep v<N>. It is the owner's written mandate (CLAUDE.md), all eight releases use it, and the standard itself says to preserve an established compatible repository convention. `build.py --naming standard` produces the other form on request. | RED |
| Save backups / schema version | Next APK: add `schema_version` (additive key, defaults backfill already tolerates it) and a `.bak` of the last good profile. Pass 4 already closed the data-loss path without a format change. | RED |
| Steamworks, App ID, Steam keyboard, Steam Cloud | Blocked on an App ID. Cloud design when it exists: sync `saves/` and `codex.json`; never `settings.json` (it holds graphics level and resolution). The in-game pad keyboard stays the fallback. No speculative Steam call was written. | RED / BLOCKED |
| Windows renderer d3d12 vs vulkan | Moot for the Deck if the native Linux build ships there (Vulkan natively). Leave Windows on d3d12 until a Windows GPU test says otherwise; decide at the next APK generation. | RED |
| Fast-forward `main` | Do it once PR #1 is accepted; no branch needs to be deleted first (ledger is clean). | RED |
| Unlicensed assets | Unused ones are now out of every build; for the used music, SFX, models and props supply receipts, or replace them before a Steam page. | RED |
| Glyph license copy | Re-fetch attempted 2026-10-12: the author's page was not reachable from the sandbox and the web search did not find it. Owner: save the page (or its URL) under `docs/licenses/`. | owner |

**Corrections made in pass 4:** `.gdignore` for unreferenced media (Windows package no longer ships ~300 MB of it); `tests/test_licenses.py`; `tests/test_offline.py`;
`tests/test_mixed_look.gd`; banner-over-pause fix + `tests/test_toast_pause.gd`; unreadable-save preservation + test; `ci.yml` `build_linux` dispatch job + wiring tests.

## Pass 5 (unified build pipeline and save protection; starting SHA `ee92cb6`)

**Owner decisions applied (2026-10-12).** (1) Future builds are named `Purgatory Dungeon Build NN` with the five standard files; v1-v8 stay as published. (2) One manual
build workflow; building and publishing are separate. (3) Backward-compatible save versioning and backups for the next native release. The decisions that remain are in the final report.

**Publication paths found (all workflows).** `ci.yml` published on a `v<N>` tag, a `release/v<N>` branch and a `promote/**` branch (removed: the replacement is the guarded `publish` job of the manual
workflow); `ota-publish.yml` publishes an OTA when an `ota/<channel>/<sha>` branch is pushed (kept: not an ordinary push, owner-authorised, protected by the signing key, the native runtime
fingerprint and the proven suite; converting it to a dispatch would make OTAs unpublishable until `main` carries the workflow, so it is documented and pinned by a test instead);
`ota.yml` / `ota-pubkey.yml` are legacy files that exist only on `main`'s registry history (not in this tree). No branch has protection (`protected: false` on every branch, `main` included):
recommendation: protect `main` (required review, no force push) when it is fast-forwarded.

**Why the unified workflow lives in `ci.yml`.** GitHub can dispatch only a workflow it has already registered (probe: `ci.yml` accepted a dispatch at the PR branch ref, a new `build.yml` returned 404),
and `main` has no workflows yet. Reusing the registered path makes the one authorised hosted run possible before the merge; after the merge the file can be renamed. `tests.yml` (pull requests and
pushes to `main`, read-only) replaces the old validation job.

**Saves.** `OTA-guarded`: `scripts/save_manager.gd` changed, so `tools/ota/classify.py` reports it as guarded and an OTA would need the owner's separate `--accept-guarded`. The new code only adds
a key and writes extra recovery files, so an older reader still loads the file, but the change is delivered in the next native release (APK), never by an OTA, until the owner decides otherwise.

**Remaining release blockers (documented, not solved):** Steam App ID + Steamworks (Steam keyboard, Steam Input, Steam Cloud, SteamPipe), Steam Deck / Android device / Windows and Linux GPU
validation, controller reconnect and suspend/resume, licences for the music, sound effects, models and props, the glyph page copy, production signing credentials (the hosted Android job uses the existing key only).
