extends Node
## Save schema version, backups and recovery (docs/COMPLIANCE_AUDIT.md RED-5): legacy, current, future-schema, corrupt and interrupted-write files, unknown keys,
## no downgrade, settings kept apart from gameplay saves. Needs PURGATORY_SAVE_ROOT (run_tests.sh sets it) so real saves are never touched.

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""


func _json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(_read(path))
	return parsed as Dictionary if parsed is Dictionary else {}


func _clean(slot: int) -> void:
	var p: String = SaveManager.get_file_path(slot)
	for suffix in ["", ".tmp", ".bak", ".unreadable", ".v0.bak", ".v1.bak", ".v7.bak"]:
		DirAccess.remove_absolute(p + suffix)
	SaveManager._backed_up_slots.erase(slot)


func _legacy_profile() -> Dictionary:
	return {"character_name": "Old", "character_class": "mage", "initialized": true, "run_count": 4, "difficulty": "hardcore",
			"unlocks": ["a"], "perks": {"potency": 2, "volatility": 0, "distillation": 1}, "keys": {"bronze": 1, "silver": 0, "gold": 0}, "legacy_only_key": "keep me"}


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT (would touch real saves)")
		get_tree().quit(2)
		return
	for i in SaveManager.SLOT_COUNT:
		_clean(i)
	_check(SaveManager.SCHEMA_VERSION == 1, "the current schema is 1")
	_check(int(SaveManager.get_default_profile()["schema_version"]) == 1, "a new profile carries the schema version")

	# --- legacy file (no schema_version): loads, migrates on the first save, backup kept, unknown keys kept ---------------------------------
	var legacy_text := JSON.stringify(_legacy_profile())
	var p0: String = SaveManager.get_file_path(0)
	_write(p0, legacy_text)
	_check(SaveManager.get_slot_state(0) == "valid", "legacy: a file without schema_version is a valid character")
	SaveManager.load_slot(0)
	_check(SaveManager.current_profile["character_name"] == "Old" and int(SaveManager.current_profile["run_count"]) == 4, "legacy: loads with its data")
	_check(SaveManager.save_profile(), "legacy: saves")
	var after: Dictionary = _json(p0)
	_check(int(after.get("schema_version", -1)) == 1, "legacy: migrated to schema 1 on save")
	_check(after.get("legacy_only_key") == "keep me" and int(after["perks"]["potency"]) == 2 and after["unlocks"] == ["a"], "legacy: unknown keys and data survive")
	_check(_read(p0 + ".v0.bak") == legacy_text, "legacy: the original bytes are kept as profile_0.save.v0.bak before migration")
	_check(_read(p0 + ".bak") == legacy_text, "legacy: and as the session-start backup")
	SaveManager.current_profile["run_count"] = 9
	SaveManager.save_profile()
	_check(_read(p0 + ".bak") == legacy_text, "current: a second save in the same session does not replace the session-start backup")
	_check(_read(p0 + ".v0.bak") == legacy_text, "the migration backup is never overwritten")

	# --- next session: the .bak becomes the previous good file; no new migration backup for a current file -------------------------------------
	SaveManager._backed_up_slots.clear()
	var current_text := _read(p0)
	SaveManager.load_slot(0)
	SaveManager.save_profile()
	_check(_read(p0 + ".bak") == current_text, "current: a new session backs up the previous good file")
	_check(not FileAccess.file_exists(p0 + ".v1.bak"), "current: a file already at the current schema needs no migration backup")

	# --- future schema: never downgraded, unknown keys at every level kept, backup of what the newer game wrote ----------------------------
	var future: Dictionary = _legacy_profile()
	future["schema_version"] = 7
	future["future_feature"] = {"nested": [1, 2, {"deep": true}]}
	future["perks"]["new_perk"] = 3
	var future_text := JSON.stringify(future)
	var p1: String = SaveManager.get_file_path(1)
	_write(p1, future_text)
	_check(SaveManager.get_slot_state(1) == "valid", "future: a newer file is still a readable character")
	SaveManager.load_slot(1)
	SaveManager.current_profile["run_count"] = 5
	_check(SaveManager.save_profile(), "future: saves")
	var fut_after: Dictionary = _json(p1)
	_check(int(fut_after["schema_version"]) == 7, "future: the schema version is NOT lowered")
	var nested: Array = fut_after["future_feature"]["nested"]
	_check(nested.size() == 3 and int(nested[1]) == 2 and bool((nested[2] as Dictionary)["deep"]) and int(fut_after["perks"]["new_perk"]) == 3, "future: unknown keys (nested too) survive the save")
	_check(int(fut_after["run_count"]) == 5, "future: the game's own edit was applied")
	_check(_read(p1 + ".v7.bak") == future_text, "future: the newer file is kept untouched as profile_1.save.v7.bak")

	# --- corrupt main file --------------------------------------------------------------------------------------------------------------
	var p2: String = SaveManager.get_file_path(2)
	_write(p2, "{ not json")
	SaveManager.load_slot(2)
	_check(not SaveManager.current_profile_is_valid(), "corrupt, no backup: loads an empty default profile")
	_check(_read(p2 + ".unreadable") == "{ not json", "corrupt: the unreadable bytes are preserved")
	SaveManager.save_profile()
	_check(_read(p2 + ".unreadable") == "{ not json", "corrupt: ...and survive the profile being saved over the slot")
	var p3: String = SaveManager.get_file_path(3)
	var good3 := JSON.stringify(_legacy_profile())
	_write(p3 + ".bak", good3)
	_write(p3, "garbage{")
	_check(SaveManager.get_slot_state(3) == "valid", "corrupt + good backup: the slot is recoverable")
	SaveManager.load_slot(3)
	_check(SaveManager.current_profile["character_name"] == "Old", "corrupt + good backup: the previous session's progress is restored")
	_check(_read(p3 + ".unreadable") == "garbage{", "corrupt + good backup: the corrupt file is still preserved")
	SaveManager.save_profile()
	_check(not _json(p3).is_empty() and _read(p3 + ".bak") == good3, "corrupt + good backup: saving rewrites a valid main file and keeps the backup")

	# --- interrupted writes -------------------------------------------------------------------------------------------------------------
	var p4: String = SaveManager.get_file_path(4)
	_write(p4 + ".tmp", JSON.stringify(_legacy_profile()))   # crash after the temp file was complete, main file gone
	_check(SaveManager.slot_has_file(4) and SaveManager.get_slot_state(4) == "valid", "interrupted: a complete temp file with no main file is a living slot")
	SaveManager.load_slot(4)
	_check(SaveManager.current_profile["character_name"] == "Old", "interrupted: it loads from the temp file")
	var p5: String = SaveManager.get_file_path(5)
	var main5 := JSON.stringify(_legacy_profile())
	_write(p5, main5)
	_write(p5 + ".tmp", "{\"character_name\": \"Trunc")   # crash in the middle of writing the temp file
	SaveManager.load_slot(5)
	_check(SaveManager.current_profile["character_name"] == "Old", "interrupted: a truncated temp file never replaces a good main file")
	_check(_read(p5) == main5, "interrupted: the main file is untouched by loading")
	var p6: String = SaveManager.get_file_path(6)
	_write(p6, "{trunc")
	_write(p6 + ".tmp", JSON.stringify(_legacy_profile()))
	SaveManager.load_slot(6)
	_check(SaveManager.current_profile["character_name"] == "Old", "interrupted: a complete temp file beats a corrupt main file")

	# --- deleting a character removes its recovery copies (nothing resurrects it), keeps copies of unreadable files --------------------------
	SaveManager.delete_slot(3)
	_check(not FileAccess.file_exists(p3) and not FileAccess.file_exists(p3 + ".bak") and not FileAccess.file_exists(p3 + ".tmp"), "delete: file, backup and temp file are gone")
	_check(SaveManager.get_slot_state(3) == "empty", "delete: the slot is empty again")
	_check(FileAccess.file_exists(p3 + ".unreadable"), "delete: the copy of an unreadable file is kept")

	# --- a character that lived only in a recovered temp file is really deleted (the active profile is reset too), and a blank profile is never written ----------
	var p7: String = SaveManager.get_file_path(7)
	_write(p7 + ".tmp", JSON.stringify(_legacy_profile()))
	SaveManager.load_slot(7)
	_check(SaveManager.current_profile["character_name"] == "Old", "tmp-only slot: loaded as the active profile")
	SaveManager.delete_slot(7)
	_check(not SaveManager.current_profile_is_valid(), "tmp-only slot: deleting it resets the active profile")
	SaveManager.save_profile()
	_check(not FileAccess.file_exists(p7) and not FileAccess.file_exists(p7 + ".tmp") and SaveManager.get_slot_state(7) == "empty", "tmp-only slot: a later save does not bring the deleted character back")
	var p8: String = SaveManager.get_file_path(8)
	SaveManager.load_slot(8)   # a slot that never had a character (first launch, main menu backgrounded or quit)
	_check(not SaveManager.save_profile(), "a blank default profile is not written")
	_check(not FileAccess.file_exists(p8) and SaveManager.get_slot_state(8) == "empty", "first launch: backgrounding the menu leaves the slot empty, not a broken ghost")
	SaveManager.current_profile["character_name"] = "Fresh"
	SaveManager.current_profile["character_class"] = "mage"
	SaveManager.current_profile["initialized"] = true
	_check(SaveManager.save_profile() and SaveManager.get_slot_state(8) == "valid", "a real character still saves")

	# --- settings stay separate from gameplay saves -------------------------------------------------------------------------------------
	var fresh := SaveManager.get_default_profile()
	for key in ["GraphicsQuality", "ControllerPrompts", "MasterVolume", "Resolution", "DisplayMode"]:
		_check(not fresh.has(key), "a profile holds no device setting (%s)" % key)
	var settings_path: String = SaveManager.SETTINGS_PATH
	var settings_before := _read(settings_path)
	SaveManager.load_slot(0)
	SaveManager.save_profile()
	_check(_read(settings_path) == settings_before, "saving a profile does not write settings.json")

	print("test_save_schema: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
