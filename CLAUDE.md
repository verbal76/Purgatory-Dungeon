# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Purgatory Dungeon** is a 3D dungeon-crawler roguelike built in **Godot 4.6** (Forward Plus, Jolt Physics). Language is 100% GDScript. Players choose Barbarian or Mage, run procedurally generated dungeons of ~110 rooms, pick daily buffs, and survive 30 in-game days (~30 min). Target: stable 60+ FPS on mid-range hardware.

## Release convention (mandatory — read before delivering any build)

The owner identifies builds only as **`Purgatory Dungeon v<N>`** (plain sequential integers; current
number in `./VERSION`). Deliver every playable build as a GitHub Release titled exactly
`Purgatory Dungeon v<N>`, marked Latest, with a file named `Purgatory-Dungeon-v<N>-Windows.zip`. Never use
codenames, SHAs, build counters or CI artifact links in anything the owner sees; keep those as
engineering metadata in the release notes. One number = one delivered binary; never reuse or overwrite.
Full procedure, tooling and history: **docs/RELEASES.md** (`tools/release_tool.py`, tag `vN` triggers CI publishing).

## Studio splash (Hot Attic Games standing requirement — do not remove)

Every Hot Attic Games application opens with the studio splash before its own title screen:
cold launch -> **Hot Attic Games splash** -> product title/menu -> normal game. The artwork is the
owner-supplied canonical file **`Hot_Attic_Games_Master_Logo_ALPHA_FINAL.png`** (look for exactly
that name; the older `branding/Hot_Attic_Games_Master_Logo.png` path is obsolete). Never redraw,
recreate, crop, stretch or substitute it, and do not wait for a differently named asset.
Implementation: `scenes/StudioSplash.tscn` + `scripts/studio_splash.gd` (`StudioSplash`) is the
project's main scene; it finds the file by name at the repo root, `branding/`, `assets/` or
`Music & background images/`, fits the whole image with its aspect ratio and transparency, shows it
about 2.4 s (fade in/hold/fade out) while the main menu loads behind it, plays only on cold launch,
and can never strand the player (missing logo skips it; failsafe timer). `tests/test_studio_splash.gd`
covers it; release builds set `REQUIRE_STUDIO_LOGO=1`, so a release without the logo fails CI.

## Human testing gate (Hot Attic Games rule — applies before asking the owner to test)

Do not send the owner a build to test while confirmed, reproducible, repairable engineering defects
remain that can be fixed without human judgment. A build that exists, launches, or passes CI/headless
tests is not by itself an owner-testing gate. The owner tests subjective questions (feel, visuals,
audio, real-hardware performance, fun); never ask him to rediscover defects already known.
Until those defects are repaired the project state is "engineering work remains", not "waiting on
owner testing" — unless the owner explicitly says to test anyway. Earlier builds stay as rollback
checkpoints; repairing defects never invalidates them.

## How to Run

- Open `project.godot` in Godot 4.6+.
- Headless tests: `tests/run_tests.sh <godot-binary>` (see README). CI: `.github/workflows/ci.yml`.
- Windows export: `godot --headless --export-release "Windows Desktop" build/windows/PurgatoryDungeon.exe`.
- Entry point: `MainMenu.tscn` → `CharacterSelection.tscn` → `Purgatory_Dungeon_main_game_file.tscn`
- Settings persist to `<Documents>/PurgetoryDungeon/settings.json` (path logic in `scripts/storage_paths.gd`); save slots persist alongside it. Keep the misspelled folder name (compatibility).

## How to Work With Claude

- Discuss findings first. Present what you found and your proposed approach, then wait for explicit approval before editing or creating any file.
- Always show clear before/after diffs. Suggest small, testable changes — never large rewrites in one step.
- Explore the full relevant structure first to identify the actual bottleneck or bug location before proposing anything.
- Profile with Godot's built-in Profiler (Script Functions, _process, _physics_process, draw calls, physics ticks) before and after every performance change. Report the measured delta, not just the code change.

## Architecture

### Autoloads (Global Singletons)

| Autoload | Purpose |
|---|---|
| `GlobalRunData` | Current run metadata (class, day, stats) |
| `SaveManager` | 10-slot character persistence; identity (name/class) is locked once created |
| `AudioManager` | Music/SFX streaming; 8-slot SFX pool to avoid runtime node creation |
| `GameClock` | 1 real-minute = 1 in-game day; emits `day_changed`, `buff_pick_triggered`, `run_ended` |
| `BuffManager` | Buff card UI, tracks active buffs; pauses GameClock while picking |
| `GlobeManager` | Mystery sphere pickup effects (defined in `data/globe_effects.json`) |
| `PlayerWallet` | Currency HUD; used by `AlchemistStore` mid-run |
| `SettingsManager` | Audio/video/gameplay preferences |
| `CodexManager` | Lore/bestiary data from `data/codex_lore.txt` |

### Main Game Scene

`scripts/Purgatory_Dungeon_main_game_file.gd` boots the level:
1. Spawns player (Barbarian or Mage from `GlobalRunData`)
2. Runs `DungeonGenerationFunction` — places ~110 rooms (`target_piece_count` in the main scene; ~310-340 modules including connectors/end caps), registers typed spawn points (`brute`/`mage`/`buffed`), builds waypoint graph
3. Instantiates `EnemyManager` (proximity spawner using typed spawn data + waypoints)
4. Instantiates `HealthOrbManager`, `TrapManager`
5. Starts `GameClock`

Exploration tracking is throttled to 0.5 s intervals (not every frame).

### Character System

- `characters/brute/scripts/character_base.gd` — Abstract base for all characters. Handles health, buffs, animation blending with LOD, stun, physics. Caches animation map once (not per frame). Maintains a **static player LOD cache** shared across all enemy instances to avoid per-enemy tree scans.
- `characters/brute/scripts/brute_player.gd` — Barbarian: 1st-person with head-bob, swing/rapid_attack/kick/AOE/block
- `characters/Lutsch Mage/scripts/mage_player.gd` — Mage: projectile firing, area spells
- `*_ai.gd` variants implement enemy AI with **LOD tick intervals** (nominally 60/30/10 Hz; physics runs at 30 ticks/s so effective rates are 30/15/5 Hz): <12 m, 12–25 m, >25 m

### Procedural Generation

`scripts/dungeon_generation_function.gd` places modules from `dungeon modules/` (20+ `.tscn` templates), registers typed spawn points, and builds the waypoint graph used by enemy pathfinding. Module exploration state is tracked per room.

### Data Files

- `data/buffs.json` — 54 buffs with `effect_type`, `stat`, `tradeoff` fields; extensible. Percent-style stats (`BuffManager.PERCENT_OF_BASE_STATS`) are fractions of the player's base value; the pick pool only offers buffs whose stats exist on the current player (`tests/test_buffs.gd` enforces both)
- `data/globe_effects.json` — Mystery sphere pickup effects
- `data/codex_lore.txt` — Bestiary/lore entries

### Key Manager Scripts

| Script | Role |
|---|---|
| `scripts/enemy_manager.gd` | Proximity spawner; type-3 (buffed) enemies get +25% HP |
| `scripts/health_orb_manager.gd` | Spawns 10 orbs in safe rooms; 60 s respawn timer |
| `scripts/trap_manager.gd` | 25 traps/run (reversed controls, acid pools, jumpscare, etc.) |
| `scripts/minimap_function.gd` | Real-time 2D map from module positions/bounds |
| `scripts/save_manager.gd` | Identity-locked slots; persists run count, perks, potions, unlocks |
| `scripts/AlchemistStore.gd` | Mid-run potion shop using `PlayerWallet` |

## Performance Rules

Target: stable 60+ FPS on mid-range hardware. These rules are non-negotiable on any code that touches hot paths.

### Profiling (required, not optional)

Always open Godot's built-in Profiler and capture before/after for every change. Key columns to watch:
- **Script Functions** — total GDScript CPU time
- **_process / _physics_process** — per-script frame contribution
- **Draw Calls / Objects Drawn** — GPU submission cost
- **Physics 3D** — Jolt tick cost (configured at 30 ticks/s)

Never claim a change improves performance without a measured delta.

### Hot-Path Rules

- Use `_physics_process()` for all movement, AI decisions, and physics interactions. Keep `_process()` for UI/HUD only, and throttle even that where possible (see existing 0.5 s exploration throttle).
- **No per-frame allocations in hot loops.** Never create new nodes, arrays, dictionaries, or strings inside `_process()`, `_physics_process()`, or any function called from them. Pre-allocate at `_ready()`.
- Use typed GDScript variables (`var foo: float`) and `@onready` aggressively in any script that runs every frame. Untyped variables incur runtime type checks.
- Centralize update logic in managers (`EnemyManager`, `HealthOrbManager`, etc.) rather than giving every instance its own `_process()`. One manager loop over N enemies is faster than N independent `_process()` calls due to GDScript dispatch overhead.

### Object Pooling (heavy priority)

Pool everything that spawns and despawns repeatedly:
- **Enemies** — pre-instantiate a pool at run start; activate/deactivate rather than `queue_free()`/`instantiate()`
- **Projectiles** (Mage spells, fireball traps) — single pool per projectile type
- **Health orbs** — already respawn on timer; ensure the nodes are reused, not re-created
- **Particles/VFX** — use a shared GPUParticles3D pool with `restart()` rather than instancing

### Rendering

- Use `VisibilityNotifier3D` to pause AI and animation on off-screen enemies.
- Keep draw calls low: merge static dungeon geometry where possible, use MultiMeshInstance3D for repeated props.
- Occlusion culling is already enabled — do not add transparent materials that break the occluder.

### Existing Optimizations (do not regress)

| Optimization | Location | Rule |
|---|---|---|
| Exploration throttle (0.5 s) | `main_game_file.gd` | Never move `update_player_exploration()` back to every frame |
| Animation map cache | `character_base.gd` | Cache computed once per instance; never recompute in a loop |
| Static player LOD cache | `character_base.gd` | All enemies share one reference; never add per-enemy `get_tree()` calls |
| AI LOD tick rates | `*_ai.gd` | <12 m = 60 Hz, 12–25 m = 30 Hz, >25 m = 10 Hz — do not flatten to a single rate |
| SFX pool (8 slots) | `AudioManager` | Never create `AudioStreamPlayer` nodes at runtime |
| Proximity spawning | `enemy_manager.gd` | Never spawn all enemies at level load |
