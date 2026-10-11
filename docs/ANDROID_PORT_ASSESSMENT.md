> Superseded by `docs/ANDROID.md` (the port exists). Kept as the original planning record.

# Android Landscape Port — Assessment (planning only)

Direction: the **same** Purgatory Dungeon on Windows PC + Android landscape. Nothing here is
implemented; no Android preset, package ID, signing, or API-level work exists. No package identity
was ever established, so choosing one (e.g. `com.hotatticgames.purgatorydungeon`) is an owner
decision at the start of the Android round. Ratings: READY / NEEDS ADAPTATION / SIGNIFICANT / UNKNOWN.

| Area | Rating | Notes (evidence) |
|---|---|---|
| Gameplay/generation/AI logic | READY | Pure GDScript, headless-tested; case-sensitive path bugs already fixed (Linux filesystem = Android) |
| Input actions | NEEDS ADAPTATION | Gameplay reads `Input.is_action_*` (move/attack/jump/kick/AOE/block/equip). Look is `InputEventMouseMotion` + pad axes (horizontal-only on pad); no touch code. Pause uses raw `KEY_ESCAPE`; death screen uses raw `KEY_X`; `minimap` bound to Escape |
| Virtual movement / swipe look / buttons | SIGNIFICANT | New touch layer must emit the existing actions and a look delta; double-jump/kick/magic/interact/minimap buttons needed |
| Mouse capture | NEEDS ADAPTATION | Players call `MOUSE_MODE_CAPTURED`; irrelevant on touch |
| Save storage | NEEDS ADAPTATION | `StoragePaths` centralises the root (done). On Android use `user://` not Documents (scoped storage); folder name spelling is a desktop-compat path |
| Window/resolution code | NEEDS ADAPTATION | `DisplayServer.window_*` in Settings/Pause/Options is desktop-only; Pause/Options resolution lists hardcoded 1280×720+ |
| UI scaling/safe areas | SIGNIFICANT | No stretch settings (`project.godot` has none); many code-built UIs use fixed pixel offsets (portal, run end, wallet, clock HUD, virtual keyboard) |
| On-screen keyboard | NEEDS ADAPTATION | Custom `VirtualKeyboard` for the name field; Android native IME would conflict |
| Controller (Android) | NEEDS ADAPTATION | Pad bindings exist; focus handling relies on automatic navigation |
| Renderer | UNKNOWN / SIGNIFICANT | Project uses Forward Plus + D3D12 hint; Android needs Mobile (Vulkan) or Compatibility; dynamic lights (torches, per-fireball OmniLight) and ~13.8k nodes are risks |
| Physics | UNKNOWN | Jolt at 30 ticks is fine on desktop; mobile cost unmeasured |
| Memory / package size | SIGNIFICANT | ~750 MB static memory in headless run; PCK 671 MB (4K-class skyboxes 387 MB). Needs texture compression (ETC2/ASTC) and asset budgeting; Play AAB size limits apply |
| Toolchain | UNKNOWN | Needs Android SDK/JDK/export templates, target API 36 (verify Play requirement at the time), 16 KB page-size check of the actual APK `.so` files, signing, AAB — none started |
| CI | NEEDS ADAPTATION | Add an Android export job to `.github/workflows/ci.yml` after toolchain choice; keep Windows job |
| Physical device testing | UNKNOWN | None possible yet |

Do first in the Android round: owner picks package ID → add Android preset (landscape-only,
ETC2/ASTC) → platform-neutral input/touch layer feeding existing actions → `user://` storage
switch → stretch/safe-area pass → asset budget → API 36 + 16 KB qualification of the built APK.
