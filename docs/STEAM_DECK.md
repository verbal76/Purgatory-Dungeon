# Steam Deck / Steam Machine

The Deck can run the Windows build through Proton, and the repository now also builds a **native Linux x86-64 package** (`python3 tools/build.py --platform linux`, `docs/PLATFORM_SUPPORT.md`; the master standard requires it). The 2026-10-11 "Windows via Proton" decision stands for what has been tested; the Linux package has booted headless to the main menu and has NOT been run on a Deck. This page is Valve's "Deck Verified" input,
display and performance checklist against what the game does, what was measured, and what still needs a real Deck. Nothing here is released:
it is held for the next APK generation (owner decision, 2026-10-11).

## Checklist

| Requirement | Status | How |
|---|---|---|
| Controller support with the default configuration, no setting to change | Done, tested | Every action has a gamepad binding in `project.godot`; `tests/test_controller_nav` opens each menu screen (main menu, profiles, character select, every Options tab, Codex, Alchemist, pause, win screen, the on-screen keyboard) and checks a control has focus and every control is reachable by D-pad focus moves. The death screen and buff reel act on single buttons (Start / A / X, A). |
| Glyphs match the input in use; no keyboard / mouse glyph while on a controller | Done, tested | `scripts/controller_glyphs.gd` + `glyph_prompt.gd`: prompts show original button art (`assets/ui/glyphs`, drawn by `tools/make_controller_glyphs.py`) in the Xbox or the Steam Deck / Steam Controller label set (L1/R1/L2/R2), read from the InputMap so a remap is followed; keyboard / mouse names show only while the keyboard / mouse is the active input. `tests/test_controller_glyphs`. Exception by design: Options > Controls > *Remap Bindings* keeps its keyboard column because that is where a key is rebound; its Quick Reference shows controller buttons only while a controller is in use. |
| Text entry without a keyboard | Done, tested | The character name uses the game's own on-screen keyboard (`scripts/virtual_keyboard.gd`), opened with A, typed with the D-pad, X deletes, B closes. No Steamworks keyboard call is needed (the Steam keyboard was considered, and dropped: it would need the GodotSteam plugin and a Steam App ID for no gain). The custom seed field is removed from the UI (every run auto-generates its seed). |
| Playable default: 30 fps at 800p | Built, NOT measured on a Deck | `Graphics Quality` (`scripts/graphics_quality.gd`, Options > Video): **Balanced** (saved level Medium) on a Deck = FSR 1.0 upscaled from 77 % (about 985x616 inside the 1280x800 panel); **Cool / Battery** (Low) = 59 %, no bloom; **Quality** (High) = full resolution (the PC default, unchanged). The device's default is marked "(Recommended)". Only the 3D scene is scaled: menus and text stay sharp. Needs a measurement on a real Deck (see below). |
| No device-compatibility warning | Checked | No code path shows a GPU / OS / hardware warning (the only "incompatible" texts are the Android update system's). |
| Launcher | None | The game starts straight into the studio splash and menu. |
| Deck resolution 1280x800 / 1280x720 | Fine | Default window mode is borderless fullscreen at the display's resolution; the UI is laid out for 1280x720 and scales. |
| Text legible: nothing below 9 px at 1280x800 (12 px recommended) | Fine | The smallest UI text is the *caption* role: 16 px x 0.86 desktop scale = 14 px. No smaller font size exists in the project (searched `.gd`, `.tscn`, `.tres`). A user-configurable text size (Valve recommends it) is not built. |

## Checked by rendering at 1280x800 (software Vulkan, `tests/deck_shots`, `tests/deck_game_shots`; manual tools, header says how to run)

Main menu, profiles, character select, the on-screen keyboard, every Options tab, Codex, Alchemist, HUD, pause menu, death and win screens were rendered at the Deck's
panel size with the Deck defaults and a controller in use. Defects found and fixed this way: the character-select form is 1348 px wide with its developer-toggles column
(1280 on a Deck), so that column now yields where the screen is too narrow; gamepad bindings in Options read "Pad Btn 0" / "Pad Axis1-" (now "A", "R1", "Left Stick Up");
a pending controller remap could only be cancelled with Escape (it now cancels itself after 6 s); empty profile slots said "click" to a controller player (now "press A").
The "E" at the top left of the HUD is the compass heading (east), not a key prompt. Tool pitfall: render screens as children of the root window, as the game does
(a plain parent Node does not pass the UI theme down, which makes parchment screens look white-on-white).

## What is NOT proven (needs a Steam Deck)

- Frame rate. The headless CPU side is unchanged by this work, but the GPU side was never measured: there is no Deck here. Test **Balanced** on a Deck
  in a busy fight and on the opening rooms; if it is under 40 fps, lower the default (the table is `SCALE` in `graphics_quality.gd`).
- Proton behaviour: Windows Godot builds use Direct3D 12 (`rendering_device/driver.windows="d3d12"`), which Proton runs through vkd3d-proton.
- Controller names under Steam Input: a Deck normally presents itself as an Xbox pad inside Proton, so `SteamDeck=1` (which Steam sets) forces the Deck
  labels; a docked Deck with another brand of pad uses that pad's labels (Xbox style is the fallback).
- Suspend / resume and the Steam overlay were not exercised. The game does not pause when the window loses focus (the Steam overlay or the Deck's quick-access menu
  open over a running game); changing that would alter Windows behaviour too, so it is left as an owner decision.
- Not built (recommendations, not requirements): a user-configurable text size (the smallest text is 14 px), a controller look-sensitivity slider.

## For the next APK generation (native files: do NOT change in an OTA)

- `project.godot`: consider `rendering/rendering_device/driver.windows` = `"vulkan"` instead of `"d3d12"`. Vulkan is what Valve recommends under Proton and avoids
  vkd3d-proton as a layer; D3D12 may have been chosen on purpose for Windows GPUs, so this is an owner decision. Changing it changes the runtime fingerprint
  (`python3 tools/ota_runtime.py --check`, then `--bump` or `--relock`).
- Everything else on this page is plain scripts / assets and is OTA-safe.

## Trying it on a PC

- `PURGATORY_FORCE_DECK=1` makes the game act like a Deck (Medium quality default, Deck button labels).
- Plug a gamepad in; the prompts switch as soon as a button is pressed, and back to key names on the next key press or mouse click (mouse movement alone does not flip them: Deck trackpads and gyro send motion while a pad is in use, master standard 12.3).
- Tests: `tests/test_controller_glyphs`, `tests/test_controller_nav`, `tests/test_steam_deck`, `tests/test_mixed_look` (mouse + stick look add up), `tests/test_offline.py` (all in `tests/run_tests.sh`).
- Screenshots of the prompts: `tests/glyph_shots` (manual tool, header explains how to run it).
