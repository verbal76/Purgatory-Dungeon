# ==============================================================================
# File Name: ota_config.gd
# Path: res://scripts/boot/ota_config.gd
#
# Description:
#   NATIVE LAYER (docs/OTA.md section 1). Installed with the APK and never replaced by an OTA
#   pack. Everything the bootstrap needs to decide what it may load lives here. Changing this
#   file (or anything under scripts/boot/) changes the installed runtime fingerprint: bump
#   RUNTIME_REVISION with `python3 tools/ota_runtime.py --bump` and ship a new APK.
# ==============================================================================
extends RefCounted

## Version of the on-device OTA bootstrap protocol. Manifests may demand a minimum.
const BOOTSTRAP_VERSION := 1
## Bumped whenever the native layer changes incompatibly (see ota/runtime_lock.json).
const RUNTIME_REVISION := 1
## The channel an installed app follows unless its native build info names another one
## (the "ota_channel" field written at APK build time). Channels are manifest pointers, not
## packages: a later "stable" channel is a second pointer, not a second code path.
const CHANNEL := "dev"
## !!! PLACEHOLDER !!! Where OTA releases are downloaded from (docs/OTA.md sections 6 and 14).
## The owner has NOT decided the release host (the source repository is private and devices
## download anonymously). Changing this value is a NATIVE change (new APK, runtime revision
## bump). It must match OTA_RELEASE_REPO in CI.
const REPO := "verbal76/Purgatory-Dungeon"
## Custom export feature that turns the OTA client on. Only the Android preset sets it.
const FEATURE := "ota"
## The only platform OTA packages are built for.
const PLATFORM := "android"

## !!! PLACEHOLDER PUBLIC KEY !!! The integrator pastes the real RSA-3072 public key here
## (`openssl rsa -pubout`). The matching private key lives outside the repository (CI key
## store). While this placeholder is in place no manifest can verify, so nothing is ever
## mounted: that is the safe failure. Tests inject their own keys through OtaCore's constructor.
const PUBLIC_KEY_PEM := """-----BEGIN PUBLIC KEY-----
PLACEHOLDER-REPLACE-WITH-THE-REAL-OTA-PUBLIC-KEY-BEFORE-THE-FIRST-OTA-APK
-----END PUBLIC KEY-----
"""

## Build identity file written into the APK by the build tooling (absent in dev runs).
const BUILD_INFO_PATH := "res://build_info.json"


static func engine_version() -> String:
	var v: Dictionary = Engine.get_version_info()
	return "%d.%d.%d" % [int(v["major"]), int(v["minor"]), int(v["patch"])]


## e.g. "android-godot-4.6.0-r1". Every OTA manifest must name exactly this.
static func runtime_id(platform: String = "") -> String:
	if platform == "":
		platform = OS.get_name().to_lower()
	return "%s-godot-%s-r%d" % [platform, engine_version(), RUNTIME_REVISION]


static func release_url(tag: String, asset: String) -> String:
	return "https://github.com/%s/releases/download/%s/%s" % [REPO, tag, asset]


static func channel_tag(channel: String = CHANNEL) -> String:
	return "ota-channel-%s" % channel


static func pointer_url(channel: String = CHANNEL) -> String:
	return release_url(channel_tag(channel), "latest.json")


## True for a channel name that is safe to put in a URL and a file name.
static func is_safe_channel(channel: String) -> bool:
	if channel.is_empty() or channel.length() > 32:
		return false
	for c in channel:
		if not "abcdefghijklmnopqrstuvwxyz0123456789-_".contains(c):
			return false
	return true


## The identity baked into this build: {} when res://build_info.json is absent or unreadable.
## Keys used by the client: commit (native baseline source SHA), runtime_fingerprint, runtime_id,
## ota_channel. Read once at boot, before any pack is mounted.
static func native_info() -> Dictionary:
	if not FileAccess.file_exists(BUILD_INFO_PATH):
		return {}
	var j: JSON = JSON.new()
	if j.parse(FileAccess.get_file_as_string(BUILD_INFO_PATH)) != OK:
		return {}
	return j.data as Dictionary if j.data is Dictionary else {}
