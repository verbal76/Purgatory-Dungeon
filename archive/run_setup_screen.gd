# ==============================================================================
# File Name: run_setup_screen.gd
# Path: res://scripts/run_setup_screen.gd
# Description: Universal script that automatically detects and connects visible buttons.
# Dependencies: SaveManager, Alchemist, GlobalRunData
# Mod Notes: Uses find_child to guarantee no crashes regardless of scene layout.
# ==============================================================================
extends Control

@export var scene_to_load_on_start: String = "res://scenes/Purgatory_Dungeon_main_game_file.tscn"
@export var alchemist_scene: String = "res://scenes/AlchemistStore.tscn"

# Universal node variables
var slot_container: GridContainer
var char_label: Label
var seed_label: Label
var status_label: Label
var edit_name_btn: Button
var random_btn: Button
var custom_seed_btn: Button
var start_btn: Button
var alchemist_btn: Button
var exit_btn: Button
var keyboard: Control

var current_seed_text: String = ""
var current_seed_is_random: bool = true
var entering_name: bool = false
var entering_seed: bool = false

func _ready() -> void:
	_bind_nodes_universally()
	_connect_available_buttons()
	
	# Default to Slot 0 so you can actually test the game without a slot grid
	SaveManager.load_slot(0)
	
	if current_seed_text == "":
		_prepare_initial_seed()
		
	_refresh_display()

func _bind_nodes_universally() -> void:
	# This searches the entire scene for these names. It will not crash if they are missing.
	slot_container = find_child("SlotGrid", true, false)
	char_label = find_child("CharacterNameValue", true, false)
	seed_label = find_child("SeedValue", true, false)
	status_label = find_child("StatusLabel", true, false)
	edit_name_btn = find_child("EditNameButton", true, false)
	random_btn = find_child("RandomButton", true, false)
	custom_seed_btn = find_child("CustomSeedButton", true, false)
	start_btn = find_child("StartButton", true, false)
	alchemist_btn = find_child("AlchemistButton", true, false)
	exit_btn = find_child("ExitButton", true, false)
	keyboard = find_child("VirtualKeyboard", true, false)

func _connect_available_buttons() -> void:
	if edit_name_btn: edit_name_btn.pressed.connect(_on_edit_name_pressed)
	if random_btn: random_btn.pressed.connect(_on_random_pressed)
	if custom_seed_btn: custom_seed_btn.pressed.connect(_on_custom_seed_pressed)
	if start_btn: start_btn.pressed.connect(_on_start_pressed)
	if alchemist_btn: alchemist_btn.pressed.connect(_on_alchemist_pressed)
	if exit_btn: exit_btn.pressed.connect(func(): get_tree().quit())
	
	if keyboard and keyboard.has_signal("submitted"):
		keyboard.submitted.connect(_on_keyboard_submitted)

func _refresh_display() -> void:
	if char_label: 
		var n = SaveManager.get_character_name()
		char_label.text = n if n != "" else "[NO CHARACTER]"
	
	if seed_label: 
		seed_label.text = current_seed_text
		
	var has_data = SaveManager.has_character()
	if start_btn: start_btn.disabled = not has_data
	if alchemist_btn: alchemist_btn.disabled = not has_data

# --- Button Actions ---

func _on_edit_name_pressed() -> void:
	entering_name = true; entering_seed = false
	if keyboard: 
		keyboard.visible = true
		keyboard.call("open_with_text", SaveManager.get_character_name(), 15, true)

func _on_random_pressed() -> void:
	_prepare_initial_seed()
	_refresh_display()

func _on_custom_seed_pressed() -> void:
	entering_name = false; entering_seed = true
	if keyboard: 
		keyboard.visible = true
		keyboard.call("clear_and_open", 15, false)

func _on_alchemist_pressed() -> void:
	get_tree().change_scene_to_file(alchemist_scene)

func _on_start_pressed() -> void:
	var run_data = SaveManager.create_run_data_random() if current_seed_is_random else SaveManager.create_run_data_custom(current_seed_text)
	SaveManager.commit_run_seed(run_data.seed_text, run_data.seed_hash)
	
	GlobalRunData.character_name = SaveManager.get_character_name()
	GlobalRunData.seed_text = run_data.seed_text
	GlobalRunData.seed_hash = run_data.seed_hash
	
	get_tree().change_scene_to_file(scene_to_load_on_start)

func _on_keyboard_submitted(value: String) -> void:
	if keyboard: keyboard.visible = false
	
	if entering_name:
		var cleaned = SaveManager.sanitize_name(value)
		SaveManager.set_character_name(cleaned)
	elif entering_seed:
		current_seed_text = SaveManager.sanitize_seed(value)
		current_seed_is_random = false
		
	entering_name = false
	entering_seed = false
	_refresh_display()

func _prepare_initial_seed() -> void:
	current_seed_text = "RANDOM_" + str(randi() % 9999)
	current_seed_is_random = true
