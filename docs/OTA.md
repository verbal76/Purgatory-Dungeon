# Purgatory Dungeon over-the-air (OTA) updates

Status: **infrastructure only. No OTA has been published.** The first OTA needs the owner's
authorization (see "Publishing the first OTA"). v5 is the rollback baseline and is untouched.

## Why this design (Godot facts that drove it)
- A Godot game is a native engine binary plus one data pack (`.pck`) of scripts, scenes, data and imported
  assets. Almost all day-to-day changes live in the pack. The engine, Android manifest/permissions,
  package ID, signing key and `project.godot` settings do not.
- `ProjectSettings.load_resource_pack(path, replace_files=true)` overlays a patch pack on the running base
  pack. Verified on Godot 4.6 (see `tests/test_ota_*`, `tools/ota/`): a patch mounted from the **first
  autoload's `_init()`** overrides scripts, scenes and data seen by every later autoload and by the main
  scene. Nothing after the first autoload has to know OTA exists.
- `godot --export-patch <preset> <out.pck> --patches <base.pck>` writes a pack holding only files that changed
  versus the base (plus removal markers). Each update is therefore **cumulative against the native build**,
  not a chain of deltas: the newest valid update is the only one that is ever mounted, and no update depends
  on another having been applied.
- `load_resource_pack` returns `true` for a truncated patch file (observed). Success of the call proves
  nothing, so the client verifies size, SHA-256 and an RSA signature **before** it mounts anything.
- A pack is mounted once, at process start. There is never a mixed old/new state inside a running session.

## Vocabulary
| Term | Meaning |
|---|---|
| Native build | The installed APK (or the Windows exe + pck): public number `N` (`./VERSION`; Android versionCode = N), Godot engine build, package ID, signing key, manifest, `project.godot` settings, the OTA client itself. Changing any of these means a new APK = a new public number. |
| Base commit | The 40-hex source commit the native build was made from (`build_info.json` `commit`). |
| Update (payload) | A signed cumulative patch pack for **exactly one** (native `N`, platform, base commit). Numbered `seq = 1, 2, 3...` per base. Publicly: "Purgatory Dungeon v5 update 2". |
| Channel | A static HTTPS directory holding `channel.json` (+ signature) and the update folders. |
| Trust anchor | The OTA public key (`ota_trust.pem`), written into every CI build; the matching private key never leaves CI. |

(Public naming: owner-visible builds are still only "Purgatory Dungeon vN". An OTA is "vN update K" and is never
a new `vN`; see docs/RELEASES.md.)

## Formats (version 1)

### `manifest.json` (signed)
```
{ "format": 1, "product": "purgatory-dungeon", "platform": "android" | "windows",
  "native_version": 5, "base_commit": "<40 hex>", "engine": "4.6.stable.official.89cea1439", "ota_api": 1,
  "payload_seq": 2, "label": "Purgatory Dungeon v5 update 2",
  "source_commit": "<40 hex of the update source>", "created_utc": "2026-10-05T19:00:00Z",
  "payload": { "file": "payload.pck", "size": 123456, "sha256": "<64 hex>" },
  "files": [ { "path": "scripts/foo.gdc", "op": "replace" | "add" | "remove" } ] }
```
`files` is generated from the pack's own directory by the builder (and re-verified by an independent parser);
the client enforces the protected-path rule against it before mounting.
`manifest.sig` = base64 of `openssl dgst -sha256 -sign ota.key manifest.json` (RSA-3072, PKCS#1 v1.5, SHA-256).
Godot checks it with `Crypto.verify()` against the embedded public key.

### `channel.json` (signed, `channel.json.sig`)
```
{ "format": 1, "product": "purgatory-dungeon", "generation": 7, "generated_utc": "...",
  "updates": [ { "native_version": 5, "platform": "android", "base_commit": "...", "seq": 2,
                 "manifest": "v5/android/update-2/manifest.json",
                 "signature": "v5/android/update-2/manifest.sig",
                 "payload": "v5/android/update-2/payload.pck" } ],
  "revoked": [ { "native_version": 5, "platform": "android", "base_commit": "...", "seq": 2 } ] }
```
`generation` only goes up; the client remembers the highest one it saw and refuses an older (replayed) index.
`revoked` is the remote kill switch (see rollback).

### On-device layout (`user://ota/`, never the save folder)
```
state.json                     {active, pending, known_good, boot_attempts, failed[], revoked[], generation, last_*}
slots/<seq>/{manifest.json, manifest.sig, payload.pck}
staging/                       downloads in flight (deleted at every start)
quarantine/<seq>-<reason>/     slots that failed verification or crash-looped (kept for diagnosis, size-capped)
backups/seq-<k>-<utc>/         copy of saves + settings taken before an update is first activated (last 3 kept)
```

## What ships OTA and what needs a new APK
Single source of truth: `tools/ota/ota_rules.json`, enforced by `tools/ota/classify.py` (CI) and again by the
client (protected paths) before it mounts a payload.

**OTA-safe** (replaceable files inside the pack): GDScript, scenes, resources, shaders, data JSON/TXT, UI themes,
audio, textures, models, dungeon modules, fonts, translations.

**APK-required** (never OTA): anything outside the pack or read before it is mounted:
`project.godot` / `project.binary` (autoloads, input map, rendering, display, physics), `export_presets.cfg`,
the Android manifest/gradle/permissions/target SDK/ABIs/icons, version numbers, the signing identity,
`addons/**` native code (`*.gdextension`, `*.so`, `*.dll`, `*.dylib`), the Godot engine version, the OTA client
itself (`scripts/ota/**`), `ota_trust.pem`, `ota_channel.json`, `build_info.json`, `VERSION`.

**Guarded** (OTA only with `--accept-guarded` and a stated reason, because a rollback must still read saves written
by the update): save/profile/settings code (`save_manager.gd`, `storage_paths.gd`, `SettingsManager.gd`).

A change set that touches any APK-required path is not an OTA; it ships as the next numbered APK.

## Compatibility rules
A device applies update `U` only if **all** hold, checked at download time and again at every boot:
1. `U.manifest.signature` verifies against the embedded trust anchor and `sha256(manifest.json)` equals the slot id.
2. `format == 1`, `product == purgatory-dungeon`, `ota_api == the client's OTA_API`.
3. `platform` equals the device's; `native_version` equals the installed public number; `base_commit` equals the
   installed `build_info.json` commit; `engine` equals the running engine build string.
4. `payload.size` and `payload.sha256` match the file on disk, and `payload.size <= 512 MiB`.
5. No entry in `files` is a protected path (above), none escapes `res://` (`..`, absolute, `user://`).
6. `seq` is not in `failed[]`/`revoked[]`, and is higher than the active update.
Anything else (unknown format, wrong base, missing key, bad signature) is **ignored and the game runs as the
native build**. The client never downgrades, never guesses, never mounts "close enough".
`OTA_API` is bumped only when the client contract itself changes (and that change ships as an APK).

## Failure and rollback behaviour
Principle: **an update can only ever make the next launch fall back to something that already worked.**
- *Unavailable / corrupt / interrupted download*: staged in `staging/`, verified fully, then moved into `slots/`
  atomically. A partial file is never visible to the boot path. No network = no effect on the game.
- *Verification failure at boot*: slot moved to `quarantine/`, seq added to `failed[]`, the boot continues with
  the last known-good update if there is one, otherwise the native build.
- *Crash loop guard*: `boot_attempts` is persisted **before** the pack is mounted. The game confirms health
  (`known_good = seq`, attempts = 0) only after it has reached the main menu and stayed up 10 s. If an
  unconfirmed update has been tried twice without confirming, the third launch quarantines it and falls back.
  This covers parse errors, startup crashes and native crashes.
- *Mount failure*: `load_resource_pack` returning false quarantines the slot the same way.
- *Remote kill switch*: publishing a new `channel.json` that lists `{seq}` under `revoked` makes every device
  that sees it stop using that update at the next launch and fall back to the previous known-good update or the
  native build. Needs no APK and no cooperation from the update itself.
- *Manual recovery*: `--no-ota` on the command line or `PURGATORY_NO_OTA=1` skips every OTA step for that launch;
  installing the next APK (or reinstalling the same one) leaves old updates unusable (base commit differs) and they
  are deleted at the next start. Uninstalling removes everything, including saves.
- A bad update that does not crash (wrong behaviour) is handled by the kill switch; the device-visible update
  number in the footer tells you which one it is running.

## Save and data protection
- OTA code touches only `user://ota/`. It never writes the save folder (`PurgetoryDungeon/`) or `settings.json`.
- Before an update is activated for the first time the client copies the save folder and settings to
  `ota/backups/` (last 3 kept). Tests assert saves are byte-identical across stage, activate, fail and rollback.
- Update code that changes save shape is *guarded* (above) and must stay readable by the previous code.

## Device-visible diagnostics
- Main menu footer: `Purgatory Dungeon v5` (native build) and, when an update is running, `· update 2`. A pending
  update shows `· update 3 downloaded - restart to apply`; a fallback shows `· update 2 rolled back`.
- `BuildInfo.diagnostics()` (also printed at startup and visible with `adb logcat -s godot`) adds:
  native version, engine, platform, base commit, OTA API, trust-anchor present, channel configured, OTA status
  (`none | active | pending | rolled_back:<reason> | disabled:<reason>`), active/pending/known-good seq, update
  source commit, short payload id, boot attempts, last check time and last error.

## CI and release integration
See "Procedures" below. `tools/ota/classify.py` runs on every push (job `ota-validate` in
`.github/workflows/ota.yml`) and the OTA tests are part of `tests/run_tests.sh`.

## Procedures
(Filled in by `docs/OTA.md` sections below as the tooling lands: create, validate, publish, apply, verify, recover.)
