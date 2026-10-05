# ==============================================================================
# File Name: ota_const.gd
# Path: res://scripts/ota/ota_const.gd
#
# Description:
#   Constants of the OTA client (see docs/OTA.md). The protected-path lists mirror
#   tools/ota/ota_rules.json; tests/test_ota_client.gd fails if the two drift apart.
#   This file is part of the OTA client itself, so it is APK-required (never OTA).
# ==============================================================================
class_name OtaConst
extends RefCounted

const OTA_API := 1                       # the client contract; bumped only with an APK
const FORMAT := 1
const PRODUCT := "purgatory-dungeon"
const MAX_PAYLOAD_BYTES := 512 * 1024 * 1024
const MAX_META_BYTES := 1024 * 1024      # manifest / channel / signature documents
const MAX_BOOT_ATTEMPTS := 2             # launches an unconfirmed update gets before it is quarantined
const HEALTHY_AFTER_SEC := 10.0          # main menu reached and still running -> the update is confirmed good
const CHECK_DELAY_SEC := 15.0            # first channel check after launch (main menu only, never mid-run)
const CHECK_INTERVAL_SEC := 6 * 3600     # minimum time between channel checks
const HTTP_TIMEOUT_SEC := 30.0
const KEEP_BACKUPS := 3
const KEEP_QUARANTINE := 3

const TRUST_PATH := "res://ota_trust.pem"
const CHANNEL_CONFIG_PATH := "res://ota_channel.json"
const SPLASH_SCENE := "res://scenes/StudioSplash.tscn"

# Developer / test hooks. Honoured ONLY in non-template builds (editor / test runs), never in a shipped game.
const ENV_ROOT := "PURGATORY_OTA_ROOT"
const ENV_CHANNEL := "PURGATORY_OTA_CHANNEL_URL"
const ENV_PLATFORM := "PURGATORY_OTA_PLATFORM"   # lets a Linux CI host act as "android" / "windows"
# Honoured everywhere: an escape hatch for the player / adb (skip every OTA step for this launch).
const ENV_DISABLE := "PURGATORY_NO_OTA"
const ARG_DISABLE := "--no-ota"

# Paths that can never arrive by OTA (see docs/OTA.md "What ships OTA").
const PROTECTED_EXACT: Array[String] = [
	"project.godot", "project.binary", "export_presets.cfg", "ota_trust.pem", "ota_channel.json",
	"build_info.json", "VERSION", ".godot/extension_list.cfg",
]
const PROTECTED_PREFIXES: Array[String] = ["scripts/ota/", "android/"]
const PROTECTED_SUFFIXES: Array[String] = [".gdextension", ".so", ".dll", ".dylib"]
