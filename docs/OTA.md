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

## Hosting: the public channel repository (least privilege)
Phones cannot read a private repository's releases (no login on the device), so updates are served from a
**dedicated public repository that contains nothing but update files**:

    https://raw.githubusercontent.com/verbal76/purgatory-dungeon-updates/main/      (baked into ota_channel.json)

- The Purgatory Dungeon **source repository stays private.** The channel repo holds only `channel.json`,
  `channel.json.sig` and `v<N>/<platform>/update-<K>/{manifest.json, manifest.sig, payload.pck}`, plus a short README.
  No source, no CI configuration, no signing material, no development artifacts. A payload contains the *changed
  game files in exported form* (compiled scripts, scenes, data, imported assets) and is useless without the signing
  key: a device refuses anything not signed by it. Manifests name the source commit hash (not its contents).
- The URL is part of the native build (`ota_channel.json` is APK-required) so no further APK is needed just to
  establish it. It is HTTPS only; plain http is honoured in test runs only.
- **CI access is one credential with one job.** `OTA_PUBLISH_TOKEN` (Actions secret in the private source repo) is a
  fine-grained personal access token whose repository access is *only* `verbal76/purgatory-dungeon-updates` and whose
  only permission is *Contents: read and write* (no other repositories, no admin, no workflows, no packages). It is
  referenced by exactly one job (`ota-publish` in `.github/workflows/ota.yml`), which only runs on a branch named
  `ota/v<N>/<K>`, pushes fast-forward only (no force, no tags) and never touches a GitHub Release. Give the token an
  expiry and rotate it. (A repository *deploy key* with write access is an equivalent single-repo alternative.)
- The private OTA signing key lives in the source repo's private draft release "OTA signing key (do not delete)"
  (or the Actions secret `OTA_SIGNING_KEY_PEM_BASE64`), never in the channel repo and never in logs.
- A git-hosted channel accepts at most 100 MB per file; CI refuses bundles with a payload above 95 MiB (ship that
  change as an APK, or move the channel to bucket hosting). The channel repo grows with every update; the owner can
  squash its history at any time (devices only ever read the latest `channel.json` and the update they need).

### One-time setup (owner actions; nothing here has been done)
1. Create the **public** repository `verbal76/purgatory-dungeon-updates` with a default branch `main` and a README that
   says only that it distributes signed update files for Purgatory Dungeon. Nothing else is committed by hand.
2. Create the fine-grained token described above and add it to the source repo as secret `OTA_PUBLISH_TOKEN`; add the
   repository variable `OTA_CHANNEL_REPO` = `verbal76/purgatory-dungeon-updates`. Until both exist the publish job is a
   dry run that uploads the bundle as a CI artifact and writes "NOTHING WAS PUBLISHED" to its summary.
3. (Optional, recommended) Add the Actions secret `OTA_SIGNING_KEY_PEM_BASE64` to hold the signing key outside the draft release.

## CI and release integration
- `.github/workflows/ci.yml`: job `ota-key` (serialised creation of the OTA signing key, the public half is handed on)
  and both build jobs write the public key to `ota_trust.pem` before export. `tools/verify_package.py` /
  `tools/verify_apk.py` fail a build that contains the OTA client but no trust anchor, contains key material, or
  (Android) does not declare the INTERNET permission.
- `.github/workflows/ota.yml`: `ota-validate` on every push (OTA unit tests, the end-to-end device simulation, an Android
  self-test of the chain, classification against the latest native tag) and `ota-publish` only for `ota/v<N>/<K>`.
- `tests/run_tests.sh` runs `tests/test_ota_client.gd` (150+ checks), `tests/test_mage_aim.gd` etc. and the python tool
  tests (`tests/test_ota_tools.py`).

## Procedures

### Decide: OTA or APK?
Run `python3 tools/ota/classify.py v<N> HEAD` against the native build the phone has installed (N = the number in the
footer). Exit 0 = OTA-safe, 10 = APK required (each offending path and rule is listed), 11 = guarded save/settings code
was touched (re-run with `--accept-guarded "<why a rollback still reads the saves>"` only if that is true).
Rules: "What ships OTA and what needs a new APK" above.

### Create
1. Land the change on a branch that descends from tag `v<N>`; CI (`ci.yml` / `ota.yml`) must be green on it.
2. Push a branch named `ota/v<N>/<K>` at that commit, where `K` is the next update number for `v<N>` (1 for the
   first; the tooling refuses a number that already exists and the client never goes backwards). This push *is* the
   publication request.

### Validate (automatic, before anything can be published)
`ota-validate` + `ota-publish` run: unit tests; the end-to-end device simulation; classification (APK-required aborts
the job); an export of the *base* pack from `v<N>` and a byte comparison with the pack inside the shipped Windows
zip / Android APK (import products only have to exist, everything else must match); `--export-patch` of the update
commit against it; manifest generation from the pack's own directory; RSA signature; `verify_bundle.py` (signature,
size/SHA-256, `files[]` against an independent PCK parser, compatibility fields, protected paths, channel
consistency and generation). Any failure stops the job with a message; nothing is pushed.

### Publish
If `OTA_CHANNEL_REPO` and `OTA_PUBLISH_TOKEN` exist, the job pushes the bundle (payload folders and `channel.json`
in one fast-forward commit) to the channel repository. Otherwise it stops after uploading the bundle as a CI artifact.
It never creates a tag or a GitHub Release and never changes "Latest".

### Apply (on the phone, automatic)
Main menu, about 15 s after launch and at most every 6 h: download -> verify -> stage as *pending* (footer: "update K
downloaded - restart to apply"). The next launch verifies again, backs up the saves, mounts it and shows "update K".
After the main menu has been up for 10 s the update is confirmed healthy and becomes the rollback target.

### Verify (what to look at)
- Main menu footer: `Purgatory Dungeon v<N> · update <K>`.
- `adb logcat -s godot` at startup prints `BuildInfo.diagnostics()`: native version, engine, base commit, OTA status,
  active/pending/known-good update, source commit and payload id of the update, last check and last error.
- CI: the `ota-publish` summary prints the channel generation and the update folders pushed.

### Recover / roll back
- Automatic: a bad file, signature, wrong build or failed mount -> the next launch runs the last known-good update or the
  native build. An update that never reaches a healthy menu is dropped after two launches.
- Kill switch (no phone access needed): `python3 tools/ota/channel.py revoke --out <channel checkout> --key <ota key>
  --native-version N --platform P --base-commit C --seq K`, then push the channel repo. Devices that fetch the new
  index stop using update K at their next launch and fall back to the previous known-good update or the native build.
  Publishing a *fixed* update K+1 is the normal follow-up. Replayed older indexes are refused (generation check).
- On the device: launch with `PURGATORY_NO_OTA=1` / `--no-ota` to skip OTA for that launch. Installing the next APK makes
  every older update unusable (different base commit) and it is deleted at the next start.
- Known limitation: `channel.json` has no expiry. A device that has never seen a revocation could be served an older
  signed index by an attacker who can break TLS to raw.githubusercontent.com. A future format version can add
  `expires_utc`; today the exposure is limited to re-offering an update that was once signed by us.

### Protocol notes found while building it
- `ProjectSettings.load_resource_pack()` returns true for a truncated pack, so size and SHA-256 are always checked first.
- Godot's importer is not byte-deterministic (about 14% of imported files differ between two imports of one commit), so
  the update build seeds the update tree with the base import cache; pack paths read `godot/...` because the project
  uses a visible project-data directory.
- Both `ota_trust.pem` and `ota_channel.json` are exported through `include_filter`; the client reads them from the base pack
  and they are protected paths, so an update can never replace the trust anchor or the endpoint.
