# Releases and public version numbers

**Product:** Purgatory Dungeon  **Public name format:** `Purgatory Dungeon v<N>` (N = 1, 2, 3, ...)

The owner must never have to decode a branch name, SHA, build counter, codename or CI run to
know which file to play. The answer is always the GitHub **Releases** page: the release marked
**Latest** is the newest playable build.

## The rule
- Every playable build that is intentionally delivered to the owner (for testing or release)
  gets the next sequential number: v1, v2, v3, ... Plain integers. No semantic versions, no
  `b9` / `build-17` / `final` / `candidate` / `launch-g2` style names anywhere public.
- A number identifies exactly one delivered build. Never reuse a number; never replace a
  published release's binary with a different one. (Tooling refuses to overwrite.)
- Failed or developer-only CI builds that are not delivered do not consume a number.
- The public number is **not** the Godot engine version, the Git SHA, or (later) the Android
  `versionCode`. Those stay as engineering metadata.
- If Android and Windows builds are the same release they share the same `vN`
  (`Purgatory-Dungeon-vN-Windows.zip`, `Purgatory-Dungeon-vN.apk`; package, signing and 16 KB details: `docs/ANDROID.md`). Platform counters such as
  `versionCode` stay internal and may differ.

## Names
- GitHub Release title: exactly `Purgatory Dungeon v<N>`.
- Windows file: `Purgatory-Dungeon-v<N>-Windows.zip` (extract all files into one folder, keep
  `PurgatoryDungeon.exe` and `PurgatoryDungeon.pck` together; the inner `.exe`/`.pck` names are
  fixed because Godot loads the `.pck` that shares the exe's name).
- Release notes start with the file name and install steps; technical provenance (source
  commit, CI run, SHA-256s, engine) follows under "Technical details".
- **Never give the owner a CI artifact link.** CI artifacts (`PurgatoryDungeon-windows-<sha>`)
  are engineering-only and expire after 7 days. Deliver through a Release.

## How the version is stored (one source)
`./VERSION` holds the integer. `tools/release_tool.py set N` updates it together with
`project.godot` (`application/config/version`) and the Windows file/product version in
`export_presets.cfg`; `tools/release_tool.py check` (run by CI and `tests/run_tests.sh`)
verifies they agree and that this document and `CLAUDE.md` still describe the convention.
In the game, `BuildInfo` (`scripts/build_info.gd`) shows the version on the main menu and prints
diagnostics (version, source commit, CI run, build time, engine) at startup. CI writes
`build_info.json` into every build. A build is labelled plainly `Purgatory Dungeon vN` only when
CI built it from tag `vN` or from the branch `release/vN`; any other build says `development build after vN`.

## Delivering the next build (N = current VERSION + 1)
1. Finish and merge/test the work to be delivered; ensure `tests/run_tests.sh` is green.
2. `python3 tools/release_tool.py set N` and commit it (this commit is the release commit).
3. Push the tag: `git tag vN <release-commit> && git push origin vN`. Where tags cannot be pushed
   (the agent environment), push the branch `release/vN` at the release commit instead
   (`git push origin <release-commit>:refs/heads/release/vN`); CI treats it exactly like the tag.
4. CI (`.github/workflows/ci.yml`, job `publish`) tests and builds that exact commit, stamps the
   build as the release build (so the game shows plainly "Purgatory Dungeon vN"), and
   publishes the Release "Purgatory Dungeon vN" as **Latest**, with the zip attached. The version
   check refuses the run if `VERSION` is not N.
5. Tell the owner: "Purgatory Dungeon vN" and the exact file name. Nothing else.

To publish a build CI already made, without rebuilding it: create a helper branch
`promote/v<N>/<ci_run_id>/<full_40_char_sha>` (append `/notlatest` for a historical release) from a
commit that contains `.github/workflows/ci.yml` and push it; wait for the `promote` job; then delete
the helper branch. The job downloads that run's artifact and publishes exactly those bytes, so
no binary drift. (A branch push is used because `workflow_dispatch` only works for workflows on the
default branch, and the agent environment cannot push tags or download CI artifacts directly.)
That is how v1 and v2 were published; their release notes were then edited to add a plain-English summary.

## Package verification
`tools/verify_package.py` inspects the package itself: CI runs it on the exported build directory
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
