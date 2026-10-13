extends Node
## The public version ("Purgatory Dungeon vN") is single-sourced from ./VERSION and must show
## up consistently in the game. A build is only called "vN" when CI built it from tag vN.

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _write_info(release: bool, version: int) -> void:
	var f := FileAccess.open(BuildInfo.INFO_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"product": "Purgatory Dungeon", "public_version": version, "release": release,
			"commit": "0123456789abcdef0123456789abcdef01234567", "ci_run": "1", "built_utc": "2026-01-01T00:00:00Z"}))
	f.close()


func _ready() -> void:
	var version_file := FileAccess.get_file_as_string("res://VERSION").strip_edges()
	_check(version_file.is_valid_int() and int(version_file) >= 1, "VERSION is a positive integer (%s)" % version_file)
	var v := int(version_file)
	_check(BuildInfo.public_version() == v, "project.godot config/version matches VERSION (%d vs %d)" % [BuildInfo.public_version(), v])

	var had_info := FileAccess.file_exists(BuildInfo.INFO_PATH)
	var saved := FileAccess.get_file_as_string(BuildInfo.INFO_PATH) if had_info else ""
	if had_info:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(BuildInfo.INFO_PATH))

	# No build_info.json (editor / local run): clearly a development build, never "vN".
	_check(not BuildInfo.is_release_build(), "no build_info.json -> not a release build")
	_check(BuildInfo.display_string() == "Purgatory Dungeon · development build after v%d" % v, "development display string (%s)" % BuildInfo.display_string())

	# CI development build (not from a tag): explicit, with the commit.
	_write_info(false, v)
	_check(not BuildInfo.is_release_build(), "release=false -> development build")
	_check(BuildInfo.display_string() == "Purgatory Dungeon · development build after v%d · 0123456" % v, "CI development display string (%s)" % BuildInfo.display_string())

	# Tag build whose number matches VERSION: plainly "Purgatory Dungeon vN".
	_write_info(true, v)
	_check(BuildInfo.is_release_build(), "release=true and matching version -> release build")
	_check(BuildInfo.display_string() == "Purgatory Dungeon v%d" % v, "release display string (%s)" % BuildInfo.display_string())

	# A release flag from a different version must not be trusted.
	_write_info(true, v + 7)
	_check(not BuildInfo.is_release_build(), "release flag for another version is not trusted")

	var diag := BuildInfo.diagnostics()
	_check(diag.contains("Product: Purgatory Dungeon") and diag.contains("Version: v%d" % v) and diag.contains("Source commit:") and diag.contains("Engine: Godot"), "diagnostics show product, version, commit and engine")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(BuildInfo.INFO_PATH))
	if had_info:
		var f := FileAccess.open(BuildInfo.INFO_PATH, FileAccess.WRITE)
		f.store_string(saved)
		f.close()

	print("test_release_metadata: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
