extends Node
## Regression checks for small state/UI defects: a purchase is one profile write, every run start
## grants the starter potion, trap hallucinations stack by reference count, and one input can
## never drive two actions.

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	for i in SaveManager.SLOT_COUNT:
		DirAccess.remove_absolute(SaveManager.get_file_path(i))
	SaveManager.current_profile = SaveManager.get_default_profile()
	SaveManager.active_slot_index = 0
	SaveManager.load_slot(0)
	_check(SaveManager.create_initial_identity("Tester", "barbarian", "medium"), "created a test profile")

	# --- Alchemist purchase = one write, potions and perk together -----------------------------------
	var store: Node = (load("res://scripts/AlchemistStore.gd") as GDScript).new()
	SaveManager.current_profile["meta_currency"] = 5
	SaveManager.current_profile["perks"] = {}
	var writes0: int = SaveManager.save_count
	_check(store._purchase_perk("scavenge", 2), "purchase succeeds with enough potions")
	_check(SaveManager.save_count - writes0 == 1, "a purchase writes the profile once (%d writes)" % (SaveManager.save_count - writes0))
	_check(int(SaveManager.current_profile["meta_currency"]) == 3 and int(SaveManager.current_profile["perks"]["scavenge"]) == 1, "potions spent and perk granted together")
	var on_disk = JSON.parse_string(FileAccess.get_file_as_string(SaveManager.get_file_path(0)))
	_check(on_disk is Dictionary and int(on_disk.get("meta_currency", -1)) == 3 and int(on_disk.get("perks", {}).get("scavenge", 0)) == 1, "the single write already holds both changes")
	var writes1: int = SaveManager.save_count
	_check(not store._purchase_perk("scavenge", 99), "purchase is refused without enough potions")
	_check(SaveManager.save_count == writes1 and int(SaveManager.current_profile["meta_currency"]) == 3, "a refused purchase writes nothing and spends nothing")
	store.free()

	# --- Starter potion is granted by every run-start route -------------------------------------------
	SaveManager.current_profile["meta_currency"] = 0
	RunLifecycle.grant_starter_potion()
	_check(int(SaveManager.current_profile["meta_currency"]) == 1, "grant_starter_potion adds one potion")
	# Exactly once per run start: character select has two mutually exclusive branches (new / existing
	# character), the other routes one each.
	for entry in [["res://scripts/character_selection.gd", 2], ["res://scripts/AlchemistStore.gd", 1], ["res://scripts/you_died_screen.gd", 1]]:
		var src := FileAccess.get_file_as_string(entry[0])
		_check(src.count("RunLifecycle.grant_starter_potion()") == entry[1], "%s grants the starter potion through RunLifecycle %d time(s)" % [entry[0].get_file(), entry[1]])
	_check(not FileAccess.get_file_as_string("res://scripts/character_selection.gd").contains("\"meta_currency\"] = int("), "character select no longer grants it inline")

	# --- Persistence is hidden from the Barbarian only -------------------------------------------------------
	var store2: Node = (load("res://scripts/AlchemistStore.gd") as GDScript).new()
	var keys_barb: Array = []
	for p in store2.visible_perks():
		keys_barb.append(p["key"])
	_check(not ("persistence" in keys_barb) and "magnitude" in keys_barb, "the Barbarian is not offered Persistence (it has no effect for them)")
	SaveManager.current_profile["character_class"] = "mage"
	var keys_mage: Array = []
	for p in store2.visible_perks():
		keys_mage.append(p["key"])
	_check("persistence" in keys_mage, "the Mage still sees Persistence")
	SaveManager.current_profile["character_class"] = "barbarian"
	store2.free()

	# --- Trap hallucinations: reference-counted, so a re-trigger extends the effect -------------------
	var player := Node3D.new()
	player.add_to_group("player")
	add_child(player)
	BuffManager.reset()
	BuffManager._handle_schizophrenia(true)
	BuffManager._handle_schizophrenia(true)
	_check(player.get_node_or_null("SchizophreniaEffect") != null, "hallucination effect attached")
	BuffManager._handle_schizophrenia(false)
	await _frames(2)
	_check(player.get_node_or_null("SchizophreniaEffect") != null, "one source ending does not remove the effect while another is active")
	BuffManager._handle_schizophrenia(false)
	await _frames(2)
	_check(player.get_node_or_null("SchizophreniaEffect") == null, "the effect is removed when the last source ends")

	# Generous margins (0.4 s) so a slow CI frame cannot reorder the checks.
	BuffManager.begin_timed_schizophrenia(1.0)
	await get_tree().create_timer(0.6).timeout
	BuffManager.begin_timed_schizophrenia(1.0)   # re-triggered at ~0.6 s: now lasts until ~1.6 s
	await get_tree().create_timer(0.6).timeout   # ~1.2 s: the first timer (1.0 s) has fired
	_check(player.get_node_or_null("SchizophreniaEffect") != null, "re-triggering the trap extends the effect past the first timer")
	await get_tree().create_timer(0.7).timeout   # ~1.9 s: the second timer has fired too
	await _frames(2)
	_check(player.get_node_or_null("SchizophreniaEffect") == null, "the effect ends after the later timer")
	# A timer from a previous run must not end the next run's effect.
	BuffManager.begin_timed_schizophrenia(0.3)
	BuffManager.reset()
	BuffManager._handle_schizophrenia(true)
	await get_tree().create_timer(0.8).timeout
	_check(player.get_node_or_null("SchizophreniaEffect") != null, "a stale timer from a finished run does not end the new run's effect")
	BuffManager.reset()
	player.queue_free()

	# --- One input never drives two actions -------------------------------------------------------------
	var options: Control = (load("res://scenes/OptionsScreen.tscn") as PackedScene).instantiate()
	add_child(options)
	await _frames(3)
	var kb_attack: InputEvent = options._binding_of("attack", "keyboard")
	var kb_kick: InputEvent = options._binding_of("kick", "keyboard")
	_check(kb_attack != null and kb_kick != null, "attack and kick have keyboard bindings")
	# Rebind Kick to Attack's input: they must swap, not both fire on one input.
	var press := InputEventKey.new() if kb_attack is InputEventKey else null
	if press != null:
		press.keycode = (kb_attack as InputEventKey).keycode
		press.physical_keycode = (kb_attack as InputEventKey).physical_keycode
		press.pressed = true
		_check(options._find_conflict("kick", "keyboard", press) == "attack", "the conflict with Attack is detected")
		options._apply_remap("kick", "keyboard", press)
		await _frames(3)
		var kick_now: InputEvent = options._binding_of("kick", "keyboard")
		var attack_now: InputEvent = options._binding_of("attack", "keyboard")
		_check(kick_now != null and attack_now != null, "neither action is left unbound")
		_check(options._find_conflict("kick", "keyboard", kick_now) == "", "after the remap no other action shares Kick's input")
		_check(attack_now.is_match(kb_kick, true), "Attack received Kick's old input (swap)")
		_check(InputMap.action_get_events("attack").size() >= 1 and InputMap.action_get_events("kick").size() >= 1, "both actions keep a binding")
	# A free input just rebinds.
	var free_key := InputEventKey.new()
	free_key.keycode = KEY_F9
	free_key.physical_keycode = KEY_F9
	free_key.pressed = true
	_check(options._find_conflict("kick", "keyboard", free_key) == "", "an unused key reports no conflict")
	options._apply_remap("kick", "keyboard", free_key)
	_check((options._binding_of("kick", "keyboard") as InputEventKey).keycode == KEY_F9, "a free key rebinds the action")
	options.queue_free()
	InputMap.load_from_project_settings()
	SettingsManager.gameplay_settings.erase("controls")

	# --- Minimap is on Tab (the controls reference says so); Escape is pause / back only -----------------
	InputMap.load_from_project_settings()
	var mm_keys: Array = []
	for e in InputMap.action_get_events("minimap"):
		if e is InputEventKey:
			mm_keys.append((e as InputEventKey).physical_keycode)
	_check(mm_keys == [KEY_TAB], "the minimap keyboard binding is Tab only %s" % [mm_keys])

	print("test_misc_fixes: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
