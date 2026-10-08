extends Node
## Run start/exit paths must leave identical state behind.
## (Scene changes are deferred, so state is asserted synchronously after each call.)

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _ready() -> void:
	# The code under test calls change_scene_to_file(), which frees current_scene. Park a
	# dummy as the current scene and move this node to the root so the test survives it.
	var dummy := Node.new()
	dummy.name = "DummyScene"
	get_tree().root.add_child.call_deferred(dummy)
	_start.call_deferred(dummy)


func _start(dummy: Node) -> void:
	get_tree().current_scene = dummy
	reparent(get_tree().root)
	_run()


func _run() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	# A hardcore Mage profile, then stale run data from some earlier Barbarian run.
	SaveManager.load_slot(2)
	SaveManager.create_initial_identity("Lifecycle", "mage", "hardcore")
	SaveManager.load_slot(2)
	GlobalRunData.character_class = "barbarian"
	GlobalRunData.difficulty = "medium"
	GlobalRunData.character_name = "stale"

	RunLifecycle.sync_run_data_from_profile()
	_check(GlobalRunData.character_class == "mage" and GlobalRunData.difficulty == "hardcore" and GlobalRunData.character_name == "Lifecycle", "sync copies class/difficulty/name from the profile")

	# Build everything first; scene changes are deferred, so nothing may yield after the
	# first scene-changing call below or the test scene itself gets replaced.
	var store: Node = (load("res://scenes/AlchemistStore.tscn") as PackedScene).instantiate()
	add_child(store)
	var pause: Node = (load("res://scenes/pause_menu_function.tscn") as PackedScene).instantiate()
	add_child(pause)
	await get_tree().process_frame

	# Pause menu 'Exit to main menu' stops the run systems.
	GameClock.start_run()
	GlobeManager._is_running = true
	pause._on_exit_to_main_menu_button_pressed()
	_check(GameClock._timer.is_stopped(), "exiting to the menu stops the day clock")
	_check(not GameClock._hud_layer.visible, "exiting to the menu hides the day HUD")
	_check(not GlobeManager._is_running, "exiting to the menu stops globes")
	_check(not get_tree().paused, "tree unpaused for the menu")

	# Alchemist 'start another run' (fresh-launch scenario: stale default run data).
	GlobalRunData.character_class = "barbarian"
	GlobalRunData.difficulty = "medium"
	GlobeManager._is_running = true
	var runs_before := int(SaveManager.current_profile.get("run_count", 0))
	store._start_new_run()
	_check(GlobalRunData.character_class == "mage", "Alchemist start runs the profile's class, not the default (%s)" % GlobalRunData.character_class)
	_check(GlobalRunData.difficulty == "hardcore", "Alchemist start keeps the profile's difficulty (%s)" % GlobalRunData.difficulty)
	_check(GlobalRunData.seed_hash == 0, "Alchemist start requests a fresh random seed")
	_check(not GlobeManager._is_running, "Alchemist start resets globes")
	_check(int(SaveManager.current_profile.get("run_count", 0)) == runs_before + 1, "run_count incremented exactly once")

	# Run-end "Return" must act once and remove itself (it is a root child that survives the
	# scene change; it used to stay on top of the Alchemist with live buttons).
	var screen := CanvasLayer.new()
	screen.set_script(load("res://scripts/run_end_screen.gd"))
	add_child(screen)
	var completions_before := int(SaveManager.current_profile.get("dungeon_completions", 0))
	screen._on_leave_pressed()
	screen._on_leave_pressed()
	_check(int(SaveManager.current_profile.get("dungeon_completions", 0)) == completions_before + 1, "pressing Return twice records the completion once")
	_check(screen.is_queued_for_deletion(), "run-end screen removes itself after Return")

	print("test_run_lifecycle: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
