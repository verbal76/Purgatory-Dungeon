# ==============================================================================
# File Name: profile_screen.gd
# Path: res://scripts/profile_screen.gd
#
# Dependencies: SaveManager (autoload)
#
# Description:
#   Slot authority screen. Displays all 10 save slots with context-aware
#   labels and popups. Each slot shows one of three states:
#     - Empty   → available for new character creation
#     - Valid   → fully initialized character with locked identity
#     - Broken  → file exists but identity is incomplete (ghost/corrupt)
#
#   Popup actions change based on slot state:
#     - Empty  → Create Character / Cancel
#     - Valid  → Load Character / Delete Character / Cancel
#     - Broken → Clear Slot / Cancel
#
# Adjustable Settings:
#   main_menu_scene  — scene to return to when Back is pressed
#   selection_scene  — scene to go to when loading or creating a character
#
# Mod Notes:
#   - Uses SaveManager.get_slot_state() for three-tier slot detection
#   - Dynamically shows/hides popup buttons based on slot state
#   - Class name displayed in slot text for valid characters
#   - Broken slots offer Clear Slot which deletes the corrupt file
#   - Existing scene nodes (ChoicePanel, ConfirmPanel) are reused with
#     dynamic text and visibility changes — no new scene nodes required
#   - Programmatic ClickBlocker added to prevent ghost-clicks through UI
#   - Focus locking: when popup is open, all background buttons have their
#     focus_mode set to FOCUS_NONE so gamepad cannot reach them. Restored
#     to FOCUS_ALL when popup closes.
# ==============================================================================
extends Control


# ══════════════════════════════════════════════════════════════
#  EXPORTS
# ══════════════════════════════════════════════════════════════

@export var main_menu_scene: String = "res://scenes/MainMenu.tscn"
@export var selection_scene: String = "res://scenes/CharacterSelection.tscn"


# ══════════════════════════════════════════════════════════════
#  NODE REFERENCES
# ══════════════════════════════════════════════════════════════

var slot_grid: GridContainer
var back_btn: Button
var popup_layer: Control
var choice_panel: PanelContainer
var confirm_panel: PanelContainer

# Buttons inside ChoicePanel — reused with dynamic text/visibility.
var load_btn: Button
var delete_btn: Button
var cancel_btn: Button

# Title label inside ChoicePanel — set dynamically per slot.
var slot_title_label: Label

# Buttons inside ConfirmPanel — delete confirmation flow.
var yes_btn: Button
var no_btn: Button

# Confirmation text label inside ConfirmPanel — set dynamically per action.
var confirm_label: Label


# ══════════════════════════════════════════════════════════════
#  RUNTIME STATE
# ══════════════════════════════════════════════════════════════

# Which slot index the player clicked on. -1 means nothing selected.
var selected_index: int = -1

# The state of the currently selected slot: "empty", "valid", or "broken".
var selected_slot_state: String = "empty"


# ══════════════════════════════════════════════════════════════
#  LIFECYCLE
# ══════════════════════════════════════════════════════════════

func _ready() -> void:
	# The dungeon captures the mouse; make sure menus are clickable after leaving it.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_bind_nodes()
	_connect_buttons()
	_build_code_click_blocker()
	_populate_slots()

	# GAMEPAD: Focus the back button so the controller works immediately.
	if back_btn:
		back_btn.call_deferred("grab_focus")

	_wire_button_clicks()


func _wire_button_clicks() -> void:
	if has_node("/root/AudioManager"):
		AudioManager.wire_click_sounds(self)


# ══════════════════════════════════════════════════════════════
#  NODE BINDING
# ══════════════════════════════════════════════════════════════

func _bind_nodes() -> void:
	slot_grid = find_child("SlotGrid", true, false)
	back_btn = find_child("BackButton", true, false)
	popup_layer = find_child("PopupLayer", true, false)
	choice_panel = find_child("ChoicePanel", true, false)
	confirm_panel = find_child("ConfirmPanel", true, false)

	# Grab individual popup buttons for dynamic control.
	load_btn = find_child("LoadBtn", true, false)
	delete_btn = find_child("DeleteBtn", true, false)
	cancel_btn = find_child("CancelBtn", true, false)
	yes_btn = find_child("YesBtn", true, false)
	no_btn = find_child("NoBtn", true, false)

	# Grab labels for dynamic popup text.
	slot_title_label = find_child("SlotTitle", true, false)

	# Scoped to ConfirmPanel so it doesn't grab a wrong Label elsewhere.
	if confirm_panel:
		confirm_label = confirm_panel.find_child("Label", true, false)


# ══════════════════════════════════════════════════════════════
#  CLICK BLOCKER (ANTI-GHOST CLICK)
# ══════════════════════════════════════════════════════════════

# Creates an invisible shield behind the popups to eat stray mouse clicks.
# NOTE: This only blocks mouse input. Gamepad/keyboard focus is handled
# separately by _lock_background_focus() and _unlock_background_focus().
func _build_code_click_blocker() -> void:
	var blocker = ColorRect.new()
	blocker.name = "ClickBlocker"
	blocker.color = Color(0, 0, 0, 0.6)

	# Brute-force the size so it covers the entire viewport regardless
	# of PopupLayer's own size.
	blocker.custom_minimum_size = Vector2(5000, 5000)
	blocker.position = Vector2(-2500, -2500)

	# MOUSE_FILTER_STOP prevents any mouse event from passing through.
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP

	if popup_layer:
		popup_layer.add_child(blocker)
		popup_layer.move_child(blocker, 0)


# ══════════════════════════════════════════════════════════════
#  FOCUS LOCKING
# ══════════════════════════════════════════════════════════════

# When a popup is open, the gamepad/keyboard focus system can still
# jump to slot grid buttons and the back button behind the popup.
# These two functions disable and re-enable focus on all background
# controls so the player is trapped inside the popup until they
# dismiss it.

# Call this when a popup opens.
func _lock_background_focus() -> void:
	if back_btn:
		back_btn.focus_mode = Control.FOCUS_NONE
	if slot_grid:
		for child in slot_grid.get_children():
			if child is Button:
				child.focus_mode = Control.FOCUS_NONE


# Call this when all popups close.
func _unlock_background_focus() -> void:
	if back_btn:
		back_btn.focus_mode = Control.FOCUS_ALL
	if slot_grid:
		for child in slot_grid.get_children():
			if child is Button:
				child.focus_mode = Control.FOCUS_ALL


# ══════════════════════════════════════════════════════════════
#  SIGNAL CONNECTIONS
# ══════════════════════════════════════════════════════════════

func _connect_buttons() -> void:
	if back_btn:
		back_btn.pressed.connect(func(): get_tree().change_scene_to_file(main_menu_scene))

	# ChoicePanel buttons — actions depend on slot state at click time.
	if load_btn:
		load_btn.pressed.connect(_on_primary_action_pressed)
	if delete_btn:
		delete_btn.pressed.connect(_on_secondary_action_pressed)
	if cancel_btn:
		cancel_btn.pressed.connect(_hide_popups)

	# ConfirmPanel buttons — always used for delete/clear confirmation.
	if yes_btn:
		yes_btn.pressed.connect(_on_confirm_yes)
	if no_btn:
		no_btn.pressed.connect(_hide_popups)


# ══════════════════════════════════════════════════════════════
#  SLOT GRID POPULATION
# ══════════════════════════════════════════════════════════════

# Clears and rebuilds all 10 slot buttons with state-aware labels.
func _populate_slots() -> void:
	# Clear existing slot buttons.
	for child in slot_grid.get_children():
		child.queue_free()

	# Slots are inspected with SaveManager.peek_slot(), which has no side
	# effects, so the active slot and last-slot preference are untouched.
	for i in range(SaveManager.SLOT_COUNT):
		var btn = Button.new()
		btn.custom_minimum_size = Vector2(300, 50)
		btn.text = _build_slot_label(i)
		btn.pressed.connect(_on_slot_clicked.bind(i))
		slot_grid.add_child(btn)


# Builds the display label for a single slot based on its state.
func _build_slot_label(slot_index: int) -> String:
	var slot_num := str(slot_index + 1)
	var state := SaveManager.get_slot_state(slot_index)

	match state:
		"empty":
			return "Slot " + slot_num + ": (Empty)"

		"valid":
			# Peek into the slot to grab name and class for display.
			var peeked := SaveManager.peek_slot(slot_index)
			var char_name := str(peeked.get("character_name", "")).strip_edges()
			var char_class := str(peeked.get("character_class", "")).capitalize()
			var run_count := int(peeked.get("run_count", 0))
			var death_count := int(peeked.get("death_count", 0))
			return "Slot " + slot_num + ": " + char_name + " (" + char_class + ") — Runs: " + str(run_count) + " Deaths: " + str(death_count)

		"broken":
			return "Slot " + slot_num + ": (Corrupted Save)"

		_:
			return "Slot " + slot_num + ": (Unknown)"


# ══════════════════════════════════════════════════════════════
#  SLOT CLICK — CONTEXT-AWARE POPUP
# ══════════════════════════════════════════════════════════════

# When a slot is clicked, determine its state and configure the
# popup buttons accordingly before showing the panel.
func _on_slot_clicked(index: int) -> void:
	selected_index = index
	selected_slot_state = SaveManager.get_slot_state(index)

	# Configure buttons based on what this slot actually is.
	match selected_slot_state:
		"empty":
			_configure_popup_for_empty_slot()
		"valid":
			_configure_popup_for_valid_slot()
		"broken":
			_configure_popup_for_broken_slot()

	# Lock background so gamepad/keyboard can't escape the popup.
	_lock_background_focus()

	# Show the popup.
	popup_layer.show()
	choice_panel.show()
	confirm_panel.hide()

	# Focus the primary action button for gamepad navigation.
	if load_btn and load_btn.visible:
		load_btn.grab_focus()
	elif delete_btn and delete_btn.visible:
		delete_btn.grab_focus()
	elif cancel_btn:
		cancel_btn.grab_focus()


# ── Empty Slot: Create Character / Cancel ────────────────────
func _configure_popup_for_empty_slot() -> void:
	if slot_title_label:
		slot_title_label.text = "Slot " + str(selected_index + 1) + ": Empty"
	if load_btn:
		load_btn.text = "Create Character"
		load_btn.show()
	if delete_btn:
		delete_btn.hide()
	if cancel_btn:
		cancel_btn.text = "Cancel"
		cancel_btn.show()


# ── Valid Slot: Load Character / Delete Character / Cancel ────
func _configure_popup_for_valid_slot() -> void:
	if slot_title_label:
		# Peek at the slot to show the character name in the popup title.
		var original_slot := SaveManager.active_slot_index
		var original_profile := SaveManager.current_profile.duplicate(true)
		SaveManager.load_slot(selected_index)
		var char_name := SaveManager.get_character_name()
		var char_class := SaveManager.get_character_class().capitalize()
		slot_title_label.text = "Slot " + str(selected_index + 1) + ": " + char_name + " (" + char_class + ")"
		SaveManager.active_slot_index = original_slot
		SaveManager.current_profile = original_profile
	if load_btn:
		load_btn.text = "Load Character"
		load_btn.show()
	if delete_btn:
		delete_btn.text = "Delete Character"
		delete_btn.show()
	if cancel_btn:
		cancel_btn.text = "Cancel"
		cancel_btn.show()


# ── Broken Slot: Clear Slot / Cancel ─────────────────────────
func _configure_popup_for_broken_slot() -> void:
	if slot_title_label:
		slot_title_label.text = "Slot " + str(selected_index + 1) + ": Corrupted Save"
	if load_btn:
		load_btn.hide()
	if delete_btn:
		delete_btn.text = "Clear Slot"
		delete_btn.show()
	if cancel_btn:
		cancel_btn.text = "Cancel"
		cancel_btn.show()


# ══════════════════════════════════════════════════════════════
#  POPUP ACTIONS
# ══════════════════════════════════════════════════════════════

# Primary action (LoadBtn) — behavior changes based on slot state.
#   Empty slot → load the empty slot and go to CharacterSelection (new character mode)
#   Valid slot → load the character and go to CharacterSelection (existing character mode)
func _on_primary_action_pressed() -> void:
	if selected_index < 0:
		return

	match selected_slot_state:
		"empty":
			# Load the empty slot so CharacterSelection sees a blank profile.
			SaveManager.load_slot(selected_index)
			get_tree().change_scene_to_file(selection_scene)

		"valid":
			# Load the existing character so CharacterSelection sees locked identity.
			SaveManager.load_slot(selected_index)
			get_tree().change_scene_to_file(selection_scene)


# Secondary action (DeleteBtn) — behavior changes based on slot state.
#   Valid slot → confirm before deleting
#   Broken slot → confirm before clearing
func _on_secondary_action_pressed() -> void:
	if selected_index < 0:
		return

	match selected_slot_state:
		"valid":
			# Set confirmation text for character deletion.
			if confirm_label:
				confirm_label.text = "Delete this character?\nThis cannot be undone."
			choice_panel.hide()
			confirm_panel.show()
			if no_btn:
				no_btn.grab_focus()

		"broken":
			# Set confirmation text for corrupt slot clearing.
			if confirm_label:
				confirm_label.text = "Clear this corrupted save?\nThis cannot be undone."
			choice_panel.hide()
			confirm_panel.show()
			if no_btn:
				no_btn.grab_focus()


# Confirmation Yes — deletes or clears the selected slot.
func _on_confirm_yes() -> void:
	if selected_index < 0:
		return

	SaveManager.delete_slot(selected_index)
	_hide_popups()
	_populate_slots()

	# Return focus to the back button after the grid refreshes.
	if back_btn:
		back_btn.grab_focus()


# ══════════════════════════════════════════════════════════════
#  POPUP VISIBILITY
# ══════════════════════════════════════════════════════════════

# Hides all popup layers, unlocks background focus, and resets selection.
func _hide_popups() -> void:
	if popup_layer:
		popup_layer.hide()
	if choice_panel:
		choice_panel.hide()
	if confirm_panel:
		confirm_panel.hide()

	# Unlock background so gamepad can reach slot buttons again.
	_unlock_background_focus()

	# Return focus to the back button when popups close.
	if back_btn:
		back_btn.grab_focus()
