# ==============================================================================
# File Name: virtual_keyboard.gd
# Path: res://scripts/virtual_keyboard.gd
#
# Dependencies: None (Standalone UI Component)
#
# Description:
#   An on-screen virtual keyboard for text entry. Supports mouse and gamepad
#   navigation with dynamic spatial focus mapping for the D-Pad. Features
#   a dynamic shader background.
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
@export var key_height: int = 44

@onready var blur_overlay: ColorRect = $BlurOverlay
@onready var panel: Panel = $Panel
@onready var input_label: Label = $Panel/VBox/InputDisplay

@onready var row_1: HBoxContainer = $Panel/VBox/KeyboardRows/Row1
@onready var row_2: HBoxContainer = $Panel/VBox/KeyboardRows/Row2
@onready var row_3: HBoxContainer = $Panel/VBox/KeyboardRows/Row3
@onready var row_4: HBoxContainer = $Panel/VBox/KeyboardRows/Row4
@onready var row_5: HBoxContainer = $Panel/VBox/KeyboardRows/Row5

var _blur_material: ShaderMaterial
var _keyboard_buttons: Array[Button] = []
var _trapped_focus_nodes: Dictionary = {}

func _ready() -> void:
	_setup_blur_overlay()
	_style_keyboard_panel()
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

func _setup_blur_overlay() -> void:
	if blur_overlay == null:
		return

	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;

uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform float blur_strength = 2.0;
uniform vec4 tint_color : source_color = vec4(0.0, 0.0, 0.0, 0.28);

void fragment() {
	vec2 size = vec2(textureSize(SCREEN_TEXTURE, 0));
	vec2 pixel = 1.0 / size;

	vec4 c = textureLod(SCREEN_TEXTURE, SCREEN_UV, blur_strength);
	c += textureLod(SCREEN_TEXTURE, SCREEN_UV + vec2(pixel.x, 0.0) * 2.0, blur_strength);
	c += textureLod(SCREEN_TEXTURE, SCREEN_UV - vec2(pixel.x, 0.0) * 2.0, blur_strength);
	c += textureLod(SCREEN_TEXTURE, SCREEN_UV + vec2(0.0, pixel.y) * 2.0, blur_strength);
	c += textureLod(SCREEN_TEXTURE, SCREEN_UV - vec2(0.0, pixel.y) * 2.0, blur_strength);
	c /= 5.0;

	COLOR = mix(c, tint_color, tint_color.a);
}
"""
	_blur_material = ShaderMaterial.new()
	_blur_material.shader = shader
	_blur_material.set_shader_parameter("blur_strength", 2.4)
	_blur_material.set_shader_parameter("tint_color", Color(0, 0, 0, 0.40))
	blur_overlay.material = _blur_material

func _style_keyboard_panel() -> void:
	if panel == null:
		return

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.09, 0.96)
	style.corner_radius_top_left = 16
	style.corner_radius_top_right = 16
	style.corner_radius_bottom_right = 16
	style.corner_radius_bottom_left = 16
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(0.50, 0.54, 0.62, 0.60)
	style.shadow_color = Color(0, 0, 0, 0.50)
	style.shadow_size = 12
	style.content_margin_left = 10
	style.content_margin_top = 10
	style.content_margin_right = 10
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)

func _style_input_display() -> void:
	if input_label == null:
		return

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.13, 0.16, 0.98)
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	style.corner_radius_bottom_right = 10
	style.corner_radius_bottom_left = 10
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(0.58, 0.63, 0.72, 0.50)
	style.content_margin_left = 12
	style.content_margin_top = 8
	style.content_margin_right = 12
	style.content_margin_bottom = 8
	input_label.add_theme_stylebox_override("normal", style)
	input_label.add_theme_font_size_override("font_size", 20)


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
		btn.text = key
		btn.custom_minimum_size = _get_button_size_for_key(key)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		btn.focus_mode = Control.FOCUS_ALL
		btn.pressed.connect(_on_key_pressed.bind(key))
		_style_key_button(btn, key)
		row.add_child(btn)
		_keyboard_buttons.append(btn)

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

func _style_key_button(btn: Button, _key: String) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.16, 0.17, 0.20, 0.98)
	normal.corner_radius_top_left = 8
	normal.corner_radius_top_right = 8
	normal.corner_radius_bottom_right = 8
	normal.corner_radius_bottom_left = 8
	normal.border_width_left = 1
	normal.border_width_top = 1
	normal.border_width_right = 1
	normal.border_width_bottom = 1
	normal.border_color = Color(0.42, 0.45, 0.52, 0.55)
	normal.shadow_color = Color(0, 0, 0, 0.35)
	normal.shadow_size = 4
	normal.content_margin_left = 4
	normal.content_margin_top = 3
	normal.content_margin_right = 4
	normal.content_margin_bottom = 3

	var hover := normal.duplicate()
	hover.bg_color = Color(0.21, 0.22, 0.26, 1.0)
	hover.border_color = Color(0.62, 0.67, 0.78, 0.8)

	var pressed := normal.duplicate()
	pressed.bg_color = Color(0.11, 0.12, 0.15, 1.0)
	pressed.content_margin_top = 5
	pressed.content_margin_bottom = 1

	var focus := hover.duplicate()
	focus.border_width_left = 2
	focus.border_width_top = 2
	focus.border_width_right = 2
	focus.border_width_bottom = 2
	focus.border_color = Color(0.85, 0.90, 1.0, 0.95)

	var disabled := normal.duplicate()
	disabled.bg_color = Color(0.12, 0.12, 0.13, 0.70)
	disabled.border_color = Color(0.25, 0.25, 0.28, 0.50)

	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_stylebox_override("focus", focus)
	btn.add_theme_stylebox_override("disabled", disabled)

	btn.add_theme_color_override("font_color", Color(0.93, 0.95, 0.98, 1.0))
	btn.add_theme_color_override("font_focus_color", Color(1, 1, 1, 1))
	btn.add_theme_color_override("font_hover_color", Color(1, 1, 1, 1))
	btn.add_theme_font_size_override("font_size", 15)


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
