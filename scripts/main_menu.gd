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
	_build_backdrop()
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
	if TouchControls.is_touch_platform():
		_fit_for_phone()


# The dungeon picture stays the hero. A light veil + vignette sits over it (PUI), and a restrained dark gradient
# on the left gives the button column a calm ground - no panel, no box.
func _build_backdrop() -> void:
	var at: int = 0
	var picture := get_node_or_null("BackgroundImage")
	if picture != null:
		at = picture.get_index() + 1
	var veil := PUI.background("veil")
	add_child(veil)
	move_child(veil, at)
	var column := MenuKit.side_veil(0.5, 0.78)
	add_child(column)
	move_child(column, at + 1)


# Phones: Quit has no place on Android (Home leaves the app) and the rest must fit a 720-high canvas
# with thumb-sized buttons.
func _fit_for_phone() -> void:
	if quit_btn:
		quit_btn.hide()
	var box := find_child("VBox", true, false) as VBoxContainer
	if box:
		box.add_theme_constant_override("separation", 10)
		var spacer := box.get_node_or_null("Spacer") as Control
		if spacer:
			spacer.custom_minimum_size.y = 0
	var margin := find_child("Margin", true, false) as MarginContainer
	if margin:
		margin.add_theme_constant_override("margin_top", 24)
		margin.add_theme_constant_override("margin_bottom", 24)


# Small public-version label in the bottom-right corner ("Purgatory Dungeon v2"), plus the
# engineering diagnostics in the log. See BuildInfo and docs/RELEASES.md.
func _add_version_label() -> void:
	print(BuildInfo.diagnostics())
	var label := PUI.label(BuildInfo.display_string(), "CaptionLabel")
	label.name = "VersionLabel"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	label.offset_right = -PUI.S5
	label.offset_bottom = -PUI.S3
	add_child(label)
	# A downloaded OTA update shows "restart to apply" without leaving the menu.
	var ota: Node = get_node_or_null("/root/OtaUpdater")
	if ota != null and ota.has_signal("status_changed"):
		ota.status_changed.connect(func() -> void: label.text = BuildInfo.display_string())


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

	# Keep the game title (and its spacer) above the buttons: moving the buttons to the front would
	# otherwise push the title under them.
	var btn_index : int = 0
	for head_name in ["TitleBlock", "TitleLabel", "Spacer"]:
		var head := container.get_node_or_null(head_name)
		if head != null:
			container.move_child(head, btn_index)
			btn_index += 1
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

var _slots_popup: Control = null

# "No Empty Slots": an in-scene popup built from the same parts as the profile screen's popups (scrim + iron panel,
# display-face title, brass rule, one primary action) instead of the engine's AcceptDialog window, which draws its
# title bar outside the panel and cannot be made to match.
func _show_full_slots_warning() -> void:
	if _slots_popup != null:
		return
	var layer := Control.new()
	layer.name = "NoEmptySlotsPopup"
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_STOP   # nothing behind the popup can be clicked

	var scrim := ColorRect.new()
	scrim.color = PUI.SCRIM
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(scrim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(520, 0)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", PUI.S3)
	panel.add_child(box)

	var title := PUI.label("No Empty Slots", "CardTitle")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	box.add_child(PUI.divider())
	var body := Label.new()
	body.text = "All 10 save slots are full!\n\nPlease delete a soul to make room for a new character."
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(body)

	var open_btn := PUI.button("Open Profiles", "primary")
	open_btn.name = "OpenProfilesButton"
	box.add_child(open_btn)
	var close_btn := PUI.button("Close", "nav")
	close_btn.name = "ClosePopupButton"
	box.add_child(close_btn)

	add_child(layer)
	_slots_popup = layer
	_set_menu_focus(false)
	if has_node("/root/AudioManager"):
		AudioManager.wire_click_sounds(layer)
	open_btn.grab_focus()

	# "Open Profiles": clean up and go to the Profile Screen (as the old dialog's OK did).
	open_btn.pressed.connect(func():
		_close_slots_popup()
		_try_load_scene(profile_scene)
	)
	close_btn.pressed.connect(_close_slots_popup)


func _close_slots_popup() -> void:
	if _slots_popup != null:
		_slots_popup.queue_free()
		_slots_popup = null
	_set_menu_focus(true)
	if new_char_btn:
		new_char_btn.grab_focus()


# While the popup is open the menu buttons behind it cannot take focus (gamepad / keyboard stay inside the popup).
func _set_menu_focus(enabled: bool) -> void:
	for b in [new_char_btn, load_char_btn, codex_btn, options_btn, alchemist_btn, quit_btn]:
		if b != null:
			b.focus_mode = Control.FOCUS_ALL if enabled else Control.FOCUS_NONE


func _unhandled_input(event: InputEvent) -> void:
	if _slots_popup != null and event.is_action_pressed("ui_cancel"):
		_close_slots_popup()
		get_viewport().set_input_as_handled()

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
