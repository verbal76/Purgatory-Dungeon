# Purgatory Dungeon over-the-air (OTA) updates (v7 architecture)

Status: **under construction on branch `v7-ota`. Nothing is published.** v6 is a shipped, protected baseline whose
dormant first-generation client is *replaced* (not extended) by this design. This file is the contract that the
native layer, the tooling and the CI follow; the "Evidence levels" section at the end says what is actually proven.

Reference architecture: the Hot Attic Games Godot OTA used by Mote (runtime lock, signed manifest, immutable releases,
channel pointer, staged activation, health-confirmed promotion, rollback). Purgatory Dungeon adopts its properties and
vocabulary and differs only where this game's size and packaging force it (see "Intentional differences").

## 0. Version identity (owner rule, authoritative)

**A new whole-number version requires a real new APK. An OTA never consumes the next whole number.**

| Version | Meaning |
|---|---|
| v6 | the published native APK (cannot receive this OTA format) |
| **v7** | the next REAL native APK, containing this OTA-capable runtime. `Purgatory-Dungeon-v7.apk` must exist for v7 to exist |
| v7.1, v7.2, ... | OTAs running on the v7 APK: owner-facing application-layer versions. No new APK, nothing to install |
| v8 | reserved for the next actual native APK (`Purgatory-Dungeon-v8.apk`); an OTA is never called v8 |

Three identities are kept apart everywhere (UI, diagnostics, manifests, release notes, reports):

1. **Native APK version** = `build_info.json` `public_version` (7), fixed by the installed APK.
2. **Owner-facing running version** = `7` on the bare baseline, `7.K` while OTA number K of this native generation is active.
3. **OTA update id** = `ota_id` (`dev-000001`), shown as `#000001`: an internal, channel-wide, forward-only sequence (`seq`).
   It is independent of K: K restarts at 1 for every new native generation, `seq` never does.
Plus the native **runtime id + fingerprint** (section 3). Every handoff states all four separately: NATIVE APK VERSION,
OWNER-FACING RUNNING VERSION, OTA UPDATE ID, NATIVE RUNTIME/FINGERPRINT.

The manifest carries `app_minor` (= K) and `game_version = "<native_version>.<app_minor>"`. The publisher assigns K from the live
pointer: previous pointer's `app_minor + 1` when the pointer's `native_version` equals this baseline's, otherwise `1`.
Nothing in this pipeline may create a release named `Purgatory Dungeon vN`, mark anything Latest or produce an APK: those belong
to the native release procedure (docs/RELEASES.md).

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

**Runtime ID** = `android-godot-<engine>-r<revision>` (e.g. `android-godot-4.6.0-r1`; r1 = v7 / v7.1 / v7.2, r2 = the post-v7.2 native generation that adds the Boot status API of section 10 and removes the player-facing overlay). **Runtime fingerprint** = the 64-hex value
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
  "game_version": "7.1", "app_minor": 1, "save_schema": 1, "min_save_schema": 1,
  "pck_url": "https://github.com/<host>/releases/download/ota-dev-000003/purgatory-dev-000003.pck",
  "pck_sha256": "<64-hex>", "pck_size": 123456, "created_at": "<UTC>",
  "build_run": {"id": "", "number": "", "attempt": "", "url": ""},
  "payload_kind": "patch", "base_source_sha": "<40-hex native baseline commit>", "platform": "android",
  "native_version": 7, "files": [{"path": "godot/...", "op": "add|replace|remove"}]
}
```
`app_minor` (whole number >= 1) is K of section 0; `game_version` = `<native_version>.<app_minor>` (two numeric parts); owner-facing name
"Purgatory Dungeon v7.1". `ota_id` = `<channel>-<seq:06d>` is the internal update id (`seq` is independent of `app_minor`). The client rejects a
manifest whose `game_version` is not exactly `<native_version>.<app_minor>`.
The signature is RSA-3072 PKCS#1 v1.5 over SHA-256 of the exact manifest bytes (`openssl dgst -sha256 -sign`), base64 on one
line in `manifest.json.sig`. The APK embeds only the public key (`scripts/boot/ota_config.gd`); the private key lives outside
the repository (CI key store: the private draft release "OTA signing key (do not delete)", or the Actions secret
`OTA_SIGNING_KEY_PEM_BASE64` which takes precedence). CI verifies the store's public key equals the embedded one before signing.

## 6. Distribution and channel

Transport = **this repository's own GitHub Releases, published with the automatic Actions token** (the established Hot Attic Games / Mote
pattern). The repository `verbal76/Purgatory-Dungeon` is **PUBLIC** (verified, see section 14), so its Releases are anonymously
readable and devices need no credential.

- Each OTA is an **immutable GitHub Release** `ota-<channel>-<seq:06d>` titled "Purgatory Dungeon v7.K (OTA #<seq:06d>)" holding
  `purgatory-<ota_id>.pck`, `manifest.json`, `manifest.json.sig`. It is **never marked Latest** (Latest is always the native release
  "Purgatory Dungeon vN" with the APK; Mote, which has no APK release, does mark its OTAs Latest: deliberate difference). It is never
  edited after publication; a tag that already exists aborts the job.
- The **channel pointer** is the mutable prerelease `ota-channel-<channel>` whose asset `latest.json` is
  `{channel, ota_id, seq, runtime_id, native_version, app_minor, manifest_url, signature_url, published_at}` (`native_version`/`app_minor`
  feed the next OTA's `app_minor`; clients tolerate extra keys). It only moves forward. Moving it is the
  moment an OTA becomes visible to devices.
- Pointer URL: `https://github.com/verbal76/Purgatory-Dungeon/releases/download/ota-channel-dev/latest.json`; OTA assets:
  `.../releases/download/ota-dev-<seq:06d>/<asset>`. The pointer is unsigned, so the client only follows URLs under the repository's
  `.../releases/download/` base and OTA tags; the manifest it points to is signed. GitHub 302-redirects asset downloads to its CDN; that hop is followed.
- The installed app follows the channel baked into `ota_config.gd` (`dev` for owner testing; a later `stable` is a second
  pointer, not a second code path). `REPO` in `ota_config.gd` must equal `GITHUB_REPOSITORY` in CI (the publish job refuses otherwise).

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

## 10. What players see, and diagnostics

**Players see no OTA or debug text over the game or the menus** (runtime r2 onwards; v7.x showed "v7.2 (dev-000002) ready: restart to run it" as a
toast, a staged-update note in the menu footer and a fixed readout button in Options > Gameplay). Specifically:
- The native layer never opens its overlay or a toast by itself: a finished download, a staged update or a failed check produce no on-screen text from
  `scripts/boot/`. The only transient native UI is the restrained "Applying update vX" panel while a never-run package starts (at most 20 s).
- The main menu footer is the Exit button over the plain version (`Purgatory Dungeon v7.2`), inside the phone safe area (`HudKit.insets`).
- **Options > About** (last tab; 5th on a phone) is where this information lives, built from `Boot.status_snapshot()` by `scripts/about_info.gd`:
  game version, app (native) version, the OTA label (`v7.2 (OTA #000002)` or "None (original v7)"), a "Waiting to start" row while an update is staged,
  the update status line, and technical rows (runtime id, shortened fingerprint, channel, engine, platform, last check).
  Status words: "You are up to date", "Update available - downloading...", "Update ready - restart to apply", "Checking for updates...", and calm
  failure lines (offline, could not be verified, needs a newer app, could not be completed) with no technical reason. On desktop: "Updates are
  delivered through the Android app." (no error, Check disabled).
- **Check for updates** calls `Boot.check_now()`: the *same* pipeline as the automatic check (pointer -> signed manifest -> signature, runtime
  fingerprint and save-schema checks -> download -> size + SHA-256 -> stage as PENDING). There is no second updater and no network code in the game layer
  (a test scans for it). Presses while a check runs are ignored. Nothing is applied mid-run: a staged update starts at the next cold start; About tells
  the player to close and reopen the game. (There is no separate "UpdateGate": staging + cold-start activation is the safe-apply path.)
- **Copy diagnostics** puts `AboutInfo.diagnostics_text()` on the clipboard: versions, update state and last error, runtime id + full fingerprint,
  channel, `Boot.diagnostics_text()` (slots, last results, recent events), device model/OS/GPU/renderer/screen/safe area/touch. No key material,
  tokens or file contents; the finished text goes through `AboutInfo.redact()` as a last line of defence.
- **Developer tools** (hidden): tapping the version heading in About seven times quickly toggles `DeveloperMode` (a setting; `SettingsManager`). They
  hold the performance readout (`ShowPerf`, previously a Gameplay option; a stored `ShowPerf=true` without DeveloperMode is ignored at load) and
  "Open update diagnostics". The native overlay also opens with F9, five quick taps in the top-left corner, or `--ota-diagnostics` (developer runs).

Native overlay and `Boot.diagnostics()` text. The first lines make the layers obvious:

```
Purgatory Dungeon v7.1
Native APK: v7
Application layer: v7.1            (v7 on the bare baseline)
OTA: #000001 (dev-000001)          (OTA: none (embedded baseline))
Runtime: android-godot-4.6.0-r1  fingerprint <64 hex>
```
followed by channel, embedded vs OTA, active OTA (id, seq, source SHA, package SHA-256), pending/ready/previous, status
(up to date / update available / downloaded / offline / incompatible / rejected), last check, last result, rollback count,
recent events. Buttons: Check, Download, Activate on restart, Roll back, Boot baseline / Re-enable OTA, Copy diagnostics, Close.
The main menu footer shows the owner-facing running version only: `Purgatory Dungeon v7` on the baseline, `Purgatory Dungeon v7.1` while OTA
7.1 runs (never "v7 · update K"); a staged OTA is not announced there any more (see About). No secrets are ever shown.

Public API for the game layer (`scripts/boot/boot.gd`, all secret-free, all degrade to "inactive" when the client is off): `status_snapshot()`
(identity, runtime, channel, staged version, last error ...), `update_state()` (`inactive | disabled | unchecked | checking | downloading |
up_to_date | pending_restart | downloaded | offline | incompatible | rejected | failed`), `can_check_now()`, `check_now()` (awaitable; returns the
final state, or `busy`/`inactive`/`disabled` when nothing started), `last_error()`, `diagnostics_text()`, `show_diagnostics()`, signal
`status_changed`. `tests/test_ota_core.gd` (section 13b) covers it against the loopback stub; `tests/test_about.gd` covers the screen.

## 11. Publishing (`.github/workflows/ota-publish.yml`)

Authorization is explicit: the workflow runs only for a pushed branch named `ota/<channel>/<full 40-hex sha>` whose head commit
**is** that SHA (a moving target cannot publish). In order: pin the exact SHA; **public-repository gate** (an anonymous API read of
`$GITHUB_REPOSITORY` must say `private: false`, and the repository must equal `REPO` in `ota_config.gd`); resolve identity; classify
against the native baseline (APK-required => stop); runtime gate (`ota_runtime.py --check` and fingerprint == the baseline's); run the
full test suite on that SHA; build the baseline pack and compare it with the shipped native build; export the patch; assign `app_minor`
from the live pointer; build the manifest; sign (after the key-match check); inspect with the client's own verification code; allowlist
and secret-scan the files; create the immutable release; re-download the published artifacts and verify them again anonymously; **only
then** advance the pointer (forward only) and confirm the live pointer serves the intended OTA (cache-busted polling); write a receipt
(source SHA, runtime, OTA id, hashes, URLs, native version, `app_minor`, owner-facing version, `anonymous_read_verified`, `published`,
`pointer_moved`). Any failure before the pointer moves leaves nothing new live for devices. A missing signing key, or a repository that is
not public, ends in a receipt with `published: false` and the reason.
Permissions: top level `contents: read`; only the publishing job has `contents: write`, and the only credential is GitHub's automatic
`${{ github.token }}` (no PAT, no extra secret besides the optional signing-key secret).

## 12. Intentional differences from Mote

1. Patch pack against the embedded baseline instead of a full pack (size).
2. Android only; client gated by the `ota` export feature.
3. Manifest adds `runtime_fingerprint`, `payload_kind`, `base_source_sha`, `platform`, `native_version`, `files`; the runtime ID
   is accompanied by a content fingerprint that the device also checks.
4. Publication is triggered by an explicit SHA-named branch, not by pushes to a development branch.
5. Same transport as Mote (own-repository Releases, automatic token) with two deliberate differences: OTA releases are never marked
   Latest (the native APK release owns Latest) and are titled "Purgatory Dungeon v7.K (OTA #seq)".
6. Signing private key custody: CI key store/secret, not committed.

## 13. v6 -> v7 and recovery of the shipped baseline

v6 (`release/v6`, `a9168e1`), v5 and the validated checkpoint are never modified. v7 is a new, real APK built from this branch (VERSION 7
at its release commit); v7.1 is the first OTA after it. Rolling back the *app* means installing the v6 APK over v7 only if the version code is allowed to go down,
which Android refuses; the supported rollback of an OTA is the in-app rollback to PREVIOUS / embedded baseline.

## 14. Repository visibility and trust boundary

**Repository visibility (verified 2026-10-06): `verbal76/Purgatory-Dungeon` is PUBLIC.** Earlier work in this branch briefly assumed it
was private and designed a Pages / second-repository transport around that; that was wrong and was removed. Do not assume visibility:
check it (`curl -s https://api.github.com/repos/verbal76/Purgatory-Dungeon` must show `"private": false`; the publish workflow runs this
exact anonymous check and refuses to publish otherwise). If the repository is ever made private, OTA delivery to devices stops working
(release downloads would need credentials) and the transport must be redesigned before the next OTA.

Because the repository is public, never commit keys, keystores, credentials or private artifacts (the signing keys live in private draft
releases / Actions secrets, which are not public). The OTA host is the repository's Releases: signed update files only.

Trust does **not** come from the host. A device accepts an update only if (1) the manifest signature verifies with the RSA public
key compiled into the APK, (2) `runtime_id` + `runtime_fingerprint` + base commit match exactly, (3) the package size and SHA-256
match, (4) the boundary rules hold (no protected path), and (5) it was not blacklisted. A compromised host can therefore withhold
updates but cannot make a device run anything the private signing key did not sign.

Write access: the publish workflow uses GitHub's automatically provided `GITHUB_TOKEN` with `contents: write` on the publishing job only.
There is no personal access token, no second repository, no Pages deployment and no credential on the device. Reads need no credential
at all, and the workflow verifies exactly that (anonymous reads) before it moves the pointer.

## 15. Evidence levels (updated as work lands)

Levels: implemented / unit-tested / integration-e2e-tested (local server, real packaged game on desktop) / CI-proven /
emulator-proven / physical-device-proven. Physical-device proof is claimed only after the owner tests.

State at branch `v7-ota` head `17d29c1` (2026-10-06); nothing is published:

| Property | Level |
|---|---|
| Manifest validation, signature, hash/size, runtime id + fingerprint, base commit, boundary rules, `app_minor`/`game_version`, URL anchoring | unit-tested (`tests/test_ota_core`, 592 checks) |
| State machine: stage, activate, health promotion, rollback, blacklist, crash-loop abandonment, save backup/schema guard, diagnostics/footer wording | unit-tested + integration-e2e-tested |
| Real packaged game, real RSA-3072 signature, real PCK patch, local server mirroring the Releases layout (incl. 302 CDN hop, stale pointer, truncated/hanging/wrong-hash downloads, foreign hosts, tampered manifests): 221 checks, 0 failures | integration-e2e-tested (desktop, Windows preset) |
| Save slots byte-identical through every OTA scenario | integration-e2e-tested |
| Publisher gates (public-repo, REPO == repo, next seq / `app_minor`, forward-only pointer, immutability, allowlist, secret scan, anonymous verification, receipt) and workflow static properties (token scope, trigger, no Latest) | unit-tested; workflow never executed on GitHub |
| Android APK builds, passes `verify_apk` (INTERNET permission, runtime identity fields, no legacy OTA files), Windows export + package verification, full headless suite | CI-proven (PR #6, runs 56-58) |
| First real publication: `ota/dev/6dd77be…` -> immutable release `ota-dev-000001` ("Purgatory Dungeon v7.1 (OTA #000001)", not Latest), pointer `ota-channel-dev`, receipt; anonymous re-download of manifest, signature and pack (size + SHA-256 + signature with the compiled-in public key verified independently) | CI-proven (OTA publish run 37463060653, 2026-10-06) |
| Redirect of release downloads to the objects CDN as seen by a phone, device mount/health/rollback of the real v7.1 on Android | NOT proven (physical device pending) |
| Real Android file layout, `user://` pack mounting, HTTPS from a phone, touch-drag in the overlay, the "Applying update" panel | NOT proven (emulator / physical device pending) |
