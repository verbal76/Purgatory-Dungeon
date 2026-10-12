extends Node
## MANUAL TOOL (not part of run_tests.sh): renders the menu screens as a Steam Deck sees them (1280x800, Deck defaults, a controller in use).
##   export PURGATORY_SAVE_ROOT=$(mktemp -d)/PurgetoryDungeon
##   PURGATORY_FORCE_DECK=1 DECK_OUT=/tmp/deck_shots xvfb-run -a -s "-screen 0 1280x800x24" godot --rendering-driver vulkan \
##     --rendering-method mobile --resolution 1280x800 --path . res://tests/deck_shots.tscn

const Glyphs := preload("res://scripts/controller_glyphs.gd")
var _out: String = ""


func _shot(name: String) -> void:
	for i in 6:
		await get_tree().process_frame
	RenderingServer.force_draw()
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_out, name])
	print("saved ", name)


func _screen(path: String) -> Node:
	var inst: Node = (load(path) as PackedScene).instantiate()
	add_child(inst)
	return inst


func _ready() -> void:
	_out = OS.get_environment("DECK_OUT")
	if _out == "":
		_out = ProjectSettings.globalize_path("user://deck_shots")
	DirAccess.make_dir_recursive_absolute(_out)
	SaveManager.load_slot(0)
	SaveManager.create_initial_identity("Deckard", "mage")
	InputManager._set_controller_style(Glyphs.Style.DECK)
	InputManager._set_scheme(InputManager.Scheme.GAMEPAD)
	var s: Node = _screen("res://scenes/MainMenu.tscn")
	await _shot("1_main_menu")
	s.queue_free()
	await get_tree().process_frame
	s = _screen("res://scenes/CharacterSelection.tscn")
	await _shot("2_character_select")
	var kb: Node = s.find_child("VirtualKeyboard", true, false)
	if kb != null:
		kb.open_with_text("Deckard")
		await _shot("3_keyboard")
	s.queue_free()
	await get_tree().process_frame
	s = _screen("res://scenes/OptionsScreen.tscn")
	var tc: TabContainer = s.find_child("TabContainer", true, false)
	for i in tc.get_tab_count():
		tc.current_tab = i
		await _shot("4_options_%d_%s" % [i, tc.get_tab_title(i)])
	s.queue_free()
	get_tree().quit()
