extends Node
## Android lifecycle on the real game scene: background -> the run is paused behind the pause menu,
## progress is written, held touches are released; foreground -> nothing is rebuilt (same dungeon, same
## music node, no splash). Needs PURGATORY_FORCE_TOUCH=1 and PURGATORY_SAVE_ROOT (run_tests.sh sets both).

const MAIN_SCENE := "res://scenes/Purgatory_Dungeon_main_game_file.tscn"
var _fails := 0
var _checks := 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	_check(TouchControls.is_touch_platform(), "run with PURGATORY_FORCE_TOUCH=1")
	SaveManager.load_slot(0)
	SaveManager.create_initial_identity("Lifecycle", "barbarian")
	GlobalRunData.character_class = "barbarian"
	var main: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	add_child(main)
	await _frames(120)

	var life := get_node_or_null("/root/AppLifecycle")
	_check(life != null, "AppLifecycle installed on touch platforms")
	var gen = main.get_node_or_null("DungeonGenerationFunction")
	var modules_before: int = gen.placed_modules.size()
	var modules_ids: Array = gen.placed_modules.map(func(m): return m.get_instance_id())
	var music_nodes_before: int = AudioManager.get_child_count()
	var tcs := get_tree().get_nodes_in_group(TouchControls.GROUP)
	_check(tcs.size() == 1, "one touch layer in the run (%d)" % tcs.size())
	var tc: TouchControls = tcs[0]
	var menu := get_tree().get_first_node_in_group("pause_menu")
	_check(menu != null and not menu.is_menu_open(), "pause menu present and closed during play")
	_check(not get_tree().paused, "running before backgrounding")

	# A finger is on the attack button when the phone locks.
	tc._button_down(tc.buttons["attack"])
	_check(tc._held.has("attack"), "touch layer registers the held attack")
	await _frames(3)
	_check(Input.is_action_pressed("attack"), "attack held before the lock")
	# Twin-stick (the default): a finger dragging from ATTACK is turning the camera.
	_check(tc.is_twin(), "the run uses the twin-stick scheme by default")
	tc.view_override = Vector2(1602, 720)   # the headless window is tiny: lay the layer out as on a phone
	tc.layout_override_insets = Vector4.ZERO
	tc._relayout()
	var player_node := get_tree().get_first_node_in_group("player") as Node3D
	tc._touch_down(5, Vector2(tc.view_size().x * 0.55, tc.view_size().y * 0.35))   # empty right-side screen: ignored
	var move_pos := Vector2(tc.view_size().x * 0.12, tc.view_size().y * 0.72)
	tc._touch_down(4, move_pos)   # the left thumb is walking too
	tc._touch_move(4, move_pos + Vector2(100, 0), Vector2.ZERO)
	await _frames(2)
	_check(Input.is_action_pressed("move_right"), "the move stick is live before the lock")
	var atk_btn: TouchButton = tc.buttons["attack"]
	tc._touch_down(6, atk_btn.center)
	tc._touch_move(6, atk_btn.center + Vector2(-90, 0), Vector2.ZERO)
	await _frames(3)
	_check(tc._look_cmd != Vector2.ZERO and tc._atk_index == 6 and tc._owners[5]["kind"] == TouchControls.Owner.NONE, "the attack drag is live before the lock")
	var yaw_live: float = player_node.rotation.y if player_node != null else 0.0

	# Progress made in the run, not yet saved: potions stashed, a perk bought, a touch setting changed.
	SaveManager.current_profile["meta_currency"] = int(SaveManager.current_profile.get("meta_currency", 0)) + 7
	SaveManager.current_profile["perks"]["potency"] = 2
	SaveManager.current_profile["keys"]["gold"] = 1
	SettingsManager.update_setting(TouchControls.KEY_SCALE, 130.0)
	var want_currency: int = SaveManager.current_profile["meta_currency"]
	var want_name: String = SaveManager.current_profile.get("character_name", "")   # slot 0 may predate this test

	var saves_before := SaveManager.save_count
	life.on_background()
	await _frames(3)
	_check(not Input.is_action_pressed("attack"), "held attack released on background")
	_check(tc._owners.is_empty() and tc._held.is_empty(), "touch layer holds no fingers/actions after background")
	_check(not Input.is_action_pressed("move_right") and not tc._stick_active, "movement is released by the background too")
	_check(tc._look_cmd == Vector2.ZERO and tc._atk_index == -1, "look velocity and the attack drag are reset by the background")
	_check(get_tree().paused and menu.is_menu_open(), "the run is paused behind the pause menu")
	_check(SaveManager.save_count == saves_before + 1, "profile written on background (%d -> %d)" % [saves_before, SaveManager.save_count])
	var clock_day: int = GameClock.current_day if "current_day" in GameClock else -1

	# "Android reclaims the process": forget everything in memory, then come back from disk only.
	SaveManager.current_profile = SaveManager.get_default_profile()
	SettingsManager.gameplay_settings[TouchControls.KEY_SCALE] = 100.0
	SaveManager.load_slot(SaveManager.active_slot_index)
	SettingsManager.load_settings()
	_check(int(SaveManager.current_profile.get("meta_currency", -1)) == want_currency, "stashed potions survive a reclaimed process (%s)" % SaveManager.current_profile.get("meta_currency"))
	_check(int(SaveManager.current_profile["perks"].get("potency", -1)) == 2, "bought perk survives a reclaimed process")
	_check(int(SaveManager.current_profile["keys"].get("gold", -1)) == 1, "keys survive a reclaimed process")
	_check(is_equal_approx(float(SettingsManager.gameplay_settings.get(TouchControls.KEY_SCALE, 0.0)), 130.0), "touch settings survive a reclaimed process")
	_check(want_name != "" and SaveManager.current_profile.get("character_name", "") == want_name, "character identity survives (%s)" % want_name)

	# Repeated notifications (PAUSED + FOCUS_OUT both fire on a real phone) must not stack effects.
	life.on_background()
	_check(life.background_count == 1, "PAUSED + FOCUS_OUT count as one background")
	_check(SaveManager.save_count == saves_before + 1, "second notification does not save again")

	# Time must not advance while backgrounded.
	var t0 := Time.get_ticks_msec()
	await get_tree().create_timer(0.5, true, false, true).timeout
	_check(GameClock.current_day == clock_day or clock_day == -1, "game clock frozen while backgrounded")

	life.on_foreground()
	_check(get_tree().paused and menu.is_menu_open(), "returning keeps the pause menu up (player resumes deliberately)")
	menu.close_menu()
	_check(not get_tree().paused, "Resume unpauses")
	await _frames(30)
	if player_node != null:
		var yaw_back: float = player_node.rotation.y
		await _frames(10)
		_check(absf(player_node.rotation.y - yaw_back) < 0.0001, "nothing keeps turning after returning from the background (yaw %.3f -> %.3f)" % [yaw_live, yaw_back])
	_check(not Input.is_action_pressed("attack"), "nothing keeps attacking after returning")

	# Nothing was rebuilt.
	_check(gen.placed_modules.size() == modules_before, "dungeon not regenerated (%d modules)" % modules_before)
	var same := true
	for i in gen.placed_modules.size():
		if gen.placed_modules[i].get_instance_id() != modules_ids[i]:
			same = false
	_check(same, "same module instances after resume")
	_check(AudioManager.get_child_count() == music_nodes_before, "no extra audio nodes created by resume")
	_check(get_tree().root.find_child("StudioSplash", true, false) == null, "splash is not replayed on resume")
	_check(get_tree().get_nodes_in_group(TouchControls.GROUP).size() == 1, "still exactly one touch layer")

	# The minimap re-renders the dungeon: on phones that is throttled (UPDATE_ONCE bursts), never ALWAYS.
	var mm := main.get_node_or_null("minimap_function")
	if mm == null:
		for c in main.get_children():
			if "minimap_viewport" in c:
				mm = c
	if mm != null:
		Input.action_press("minimap")   # the touch map button holds this action while the map is open
		var always_seen := false
		var once_seen := false
		for i in 60:
			await get_tree().process_frame
			var mode: int = mm.minimap_viewport.render_target_update_mode
			if mode == SubViewport.UPDATE_ALWAYS:
				always_seen = true
			if mode == SubViewport.UPDATE_ONCE:
				once_seen = true
		_check(mm._map_visible, "minimap opens from its action")
		_check(not always_seen, "minimap does not render every frame on phones")
		_check(once_seen, "minimap refreshes in throttled bursts on phones")
		Input.action_release("minimap")
		for i in 3:
			await get_tree().process_frame
		_check(mm.minimap_viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "minimap stops rendering when closed")
	else:
		_check(false, "minimap node found")

	# A second background/foreground cycle works the same way.
	life.on_background()
	_check(life.background_count == 2 and menu.is_menu_open(), "second cycle pauses again")
	life.on_foreground()
	menu.close_menu()

	print("test_app_lifecycle: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
