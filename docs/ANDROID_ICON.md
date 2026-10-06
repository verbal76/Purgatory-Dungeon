# Android launcher icon

Concept: a **gilded gothic dungeon door**. A pointed arch with a bevelled brass-gold frame, an iron-bound plank door and one
glowing ember keyhole that lights the planks around it, on charred stone. One shape, one focal point, no text. Colours are the
UI palette (`docs/UI_DESIGN_SYSTEM.md`): void/iron darks, brass + gold rim light, ember accent. Original artwork: the studio
logo is neither read nor copied, and the previous placeholder (the VPP portrait) is gone.

| File (`android_icons/`, referenced by `export_presets.cfg`) | Role |
|---|---|
| `adaptive_fg_432.png` | foreground, transparent; every pixel of artwork inside the 288 px safe circle (66 dp of 108 dp) |
| `adaptive_bg_432.png` | background, fully opaque: soot-stained stone blocks, warm glow, soft shadow of the door |
| `adaptive_mono_432.png` | themed icon (Android 13+): white + alpha only, keyhole and plank seams cut out |
| `main_192.png` | legacy icon (pre-adaptive launchers; the app's minSdk is 30 so it is a fallback only): rounded tile, transparent corners |

Reproduce / edit (standard library only, ~8 s, deterministic): `python3 tools/make_android_icon.py --preview docs/icon_preview.png`.
`docs/icon_preview.png` is the contact sheet: rows circle, squircle, rounded square, teardrop, legacy tile, themed icon; columns
192, 96, 72, 48, 36 px; dark wallpaper left, light wallpaper right. Masks are simulated; real launcher rendering differs
slightly (mask curve, themed-icon colours) and is only visible on a device.

Checks: `python3 tests/test_android_icons.py` (part of `tests/run_tests.sh`): preset wiring, 8-bit RGBA, sizes, safe zone, one-colour
monochrome, opaque background, legacy tile, keyhole/frame contrast, and that the committed legacy PNG equals the generator output.

Only PNG contents change, so `export_presets.cfg`/`project.godot` (the native fingerprint) are untouched. The launcher icon is
baked into the APK: it cannot be delivered by an OTA; players see it from the next real APK. The desktop/window icon
(`config/icon`, Windows/macOS native icons) is a separate, unchanged set.
