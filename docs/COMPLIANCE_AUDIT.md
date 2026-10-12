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
| 4 | Windows build (5) | PASS | exported and verified locally 2026-10-12 (470 MB; see RED-4) and by CI |
| 5 | Native Linux build (5) | PARTIAL | `tools/build.py --platform linux` builds, verifies, boots headless; no tracked preset, no CI workflow, not run on hardware (RED-3, Q-7) |
| 6 | One build number, one SHA (6) | PASS | `VERSION`, lineage gate, `SOURCE_SHA` in CI; `build.py` stamps one SHA on all targets |
| 7 | Artifact naming (7) | FAIL (convention conflict) | repo convention `Purgatory-Dungeon-v<N>-Windows.zip` / `.apk` differs from the standard's `Purgatory Dungeon Build NN EXE.zip`; `build.py --naming standard` supports both; owner decision RED-2 |
| 8 | GitHub Releases library (8) | PARTIAL | one release per number, Latest, immutable tags, never overwritten; no `build-manifest.json` / `checksums.sha256` attached by CI yet (Q-6); no Linux file |
| 9 | Manual coordinated build workflow (9) | PARTIAL | local tool done (`build.py`); the hosted workflow with inputs `platform / source_sha / build_number / destination` is not written (Q-6, needs owner review of the workflow change) |
| 10 | No accidental publication (9, 20) | PASS | PRs run only when ready, no push-triggered releases of OTA; release only by tag/release branch (owner action); OTA only by `ota/<channel>/<sha>` push |
| 11 | Update architecture (10) | PASS | signed OTA + native baseline + runtime fingerprint + rollback (`docs/OTA.md`); Android only; Windows/Linux = new package (SteamPipe pending, RED-6) |
| 12 | Publishing separation (10) | PASS | release, OTA, Steam are separate actions; `build.py` has no publish path (tested) |
| 13 | Save schema, safe writes (11) | PARTIAL | atomic temp+rename for profile, settings, last slot and now codex; **no save schema version field, no backup of the previous good file** (RED-5) |
| 14 | Corruption handling (11) | PARTIAL | a corrupt slot loads a fresh default profile; the next save overwrites the corrupt file (no `.bak`): data is not recoverable (RED-5) |
| 15 | Steam Cloud (11) | BLOCKED | no Steam App ID, no Steamworks plugin; hardware-specific settings (graphics level) live in settings.json, which a cloud sync must exclude (design note in Q-9) |
| 16 | Controller completeness (12.1) | PASS (software) | every menu reachable by pad (`test_controller_nav`, 35 checks); remap not disturbed; physical pad on a Deck UNVERIFIED |
| 17 | On-screen keyboard (12.2) | PARTIAL | the in-game pad keyboard works (tested); the Steam floating keyboard (`ShowFloatingGamepadTextInput`) is **pending**, needs Steamworks/App ID (BLOCKED, RED-6) |
| 18 | Mixed input (12.3) | PASS (software) | mouse motion no longer flips glyphs; light stick brush ignored (`test_input_desktop`). Simultaneous camera accumulation (mouse + stick) not tested: UNVERIFIED (Q-10) |
| 19 | Camera sensitivity calibration (12.4) | N/A (optional) | default `0.0025` rad/px (= 0.143 deg/px) is not Valve's 0.022 deg/px; the recommendation is optional and the established feel is kept; no change |
| 20 | Display and aspect ratios (12.5) | PASS (menus) | rendered at 1280x800, 1920x1200, 2560x1080: no clipping (`tests/deck_shots` run at those sizes); in-run HUD at ultrawide not rendered: UNVERIFIED |
| 21 | Graphics API (12.6) | UNVERIFIED | Windows uses D3D12 (Proton via vkd3d-proton), Linux native is Vulkan (booted on llvmpipe only); Vulkan-on-Windows is an owner/native decision (RED-7) |
| 22 | Codecs (12.7) | PASS | the game plays no video; audio is OGG/WAV/MP3 decoded by Godot on every platform; the unreferenced MP4 is excluded from Android/Linux |
| 23 | Graphics settings (12.8) | PASS | Quality / Balanced / Cool-Battery with "(Recommended)" per device, never locked, stored in settings.json, no gameplay or physics change. (No literal "Automatic" entry: the recommended level is the automatic default.) |
| 24 | Offline play (12.9) | PARTIAL | single-player has no network dependency; OTA check fails soft and never blocks (docs/OTA.md); not exercised on a fresh Steam account: UNVERIFIED |
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
| Q-6 | Hosted manual workflow (inputs platform/source_sha/build_number/destination), manifests + checksums on the Release, Linux asset | design only here | P1 | YELLOW | L | **Open**: `ci.yml` is validated by `tests/test_ota_workflows.py` and a release path change deserves the owner's eye; proposal in "Proposals" |
| Q-7 | Linux CI template install + verify step | needs a hosted run to prove | P2 | YELLOW | S | Open (bundle with Q-6) |
| Q-8 | Documentation set (PLATFORM_SUPPORT, THIRD_PARTY_ASSETS; UPDATES and STEAM_HARDWARE_CHECKLIST map to existing pages) | this commit | P2 | GREEN | S | **Done** |
| Q-9 | Steam Cloud design: exclude `settings.json` graphics keys from sync; sync `saves/` + codex only | design note below | P2 | BLOCKED | M | Pending App ID |
| Q-10 | Test simultaneous mouse + stick camera accumulation | brute/mage `_unhandled_input` + stick path read by inspection only | P2 | YELLOW | M | Open |
| Q-11 | Render in-run HUD at 21:9 | tool exists for menus only | P3 | GREEN | S | Open |

### RED (documented, not done)

- **RED-1** Fast-forward `main` to this line (PR #1): protected default branch.
- **RED-2** Artifact/release naming: standard `Purgatory Dungeon Build NN ...` against the owner's `Purgatory Dungeon v<N>` convention (CLAUDE.md, docs/RELEASES.md, tests). Tool supports both; the owner picks.
- **RED-3** Tracked Linux export preset: changes `export_presets.cfg` and therefore the native fingerprint (a new APK generation). The scratch-preset approach avoids it.
- **RED-4** Windows preset trims (~300 MB of unused skyboxes/video/texture, as the Android preset already does): `export_presets.cfg` change, fingerprint bump, next APK generation.
- **RED-5** Save-system hardening: add `schema_version`, keep a `.bak` of the last good profile and fall back to it on a parse failure. Touches `save_manager.gd` / `storage_paths.gd` (guarded files, the save format): needs a migration plan and the owner's approval; test with real saves first.
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
