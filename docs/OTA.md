# Purgatory Dungeon over-the-air (OTA) updates (v7 architecture)

Status: **under construction on branch `v7-ota`. Nothing is published.** v6 is a shipped, protected baseline whose
dormant first-generation client is *replaced* (not extended) by this design. This file is the contract that the
native layer, the tooling and the CI follow; the "Evidence levels" section at the end says what is actually proven.

Reference architecture: the Hot Attic Games Godot OTA used by Mote (runtime lock, signed manifest, immutable releases,
channel pointer, staged activation, health-confirmed promotion, rollback). Purgatory Dungeon adopts its properties and
vocabulary and differs only where this game's size and packaging force it (see "Intentional differences").

## 1. Layers

| Layer | Contents | Changes by |
|---|---|---|
| **Native shell** (APK) | Godot 4.6 engine/template, Android manifest + permissions (incl. INTERNET), export presets, `project.godot` (autoloads, input map, settings), the OTA bootstrap `scripts/boot/*`, the embedded baseline game, signing identity | **new APK only** |
| **Game layer** (OTA patch) | everything else under `res://`: GDScript, scenes, UI, art, audio, data, fonts, dungeon modules, saves-schema constants, `BuildInfo` | **OTA** |

Godot does not reload project settings from a pack and the bootstrap is loaded before any pack is mounted, so changes to
native-shell files would silently do nothing over OTA. CI therefore refuses to publish them (section 3).

OTA is **Android only**. The OTA client is switched on by the custom export feature `ota`, set only in the Android preset.
Windows builds contain the (inert) bootstrap and never contact a channel.

## 2. Single authoritative mechanism

v6 shipped a first-generation client (`scripts/ota/*`, autoloads `OtaBoot` + `OtaUpdater`, `ota_trust.pem`,
`ota_channel.json`, CI job `ota-key`, `tools/ota/{make_bundle,channel,verify_bundle}.py`). It points at an address that
does not exist and cannot be reached by the new format. **v7 removes all of it.** After this branch there is one OTA
mechanism: `scripts/boot/*` + `ota/*` + `tools/ota_*` + `.github/workflows/ota-publish.yml`. v6 installs never receive an
OTA; they are upgraded by installing the v7 APK (same package ID and signing key, so saves are kept).

## 3. Native boundary and runtime identity

`ota/boundary.json` is the single machine-readable definition. It lists:
- `native_inputs`: the files whose bytes define the installed runtime: `project.godot`, `export_presets.cfg`,
  `scripts/boot/*.gd`, `tools/android/build_apk.sh`, and the engine version (the `GODOT_RELEASE` value in
  `.github/workflows/ci.yml`). There are no native plugins or extensions in the repository; if one is ever added its
  libraries and `.gdextension` files join this list.
- `payload_protected`: `exact` / `prefixes` / `suffixes` of pack paths that may never appear in an OTA payload
  (`project.godot`, `project.binary`, `export_presets.cfg`, `scripts/boot/`, `android/`, `*.gdextension`, `*.so`, `*.dll`,
  `*.dylib`, `build_info.json`, `VERSION`, the godot extension list ...).
- `guarded`: save/profile/settings code, OTA-able only with an explicit, recorded waiver.
- `not_shipped`: paths that are never exported (tests, tools, docs ...).

`tools/ota_runtime.py` computes the **runtime fingerprint** = SHA-256 over the engine version and the bytes of every
`native_inputs` file (the `RUNTIME_REVISION` constant is normalised out of its own file, as in Mote). `ota/runtime_lock.json`
records `{runtime_revision, godot_version, fingerprint, files}` and is committed.
- `--check` (CI gate, also run by `tests/run_tests.sh`): fails if the native inputs changed without `--bump`.
- `--bump`: increments `RUNTIME_REVISION` and relocks (a new APK is then required).
- `--print`: shows `runtime_id` and fingerprint.

**Runtime ID** = `android-godot-<engine>-r<revision>` (e.g. `android-godot-4.6.0-r1`). **Runtime fingerprint** = the 64-hex value
above. Both are:
- compiled into the APK's build identity: `build_info.json` gains `runtime_id`, `runtime_fingerprint`, `ota_channel`,
  and (existing) `commit` = the native baseline source SHA;
- named in every OTA manifest;
- shown in diagnostics.

Ordinary game-layer content does not touch any native input, so it never changes the identity. The device refuses an OTA
unless `runtime_id` **and** `runtime_fingerprint` match exactly; the publisher refuses to build an OTA unless the
fingerprint of the commit being published equals the fingerprint recorded for the installed baseline.

## 4. Payload

A **cumulative patch pack** (`.pck`) produced by `godot --export-patch "Android" <out> --patches <baseline.pck>`, where the
baseline pack is rebuilt from the exact native source commit (`base_source_sha`) and byte-compared (import products
excepted) with the shipped APK. It contains only game-layer files that differ from the embedded baseline plus removal
markers. Each OTA supersedes all earlier ones for the same baseline: the device only ever mounts one, and never needs a
chain. (A full-pack OTA, as Mote ships, would be ~600 MB for this game.) The pack path layout is `godot/...` because the
project exports with a visible data directory.

Protected-path rule: the pack's file list must contain no `payload_protected` path (checked by the publisher with an
independent PCK parser and again by the client before mounting). A change set that touches the native boundary is
**APK-required**; CI reports it as such and publishes nothing.

## 5. Manifest (schema 1, Mote-compatible plus PD fields)

```json
{
  "schema": 1, "channel": "dev", "ota_id": "dev-000003", "seq": 3,
  "source_sha": "<40-hex commit that produced the patch>",
  "runtime_id": "android-godot-4.6.0-r1", "runtime_fingerprint": "<64-hex>",
  "minimum_bootstrap_version": 1,
  "game_version": "7.3.0", "save_schema": 1, "min_save_schema": 1,
  "pck_url": "https://github.com/<host>/releases/download/ota-dev-000003/purgatory-dev-000003.pck",
  "pck_sha256": "<64-hex>", "pck_size": 123456, "created_at": "<UTC>",
  "build_run": {"id": "", "number": "", "attempt": "", "url": ""},
  "payload_kind": "patch", "base_source_sha": "<40-hex native baseline commit>", "platform": "android",
  "native_version": 7, "files": [{"path": "godot/...", "op": "add|replace|remove"}]
}
```
`game_version` = `<native_version>.<seq>.0`. Public name: "Purgatory Dungeon v7 · update 3". `ota_id` = `<channel>-<seq:06d>`.
The signature is RSA-3072 PKCS#1 v1.5 over SHA-256 of the exact manifest bytes (`openssl dgst -sha256 -sign`), base64 on one
line in `manifest.json.sig`. The APK embeds only the public key (`scripts/boot/ota_config.gd`); the private key lives outside
the repository (CI key store: the private draft release "OTA signing key (do not delete)", or the Actions secret
`OTA_SIGNING_KEY_PEM_BASE64` which takes precedence). CI verifies the store's public key equals the embedded one before signing.

## 6. Distribution and channel

- Each OTA is an **immutable GitHub Release** `ota-<channel>-<seq:06d>` holding `purgatory-<ota_id>.pck`, `manifest.json`,
  `manifest.json.sig`. It is never edited after publication; a tag that already exists aborts the job.
- The **channel pointer** is the mutable release `ota-channel-<channel>` whose asset `latest.json` is
  `{channel, ota_id, seq, runtime_id, manifest_url, signature_url, published_at}`. It only moves forward. Moving it is the
  moment an OTA becomes visible to devices.
- The installed app follows the channel baked into `ota_config.gd` (`dev` for owner testing; a later `stable` is a second
  pointer, not a second code path).
- **The release host is a configuration value (`REPO` in `ota_config.gd`, `OTA_RELEASE_REPO` in CI).** Devices download
  anonymously, so the host repository's releases must be publicly readable. The source repository is private: this is the one
  open owner decision (section 14). Until it is decided the pipeline is complete and proven against a local server that mirrors
  the Releases layout, and the publish job refuses to advance a pointer that is not anonymously reachable.

## 7. Client behaviour (native layer, `scripts/boot/`)

- Autoload #1 `Boot` runs before any game-layer script. If the `ota` feature is absent (Windows, editor) it does nothing.
- **Cold start, no network:** choose PENDING, else CURRENT, else PREVIOUS; verify (stored signed manifest, runtime ID +
  fingerprint, channel, size, SHA-256); count the start; `load_resource_pack(path, true)`; otherwise run the embedded baseline.
  The game **never needs a connection to start.**
- **Check policy:** after the game reports ready and has run a few seconds (boot health), then on return to the foreground if
  the last attempt was >= 15 min ago, then hourly while running; failed attempts count. Requests are polled from the main loop,
  not threaded; 15 s timeout for the pointer and manifest, 15 min for the package.
- **Download** goes to `.incoming-<id>.pck`; the manifest signature, compatibility and `pck_size` are checked first, the
  package size cap is `pck_size + 1`, SHA-256 is checked on completion, and only then is the file promoted (rename) and the
  signed manifest stored. A partial or failed download is deleted; nothing active changes.
- **Activation** only at cold start (never mid-run). When a never-before-run package is being activated the native layer shows a
  restrained "Applying update" panel until the game reports ready.
- **Health:** `Boot.report_ready()` is called by the main menu when it is built; `report_ready + 5 s` running = boot healthy. Only
  then does PENDING become CURRENT (the old CURRENT becomes PREVIOUS).

## 8. State machine (device, `user://ota/state.json`)

`EMBEDDED BASELINE` (always available) / `CURRENT` known-good / `PENDING` staged candidate / `PREVIOUS` known-good / `READY`
(downloaded, not yet pending) / `bad[]` failed-or-blacklisted ids. Plus boot attempts/health, rollback count, disabled flag
and last results. Written atomically (temp + rename). A corrupt state file falls back to the baseline.

Rules: an unconfirmed OTA gets two starts (the attempt is persisted *before* mounting, so a crash during load counts); the
third start abandons and blacklists it and falls back (PREVIOUS, else baseline). A pack that fails to mount, a stored package
that fails re-verification, or a runtime mismatch is dropped in the same boot. A SHA-256 mismatch on a full-size download is
blacklisted (published packages are immutable). A blacklisted id is never downloaded again. Manual rollback and "boot baseline" /
"re-enable OTA" actions exist in the diagnostics overlay and as `--ota-action=` args. No network is needed to recover.

## 9. Saves

OTA state is under `user://ota/`; the save folder and `settings.json` are never written by OTA. Before a never-run package is
first activated the client copies the save folder to `user://ota/backups/` (last 3 kept). `scripts/save_schema.gd` (game layer)
defines `SAVE_SCHEMA` / `MIN_SAVE_SCHEMA`; manifests carry both and the client will not activate an OTA that cannot read the
schema recorded on the device (this protects rollbacks past a deliberate migration). Save formats are unchanged in v7.

## 10. Diagnostics

Native overlay (five quick taps in the top-left corner, or F9) and `Boot.diagnostics()` text: native version, runtime ID +
fingerprint, channel, embedded vs OTA, active OTA (id, seq, source SHA, package SHA-256), pending/ready/previous, status
(up to date / update available / downloaded / offline / incompatible / rejected), last check, last result, rollback count,
recent events. Buttons: Check, Download, Activate on restart, Roll back, Boot baseline / Re-enable OTA, Copy diagnostics, Close.
The main menu footer shows `Purgatory Dungeon v7` and `· update N`. No secrets are ever shown.

## 11. Publishing (`.github/workflows/ota-publish.yml`)

Authorization is explicit: the workflow runs only for a pushed branch named `ota/<channel>/<full 40-hex sha>` whose head commit
**is** that SHA (a moving target cannot publish). In order: pin the exact SHA; resolve identity; classify against the native
baseline (APK-required => stop); runtime gate (`ota_runtime.py --check` and fingerprint == the baseline's); run the full test
suite on that SHA; build the baseline pack and compare it with the shipped native build; export the patch; build the manifest;
sign (after the key-match check); inspect with the client's own verification code; create the immutable release; re-download the
published artifacts and verify them again; verify they are anonymously reachable; **only then** advance the pointer (forward only)
and confirm the live pointer serves the intended OTA; write a receipt (source SHA, runtime, OTA id, hashes, URLs, `published`,
`pointer_moved`). Any failure before the pointer moves leaves nothing new live. A missing signing key or unconfigured host ends in
a receipt with `published: false`.

## 12. Intentional differences from Mote

1. Patch pack against the embedded baseline instead of a full pack (size).
2. Android only; client gated by the `ota` export feature.
3. Manifest adds `runtime_fingerprint`, `payload_kind`, `base_source_sha`, `platform`, `native_version`, `files`; the runtime ID
   is accompanied by a content fingerprint that the device also checks.
4. Publication is triggered by an explicit SHA-named branch, not by pushes to a development branch.
5. The release host may be a different repository from the (private) source repository.
6. Signing private key custody: CI key store/secret, not committed.

## 13. v6 -> v7 and recovery of the shipped baseline

v6 (`release/v6`, `a9168e1`), v5 and the validated checkpoint are never modified. v7 is a new APK built from this branch (VERSION 7
at its release commit). Rolling back the *app* means installing the v6 APK over v7 only if the version code is allowed to go down,
which Android refuses; the supported rollback of an OTA is the in-app rollback to PREVIOUS / embedded baseline.

## 14. Open owner decision

Where phones download releases from while the source repository stays private (see section 6). Nothing in this branch creates a
repository, requests a credential or changes visibility.

## 15. Evidence levels (updated as work lands)

Levels: implemented / unit-tested / integration-e2e-tested (local server, real packaged game on desktop) / CI-proven /
emulator-proven / physical-device-proven. Physical-device proof is claimed only after the owner tests.
