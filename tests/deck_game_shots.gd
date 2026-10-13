extends Node
## MANUAL TOOL (not part of run_tests.sh): the in-game screens as a Steam Deck sees them (1280x800, controller in use): HUD, pause menu, buff
## reel, death screen, win screen.
##   export PURGATORY_SAVE_ROOT=$(mktemp -d)/PurgetoryDungeon
##   PURGATORY_FORCE_DECK=1 DECK_OUT=/tmp/deck_game xvfb-run -a -s "-screen 0 1280x800x24" godot --rendering-driver vulkan \
##     --rendering-method mobile --resolution 1280x800 --path . res://tests/deck_game_shots.tscn

const Glyphs := preload("res://scripts/controller_glyphs.gd")
var _out: String = ""


func _shot(name: String) -> void:
	for i in 8:
		await get_tree().process_frame
	RenderingServer.force_draw()
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_out, name])
	print("saved ", name)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _ready() -> void:
	_out = OS.get_environment("DECK_OUT")
	if _out == "":
		_out = ProjectSettings.globalize_path("user://deck_game")
	DirAccess.make_dir_recursive_absolute(_out)
	SaveManager.load_slot(0)
	SaveManager.create_initial_identity("Deckard", "barbarian")
	GlobalRunData.character_class = "barbarian"
	InputManager._set_controller_style(Glyphs.Style.DECK)
	InputManager._set_scheme(InputManager.Scheme.GAMEPAD)
	var main: Node = (load("res://scenes/Purgatory_Dungeon_main_game_file.tscn") as PackedScene).instantiate()
	main.use_random_seed = false
	main.fixed_seed = 12345
	add_child(main)
	await _frames(200)
	var player: Node = get_tree().get_first_node_in_group("player")
	var waited := 0
	while (get_tree().paused or not player.is_on_floor() or get_tree().get_first_node_in_group("loading_screen") != null) and waited < 4000:
		await get_tree().physics_frame
		waited += 1
	await _frames(40)
	await _shot("1_hud")
	var pause: Node = main.get_node("pause_menu_function")
	pause.open_menu()
	await _shot("2_pause")
	pause.close_menu()
	await _frames(5)
	BuffManager.trigger_buff_pick_for_test() if BuffManager.has_method("trigger_buff_pick_for_test") else null
	var died: CanvasLayer = CanvasLayer.new()
	died.set_script(load("res://scripts/you_died_screen.gd"))
	add_child(died)
	await get_tree().create_timer(4.0).timeout
	await _shot("3_death")
	died.queue_free()
	await get_tree().process_frame
	var win: CanvasLayer = CanvasLayer.new()
	win.set_script(load("res://scripts/run_end_screen.gd"))
	add_child(win)
	win.setup(null)
	await get_tree().create_timer(3.0).timeout
	await _shot("4_win")
	get_tree().quit()
