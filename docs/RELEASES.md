# Releases, build numbers and the build workflow

**Product:** Purgatory Dungeon  **Public name format (from the first build after v8):** `Purgatory Dungeon Build NN` (NN = 9, 10, 11, ...)
Releases v1-v8 keep their names, tags, assets and notes exactly as published (see History); nothing here renames, moves or rewrites them.

The owner must never have to decode a branch name, SHA, codename or CI run to know which file to play. The answer is always the GitHub **Releases** page: the release
marked **Latest** is the newest playable build. Building and publishing are separate operations; nothing is ever published by a push, a pull request, a merge, a tag
or a test run.

## The rule
- One **build number** per coordinated build, one monotonically increasing sequence for the whole product. It continues the release series: v1-v8 are builds 1-8, so the next
  number is **9**. A number is consumed by a tag `build-NN`, a tag `v<N>` or a release titled `Purgatory Dungeon Build NN`; it is never reused and must be above every consumed
  number (`tools/build_gate.py number`). OTA ids (`#000007`, `v8.5`) are a different counter and consume no build number.
- A build number identifies exactly one source commit (full 40-character SHA) and one set of artifacts. All platforms of a build come from that one commit.
- The build number is **independent of the native version** in `./VERSION`, which still says 8 and changes only with a native release (it is inside `project.godot` and
  `export_presets.cfg`, the native runtime fingerprint: `docs/OTA.md`). The APK's `versionCode` / `versionName` therefore stay 8 until the owner authorises the next native
  generation; the build number lives in the file names, `build-manifest.json`, `build_info.json` inside every package, and the release. The in-game footer is unchanged by this.
- Failed or developer-only runs that are not delivered do not consume a number.

## Names
- GitHub Release title: exactly `Purgatory Dungeon Build NN`; tag `build-NN` at the exact source commit.
- Release files (the standard set):
  - `Purgatory Dungeon Build NN APK.apk`
  - `Purgatory Dungeon Build NN EXE.zip` (Windows: extract everything into one folder, run `PurgatoryDungeon.exe`; the inner `.exe`/`.pck` names are fixed because Godot loads the `.pck` that shares the exe's name)
  - `Purgatory Dungeon Build NN Linux.tar.gz` (native Linux x86-64: Steam Deck, Steam Machine, desktops)
  - `build-manifest.json` (title, build number, source SHA, engine, configuration, timestamps, per platform status and facts such as package id, version code and signing
    certificate, per artifact SHA-256 and size) and `checksums.sha256`
  GitHub turns spaces in uploaded file names into dots; the workflow sets each asset's display label to the standard name.
- Inside each package the single top folder is `Purgatory-Dungeon-Build-NN/` with the game, `VERSION.txt` and `BUILD_INFO.txt`.
- Release notes start with the file names and install steps; technical provenance (source commit, run, hashes) follows under "Technical details".
- Never give the owner a CI artifact link; artifacts expire after 7 days and are only for the pipeline. A release is the delivery.
- (`tools/build.py --naming repo` still produces the v1-v8 names, `Purgatory-Dungeon-v<N>-Windows.zip`, to reproduce an old package.)

## The one build workflow (`.github/workflows/ci.yml`, "Build (manual)")
Trigger: **`workflow_dispatch` only**, with the inputs `platform` (android | windows | linux | all), `source_sha` (exact 40-hex commit), `build_number` and
`destination` (`local_only` default | `github_releases`). Run it from the Actions tab (or the API) by choosing the branch that holds the workflow.

| Job | What it does |
|---|---|
| `gate` | validates the inputs; checks out the source commit; proves (with the TRUSTED tools and authority file of the workflow commit) that the commit is the checked-out one, is on the authoritative line (`docs/source_authority.json`; the interim line while `main` lags), descends from every release tag, and that the workflow commit itself is on that line; proves the build number is unused and above every consumed number |
| `validate` | the full headless suite on the exact source commit (`tests/run_tests.sh`), version and native-runtime checks; nothing is built or signed before it is green |
| `windows`, `linux` | `tools/build.py` exports the exact commit (git archive, never a working tree), packages it, verifies the package (layout, PCK content, headless boot) and writes its manifest and checksums |
| `android` | signs with the EXISTING app key only (`ANDROID_REQUIRE_EXISTING_KEY=1`: the job can neither generate a key nor create a release), builds, then `tools/verify_apk.py` checks package id, version code, signing certificate, runtime identity (`runtime_id` / `runtime_fingerprint`), 16 KB alignment, content and the build number |
| `assemble` | merges the platform parts into one set and rejects an incomplete, mixed-commit, mixed-number, altered or unlisted set (`tools/build_gate.py assemble`); uploads the verified set as a private artifact of the run |
| `publish` | runs **only** for `destination=github_releases` with `platform=all`, and is the only job with a write token for releases. It first re-validates the source authority and the build number, reads the triggering actor's repository role from GitHub (admin or maintain only, never from an input), re-verifies every checksum and that the set is byte-identical to the one `assemble` produced, then creates the tag and the release |

`local_only` never tags, releases, uploads or publishes anything: the artifacts stay private to the Actions run (7-day retention). A coordinated public release needs all three
platforms. Two dispatches for one number never run at once; a started build is never cancelled. Validation of pushes and pull requests is a different workflow, `tests.yml`
(tests only, read-only token, drafts never run); an OTA is published only by `ota-publish.yml` (docs/OTA.md), a separate, owner-authorised mechanism that a push to an
`ota/<channel>/<sha>` branch starts and that never creates a build or a `Purgatory Dungeon Build NN` release.

The replaced mechanism: until build 9 a push of tag `v<N>` (or branch `release/v<N>`) built and published `Purgatory Dungeon v<N>`, and a `promote/**` branch published an earlier
run's artifact. Both are gone from the workflow (they published as a side effect of a push); `tools/publish_release.sh` remains only as the record of how v1-v8 were made.
Existing `release/v*` and `promote/*` branches are inert history.

## Local builds (no GitHub)
```
python3 tools/build.py --platform windows|linux|android|all --build-number NN --godot <godot-4.6> [--source-sha SHA] [--out DIR]
```
builds the exact commit, verifies each package, writes the manifest and checksums, and never publishes. Android is BLOCKED locally (SDK and signing key). `tools/preflight.sh`
is the Godot-free gate before a push.

## Delivering a numbered build (owner)
1. Merge or choose the validated source commit on the authoritative line; run `tools/preflight.sh` and `tests/run_tests.sh` locally.
2. Dispatch `Build (manual)` with `platform=all`, that SHA, the next number and `destination=local_only`; download the verified artifact set from the run and test it.
3. Dispatch again with `destination=github_releases` (same SHA and number: the number gate passes while no tag or release carries it, and a failed publish leaves none behind) to publish.
4. Tell the owner: "Purgatory Dungeon Build NN" and the file names. Nothing else.

## CI cost (GitHub Actions budget policy)
`tests.yml` runs the tests on ready-for-review PRs and pushes to main; `ci.yml` builds and (only on request) publishes, by manual dispatch only. Drafts and docs-only PRs
cost nothing; a newer commit cancels the superseded PR run. (The tables below are the measurements of the earlier combined `ci.yml`; the suite job is now `validate`.) All OTA safety gates are unchanged; how they are satisfied is optimised (docs/OTA.md 11a). See CLAUDE.md.

GitHub bills per job, rounded UP to the minute (Linux 1x). Numbers below come from the public job/step timings of the real runs.

### Before (measured)
| Run | Job | Real min | Billed | Where the time went |
|---|---|---|---|---|
| OTA publish 37463060653 (v7.1) | prepare | 0.55 | 1 | checkout 14 s, baseline APK 12 s |
| | tests (`ota-tests.yml`) | 16.95 | 17 | checkout 19 s, Godot 13 s, **suite 975 s** |
| | publish | 4.52 | 5 | checkout 11 s, Godot 10 s, APK again 9 s, **payload 172 s**, release 5 s, re-download + inspect 32 s |
| | **total** | | **23** | |
| OTA publish 37524010841 (v7.2) | prepare | 0.45 | 1 | |
| | tests | 18.35 | 19 | checkout **234 s** (outlier), Godot 19 s, **suite 840 s** |
| | publish | 11.05 | 12 | checkout **374 s** (outlier), Godot 22 s, payload 178 s, re-download + inspect 53 s |
| | **total** | | **32** | |
| CI on a PR, before the budget policy (37461192035) | validate-and-export / android | 15.43 / 8.57 | 16 / 9 | suite 861 s; android repeated a 358 s subset of that suite + APK 123 s |
| CI release run (37411761371) | validate / android / publish | 16.82 / 8.5 / 1.68 | 17 / 9 / 2 = 28 | suite 932 s; android subset 353 s + build 125 s |

What the numbers say: (1) the suite job is 17 of 23 (74 percent) and 19 of 32 (59 percent) billed minutes of an OTA, and the observed flow ran it **twice for one
commit** (PR CI, then the OTA publication of the same SHA: ~33 billed minutes); (2) checkouts are normally 10-20 s, so the 234 s / 374 s of v7.2 are GitHub-side
variance, not something to engineer around; (3) the payload build (two Godot imports + export) is 3 min and inherent; (4) the anonymous
re-download + inspect (32-53 s) is a safety gate, not waste; (5) everything else is below 25 s per step. Godot start-up is not the cost
(a small stage takes ~1 s locally; a fresh-clone `--import` is the large fixed part of the suite, measured 365 s on this heavily loaded
4-core box, so only an order of magnitude); the suite is 74 Godot stages run one after another on a runner with 4 vCPUs. `tests/run_tests.sh`
now prints the real per-stage times at the end of every run (and `--import`, and the Python stage), so the next run answers what dominates.

### After (design, estimated)
| Situation | Before (billed) | After (billed) | Change |
|---|---|---|---|
| OTA publish, a verified green suite exists for the SHA (CI push / attested PR run / earlier publish attempt) | 23 typical, 32 v7.2 | prepare 1 + publish 5 = **6** typical (13 with v7.2's checkouts) | -74 % (-59 %) |
| OTA publish, nothing reusable | 23 | 23 (05b adds a few seconds) | 0 |
| One commit: PR CI, then OTA of the same SHA | ~16 + 23 = 39 | ~16 + 6 = **22** | -44 % |
| Release (tag / `release/v<N>`) | 17 + 9 + 2 = 28 | 17 + ~4 + 2 = **~23** (android no longer repeats the subset; it now waits for the suite, so release wall time grows by ~15 min) | -18 % |
| Release with a red suite | 17 + 9 (APK built anyway) | 17 (android is skipped) | -35 % |
| Any suite run, `CI_TEST_JOBS=3` (opt-in, unmeasured on CI) | ~14-16 min of suite | est. 6-9 | est. -6..-8 per run |
The wall time of a reused OTA publication is ~6 minutes instead of 23-32.

### What changed (all gates kept; see the invariant table in docs/OTA.md 11a)
- **Suite reuse** (`ota-publish.yml` step 05b, `tools/ota/proven_suite.py`): a GitHub-API-verified green run of the same suite on exactly that SHA
  replaces step 06; any doubt runs the suite. Needs the "Exact-SHA attestation" step that `ci.yml` and `ota-tests.yml` now end with.
- **Baseline APK integrity between jobs**: the publish job's second download must be byte-identical (sha256) to the one the prepare job validated.
- **`ci.yml` android job** waits for the full suite and drops its duplicate subset (the same stages, runner, commit and engine).
- **Job timeouts** (suite, publish and `ci.yml` validate 45 min, android 30, ci publish/promote 20, prepare 15; before 60-120 or the 360 default), **receipt retention** 14 days.
- **`tests/run_tests.sh`**: timing summary; opt-in `TEST_JOBS=N` (`CI_TEST_JOBS` repository variable for `ci.yml`).
- Rule of thumb for a PR flow that is meant to feed an OTA: keep the PR head up to date with its base (merge/rebase the base into the head) before
  readying it, because only then is the tested merge tree the tree of the head SHA, and only then can the OTA reuse the PR's run.

### Not applied
| Candidate | Why not |
|---|---|
| Reuse a PR run without the exact-tree attestation | the PR run tested a synthetic merge commit; the API's `pull_requests[]` shows the *current* head/base, not the run-time ones (run 37461192035: `head_sha` 6dd77be, `pull_requests[0].head.sha` 479457b) |
| Replace the baseline-APK download + byte comparison by a stored hash record | the comparison is file by file against the APK's contents, a stored record is a new trust surface, and it costs 7-11 s |
| Publish `base.pck` / the import cache as a release asset, or cache the base import (saves ~1.5 min of the payload build) | new trust surface (a poisoned cache would shape the patch), 640 MB, and `actions/cache` entries of an `ota/**` ref are not readable by the next publication (cache scope) |
| Build the unsigned payload in parallel with the tests, or split `publish` into a read-only build job and a write job | wall time only; each extra job adds checkout + Godot install + 1-minute rounding, so billed minutes go **up** |
| Matrix sharding of the suite | same: per-shard checkout + import + Godot install, billed in full |
| `actions/cache` for the `godot/` import (642 MB) in `ci.yml` | would save maybe 1-2 min per PR run but is unmeasured on CI, restores/saves cost time, and entries are per PR ref; decide with the stage timings of the next run |
| Shallow `fetch-depth` in `prepare` / `publish` | not established: depth 0 took 11 s in one run and 374 s in another; the variance is GitHub's |
| A release run (tag / `release/v<N>`) reusing the PR's attested suite and running only the release-specific stages (`REQUIRE_STUDIO_LOGO=1`, `release_tool check --tag`) | would save ~16 billed minutes per release, but the release gate is the one place where re-running everything on the exact build commit is the conservative choice: owner decision |
| Path-based "tooling only" fast path (skip the Godot suite for `.github/**`, `tools/**`) | a tool or workflow change can alter what ships or how CI behaves; cannot be proven safe by paths alone |

### Owner decisions
1. **Enable `CI_TEST_JOBS`** (parallel stages in `ci.yml`; `ota-tests.yml` stays sequential until you decide) after the confirmation run below shows the
   suite is not flaky under concurrency. Locally 16 real stages (incl. `test_ota_core`, `test_run_lifecycle`, `test_release_metadata`) all passed with `TEST_JOBS=3`.
2. **Non-gating cadence for the long multi-seed stages: NOT applied, only a question.** The suite runs 8 dungeon-generation seeds, 6 stress seeds
   (20001-20006), 3 each of chests / room-lock / placement / torch / growth, 2 each of staging / light / visibility, all gating; the 1000-seed
   `tests/stress_generation.sh` already exists as the non-gating sweep. Moving e.g. 5 of the 8 generation seeds and 4 of the 6 stress seeds to a
   nightly job would trade a small chance of a seed-specific generator defect reaching an OTA for ~1-2 minutes per run. I cannot show that the
   remaining seeds cover the same defect classes without the per-stage timings and a coverage argument, so I did not change anything.
3. **PRs that feed OTAs**: keep them up to date with their base (above), or accept that such an OTA runs its own suite.
4. **Concurrency of publication stays global** (`ota-publish`): per-channel groups would need the channel in an expression, which GitHub cannot
   extract from `ota/<channel>/<sha>`. Note GitHub keeps one running and one pending run per group and drops older pending ones (nothing is published for a dropped run).

### Minimum real-CI confirmation plan (needs the owner's authorisation; one OTA, ~22 billed minutes in total)
Use the next real OTA candidate, so nothing is spent on a throwaway run. Do **not** use `workflow_dispatch` or throwaway channels (each publication creates public releases).
1. Merge the base into the candidate branch's head, open it ready for review (a draft runs nothing). Set the repository variable `CI_TEST_JOBS=3` for this one run.
   Expect ci.yml: `validate-and-export` ~8-10 min instead of ~16, ending with the two steps "Exact-tree check" and "Exact-SHA attestation" (success), and the stage-timing table in the log.
2. After it is green, push `ota/<channel>/<that exact sha>`. Expect in the run: `prepare` ~1 min with step 05b printing `reuse=1` and the source run URL; the `tests` job **skipped**;
   `publish` runs (~5 min) and ends with the usual receipt whose `suite` is `{mode: reused, run_url: <the PR run>}`, `published: true`, `anonymous_read_verified: true`.
   Total OTA wall time ~6 min.
3. What to check: (a) the API shape assumptions of `proven_suite.py` held (05b says `verified`); (b) all publish steps 03b..17 identical to before, step 03b passing the new sha256 comparison;
   (c) the receipt; (d) the timing table: the slowest stages and the import time decide the next saving; (e) the PR suite under `TEST_JOBS=3` was green with no new flaky stage.
4. The fallback path (no reusable run) is covered by unit tests and by every ordinary publication; if the owner wants it exercised on GitHub, push an `ota/` branch for a SHA that has no CI run
   (expect `reuse=0` with the reason, and the suite running as before).

## Package verification
`tools/verify_package.py` inspects the package itself (`--build-number NN` expects the standard names and folder; `.tar.gz` for Linux): the build tooling runs it on every package
(PCK contents, studio splash scene/script, canonical logo, generated `build_info.json` for the right
version, nothing from `tests/`/`archive/`/`docs/` exported, and a headless boot of the packaged PCK
through the splash to the main menu reporting `vN`), and `tools/publish_release.sh` runs it on the
final `Purgatory-Dungeon-vN-Windows.zip` (name, single `Purgatory-Dungeon-vN/` folder, exe, PCK,
`VERSION.txt`, release stamp) **before** the release is created. A failing package is never published.

## Studio splash requirement
Every release build must contain the canonical Hot Attic Games logo
`Hot_Attic_Games_Master_Logo_ALPHA_FINAL.png` (see `CLAUDE.md`, "Studio splash"). CI sets
`REQUIRE_STUDIO_LOGO=1` for tag and `release/v<N>` builds, so publishing fails if it is missing.

## History
| Version | Source commit | What it was | Notes |
|---|---|---|---|
| v1 | `073e34b9f2976f2336aedb6311bd2da33282eb17` | First recovered Windows build (CI run 37143051773), delivered for the owner's first Windows playtest | historical |
| v2 | `ef24eb4cf184dbc61f0d11f7d8b81aca2ab1a88c` | Stabilization round 2 build (CI run 37152299390) | Latest at the time this convention was adopted |
| v6 | `a9168e16ceac23b0dbb00d3f34f12ff3be070901` | Mage aim fix, typography, twin-stick controls; last native APK without the OTA-capable runtime | rollback baseline for v7; never modified |
| v7 | (the `release/v7` release commit; see its release notes) | First OTA-capable native APK: signed OTA client + runtime lock, `v7.K` versioning, separate right thumbstick removed (Attack-drag aims) | no OTA published with it; first OTA will be v7.1 |
| v8 | (the `release/v8` release commit; see its release notes) | Native generation `android-godot-4.6.0-r2`: Boot status API, Options > About (Check for updates, Copy diagnostics), no player-facing OTA overlay, main-menu Exit, gilded dungeon-door icon (Android + desktop), tap/hold/drag ATTACK gesture, Rapid Attack removed, floor-seam and enemy-model fixes | OTAs on it will be v8.1, v8.2 ... (none published yet) |

### OTAs on the v8 native generation (`android-godot-4.6.0-r2`)
| Owner-facing | OTA id | What it changed |
|---|---|---|
| v8.1 | `dev-000003` | Repulse replaces the backward Slide; the opening enemy drought is fixed; Repulse and floor-mesh stability fixes |
| v8.2 | `dev-000004` (assigned by the publisher from the live pointer) | Health balance ONLY: starting/max health Barbarian 150 -> 200, Mage 100 -> 135. No other gameplay change; follow-ups are in `docs/BACKLOG.md` |

| v8.3 | `dev-000005` (source `e6fd6ec`) | Twin-stick ATTACK drag looks through the Classic swipe path (aim smoothing removed), spawn facing, the automatic update hand-off at cold launch, redrawn Kick and Repulse icons, Repulse cooldown presentation |
| v8.4 | `dev-000006` | The game-feel ("juice") pass: sounds, camera, hit-stop, damage numbers, enemy bars, death camera, UI feel, Screen Shake and Vibration settings (`docs/GAME_FEEL.md`) |
| v8.5 | `dev-000007` (source `a9099a4`) | Your own footstep sound; enemies stand down when the player is dead; a win pays 20 potions and banks its kills; no fireball mines within 35 m of the start; prop placement avoids low geometry; the buff reel is unchanged |

### Held on the development line (NOT released; waits for the next APK)
Source: `ccr-5f32885a-gvu16v` (draft pull request #1). Steam Deck / Steam Machine readiness (`docs/STEAM_DECK.md`: controller glyph art, controller-only navigation, Graphics
Quality, Deck layout fixes, the Valve checklist), the one-history policy and release lineage gate (`docs/SOURCE_OF_TRUTH.md`, `docs/BRANCH_LEDGER.md`), and small polish found by
rendering at 1280x800. All of it is scripts, assets and docs (OTA-safe by `tools/ota/classify.py`); it is held because the owner asked for the Steam Deck work to wait for the
next APK. Not measured on a real Deck. Next native decisions: the Windows renderer (`d3d12` vs `vulkan`, `docs/STEAM_DECK.md`) and whether `main` is fast-forwarded to this line.

Why the sequence starts here: the repository had no GitHub Releases, no tags, and no APK/AAB/EXE
files when the convention was adopted (October 2026). The only playable builds ever delivered
from it are the two above, so v1 and v2 are the honest count. Earlier pre-GitHub builds
(including the project's old internal label "v2.5", now retired) are not in the repository and
could not be counted; if the owner wants the public number to continue from a higher figure,
set it once with `tools/release_tool.py set N` before the next delivery (numbers only go up).
The first CI build of 8eb36c3 was superseded within minutes and never delivered, so it has no number.

## Limits worth knowing
- No Android build exists yet, so there is no `versionCode`/package ID to record. When Android
  arrives it joins the same `vN` release; `versionCode` is recorded in the release's technical
  details only.
- Over-the-air updates (Android only, from the first v7-generation APK; see `docs/OTA.md` section 0). **A new whole-number
  version requires a real new APK**: v6 = the published APK, v7 = the next real OTA-capable APK (`Purgatory-Dungeon-v7.apk` must
  exist), v7.1 / v7.2 / ... = OTAs on the v7 APK (no new APK to install; shown as "Purgatory Dungeon v7.K"), v8 = the next
  actual APK. An OTA is **never** a new `vN`, never creates a GitHub Release titled `Purgatory Dungeon vN` and never changes
  Latest. Anything that cannot ship OTA (`tools/ota/classify.py`, `ota/boundary.json`) ships as the next numbered APK/zip exactly as
  described above. v1-v6 have no OTA client that can receive the v7 format. Handoffs state NATIVE APK VERSION, OWNER-FACING
  RUNNING VERSION, OTA UPDATE ID and NATIVE RUNTIME/FINGERPRINT separately.
- The game has no About screen; the version is on the main menu and in the startup log.
