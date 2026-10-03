# Purgatory Dungeon — Recovery Baseline

Initial source: `dc2ae6c` (3-commit history, April 2026). Evidence classes used below:
**RUNTIME** = observed running in Godot 4.6 (headless, Linux), **SOURCE** = read in code only,
**UNKNOWN** = not provable in this environment (no GPU/display, no Windows host).

## What was and was not exercised
Headless Godot 4.6.stable on Linux (dummy renderer). Exercised: project import, parse/load of all
scripts and scenes, booting the real game scene for both classes, dungeon generation (8 seeds),
enemy spawning, a kill with credit, menu-scene startup, the save system, a Windows export, and the
exported PCK booting the main menu and the dungeon. **Not exercised:** anything needing rendering or
input devices (visuals, camera framing/clipping, animation quality, audio output, HUD layout,
mouse/controller feel, GPU performance) and the Windows `.exe` itself (no Windows host/Wine here).

## Tech stack (verified)
Godot 4.6 stable (`4.6.stable.official.89cea1439`), Forward Plus, Jolt Physics (30 ticks/s), D3D12
driver preference on Windows, 100% GDScript, addons are art/audio packs only (no code plugins).
Kept on 4.6: no concrete reason to migrate.

## System status
| System | Status | Evidence |
|---|---|---|
| Project parse/load (59 scripts, 45 scenes) | WORKING | RUNTIME `tests/validate_project` (was 1 broken scene) |
| Boot + main menu + all menu scenes start | WORKING | RUNTIME `test_menu_scenes`, exported PCK boot |
| Save/profile (10 slots) | WORKING (defects fixed) | RUNTIME `test_save_manager`, 51 checks |
| Settings persistence | WORKING | RUNTIME settings round trip |
| Dungeon generation | WORKING WITH DEFECTS | RUNTIME 8 seeds: 110/110 rooms, connected, deterministic; see defects |
| Player spawn (Barbarian, Mage) | WORKING | RUNTIME one player, inside bounds, on floor |
| Enemy manager/spawning/pooling | WORKING | RUNTIME 2–12 live enemies, top-ups. Spawning is proximity-based (ring around the player), so a stationary player can see none for a while; this is design, not a fault |
| Melee/kill credit/damage | WORKING | RUNTIME credit once, no double credit, cull not credited |
| Enemy Mage fireballs | WORKING (fixed) | RUNTIME regression test (dealt 0 damage before) |
| Exploration/minimap reveal | WORKING (fixed) | RUNTIME 0 modules explored before fix |
| Perks/buffs, Alchemist, Day clock/Day 30, portal | SOURCE only | code present and reachable; not driven end-to-end |
| Legendary Mode | PARTIAL | state leak fixed; no reinforcement logic (SOURCE) |
| Codex | PARTIAL | lore unlock text only, no bestiary (SOURCE) |
| Inventory/equipment | STUB | only wallet (potions, keys) (SOURCE) |
| Quests, morality, redemption, damnation | NOT IMPLEMENTED | no code (SOURCE grep) |
| Room locks | PARTIAL | combat lock with timeout; no key/colour logic (SOURCE) |
| Mage player class | WORKING (boot), UNKNOWN (play feel) | RUNTIME boot; uses Brute model as stand-in |
| Controller, keyboard/mouse feel, HUD, audio, visuals | UNKNOWN | needs a display |
| Windows export | WORKING | RUNTIME export produced; PCK boots; EXE not executed |

## Historical defects revalidated
| Concern | Result |
|---|---|
| Enemy bodies falling through floors | Not reproduced (RUNTIME, enemies stay above y=-1) |
| Orbs outside walls | Code risk: orbs use random points inside module boxes (SOURCE); not verified |
| Gaps between modules | UNKNOWN visually; doorways connect (RUNTIME connectivity) |
| Kill tracking | Works (RUNTIME) |
| Camera/body clipping, first-person framing, Mixamo animation | UNKNOWN (needs rendering) |
| Enemy collision | All bodies share layer/mask 1; "static only" ray masks also hit enemies/props (SOURCE) |
| Stun integration | UNKNOWN |
| Minimap/player-marker | Root cause found+fixed: new Player was auto-renamed so `get_node("Player")` failed (RUNTIME) |
| Profile corruption / blank profiles | Broken files are detected and never deleted (RUNTIME); writes now atomic |
| Slot overwrite | Identity locked after first init; scans no longer touch slots (RUNTIME) |
| Class restoration | Fixed: slot scans rewrote `last_slot.json` so relaunch could load the wrong character (RUNTIME) |
| Duplicate starter-item awards | No within-path duplicate (SOURCE). Starter potion is granted by the character-select path only, not by quick-restart/Alchemist start — owner design question |

## Defects fixed in this baseline
Scene load failure (`torch.tscn` 3-arg `Color`); case-mismatched `res://` paths that break on
Linux/Android (`Globe.tscn`, `jumpscare.gd`); relative save path when no Documents dir; slot scans
overwriting `last_slot.json`/emitting signals; null deref on unreadable save; non-atomic writes;
Player renamed → traps/exploration/run-end lookups failed; pooled enemy fireballs dealt no damage
and swept-ray hits on the player were harmless; Legendary mode leaking into later runs; pressure
spawn firing at run start; dead brute landing in-flight swings; menus unclickable after leaving the
dungeon (mouse stayed captured); code-plug doorway plugs left the lower half of the door open.

## Remaining defects (by importance)
All entries are SOURCE-derived (read in code, not reproduced) unless marked RUNTIME.
**High**
- Pause → Options reloads the dungeon scene and loses the run (`pause_menu_function.gd:183`).
- Windows Documents-path saves only: Android scoped storage needs `user://` (see Android doc).
- Minimap action is bound to Escape, which is also pause (`project.godot`); likely intended Tab.

**Medium**
- Alchemist "start another run" skips run setup (class/difficulty/seed not set from profile).
- Orbs/props/portal placed from module AABBs, wrong for L/T rooms; CodePlug/connector positions
  can host orbs/portals (`health_orb_manager`, `portal_manager`, `prop_spawner`).
- Stale coroutines after enemy pooling can clobber a reborn enemy's state (`brute_ai`/`mage_ai`).
- Enemy mage allocates 6 fireballs under `current_scene` and never frees them.
- `BuffManager`/`EnemyManager`/`TrapManager` are always-process; keep running while paused.
- Per-credited-kill `save_profile()` disk writes (`PlayerWallet`).
- Every body is on collision layer 1; no layer names. Enemies/props block LOS and floor snaps.
- Ray `exclude = [self]` passes Nodes where RIDs are required (`brute_ai`, `mage_ai`).
- No `default_bus_layout.tres`: the Music/SFX buses do not exist, so those sliders map to Master.
- LOD comments claim 60/30/10 Hz; with 30 physics ticks the real rates are 30/15/5 Hz.

**Low**
- RUNTIME: engine error `!is_inside_tree()` transform read during scene teardown.
- RUNTIME: repeated generate/free cycles in one headless process can abort Godot (works in the real game's
  restart flow); tests therefore generate one seed per process.
- `GameClock.resume()` can emit `run_ended` repeatedly past the final day.
- Docs say "Hare's Delight" and 12 perks; code has 11. Default profile perk keys do not match
  Alchemist perk ids.
- Orphan: `player_guard_sword0.bin` (1.2 MB, no references), `archive/*`, `dungeon modules/2_segment_hall.tscn`.

## Procedural generation (RUNTIME, seeds 1,2,3,7,42,123,2024,98765)
Target 110 rooms reached on every seed, ~310–340 modules, 1.7–3.7 s to generate, no open doorways,
every module connected to the start (door-marker graph), no overlap between non-connector modules,
all enemy spawns inside module bounds, same seed reproduces the identical layout when generated
directly. In-game determinism is **not** guaranteed (RNG is consumed between `seed()` and
generation). 0–12 connector bounding boxes overlap neighbours (box approximation, unverified as
real geometry overlap). Code-plug fallback occurs on ~3/8 seeds (1–2 per dungeon).

## Performance (headless CPU only; no GPU data)
Boot to generated dungeon ≈ 6.6 s. Steady state (≈7–12 enemies, 13.8k nodes): process ≈ 1.6 ms,
physics ≈ 2.8 ms median (budget 33 ms at 30 Hz). Static memory ≈ 750 MB. Export: PCK 671 MB (art
is unoptimised: skyboxes 387 MB, characters 158 MB, audio/UI 99 MB). No draw-call/GPU/Android data.

## Build and CI
`PurgatoryDungeon.exe` (PE32+ x86-64, 104 MB) + `PurgatoryDungeon.pck`; produced by Godot 4.6
`--export-release "Windows Desktop"`. `.github/workflows/ci.yml` runs the tests and exports on
every push/PR and uploads `BUILD_INFO.txt` (source SHA, Godot version, SHA-256) with the files.
Artifact is ~775 MB uncompressed; mind repository artifact-storage quotas.

## Repository hygiene
`.git` ≈ 509 MB (binary assets, no LFS; history untouched). Removed: `claude.md.txt` (superseded
duplicate of `CLAUDE.md`). Kept deliberately: `player_guard_sword0.bin`, `archive/`,
`schizophrenia_audio.gd` at repo root (it is live; loaded by `BuffManager`).
Later: asset compression/import presets, Git LFS decision (needs history-rewrite analysis),
collision layer naming, bus layout.
