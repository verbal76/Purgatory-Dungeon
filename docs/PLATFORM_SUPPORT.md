# Platform support: Android, Windows, native Linux (one game, three targets)

One authoritative source line and one build number produce every target (`docs/SOURCE_OF_TRUTH.md`). This page states, per target, what is built, how, what was
actually run, and what was not. "Compiled" is never written as "tested". Status as of 2026-10-12, source line `ccr-5f32885a-gvu16v`.

| | Android | Windows | Linux (native) |
|---|---|---|---|
| Artifact | `Purgatory Dungeon Build NN APK.apk` (arm64, API 30-36, signed with the persistent key) | `Purgatory Dungeon Build NN EXE.zip` | `Purgatory Dungeon Build NN Linux.tar.gz` (executable bit set) (v1-v8: `Purgatory-Dungeon-v<N>...`) |
| Export preset | `Android` in `export_presets.cfg` | `Windows Desktop` in `export_presets.cfg` | **none tracked**: `tools/build.py` appends a `Linux` preset to a scratch copy (a tracked preset would change the native fingerprint; `docs/COMPLIANCE_AUDIT.md` RED-3) |
| Built by | the manual `ci.yml` workflow, job `android` (`tools/android/build_apk.sh`, existing key only) | the manual `ci.yml` workflow, job `windows`, or `python3 tools/build.py --platform windows` | the manual `ci.yml` workflow, job `linux`, or `python3 tools/build.py --platform linux` |
| Engine templates | Android (installed in CI) | Windows (installed in CI) | official 4.6-stable `linux_release.x86_64` (not installed in CI yet) |
| Renderer | Mobile / Vulkan, 0.75 render scale, 1280x720 expand | Forward+ with D3D12 (`rendering_device/driver.windows`) | Forward+ / Vulkan (Godot's Linux default) |
| Input | touch (`scripts/touch/`), Android back button handled | keyboard + mouse, gamepad | keyboard + mouse, gamepad |
| Updates | OTA from the v7-generation APK (`docs/OTA.md`) | none (new package) | none (new package) |
| Saves | app storage (`scripts/storage_paths.gd`) | `Documents/PurgetoryDungeon/` | `Documents/PurgetoryDungeon/` (same code path) |

## What has actually been run

| Target | Evidence | Not done |
|---|---|---|
| Android | v6, v7, v8 APKs built by CI and qualified (signature, identity, API target, 16 KB alignment); OTA v8.1-v8.5 delivered; the owner has played on phones (his findings drove the v7.x / v8.x work) | automated device farm; current `main` line not rebuilt since v8 |
| Windows | CI package verification (`tools/verify_package.py`: layout, PCK content, boots headless to the main menu); Windows zips were delivered as releases v1-v8 (owner playtesting on Windows is not recorded in the repository) | not run on a Steam Deck / Proton; D3D12 under vkd3d-proton unproven |
| Linux | 2026-10-12: `tools/build.py --platform linux` exported the exact commit, packaged it (131 MB), `verify_package.py` passed, and the extracted `PurgatoryDungeon.x86_64` started under Xvfb with software Vulkan (llvmpipe, `--rendering-method mobile`, as the repository render probes do), ran the splash and reached the main menu with no script error. | no GPU, no audio device, no gamepad, no Steam Deck, no play-through: **UNVERIFIED on real hardware**. Also launched inside an empty network namespace (offline, fresh save root): reached the main menu. |

## Defects found while building the Linux package

- The Codex lore was a `.txt` that Godot does not export, so every packaged build (Windows, Linux and, by the same preset rules, the APK) had an empty Codex.
  Fixed: `data/codex_lore.json`, and `verify_package.py` now refuses a package without its runtime data files.
- The Windows package shipped ~300 MB of unreferenced skyboxes, a video and a texture (470 MB zip against 131 MB for Linux). Fixed in pass 4 with `.gdignore` (no preset change).

## Cross-platform rules (unchanged)

Platform differences live only in the gated places listed in `docs/SOURCE_OF_TRUTH.md` section 1. Prompts, glyphs, graphics level and Steam Deck detection are
shared by Windows and Linux; the Linux build adds no platform code.

## Building locally

```
python3 tools/build.py --platform all --godot <godot-4.6-binary> [--out DIR] [--naming repo|standard]
```

Builds the exact commit (default `HEAD`; uncommitted edits are not included), verifies each package, writes `build-manifest.json` and `checksums.sha256`, and exits 1
unless every requested platform was built (Android is BLOCKED locally: it needs the SDK and the signing key that live outside the repository). Nothing is uploaded or
released. Publishing a GitHub Release, an OTA, Steam or Play remains an owner-authorised step (`docs/RELEASES.md`).
