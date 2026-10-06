# ==============================================================================
# File Name: build_info.gd
# Path: res://scripts/build_info.gd
#
# Description:
#   What build is this? The PUBLIC version ("Purgatory Dungeon v2") comes from the single
#   VERSION file, mirrored into project.godot (application/config/version) and checked by
#   tools/release_tool.py. Engineering details (source commit, CI run, build time) come
#   from res://build_info.json, which CI generates and ships inside the game; it does not
#   exist when running from the editor.
#
#   A build is only labelled as the release "vN" when CI built it from tag vN. Any other
#   build says so explicitly ("development build after vN") so it can never be mistaken
#   for a delivered version.
# ==============================================================================
class_name BuildInfo
extends RefCounted

const PRODUCT_NAME := "Purgatory Dungeon"
const INFO_PATH := "res://build_info.json"


static func public_version() -> int:
	return int(str(ProjectSettings.get_setting("application/config/version", "0")))


static func _info() -> Dictionary:
	if not FileAccess.file_exists(INFO_PATH):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(INFO_PATH))
	return parsed if parsed is Dictionary else {}


## True only for a build CI made from tag v<VERSION>.
static func is_release_build() -> bool:
	var info := _info()
	return bool(info.get("release", false)) and int(info.get("public_version", -1)) == public_version()


static func commit() -> String:
	return str(_info().get("commit", ""))


static func short_commit() -> String:
	return commit().left(7)


## The native OTA client (autoload `Boot`, scripts/boot/): null when it is not loaded (tools, tests that run without autoloads).
static func _boot() -> Node:
	var loop: MainLoop = Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("Boot")
	return null


## The owner-facing running version: "7" on the baseline, "7.1" while OTA v7.1 runs (Boot.running_version()).
## Never the OTA id or sequence. Falls back to the native version when the OTA client is not loaded.
static func running_version() -> String:
	var b: Node = _boot()
	if b != null and b.has_method("running_version"):
		return str(b.call("running_version"))
	return str(public_version())


## " · v7.2 ready, restart to apply" while a newer OTA is staged; "" otherwise (release footer unchanged).
static func _ota_suffix() -> String:
	var b: Node = _boot()
	return str(b.call("footer_suffix")) if b != null and b.has_method("footer_suffix") else ""


static func _ota_lines() -> PackedStringArray:
	var b: Node = _boot()
	if b == null or not b.has_method("diagnostics_text"):
		return PackedStringArray()
	return PackedStringArray(str(b.call("diagnostics_text")).split("\n"))


## Short line for the menu: "Purgatory Dungeon v7" (baseline) or "Purgatory Dungeon v7.1" (OTA 7.1 running), or the
## explicit development-build form.
static func display_string() -> String:
	var tail := " · " + short_commit() if commit() != "" else ""
	return compose_display(is_release_build(), public_version(), running_version(), tail, _ota_suffix())


## Pure composition of the footer (unit-tested). `running` is "7" or "7.1"; `suffix` the staged-update note.
static func compose_display(release: bool, native: int, running: String, tail: String, suffix: String) -> String:
	if release:
		return "%s v%s%s" % [PRODUCT_NAME, running, suffix]
	var ota: String = "" if running == str(native) else " · running v%s" % running
	return "%s · development build after v%d%s%s%s" % [PRODUCT_NAME, native, tail, ota, suffix]


## Multi-line engineering diagnostics (printed at startup; shown by tooling/logs).
static func diagnostics() -> String:
	var info := _info()
	var lines: PackedStringArray = []
	lines.append("Product: %s" % PRODUCT_NAME)
	lines.append("Version: v%d (%s)" % [public_version(), "release build" if is_release_build() else "development build"])
	lines.append("Source commit: %s" % (commit() if commit() != "" else "unknown (not a CI build)"))
	lines.append("CI run: %s" % str(info.get("ci_run", "n/a")))
	lines.append("Built (UTC): %s" % str(info.get("built_utc", "n/a")))
	lines.append("Engine: Godot %s" % Engine.get_version_info().get("string", "?"))
	lines.append("Platform: %s" % OS.get_name())
	lines.append_array(_ota_lines())
	return "\n".join(lines)
