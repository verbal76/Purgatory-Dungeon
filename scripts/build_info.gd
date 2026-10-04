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


## Short line for the menu: "Purgatory Dungeon v2" or the explicit development-build form.
static func display_string() -> String:
	var v := public_version()
	if is_release_build():
		return "%s v%d" % [PRODUCT_NAME, v]
	var tail := " · " + short_commit() if commit() != "" else ""
	return "%s · development build after v%d%s" % [PRODUCT_NAME, v, tail]


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
	return "\n".join(lines)
