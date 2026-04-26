# ==============================================================================
# File Name: InputManager.gd
# Path: res://scripts/InputManager.gd
# Autoload Name: InputManager
# Description: Tracks whether the player is using keyboard/mouse or a gamepad
#              and emits input_method_changed whenever they switch.
#              Falls back to keyboard automatically if a controller disconnects.
#              Other scripts can read InputManager.current_scheme or connect to
#              input_method_changed to swap HUD prompts, cursor visibility, etc.
# ==============================================================================
extends Node

enum Scheme { KEYBOARD, GAMEPAD }

var current_scheme : Scheme = Scheme.KEYBOARD

signal input_method_changed(scheme: Scheme)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Input.joy_connection_changed.connect(_on_joy_connection_changed)


func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		# Ignore analog stick drift below the dead zone.
		if event is InputEventJoypadMotion and absf(event.axis_value) < 0.2:
			return
		_set_scheme(Scheme.GAMEPAD)
	elif event is InputEventKey or event is InputEventMouseButton or event is InputEventMouseMotion:
		_set_scheme(Scheme.KEYBOARD)


func _set_scheme(scheme: Scheme) -> void:
	if current_scheme == scheme:
		return
	current_scheme = scheme
	input_method_changed.emit(scheme)


func _on_joy_connection_changed(_device: int, connected: bool) -> void:
	# If the active controller is unplugged, fall back to keyboard automatically.
	if not connected and current_scheme == Scheme.GAMEPAD:
		_set_scheme(Scheme.KEYBOARD)


# Convenience helpers so callers don't need to reference the enum directly.
func is_gamepad()  -> bool: return current_scheme == Scheme.GAMEPAD
func is_keyboard() -> bool: return current_scheme == Scheme.KEYBOARD
