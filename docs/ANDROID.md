# Purgatory Dungeon on Android

The same game as Windows (one code base, one public version number), playable on phones in
landscape. Developed against the Google Pixel 10 Pro XL (Android 17, API 37). Sideloaded APK, not
Google Play. This file replaces the planning notes in `ANDROID_PORT_ASSESSMENT.md`.

## Identity
| | |
|---|---|
| Package ID | `com.hotatticgames.purgatorydungeon` (never change: it is the install identity) |
| App name | Purgatory Dungeon |
| versionName | the public number, e.g. `4` (`./VERSION`) |
| versionCode | the same integer (strictly increasing, no timestamps) |
| ABI | arm64-v8a only |
| minSdk / targetSdk | 30 / 36 (compileSdk 36) |
| 16 KB pages | every packaged `.so` has PT_LOAD alignment >= 0x4000 and the APK passes `zipalign -c -P 16` (checked by `tools/verify_apk.py` on every build) |
| Engine | Godot 4.6-stable, Mobile renderer (automatic on Android), Jolt physics |
| Release file | `Purgatory-Dungeon-v<N>.apk` attached to the same GitHub Release as the Windows zip |

## Signing (stable install line)
Every APK is signed with one persistent key so a newer build installs over an older one and keeps
its saves. The key is never in the repository, release notes, logs or CI artifacts.
1. If the Actions secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
   `ANDROID_KEY_ALIAS` exist they are used (preferred, owner-controlled).
2. Otherwise `tools/android/signing.sh` uses the private **draft** release "Android signing key
   (do not delete)" in this repository (assets `release.p12` + `release.pw`, visible only to people
   with write access). The first CI run generated it (RSA 4096, PKCS12, alias `purgatorydungeon`,
   100-year validity). **Deleting that draft breaks the update path** for installed copies.
3. Only the public certificate SHA-256 is printed (release notes list it so installs can be checked):
   `tools/verify_apk.py --expect-cert` fails a build signed with any other key.

## Build and qualification (GitHub Actions, job `android`)
`tests` subset (touch, input, UI, lifecycle, splash) -> signing -> `tools/android/build_apk.sh`
(installs SDK pieces, unpacks the Android gradle template, enables ETC2/ASTC import, exports) ->
`tools/verify_apk.py` (identity, API levels, arm64, 16 KB, signature, PCK content incl. the studio
logo) -> artifact. `publish` (on `release/v<N>` or tag `v<N>`) attaches the APK to the release after
verifying it again.

## Controls (touch)
Everything feeds the same semantic input actions as keyboard and controller; gameplay code has no
mobile branch (`scripts/touch/`). Mouse-button bindings are removed on touch platforms so a finger's
emulated click can never attack or block.

Two schemes, chosen in Options > Gameplay > Touch Controls > **Control scheme** (setting `TouchScheme`
in settings.json, `"twin"` or `"classic"`; no key = twin). **Twin-stick is the default**; Classic is the
original swipe scheme, unchanged. A change applies live (also from the pause menu): the layer releases
every finger and action, re-lays itself out and the hints follow the new scheme. Opacity, size and look
sensitivity apply to both.

### Twin-stick (default)
| Touch control | Action | Keyboard | Controller |
|---|---|---|---|
| Left thumb: floating stick (anywhere in the lower-left 40%) | move_forward/back/left/right (analog) | WASD | left stick |
| Big sword button, lower-right rim (hold to charge). **Dragging from it aims**: a continuous turn rate measured from the touch-down point | attack (+ look while dragging) | Left Mouse (+ mouse) | RT (+ right stick) |
| Empty screen on the right (no button under the finger) | nothing: there is no look stick and no look zone | - | - |
| Slide chevrons, kick boot, shield (hold), flask (cooldown ring, potion count) on an arc around Attack | jump, kick, block, AOE | Space, F, Right Mouse, Q | B, RB, D-pad down, LB |
| USE / OPEN (appears only at a chest you can open), second ring | equip | E | A |
| Pause / Map (top right, map toggles) | ui_menu / minimap | Esc / Tab | Start / - |
| Android back | ui_cancel | - | - |

### Classic
| Touch control | Action |
|---|---|
| Left thumb: floating stick | move (analog) |
| Right side: swipe/drag (no stick) | look (yaw, one motion event per drag event) |
| Big sword button (hold to charge), boot, chevrons, shield (hold), flask, USE, Pause, Map | attack, kick, jump, block, AOE, equip, ui_menu, minimap |

### Twin-stick design notes
- **Why**: Classic needs repeated swipes to turn while moving. In twin-stick the Attack button is the aim control, as
  in Brawl Stars (drag from the attack button to aim, abilities in an arc around it): the right thumb rests on Attack
  and turning is a drag from it, at a turn rate, while attacking. There is no separate right stick.
- **Ownership**: every finger is owned by exactly one thing from touch-down to touch-up (`Owner`:
  `BUTTON` > `STICK` (left lower 40%) > `NONE`; Classic also has `LOOK` for its swipe). A touch on a button is that
  button. **A finger that starts on empty screen outside the move zone is ignored** in twin-stick (there is no look
  zone): it is owned by `NONE`, so it cannot turn into anything later, whatever it does. Extra fingers in the occupied
  move zone are ignored the same way. A finger that goes down on ATTACK stays a BUTTON finger (press/hold/release,
  `MIN_PRESS_MS` stretching unchanged) and also measures an aim drag from its touch-down point; it keeps aiming
  wherever it wanders (even far outside the button) until it is lifted, and the drag never releases or re-presses
  attack. Releasing ATTACK ends the drag at once. Left-thumb movement and the aim drag work together.
- **Input path**: the look command is turned into one `InputEventMouseMotion` (device 0) per **physics
  frame** by `TouchControls._physics_process` - the same mouse-look path the Classic swipe uses - so
  `brute_player.gd` / `mage_player.gd` are untouched (they turn by `relative.x * 0.0025` rad). The
  rate is physical (rad/s), so frame time does not matter (step capped at `LOOK_MAX_STEP` against hitches).
  The players have no pitch today and ignore `relative.y`; it is sent at `LOOK_PITCH_RATIO` for when they get one.
- **Response** (`look_response`): d = offset / radius; inside `LOOK_DEADZONE` nothing; then
  x = (d - dz) / (1 - dz) and rate = `LOOK_MAX_YAW_RATE` * x^`LOOK_CURVE_EXP` * Look Sensitivity.
  The drag origin follows a thumb dragged past the radius (never runs out of travel, reversing is immediate).
- **Lifecycle**: `release_all()` (background, lock, call, shade, pause menu, layer disabled, scheme
  change, node exit) and an engine touch cancel clear every finger, the stick, the drag and the look command, so
  nothing keeps moving, turning or attacking after returning; stale drags from the old fingers are ignored.
- **Visuals**: the move stick has a faint idle marker at rest (`STICK_IDLE_ALPHA`) and an ember rim when held; a
  faint ember drag ring (drawn above the buttons) shows while dragging from ATTACK. No other marker exists on the right.
  No shaders, nothing redrawn per frame.
- **Onboarding** teaches the active scheme: move ("Drag the left side to move"), aim ("Drag from Attack to look and
  aim", pulses ATTACK, done once the drag has been held out `AIM_DONE_SECONDS`), attack, use, block, burst. Same
  persistence and 3-showing retirement; a saved `look_stick` flag from the removed right-stick hint is ignored (it never
  replays and teaches nothing now); hints are placed on the first spot that touches no control.

### Twin-stick tuning constants (`scripts/touch/touch_controls.gd`)
| Constant | Value | Meaning |
|---|---|---|
| `AIM_DRAG_RADIUS` | 90 px | drag travel from the touch-down point for full deflection (x Control Size) |
| `LOOK_DEADZONE` | 0.12 | fraction of the radius that does nothing |
| `LOOK_CURVE_EXP` | 1.7 | response exponent (fine aim near centre, fast at the rim) |
| `LOOK_MAX_YAW_RATE` | 4.2 rad/s (~240 deg/s) | full deflection at 100% sensitivity |
| `LOOK_PITCH_RATIO` | 0.55 | pitch rate / yaw rate |
| `LOOK_MAX_STEP` | 0.1 s | cap on one look step |
| `TWIN_ATTACK_R` / `TWIN_SUB_R` / `TWIN_USE_R` | 100 / 56 / 60 px | radii at 100% size |
| `TWIN_ARC_R`, `TWIN_ARC_START`, `TWIN_ARC_STEP` | 178 px, 165 deg, 40 deg | slide 165, kick 205, block 245, burst 285 deg (screen angles, 0 = right, 90 = down) around Attack |
| `TWIN_USE_ANGLE` | 225 deg on a second ring | USE between kick and block |
| `ATTACK_MIN_MM` / `SUB_MIN_MM` | 16 / 9 mm | physical minimum diameters |

Layout at the Pixel 10 Pro XL (2992x1344 window, 1280x720 expand canvas -> 1602x720 visible, safe
area MARGIN 36/28): Attack centre (1436, 578) r 100; slide (1264, 624), kick (1275, 503), block (1361, 417),
burst (1482, 406), all r 56; USE (1218, 360) r 60; Pause (1526, 140) and Map (1526, 240) r 38 unchanged.
**Size maths**: px per mm = dpi / 25.4 * (virtual height / panel height) = 480 / 25.4 * 720 / 1344 = 10.12
(`TouchControls.px_per_mm`, dpi from `DisplayServer.screen_get_dpi()`, 480 if unknown). Attack
200 px = 19.8 mm (>= 16), subordinates 112 px = 11.1 mm (>= 9), Attack is 1.79x a subordinate. The radii are
floored by the mm minimums (so Control Size 70% never makes them smaller), and the arc radius grows when
needed so neighbours cannot overlap. Hit areas are 1.3x the drawn radius; a touch inside a drawn button
always resolves to that button. Canvases shorter than 720 px shrink the cluster (down to 0.8x) instead of
colliding with Pause/Map.

### Button anatomy and baked art (`scripts/touch/touch_button.gd`, `assets/touch/`)
Art direction: `docs/art/PD_Mobile_Control_Art_Reference.png` (direction only, never shipped or traced). The buttons are
physical round controls: a soft drop shadow, a chunky segmented aged-bronze rim, a recessed dark cracked-slate face with an
inner bevel, and a faceted hand-painted icon. The art is original, authored as faceted polygons and rendered OFFLINE by
`tools/make_control_art.gd` into PNGs (seeded: a re-run is identical). Drawing in game is a few cached `draw_texture_rect`s
(no shaders, no blur, no per-frame allocation); textures load once and are cached (`TouchButton.art_texture`), sampled
with `TEXTURE_FILTER_LINEAR_WITH_MIPMAPS`. A missing file falls back to the code-drawn button, so controls never vanish.

| Asset (`assets/touch/`) | Px | Used by |
|---|---|---|
| `base_attack_<state>.png` | 512 | Attack: 24-block bronze rim, slate face, four diamond studs at the cardinal points |
| `base_sub_<state>.png` | 256 | slide, kick, block, burst, USE: 20-block rim, no studs |
| `icon_sword / shield / boot / flask / chevrons / key _<state>.png` | 256 | attack, block, kick, burst (red gem), slide (chevrons), USE |
Pause / Map stay code-drawn (quieter family members). 32 PNGs, about 1.2 MB with their `.import` files (budget 6 MB).
**Size choice**: Attack is drawn at 200 virtual px = 374 Pixel device px, so a 512 px base is ~1.4x oversampled; subordinates are
112 px = 210 device px from a 256 px base (1.2x); icons draw at ~1.15 x the face radius, 256 px is ample. Mipmaps keep other
densities clean. Imports are lossless (`compress/mode=0`, mipmaps on): crisp alpha edges and no ETC2/ASTC dependency on Android.

Geometry (art units, disc radius 1.0): rim 0.80-1.00 (10% of the diameter, two bevel planes per block), inner bevel
0.715-0.80, slate face radius 0.715; the canvas half-size is 1.12 so the pressed glow fits (the game draws the base at half-size
r x 1.12). The code-drawn pieces that carry meaning stay on top: charge fill (ember arc on the rim), flask cooldown arc and dark
wedge, count badge, USE caption (Cinzel, `PUI.MIN_DISPLAY_SIZE`), the onboarding pulse, the drag ring, and for USE a thin ember ring.

| State | When | Base | Icon |
|---|---|---|---|
| default | at rest | bronze rim, slate face | steel / bronze / bone / red gem |
| pressed | held or toggled | rim lit toward ember + inner glow + soft outer glow, face slightly darker (pushed in; icon sits 0.03 r lower, shadow tightens) | warmed toward ember |
| cooldown | `cooldown > 0` (flask) | desaturated, cooler grey | desaturated, cool |
| disabled | `unavailable` (flask with no potions; input is unaffected) | dark grey | dark grey |

Regenerate: `xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 --path . --script tools/make_control_art.gd`
(optional name filter after `--`, e.g. `-- icon_sword`), then `godot --headless --path . --import` and commit the PNGs with
their `.import` files (keep `mipmaps/generate=true`). `tests/test_touch_art.gd` checks every referenced file exists, imports with
mipmaps, has the expected size and mip chain, has all four states, and that the buttons pick the right one.

Code-drawn fallback / Pause / Map / sticks (same family, from primitives): shadow (cached radial, alpha 0.55, reach 1.16 r,
offset 0.07 r down), bezel 0.22 r (Pause/Map 0.18 r) with a hairline and inner shadow line, recessed iron face, bone icon, ember
bezel when held. The move stick uses this language: a recessed well in a 0.10 r aged-brass bezel with a bone thumb in its
own bezel; resting sticks keep the idle alpha (`STICK_IDLE_ALPHA` 0.62); the Control Opacity setting scales everything.

Options > Gameplay > Touch Controls: control scheme, opacity, size, look sensitivity. Buttons are laid out inside the
system safe area (cutouts, rounded corners, gesture bar). Onboarding shows one contextual hint at a
time, fades when the player does the thing, is saved, and is retired after 3 ignored showings.

## Phone UI
`scripts/touch/mobile_ui.gd` (touch platforms only) enlarges the default font, raises any smaller
font and gives buttons a 72 px minimum on the 1280x720 phone canvas. Screens with fixed layouts were
adapted individually (main menu without Quit, character select without dev toggles and with the
game's own keyboard, Alchemist 3x2 pages, pause menu Resume/Options/Exit, death-screen buttons,
tap-to-stop buff roulette, wallet moved top-right). `tools/ui_shot.gd` renders any scene at phone
shape for review (needs a display; opengl3 under xvfb works).

## Updates (OTA)
The APK contains the OTA client (`scripts/boot/`) and declares the INTERNET permission, used only to fetch the signed update
index and package (nothing else uses the network). Saves live in `user://PurgetoryDungeon`;
OTA state lives in `user://ota`, so updates never write the save folder, and the save folder is backed up before an update is
first activated. The APK bakes `runtime_id` / `runtime_fingerprint` into `build_info.json`; `tools/verify_apk.py` requires them.
How updates are made, published, applied and rolled back: `docs/OTA.md`. The main menu footer shows the running version: `Purgatory Dungeon v7` on the APK as installed and `v7.K` while an OTA runs; tapping the top-left corner 5 times opens the diagnostics overlay.

## Lifecycle and saves
- Saves live in the app's private `user://` (folder `PurgetoryDungeon`, spelling kept for
  compatibility); they survive app updates and process kills.
- `scripts/touch/app_lifecycle.gd`: when backgrounded (Home, app switch, lock, call, shade) the
  profile and settings are written, a live run is paused behind the pause menu and held touches are
  released. Returning rebuilds nothing (same dungeon, same music player, no second splash).
- A dungeon in progress is **not** serialized (it is procedurally generated); if Android reclaims
  the process the player returns to the main menu with all progress/unlocks intact.

## Performance notes
Mobile renderer, 3D scaled to 0.75, MSAA off, no shadow-casting lights anywhere, torch lights fade by
distance. Options > Gameplay > "Show performance readout" overlays FPS, 1% low, worst frame, draw
calls; the same line goes to `adb logcat` every 30 s. Real-device numbers are still to be gathered.

## Testing
`tests/run_tests.sh` includes `test_touch_controls` (the Classic scheme, run with `PURGATORY_FORCE_TOUCH=1`),
`test_twin_stick` (default/persisted scheme, layout at five canvas shapes with and without cutouts, mm minimums,
ownership of simultaneous fingers, look response and frame-rate independence, attack drag, lifecycle,
Options selector, onboarding, plus the real Barbarian and Mage turned by the ATTACK drag, empty right-side screen inert),
`test_mobile_ui`, `test_app_lifecycle` and `test_input_desktop` (proves keyboard/controller bindings
are unchanged). Procedural generation is untouched by the Android work.
