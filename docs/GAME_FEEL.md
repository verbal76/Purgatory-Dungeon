# Game feel (the "juice" pass)

Presentation only: nothing here reads or changes a gameplay number, except the two clearly-marked behaviour changes in section 8.
Everything is built on the existing pooling rules (no node is created while playing) and is OTA-safe (no new autoload, no new
global `class_name`, no input action, no `project.godot` / `export_presets.cfg` / `scripts/boot/**` change).

## 1. Architecture

| Piece | File | Role |
|---|---|---|
| `Juice` (static, `const Juice := preload(...)`) | `scripts/juice.gd` | Reads the comfort settings (`motion_scale()`), is the one thin call surface for effects (`burst`, `flash`, `number`, `banner`, `counter`, `haptic`, `cam_fx`) and builds the pool (`ensure_pool`) and the dust motes. `CharacterBase` declares `Juice`, so player/enemy scripts use it directly. |
| `VfxPool` | `scripts/vfx_pool.gd` | One node per run (group `vfx_pool`, built by the main game file under the loading screen): 13 pre-built one-shot `GPUParticles3D` presets x 4, 3 flash `OmniLight3D`, 14 `Label3D` damage numbers. All reused (`restart()` / re-aim / re-text). Idle = no `_process`. |
| `HudToast` | `scripts/hud_toast.gd` | Group `hud_toast`: one banner label (day change, "SEALED", objective) and one counter line ("Sealed: 3 left"), reused. |
| `CameraFx` | `scripts/camera_fx.gd` | One node per player (`player.camera_fx`): trauma shake (roll + side offset), FOV punch (cap +8 deg), pitch kick, landing dip, hit-stop (animation speed, never `Engine.time_scale`), radial damage vignette scaled by the hit, low-health pulse, heal/block/status tints, death camera, and the render-rate camera smoothing. |
| `AudioManager` | `scripts/audio_manager.gd` | `play_one_shot(stream, db, pitch, priority, min_gap_ms)` over the 8 voices with free-slot-first / least-important-oldest stealing and a per-clip gap; a pooled 8-voice `play_3d_one_shot` (it used to create an `AudioStreamPlayer3D` per hit); `play_varied`, `play_sfx(name)`, `play_footstep`, low-pass filters on Music/SFX (pause, low health, hit muffle), ambience beds, `haptic`. |
| Sounds | `Music & background images/Sound Effects/juice/*.wav` | 28 original sounds synthesised by `tools/make_juice_audio.py` (stdlib only, fixed seed: re-running reproduces them). Music is OGG now (WAV 21 MB -> 2 MB). |

## 2. Comfort settings

- **Options > Gameplay > Screen Shake** (`ShakeSlider`, 0-100, default 50 = designed amount) scales shake, FOV punch, kick, dip, hit-stop and
  the scene wipe. **0 = reduced motion: every one of them is off** (the vignette tint, sounds and numbers stay: they are not motion).
- **Options > Gameplay > Touch Controls > Vibration** (`Vibration`, 0-100, default 60): haptics on a phone; 0 = none. Desktop never vibrates.
  Stored in the same settings file; no `SettingsManager` change was needed (`get_setting("Vibration", 60.0)`).

## 3. What was wired (by audit tier)

**Silence fixed.** Footsteps (there was no `FootstepPlayer` node, so the code that played them never ran), the swing whoosh and blade
sparks (`anim_trigger_*` were never called), the player's hurt grunt (`hit_grunt_sound` was never assigned), the Mage cast / dome sound
(`fireball_cast_sound` was never assigned), the kick and shove (sound now on contact, not on press), the enemy attack tells, trap clicks,
chest/mimic/globe/pickup/orb sounds, the buff reel tick and landing, day bell, door slam / unlock chime, death and victory stingers.

**Weight.** Hit-stop on melee hits (longer on kills and kicks), camera jolt and FOV push on swings, kicks, casts, Repulse, potion blast,
trauma on being hit (scaled by hit size), block sparks + PERFECT block (raised within 280 ms of the hit), hit sparks and floating damage
numbers, landing dip + thud + dust, status-effect tints and distinct cues (drunk sway eases in/out, reversed view turns over in 0.4 s
instead of snapping), death camera (sink, roll, narrow) + stinger + music fade.

**Readability.** Brute kick / Mage shove / swing tells (a swish when the arm goes back), Mage cast charge and release, fireball impact,
elite floor ring + aggro rumble, pressure-spawn rumble (audible far away), enemy health bars (shown only once hurt / for elites),
corpses sink and puff instead of vanishing, room lock: slam, tremor, "SEALED / Sealed: N left", the barrier collapses into embers on unlock.

**UI / reward.** Wallet and kill-counter pops, pickup pop-in + glitter + floating "+N", distinct pickup sounds, buff reel tick + landing
punch by rarity, day-change banner ("FINAL DAY" on the last), run-start objective line, death screen stat count-up, victory stat line + fanfare,
menu button hover/press feel + hover sound, scene arrival wipe, health-bar heal sweep + low-health pulse, touch press spring + haptic tick +
cooldown-ready pop, Vibration slider.

**World.** Ambient dust motes, torch flicker (budget `flicker_amount` 0.09, stepped at 14 Hz; 0 in the light-budget tests), trap telegraph
and consequence (click, dust, red flicker, volley bang, ember impacts), prop kick thud + dust, portal opening event (sting, tremor,
burst) and the white step-through, globe wake + collect cues by rarity, pause / buff-pick low-pass, cave bed + torch crackle + water drips.

## 4. Camera smoothing

Physics runs at 30 Hz, so the body (and the first-person camera on it) moved in 30 Hz steps. `CameraFx` offsets the camera arm each
rendered frame by `-(1 - Engine.get_physics_interpolation_fraction()) x (last physics step)` (plus the head-bob's), which is the
interpolated position without touching the body, the physics or the look yaw (yaw stays immediate). A step over 1.5 m is a teleport and
is not smoothed. This replaces the idea of turning on `physics/common/physics_interpolation` in `project.godot`, which would need an APK.

## 5. Budget

- Particles: 6-16 per burst, 0.2-0.9 s, unshaded quads sharing one mesh + material per preset; at most 52 pool bursts exist, idle ones cost
  nothing. Lights: 3 flash lights (0.1-0.5 s each) on top of the 16-torch budget. Dust motes: 48 particles at 15 fps.
- Audio: 8 + 8 voices, fixed. No `AudioStreamPlayer` is created while playing.
- No per-frame allocation was added; `CameraFx._process` is a handful of float operations.
- Measured (headless, CPU side only, `tests/perf_probe.tscn`, three interleaved runs per build, an idle player in a populated dungeon with 10-14 live
  enemies): median `_process` 3.89 ms before (v8.3 source) vs 3.40 ms after, median `_physics_process` 4.63 ms vs 4.42 ms: no regression beyond the
  run-to-run noise (about +-0.4 ms). Static memory rose about 10 MB (322 vs 312 MB: the sounds, the effect pool, the dust motes). NOT measured:
  GPU / rendering cost, a fight with many simultaneous effects, anything on a phone. Physical-device checks are listed in section 9.

## 6. Tests

`tests/test_juice.tscn` (both classes; 133 checks): sound set imported and loops, voice pools create no node, per-clip gap, priority stealing,
`CameraFx` scale-0 reduced motion, hit-stop restore (not `Engine.time_scale`, not over another speed), FOV cap, vignette scaling, smoothing bounds
and teleports, dip spring, death camera, pool no-growth over 120 effects, light cap, banner layer, and in the real run: the pool/banner exist, footsteps
sound, a hit tints/shakes/starts low-health, landing dips, enemy bars/numbers/elite mark/flinch cancel/credited kill/size restore, wallet pop, torch flicker.
Existing suites cover the unchanged contracts (fireball pool, enemy pooling, chests, room locks, light budget, touch art/controls).

## 7. Regenerating the sounds

`python3 tools/make_juice_audio.py` (repo root) rewrites `Music & background images/Sound Effects/juice/*.wav`; then `godot --headless --import`.

## 8. Behaviour changes (everything else is presentation)

1. **A hit that makes an enemy flinch cancels the attack it was in the middle of** (`CANCEL_ATTACK_ON_FLINCH` in `brute_ai.gd` and `mage_ai.gd`;
   set it to `false` for the old behaviour). Before, the animation showed the stagger while the blow or bolt still landed half a second later. The
   enemy waits its normal attack cooldown before trying again. This makes striking first slightly more rewarding: flag it if it plays too easy.
2. **Enemy deaths that the player did not earn (day cull, room-lock cull, trap, kill plane) are silent** (no death sound). Loot drops are unchanged.

## 9. Needs a physical check (cannot be proven headless)

Haptic strength on a phone; whether the 14 Hz torch flicker and the dust motes are comfortable on the Pixel; frame time with a busy fight
(the budget above is by construction, not measured); the camera smoothing at 20-40 fps on device; loudness balance of the new sounds against
the music at default volumes; the scene wipe on slow storage. Screen Shake 0 should be tried once by someone sensitive to motion.

## 10. Deferred (not in this pass)

- Pooling the player Mage's bolts / dome bolts (`mage_player._launch_fireball` still builds an `Area3D` per bolt; `test_mage_aim` and
  `test_attack_gesture` count the `MageFireball_*` nodes, so this needs a coordinated change).
- Combat-intensity music layers, per-room reverb, footstep surface variants.
- `physics/common/physics_interpolation` in `project.godot` (native; replaced by the camera smoothing above).
- Design items kept out on purpose (owner decisions): a real choice at the buff pick, positive globes, a fairer fireball mine / start-area
  exclusion, potions on a win. See `docs/BACKLOG.md`.
