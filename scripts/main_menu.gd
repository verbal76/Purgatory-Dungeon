# ==============================================================================
# File Name: main_menu.gd
# Path: res://scripts/main_menu.gd
# Description: Main Menu controller for Purgetory Dungeon.
#              Phase 3 Implementation: Clear separation of New vs Load Character
#              with built-in slot overflow protection.
# ==============================================================================
extends Control

@export var start_scene: String = "res://scenes/CharacterSelection.tscn"
@export var profile_scene: String = "res://scenes/ProfileScreen.tscn"
@export var codex_scene: String = "res://scenes/CodexScreen.tscn"
@export var options_scene: String = "res://scenes/OptionsScreen.tscn"
@export var alchemist_scene: String = "res://scenes/AlchemistStore.tscn"

var new_char_btn: Button
var load_char_btn: Button
var codex_btn: Button
var options_btn: Button
var alchemist_btn: Button
var quit_btn: Button

func _ready() -> void:
	# The dungeon captures the mouse; make sure menus are clickable after leaving it.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_bind_nodes()
	_connect_signals()
	_reorder_buttons()

	# AUDIO: Ensure menu music triggers through the global AudioManager
	if has_node("/root/AudioManager"):
		AudioManager.play_menu_music()

	# SURGICAL ADD: Hide the dungeon wallet overlay — menus have their own displays.
	if has_node("/root/PlayerWallet"):
		PlayerWallet.hide_hud()

	# GAMEPAD: Focus the new character button so it is immediately interactive
	if new_char_btn:
		new_char_btn.call_deferred("grab_focus")

	_wire_button_clicks()
	_add_version_label()


# Small public-version label in the bottom-right corner ("Purgatory Dungeon v2"), plus the
# engineering diagnostics in the log. See BuildInfo and docs/RELEASES.md.
func _add_version_label() -> void:
	print(BuildInfo.diagnostics())
	var label := Label.new()
	label.name = "VersionLabel"
	label.text = BuildInfo.display_string()
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8, 0.8))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	label.offset_right = -16.0
	label.offset_bottom = -10.0
	add_child(label)


# Enforces the desired button order in whatever VBoxContainer (or other
# container) holds the menu buttons. Finds the shared parent and uses
# move_child() to guarantee the order below regardless of scene layout:
#   1. New Character
#   2. Load Character (Profile)
#   3. Alchemist's Lab   ← third
#   4. Codex
#   5. Options
#   6. Quit
func _wire_button_clicks() -> void:
	if has_node("/root/AudioManager"):
		AudioManager.wire_click_sounds(self)


func _reorder_buttons() -> void:
	# All buttons must share the same parent for move_child() to work.
	# Use new_char_btn's parent as the reference container.
	if new_char_btn == null or new_char_btn.get_parent() == null:
		return

	var container : Node = new_char_btn.get_parent()

	# Desired order — any button that wasn't found is simply skipped.
	var ordered : Array = [
		new_char_btn,
		load_char_btn,
		alchemist_btn,
		codex_btn,
		options_btn,
		quit_btn,
	]

	var btn_index : int = 0
	for btn in ordered:
		if btn != null and btn.get_parent() == container:
			container.move_child(btn, btn_index)
			btn_index += 1

func _bind_nodes() -> void:
	# Check for new Phase 3 names, fallback to old names if scene is unedited
	new_char_btn = find_child("NewCharacterButton", true, false)
	if not new_char_btn: 
		new_char_btn = find_child("StartButton", true, false)
		
	load_char_btn = find_child("LoadCharacterButton", true, false)
	if not load_char_btn: 
		load_char_btn = find_child("ProfileButton", true, false)

	codex_btn = find_child("CodexButton", true, false)
	options_btn = find_child("OptionsButton", true, false)
	alchemist_btn = find_child("AlchemistButton", true, false)
	quit_btn = find_child("QuitButton", true, false)

func _connect_signals() -> void:
	if new_char_btn:  new_char_btn.pressed.connect(_on_new_character_pressed)
	if load_char_btn: load_char_btn.pressed.connect(func(): _try_load_scene(profile_scene))
	if codex_btn:     codex_btn.pressed.connect(func(): _try_load_scene(codex_scene))
	if options_btn:   options_btn.pressed.connect(func(): _try_load_scene(options_scene))
	if alchemist_btn: alchemist_btn.pressed.connect(func(): _try_load_scene(alchemist_scene))
	if quit_btn:      quit_btn.pressed.connect(_on_quit_pressed)

func _on_new_character_pressed() -> void:
	# Check for an empty slot first
	var empty_slot : int = SaveManager.find_first_empty_slot()
	
	if empty_slot >= 0:
		SaveManager.load_slot(empty_slot)
		_try_load_scene(start_scene) # Go to Character Creation
	else:
		# ALL 10 SLOTS FULL - Trigger the popup instead of a silent redirect
		_show_full_slots_warning()

func _show_full_slots_warning() -> void:
	# Create a built-in Godot popup dialog dynamically
	var dialog = AcceptDialog.new()
	dialog.title = "No Empty Slots"
	dialog.dialog_text = "All 10 save slots are full!\n\nPlease delete a soul to make room for a new character."
	
	# Add it to the scene and show it
	add_child(dialog)
	dialog.popup_centered()
	
	# When the user clicks "OK", clean up the dialog and transition to the Profile Screen
	dialog.confirmed.connect(func():
		dialog.queue_free()
		_try_load_scene(profile_scene)
	)

func _try_load_scene(path: String) -> void:
	if ResourceLoader.exists(path):
		get_tree().change_scene_to_file(path)
	else:
		printerr("ERROR: Scene file not found at: ", path)


func _on_quit_pressed() -> void:
	# Final save before exit so nothing is lost.
	if has_node("/root/SaveManager") and not SaveManager.current_profile.is_empty():
		SaveManager.save_profile()
	get_tree().quit()
