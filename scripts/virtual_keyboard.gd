# ==============================================================================
# File Name: virtual_keyboard.gd
# Path: res://scripts/virtual_keyboard.gd
#
# Dependencies: None (Standalone UI Component)
#
# Description:
#   An on-screen virtual keyboard for text entry. Supports mouse and gamepad
#   navigation with dynamic spatial focus mapping for the D-Pad. Styled by the
#   Purgatory UI theme (iron panel, inset text field, iron keys, ember focus) -
#   no shader, no blur: a flat dark scrim keeps the form behind it quiet.
#
# Mod Notes:
#   - Programmatic ClickBlocker added to prevent ghost-clicks through UI.
#   - Recursive Focus Trap: Background nodes are temporarily removed from
#     the focus graph while the keyboard is visible to strictly lock gamepad 
#     input inside the keyboard.
# ==============================================================================
extends Control

signal text_changed(new_text)
signal submitted(final_text)
signal cancelled()

var target_text: String = ""
var max_length: int = 20
var accept_spaces: bool = true

@export var key_width: int = 72
@export var key_height: int = 56

@onready var blur_overlay: ColorRect = $BlurOverlay
@onready var panel: PanelContainer = $Panel
@onready var input_label: Label = $Panel/VBox/InputDisplay

@onready var row_1: HBoxContainer = $Panel/VBox/KeyboardRows/Row1
@onready var row_2: HBoxContainer = $Panel/VBox/KeyboardRows/Row2
@onready var row_3: HBoxContainer = $Panel/VBox/KeyboardRows/Row3
@onready var row_4: HBoxContainer = $Panel/VBox/KeyboardRows/Row4
@onready var row_5: HBoxContainer = $Panel/VBox/KeyboardRows/Row5

var _keyboard_buttons: Array[Button] = []
var _trapped_focus_nodes: Dictionary = {}

func _ready() -> void:
	_setup_scrim()
	_style_input_display()

	_build_code_click_blocker()
	visibility_changed.connect(_on_visibility_changed)

	hide()
	update_display()
	build_keyboard()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return

	if event.is_action_pressed("ui_text_backspace"):
		_backspace()
		get_viewport().set_input_as_handled()
		return

	if event is InputEventKey and event.pressed and not event.echo:
		var key_event: InputEventKey = event as InputEventKey

		match key_event.keycode:
			KEY_BACKSPACE:
				_backspace()
				get_viewport().set_input_as_handled()
				return

			KEY_ENTER, KEY_KP_ENTER:
				submitted.emit(target_text)
				hide()
				get_viewport().set_input_as_handled()
				return

			KEY_ESCAPE:
				cancelled.emit()
				hide()
				get_viewport().set_input_as_handled()
				return

			KEY_SPACE:
				if accept_spaces and target_text.length() < max_length:
					target_text += " "
					update_display()
					text_changed.emit(target_text)
				get_viewport().set_input_as_handled()
				return

		var typed: String = key_event.as_text_key_label()

		if typed.length() == 1:
			var c: String = typed.to_upper()

			if _is_allowed_character(c) and target_text.length() < max_length:
				target_text += c
				update_display()
				text_changed.emit(target_text)
				get_viewport().set_input_as_handled()


# ══════════════════════════════════════════════════════════════
#  MODAL TRAPPING (ANTI-GHOST CLICK & GAMEPAD FOCUS)
# ══════════════════════════════════════════════════════════════

func _on_visibility_changed() -> void:
	if visible:
		_lock_background_focus()
	else:
		_unlock_background_focus()

func _build_code_click_blocker() -> void:
	var blocker = ColorRect.new()
	blocker.name = "ClickBlocker"
	blocker.color = Color(0, 0, 0, 0)

	blocker.custom_minimum_size = Vector2(5000, 5000)
	blocker.position = Vector2(-2500, -2500)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP

	add_child(blocker)
	move_child(blocker, 0)

func _lock_background_focus() -> void:
	_trapped_focus_nodes.clear()
	if get_tree() and get_tree().current_scene:
		_trap_focus_recursive(get_tree().current_scene)

func _trap_focus_recursive(node: Node) -> void:
	if node == self:
		return

	if node is Control and node.focus_mode != Control.FOCUS_NONE:
		_trapped_focus_nodes[node] = node.focus_mode
		node.focus_mode = Control.FOCUS_NONE

	for child in node.get_children():
		_trap_focus_recursive(child)

func _unlock_background_focus() -> void:
	for node in _trapped_focus_nodes:
		if is_instance_valid(node):
			node.focus_mode = _trapped_focus_nodes[node]
	_trapped_focus_nodes.clear()


# ══════════════════════════════════════════════════════════════
#  STYLING & SETUP
# ══════════════════════════════════════════════════════════════

# The old frosted-glass shader is gone (no shaders in the UI): a flat warm-black scrim dims what is behind.
func _setup_scrim() -> void:
	if blur_overlay == null:
		return
	blur_overlay.color = Color(PUI.VOID.r, PUI.VOID.g, PUI.VOID.b, 0.72)

# The typed text sits in the theme's recessed iron field (InsetPanel), the same look as every text input.
func _style_input_display() -> void:
	if input_label == null:
		return
	var inset := PUI.theme().get_stylebox("panel", "InsetPanel").duplicate() as StyleBoxTexture
	inset.content_margin_left = PUI.S4
	inset.content_margin_right = PUI.S4
	inset.content_margin_top = PUI.S2
	inset.content_margin_bottom = PUI.S2
	input_label.add_theme_stylebox_override("normal", inset)
	input_label.add_theme_color_override("font_color", PUI.BONE_BRIGHT)


# ══════════════════════════════════════════════════════════════
#  KEYBOARD BUILDER
# ══════════════════════════════════════════════════════════════

func build_keyboard() -> void:
	_keyboard_buttons.clear()
	_clear_row(row_1)
	_clear_row(row_2)
	_clear_row(row_3)
	_clear_row(row_4)
	_clear_row(row_5)

	_add_keys_to_row(row_1, ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"])
	_add_keys_to_row(row_2, ["A", "S", "D", "F", "G", "H", "J", "K", "L"])
	_add_keys_to_row(row_3, ["Z", "X", "C", "V", "B", "N", "M"])
	_add_keys_to_row(row_4, ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"])
	_add_keys_to_row(row_5, ["SPACE", "BACK", "CLEAR", "OK", "CANCEL"])

	call_deferred("_setup_button_focus")

func _clear_row(row: HBoxContainer) -> void:
	if row == null:
		return

	for child in row.get_children():
		child.queue_free()

func _add_keys_to_row(row: HBoxContainer, keys: Array[String]) -> void:
	if row == null:
		return

	for key in keys:
		var btn := Button.new()
		btn.text = _key_caption(key)
		btn.custom_minimum_size = _get_button_size_for_key(key)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		btn.focus_mode = Control.FOCUS_ALL
		btn.pressed.connect(_on_key_pressed.bind(key))
		_style_key_button(btn, key)
		row.add_child(btn)
		_keyboard_buttons.append(btn)

# Captions: letters and digits as typed; the five command keys in sentence case.
func _key_caption(key: String) -> String:
	match key:
		"SPACE": return "Space"
		"BACK": return "Back"
		"CLEAR": return "Clear"
		"CANCEL": return "Cancel"
	return key

func _get_button_size_for_key(key: String) -> Vector2:
	match key:
		"SPACE":
			return Vector2(120, key_height)
		"BACK":
			return Vector2(96, key_height)
		"CLEAR":
			return Vector2(96, key_height)
		"OK":
			return Vector2(82, key_height)
		"CANCEL":
			return Vector2(110, key_height)
		_:
			return Vector2(key_width, key_height)

# Keys are plain theme buttons: letters/digits and Space use the default iron button, Back/Clear/Cancel the quieter
# NavButton, OK the one primary action. Hover / focus (ember ring) / pressed come from the theme.
func _style_key_button(btn: Button, key: String) -> void:
	match key:
		"OK":
			btn.theme_type_variation = &"PrimaryButton"
		"BACK", "CLEAR", "CANCEL":
			btn.theme_type_variation = &"NavButton"
		_:
			btn.theme_type_variation = &""


# ══════════════════════════════════════════════════════════════
#  INTERNAL FOCUS MANAGEMENT
# ══════════════════════════════════════════════════════════════

func _setup_button_focus() -> void:
	if _keyboard_buttons.is_empty():
		return

	for i in range(_keyboard_buttons.size()):
		var btn: Button = _keyboard_buttons[i]
		if btn == null:
			continue

		var left_index: int = max(i - 1, 0)
		var right_index: int = min(i + 1, _keyboard_buttons.size() - 1)

		btn.focus_neighbor_left = _keyboard_buttons[left_index].get_path()
		btn.focus_neighbor_right = _keyboard_buttons[right_index].get_path()

	for i in range(_keyboard_buttons.size()):
		var btn: Button = _keyboard_buttons[i]
		if btn == null:
			continue

		var above: Button = _find_vertical_neighbor(i, -1)
		var below: Button = _find_vertical_neighbor(i, 1)

		if above != null:
			btn.focus_neighbor_top = above.get_path()
		if below != null:
			btn.focus_neighbor_bottom = below.get_path()

func _find_vertical_neighbor(button_index: int, direction: int) -> Button:
	if button_index < 0 or button_index >= _keyboard_buttons.size():
		return null

	var current: Button = _keyboard_buttons[button_index]
	if current == null:
		return null

	var current_pos: Vector2 = current.global_position
	var current_center: Vector2 = current_pos + (current.size * 0.5)

	var best_button: Button = null
	var best_score: float = INF

	for candidate in _keyboard_buttons:
		if candidate == null or candidate == current:
			continue

		var candidate_pos: Vector2 = candidate.global_position
		var candidate_center: Vector2 = candidate_pos + (candidate.size * 0.5)
		var delta: Vector2 = candidate_center - current_center

		if direction < 0 and delta.y >= -1.0:
			continue
		if direction > 0 and delta.y <= 1.0:
			continue

		var score: float = absf(delta.y) * 10.0 + absf(delta.x)
		if score < best_score:
			best_score = score
			best_button = candidate

	return best_button

func focus_first_key() -> void:
	for btn in _keyboard_buttons:
		if btn != null:
			btn.grab_focus()
			return


# ══════════════════════════════════════════════════════════════
#  INPUT LOGIC
# ══════════════════════════════════════════════════════════════

func _on_key_pressed(key: String) -> void:
	match key:
		"BACK":
			_backspace()

		"CLEAR":
			target_text = ""

		"SPACE":
			if accept_spaces and target_text.length() < max_length:
				target_text += " "

		"OK":
			submitted.emit(target_text)
			hide()
			return

		"CANCEL":
			cancelled.emit()
			hide()
			return

		_:
			if target_text.length() < max_length:
				target_text += key

	update_display()
	text_changed.emit(target_text)

func _backspace() -> void:
	if target_text.length() > 0:
		target_text = target_text.substr(0, target_text.length() - 1)
		update_display()
		text_changed.emit(target_text)

func _is_allowed_character(c: String) -> bool:
	if c >= "A" and c <= "Z":
		return true
	if c >= "0" and c <= "9":
		return true
	return false

func update_display() -> void:
	if input_label != null:
		input_label.text = target_text


# ══════════════════════════════════════════════════════════════
#  API EXPORTS
# ══════════════════════════════════════════════════════════════

func open_with_text(new_text: String, new_max_length: int = 20, allow_spaces_value: bool = true) -> void:
	max_length = new_max_length
	accept_spaces = allow_spaces_value
	target_text = new_text.substr(0, max_length)
	update_display()
	show()
	call_deferred("focus_first_key")

func clear_and_open(new_max_length: int = 20, allow_spaces_value: bool = true) -> void:
	max_length = new_max_length
	accept_spaces = allow_spaces_value
	target_text = ""
	update_display()
	show()
	call_deferred("focus_first_key")

func set_text(new_text: String) -> void:
	target_text = new_text.substr(0, max_length)
	update_display()

func clear_text() -> void:
	target_text = ""
	update_display()

func get_text() -> String:
	return target_text
