extends Node
## Regression: opening Options from the pause menu must not destroy/reload the run.
## Also covers Pause -> Resume and Pause -> Options -> Back -> Resume.

var _fails: int = 0
var _checks: int = 0


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
	GlobalRunData.character_class = "barbarian"
	var main: Node = (load("res://scenes/Purgatory_Dungeon_main_game_file.tscn") as PackedScene).instantiate()
	add_child(main)
	await _frames(240)

	var pause = main.get_node("pause_menu_function")
	var gen = main.get_node("DungeonGenerationFunction")
	var player = main.get_node_or_null("Player")
	_check(player != null and gen.placed_modules.size() > 100, "run is live before pausing")
	var player_id: int = player.get_instance_id()
	var gen_id: int = gen.get_instance_id()
	var module_count: int = gen.placed_modules.size()
	var first_module = gen.placed_modules[0]
	var day: int = GameClock.current_day
	var player_pos: Vector3 = player.global_position

	# Pause -> Resume
	pause.open_menu()
	_check(get_tree().paused and pause.is_menu_open(), "pause opens and pauses the tree")
	pause.close_menu()
	_check(not get_tree().paused and not pause.is_menu_open(), "resume unpauses")

	# Pause -> Options
	pause.open_menu()
	pause._on_options_button_pressed()
	await _frames(3)
	var overlay = pause.get_node_or_null("OptionsOverlay")
	_check(overlay != null and overlay.get_child_count() > 0, "options opens as an overlay inside the run")
	_check(get_tree().paused, "tree stays paused while Options is open")
	_check(is_instance_valid(main) and is_instance_valid(player) and main.get_node_or_null("Player") == player, "run scene and player survive opening Options")
	_check(player.get_instance_id() == player_id and gen.get_instance_id() == gen_id, "same player and generator instances")
	_check(gen.placed_modules.size() == module_count and gen.placed_modules[0] == first_module, "dungeon not regenerated")
	_check(is_instance_valid(self) and get_tree().current_scene != null, "test scene not replaced by a scene change")

	# Options -> Back
	var options: Control = overlay.get_child(0)
	options._go_back()
	await _frames(3)
	_check(pause.get_node_or_null("OptionsOverlay") == null, "overlay removed after Back")
	_check(pause.is_menu_open() and get_tree().paused, "back returns to the pause menu, still paused")

	# Resume
	pause.close_menu()
	await _frames(5)
	_check(not get_tree().paused, "resume after Options unpauses")
	_check(main.get_node_or_null("Player") == player and player.get_instance_id() == player_id, "same player after Options round trip")
	_check(player.global_position.distance_to(player_pos) < 5.0, "player was not teleported/reset")
	_check(GameClock.current_day >= day, "run clock not reset")
	# (Mouse capture cannot be asserted: the headless display server never holds CAPTURED.)

	print("test_pause_options: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
