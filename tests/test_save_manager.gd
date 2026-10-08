extends Node
## Save/profile characterization + regression test.
## Must be run with PURGATORY_SAVE_ROOT pointing at a scratch dir (see run_tests.sh),
## so real player saves are never touched.

var _fails: int = 0
var _checks: int = 0
var _loaded_signals: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _write_raw(slot: int, text: String) -> void:
	var f := FileAccess.open(SaveManager.get_file_path(slot), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _ready() -> void:
	var root := StoragePaths.root()
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT (would touch real saves)")
		get_tree().quit(2)
		return
	# Start from a clean slate.
	for i in SaveManager.SLOT_COUNT:
		DirAccess.remove_absolute(SaveManager.get_file_path(i))
	DirAccess.remove_absolute(root.path_join("last_slot.json"))
	SaveManager.current_profile = SaveManager.get_default_profile()
	SaveManager.active_slot_index = 0
	SaveManager.profile_loaded.connect(func(): _loaded_signals += 1)

	_check(SaveManager.SAVE_DIR.begins_with(root), "save dir lives under the storage root")
	_check(SaveManager.SLOT_COUNT == 10, "10 slots")
	for i in SaveManager.SLOT_COUNT:
		_check(SaveManager.get_slot_state(i) == "empty", "slot %d starts empty" % i)
	_check(SaveManager.find_first_empty_slot() == 0, "first empty slot is 0")

	# --- creation -----------------------------------------------------------
	SaveManager.load_slot(0)
	_check(not SaveManager.create_initial_identity("   ", "barbarian"), "blank name rejected")
	_check(not SaveManager.create_initial_identity("Bob", "paladin"), "invalid class rejected")
	_check(SaveManager.get_slot_state(0) == "empty", "rejected creation writes nothing")
	_check(SaveManager.create_initial_identity("Conan", "barbarian", "hardcore"), "create barbarian")
	_check(not SaveManager.create_initial_identity("Other", "mage"), "identity cannot be re-initialised")
	_check(SaveManager.get_character_name() == "Conan" and SaveManager.get_character_class() == "barbarian", "identity locked")
	_check(SaveManager.get_character_difficulty() == "hardcore", "difficulty stored")
	_check(not SaveManager.set_character_name("Renamed"), "rename blocked after init")

	SaveManager.load_slot(3)
	_check(SaveManager.create_initial_identity("x".repeat(40), "mage"), "create mage with over-long name")
	_check(SaveManager.get_character_name().length() == SaveManager.MAX_NAME_LENGTH, "name truncated to MAX_NAME_LENGTH")
	_check(SaveManager.set_last_seed("ABC", 7), "set_last_seed saves")
	_check(int(SaveManager.current_profile["run_count"]) == 1, "run_count incremented once")

	# --- regression: peeking must not move the active slot / last_slot pref ---
	SaveManager.load_slot(3)
	var signals_before := _loaded_signals
	for i in SaveManager.SLOT_COUNT:
		SaveManager.get_slot_state(i)
		SaveManager.peek_slot(i)
	_check(_loaded_signals == signals_before, "slot inspection emits no profile_loaded")
	_check(SaveManager.active_slot_index == 3, "slot inspection keeps active slot")
	_check(SaveManager.get_character_class() == "mage", "slot inspection keeps current profile")
	var pref = JSON.parse_string(FileAccess.get_file_as_string(root.path_join("last_slot.json")))
	_check(pref is Dictionary and int(pref.get("slot", -1)) == 3, "last_slot.json still points at slot 3 after scanning all slots")

	# --- save -> restart -> restore ----------------------------------------
	SaveManager.current_profile = {}
	SaveManager.active_slot_index = 0
	SaveManager._ready()   # what happens on game launch
	_check(SaveManager.active_slot_index == 3, "restart restores last slot")
	_check(SaveManager.get_character_class() == "mage", "restart restores class")
	_check(int(SaveManager.current_profile["run_count"]) == 1, "restart restores progression")
	SaveManager.load_slot(0)
	_check(SaveManager.get_character_class() == "barbarian" and SaveManager.get_character_name() == "Conan", "slot 0 restores barbarian")
	_check(SaveManager.get_slot_state(0) == "valid" and SaveManager.get_slot_state(3) == "valid", "both slots valid")
	_check(SaveManager.find_first_empty_slot() == 1, "first empty slot now 1")

	# --- no temp files left by atomic writes --------------------------------
	var leftovers := 0
	for f in DirAccess.get_files_at(SaveManager.SAVE_DIR):
		if f.ends_with(".tmp"):
			leftovers += 1
	_check(leftovers == 0, "no .tmp leftovers")

	# --- corruption handling -------------------------------------------------
	_write_raw(5, "{ this is not json")
	_check(SaveManager.get_slot_state(5) == "broken", "garbage JSON -> broken")
	_write_raw(6, "")
	_check(SaveManager.get_slot_state(6) == "broken", "empty file -> broken")
	_write_raw(7, "[1,2,3]")
	_check(SaveManager.get_slot_state(7) == "broken", "non-object JSON -> broken")
	_write_raw(8, JSON.stringify({"character_name": "Ghost", "initialized": true}))
	_check(SaveManager.get_slot_state(8) == "broken", "initialized but no class -> broken")
	_check(SaveManager.find_first_empty_slot() == 1, "broken slots are not offered as empty")
	SaveManager.load_slot(5)
	_check(SaveManager.current_profile == {} or not SaveManager.current_profile_is_valid(), "loading corrupt slot yields invalid default profile")
	_check(FileAccess.file_exists(SaveManager.get_file_path(5)), "loading corrupt slot does not delete it")

	# --- old schema backfill ------------------------------------------------
	_write_raw(9, JSON.stringify({"character_name": "Old", "character_class": "mage", "initialized": true, "run_count": 4}))
	_check(SaveManager.get_slot_state(9) == "valid", "old-schema save is valid")
	SaveManager.load_slot(9)
	_check(SaveManager.get_character_difficulty() == "medium", "missing difficulty defaults to medium")
	_check(SaveManager.current_profile.has("keys") and SaveManager.current_profile.has("perks"), "missing keys backfilled")
	_check(int(SaveManager.current_profile["run_count"]) == 4, "existing values preserved on backfill")

	# --- removed content: an old save that still carries the removed "cyclone" perk (Rapid Attack) loads and is ignored ---
	_write_raw(9, JSON.stringify({"character_name": "Old", "character_class": "barbarian", "initialized": true, "run_count": 7,
			"perks": {"vitality": 2, "cyclone": 3}, "active_buffs": ["rapid_attack_master"]}))
	_check(SaveManager.get_slot_state(9) == "valid", "a save with the removed cyclone perk is still valid")
	SaveManager.load_slot(9)
	_check(int(SaveManager.current_profile["perks"].get("vitality", 0)) == 2 and int(SaveManager.current_profile["run_count"]) == 7, "the rest of that save loads untouched")
	var old_store: Node = (load("res://scripts/AlchemistStore.gd") as GDScript).new()
	var old_keys: Array = []
	for p in old_store.visible_perks():
		old_keys.append(p["key"])
	_check(not ("cyclone" in old_keys) and "vitality" in old_keys, "the store no longer offers the removed cyclone perk")
	old_store.free()

	# --- delete ----------------------------------------------------------------
	SaveManager.load_slot(3)
	SaveManager.delete_slot(3)
	_check(SaveManager.get_slot_state(3) == "empty", "delete empties slot")
	_check(not SaveManager.current_profile_is_valid(), "deleting active slot resets profile")

	# --- settings round trip -----------------------------------------------
	SettingsManager.gameplay_settings["MusicSlider"] = 12.0
	SettingsManager.save_settings()
	SettingsManager.gameplay_settings["MusicSlider"] = 99.0
	SettingsManager.load_settings()
	_check(is_equal_approx(float(SettingsManager.gameplay_settings["MusicSlider"]), 12.0), "settings persist and reload")
	_check(FileAccess.file_exists(root.path_join("settings.json")), "settings.json lives in the storage root")

	print("test_save_manager: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
