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

## Remaining defects as of the round-1 checkpoint 073e34b (superseded: see "Round 2" above)
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

## Round 2 (branch `purgatory-stabilization-round2`, from checkpoint 073e34b)
Every finding below was re-validated against the current source, reproduced where possible
(tests fail on the old code, pass on the new), then fixed. Tests live in `tests/` and run in CI.

**Fixed (each has a regression test unless noted)**
- Pause -> Options reloaded the dungeon and destroyed the run: Options is now an in-place overlay.
- Pooled enemies: died-while-idle came back frozen on the death pose; animation speed leaked;
  stale attack/kick/shove/spell/hit-react/death coroutines could touch a reborn enemy (lifetime
  token); brute frustration timer leaked; each freed enemy mage leaked its 6-fireball pool.
- `run_ended` fired repeatedly (3 emissions, clock ran to day 32, duplicate portals); Legendary
  entry restarted the day timer; queued chest picks survived a reset; timed buffs expired during
  the pause menu; the pause menu could open over a buff pick; `health_changed` never emitted for
  max-health buffs.
- Run start/exit consistency (`RunLifecycle`): Alchemist and quick-restart now load class,
  difficulty and name from the profile (a Mage started from the Alchemist ran as a Barbarian);
  globes reset on every exit; pause "Exit to main menu" stops the clock and buffs.
- Audio: Music and SFX buses added (`default_bus_layout.tres`); Master volume restored if the
  loading screen is interrupted (the game stayed muted).
- Rays assumed "static geometry only" but all bodies share layer 1: spawn floor snap, spawn
  visibility, brute line of sight and the Mage's damage gate are now blocked only by real
  level geometry (`PhysicsUtil.ray_world`).
- Pause freeze: enemy manager timers, in-flight top-up waves, the pressure-spawn clock and trap
  homing fireballs no longer run behind the pause menu.
- Placement: the Day-30 portal was chosen from module origins (all outside the dungeon bounds,
  ~30% inside walls); orbs, props and globes sampled the module box and landed in walls; wall
  furniture could be buried; orb spawn points never recycled; the portal could fall back to the
  world origin; the portal did not open if the last enemy died while the player stood in it.
- Run-end screen was not one-shot and survived into the Alchemist; Legendary Mode did not
  re-enable enemy spawning.
- Damaged `settings.json` could strip default key bindings or abort the remap restore.
- Globes collected from a dead player (wiping the death-screen potions); trap banner HUD leaked
  one CanvasLayer per run; a prop could spawn two potions in one tick; buffs could drive the
  footstep interval to <= 0 (sound every frame) or invert head bob (floored, meaning unchanged).
- Static check (`tests/check_res_paths.py`) for case-mismatched/missing `res://` paths.

**Verified / no longer an issue**
- `exclude = [node]` in ray queries is fine (Godot converts to the RID; verified).
- Per-kill save cost: 0.34 ms (Linux, measured). Windows not measured.
- Pooled enemies remaining in the `enemy` groups are harmless (dead until reborn; consumers skip dead).
- `damage_reduction` is ignored when <= 0, but the only buff using it (Iron Will, +0.22) works.
- Alchemist cost math, single spend, perk keys match their consumers; kill-to-potion on death runs once.
- GameClock timer pauses with the tree; `start_run()` resets all run state.
- Collision-layer naming is cosmetic once the ray masks are right.

**Requires human judgment (not changed in round 2; most are resolved in round 3 below)**
- Chests never spawn: the only end-cap module is a solid 2 m wall slab and `ChestManager` rejects it.
  Chest rewards, mimics and the keys that open them are inert until the owner decides where chests live.
- Minimap action is bound to Escape (also pause).
- Starter potion is granted only on the character-select start path.
- Slide kicks re-roll the 8% prop loot roll every physics tick (balance).
- Buff data: `jump_velocity`/`torch_duration` exist on no player (Jump Master, Torchbearer, Dimming
  Legend, Flickering Torment, Eternal Night do nothing); percent-like values are added as absolutes
  (Blood Rush ~+3% speed); no class filter on the pick pool (Mage/Brute-only stats); Adrenaline Spike
  and Shadow Dancer are not conditional as described.
- Homing trap fireballs detonate on the first body (also hurting enemies).
- Portal needs every enemy dead, including any that are unreachable.
- Kills convert to potions only on death.
- Acid damage is hard-coded (exported tunables unused); perk descriptions are stale (Scavenge/Greed).

**Remaining, low (not fixed)**
- Missing prop texture files referenced by FBX imports (warnings); engine teardown messages;
  trap schizophrenia timer does not stack; Mage drunk/reversed-controls fire-and-forget timers;
  Alchemist saves twice per purchase; no duplicate-binding detection in the options screen;
  portal hint layers accumulate; `_fly_homing`/options awaits can resume after their node is freed
  (log noise); mouse capture cannot be asserted headless.

**Deferred for the Android port**: touch controls, window/resolution code, fixed-pixel UI and
safe areas, renderer choice, asset size, storage root, package/API 36/16 KB/signing.

## Round 3 (branch `purgatory-stabilization-round2`, toward v3)
Every item the round-2 "Requires human judgment" and "Remaining, low" lists named was re-validated
against the source. Fixes have regression tests that fail on the old code and pass on the new.

**Chests / keys / mimics.** Root cause: `ChestManager` only accepted modules tagged `is_end_cap`,
and the only end-cap module is a solid 2 m wall slab that its own size gate rejects, so no chest
ever spawned and keys (5% enemy drop, saved in the profile) had nothing to open. Chests now live
in **dead-end rooms** (a room with exactly one opening, never the start room, plugs or connectors);
the spot is checked inside the dungeon and clear of walls, with a fallback to the generator's safe
interior point. ~5-10 such rooms per dungeon x 40% = roughly 2-4 chests per run. The chest/key/mimic
FBX files point at texture files that only exist on the artist's machine, so they import untextured:
they now use the shipped `SM_Chests_Mat_Chests_*` textures (needs a visual check).
Test: `test_chests` (3 seeds). Owner decision: chests stay in dead-end rooms (no alcove scene for v3).

**Buffs (54 in `data/buffs.json`, 28 globe effects).** Audited every entry against both players.
- Percent-like values (Blood Rush +25% was +3%) were added as absolutes. A fixed list of stats
  (`BuffManager.PERCENT_OF_BASE_STATS`) is now scaled by the player's base value, stacks additively
  and is removed exactly. `test_buffs` checks every card's text against its data and magnitude.
- Class filtering: the pick pool (and the globe curse pool) only offers entries whose stats exist on
  the current player, so a Mage is no longer offered Barbarian-only buffs and vice versa.
- Adrenaline Spike now only applies below 30% health; Shadow Dancer now gives +18% speed for 5 s
  after a kill (it was +2% permanently-on-pick, then removed after 5 s).
- Slow the Horde / Enemy Weaken / Horde Caller now work for the Mage too (the stats moved to
  `CharacterBase`); negative `damage_reduction` curses (Pain Mirror, Void Embrace) now make the
  player take more damage instead of doing nothing.
- Card texts that disagreed with behaviour were corrected (Wrath/Thunder Expansion, Radiant Sparks,
  Slow the Horde, Enemy Weaken, Footstep Stalker, Horde Caller).
- **Removed (owner decision):** Jump Master, Torchbearer, Dimming Legend and the curses Flickering
  Torment and Eternal Night were deleted from the data: their stats (`jump_velocity`,
  `torch_duration`) exist on no player (there is no jump; torches only dim on hardcore). `test_buffs`
  fails if any of them returns or if any entry references a stat no player has.
- **Curses.** Blood Thirst (-6 health on kill) and Shattered Spark (sparks cost you health on kill)
  are independent: they now hurt the player on each kill (never below 1 HP). Dimmed Sparks, Blind
  Rage, Weakened Flame and Cursed Regen only modify an opt-in effect, so they declare
  `requires_any_positive` in `data/globe_effects.json` and a globe that would hand out one the
  player cannot use gives another curse of the same rarity instead (decided at pickup).

**Portal completion.** The portal could stay shut forever: after Day 30 the pressure spawner (and
an in-flight top-up wave) kept sending a buffed enemy every 5 s to a player who stayed undamaged;
the portal read a once-a-second cached count that lags kills and does not refresh while paused; an
enemy that fell out of the world (they have no kill plane) or a guard placed in a wall/void stayed
"alive" for good. Fixed: reinforcements honour the lock; the portal counts live enemies exactly;
stranded enemies below y = -15 are rescued; guards are placed inside the dungeon and snapped to the
floor and are counted from the moment they spawn; failsafe - if at most 3 enemies remain and none
dies for 180 s of game time the portal opens (they are treated as unreachable). Test:
`test_portal_completion`.

**Trap fireballs** detonated on, and damaged, the first body in their path (usually an enemy).
They now fly through enemies and only damage the player. Test: `test_trap_fireball`.

**Lower-priority fixes**
- Alchemist purchase: one profile write holding both the spent potions and the perk
  (`SaveManager.save_count` lets a test assert it).
- Duplicate key bindings: remapping an action to an input another action uses swaps the two (and
  refuses when there is nothing to swap). The Block/AOE default gamepad overlap is unchanged.
- Portal hint: one reusable layer instead of one per entry.
- Mage drunk/reversed-controls: tracked timers (refresh on re-apply, pause with the game).
- Schizophrenia: reference-counted hallucination node, game-time timers, stale timers from a
  previous run ignored; a re-triggered trap extends the effect instead of being cut short.
- Acid trap: duration and damage now come from `TrapManager.acid_duration` /
  `acid_damage_per_sec` (1.0 dps x 15 s, the documented values). The Barbarian took a hard-coded
  15 dps (225 damage over the effect, lethal at 100 HP) - **this changes the Barbarian's acid from
  lethal to 15 total damage; retune the exports if more bite is wanted.**
- Slide kick: each prop in range is kicked once per slide (it was re-kicked, re-rolling its 8%
  potion/curse loot, every physics tick; the single-prop `break` also contradicted the comment).
- Starter potion: granted by every run-start route (character select, Alchemist, quick restart)
  through `RunLifecycle.grant_starter_potion()`.
- Minimap key: the game's own controls reference lists Minimap = Tab and Pause = Esc, but the input
  action was bound to Escape. Now Tab.
- Perk texts: Scavenge +3% and Greed +5% (the live values); Magnitude/Persistence describe each
  class; the stats screen knows `health_regen`.
- Test fix: `test_physics_queries` probed a different ray than the brute's sight ray, so it failed
  intermittently depending on the random start room.

**Dungeon generation could leave a tiny dungeon.** Found when a CI run of `test_physics_queries`
generated "Modules: 9, Rooms: 5 / target 110, Typed spawns: 0": the generator is random and every
open doorway can end up closed by dead-end rooms early (about 0 of 168 probed seeds, so well under
1% of runs, but a run with no enemies is unplayable). Fixed two ways: the last open doorway is
never given a dead-end room while below target, and a finished layout under 80% of the room target
is discarded and generated again (up to 6 times; `minimum_fill_fraction`, `max_layout_attempts`).
Layouts for a given seed differ from v2 builds (the random draws changed); a seed still reproduces
its own layout. Test: `test_generation_growth` (normal / recover / exhaust cases).

**Studio splash.** The Hot Attic Games splash (`scenes/StudioSplash.tscn`, the main scene) is built
and tested (`test_studio_splash`: launch order, 2-3 s timing, aspect/transparency/whole-logo layout,
no replay on re-entry, no stranding). **The canonical logo `Hot_Attic_Games_Master_Logo_ALPHA_FINAL.png`
was not present in the repository when this was written**, so the card is skipped at runtime until it
is added (project root or `branding/`); release builds refuse to publish without it.

**Globe pool bug.** `GlobeManager` loaded the data file's `_comment` lines as effects, so about a third of common globes
(13 of 39 pool entries) rolled a no-op "effect". Entries without an `id` are now skipped; `test_buffs` checks the pool.

**Also in round 3**
- Persistence is hidden from the Barbarian's perk list (it has no effect for that class); the Mage keeps it.
- Mage trap-status panel: the Mage now has the same on-screen list of active trap effects as the
  Barbarian (the banner only flashes at trigger time and day-long effects were invisible after).
- Far-away frozen enemies were investigated: they skip their AI tick while off-screen and >20 m away
  (a deliberate optimisation). They are bounded by the population cap, are culled by the existing
  stale-enemy and room-lock culls, count correctly, and cost almost nothing, so nothing is
  despawned. The real problem was discoverability of the last enemies, solved by minimap markers.
- Minimap markers: once the portal is open and 5 or fewer enemies remain, they show as red dots on
  the map (never earlier, so the map stays uncluttered).
- Generator reliability. Stress harness `tests/stress_generation.sh` (one seeded generation per process, checks rooms,
  spawns, connectivity, chests, Day-30 portal and 25 guards). Production weights, seeds 10000-10999 with chests/portal/guard
  checks: **1000/1000 OK, 0 regenerations needed**, 110 rooms every time, 219-420 enemy spawn points, 0-14 dead-end rooms
  (a seed with none has no chests). Seeds 6000-6599 single-attempt: 600/600 reached the target. Adverse test (dead-end
  weight 15, single attempt, seeds 7000-7199): 130/200 failed before the frontier reserve + door retries, 56/200 after;
  every failure is `open_exhausted` and is recovered by regeneration (up to 6 layouts). A failing seed reproduces with
  `STRESS_SEED=<seed> godot --headless --path . res://tests/stress_generation.tscn`.

**Still open after round 3**
- Balance numbers are untouched pending physical play: Quick Recovery +4 HP/s, Purgatory King +12 HP/s.
- Chest/key/mimic and Mage visuals, and every subjective item, need the physical test.

## Repository hygiene
`.git` ≈ 509 MB (binary assets, no LFS; history untouched). Removed: `claude.md.txt` (superseded
duplicate of `CLAUDE.md`). Kept deliberately: `player_guard_sword0.bin`, `archive/`,
`schizophrenia_audio.gd` at repo root (it is live; loaded by `BuffManager`).
Later: asset compression/import presets, Git LFS decision (needs history-rewrite analysis),
collision layer naming, bus layout.
