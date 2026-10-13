# Purgatory Dungeon

First-person procedural dungeon-crawler roguelike (Barbarian or Mage) built in **Godot 4.6**
(Forward Plus, Jolt Physics, 100% GDScript). Survive 30 in-game days (~30 min) in a generated
dungeon, pick daily buffs, and reach the portal. Windows PC is the authoritative platform;
an Android landscape port is planned (see `docs/ANDROID_PORT_ASSESSMENT.md`).

## Run
1. Install **Godot 4.6** (stable).
2. Open `project.godot` (first import takes a few minutes: ~700 MB of art assets).
3. Run. Flow: `MainMenu` → `CharacterSelection` / `ProfileScreen` → dungeon.

## Test
```bash
tests/run_tests.sh /path/to/Godot_v4.6-stable_linux.x86_64   # or: GODOT=... tests/run_tests.sh
```
Headless; runs a static `res://` path/case check, the project parse/load validator, and
regression/characterization tests for saves, pause/Options, enemy pooling, clock/buffs, run
lifecycle, audio buses, pause freeze, physics queries, settings remap, placement (portal, orbs,
props, globes), a gameplay smoke test (boots the real game for both classes) and multi-seed
dungeon validation. Saves are redirected to a scratch dir via `PURGATORY_SAVE_ROOT`, never your real saves.
`tests/perf_probe.tscn` prints a headless performance snapshot (informational).

## Build (Windows)
`godot --headless --path . --export-release "Windows Desktop" build/windows/PurgatoryDungeon.exe`
(needs the 4.6 export templates). Output is `PurgatoryDungeon.exe` + `PurgatoryDungeon.pck`
(keep them together). CI does this on every push (`.github/workflows/ci.yml`) and uploads the
result, with `BUILD_INFO.txt` (source SHA, Godot version, SHA-256), as a workflow artifact.

## Saves and settings
`<Documents>/PurgetoryDungeon/` — `saves/profile_<0-9>.save` (JSON), `settings.json`,
`last_slot.json`, `codex.json`. The misspelled folder name is an established compatibility
path; do not rename it without a migration. If the OS has no Documents folder the game falls
back to Godot's user-data dir. See `scripts/storage_paths.gd`.

## Releases
Play builds come only from the GitHub **Releases** page: the one marked **Latest** is the newest
(`Purgatory Dungeon v<N>`, file `Purgatory-Dungeon-v<N>-Windows.zip`). See `docs/RELEASES.md`.

## More
- `docs/BASELINE.md` — verified state of every system, defects fixed and remaining.
- `docs/ANDROID_PORT_ASSESSMENT.md` — what the later Android landscape port needs.
- `CLAUDE.md` — engineering rules for AI-assisted work in this repo.
