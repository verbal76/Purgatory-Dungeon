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

| Touch control | Action | Keyboard | Controller |
|---|---|---|---|
| Left thumb: floating stick (anywhere in the lower-left) | move_forward/back/left/right (analog) | WASD | left stick |
| Right side: swipe/drag (no button) | look (yaw) | mouse | right stick |
| Big sword button (hold to charge) | attack | Left Mouse | RT |
| Boot | kick | F | RB |
| Chevrons | jump / slide | Space | B |
| Shield (hold) | block | Right Mouse | D-pad down |
| Flask (cooldown ring, potion count) | AOE burst | Q | LB |
| USE / OPEN (appears only at a chest you can open) | equip | E | A |
| Pause (top right) | ui_menu | Esc | Start |
| Map (top right, toggle) | minimap | Tab | - |
| Android back | ui_cancel | - | - |

Options > Gameplay > Touch Controls: opacity, size, look sensitivity. Buttons are laid out inside the
system safe area (cutouts, rounded corners, gesture bar). Onboarding shows one contextual hint at a
time (move, look, attack, use, block, burst), fades when the player does the thing, is saved, and is
retired after 3 ignored showings.

## Phone UI
`scripts/touch/mobile_ui.gd` (touch platforms only) enlarges the default font, raises any smaller
font and gives buttons a 72 px minimum on the 1280x720 phone canvas. Screens with fixed layouts were
adapted individually (main menu without Quit, character select without dev toggles and with the
game's own keyboard, Alchemist 3x2 pages, pause menu Resume/Options/Exit, death-screen buttons,
tap-to-stop buff roulette, wallet moved top-right). `tools/ui_shot.gd` renders any scene at phone
shape for review (needs a display; opengl3 under xvfb works).

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
`tests/run_tests.sh` includes `test_touch_controls` (run with `PURGATORY_FORCE_TOUCH=1`),
`test_mobile_ui`, `test_app_lifecycle` and `test_input_desktop` (proves keyboard/controller bindings
are unchanged). Procedural generation is untouched by the Android work.
