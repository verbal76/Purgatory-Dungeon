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

enum Scheme { KEYBOARD, GAMEPAD, TOUCH }

var current_scheme : Scheme = Scheme.KEYBOARD

signal input_method_changed(scheme: Scheme)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	# Phones start on touch prompts (and the Android back button must not quit the game).
	if TouchControls.is_touch_platform():
		current_scheme = Scheme.TOUCH
		MobileUi.install(get_tree())
		AppLifecycle.install(get_tree())


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		_set_scheme(Scheme.TOUCH)
	elif event is InputEventMouseMotion or event is InputEventMouseButton:
		# Mouse events a finger emulates are not a real mouse: stay on touch.
		if event.device == InputEvent.DEVICE_ID_EMULATION:
			return
		if TouchControls.is_touch_platform():
			return
		_set_scheme(Scheme.KEYBOARD)
	elif event is InputEventJoypadButton or event is InputEventJoypadMotion:
		# Ignore analog stick drift below the dead zone.
		if event is InputEventJoypadMotion and absf(event.axis_value) < 0.2:
			return
		_set_scheme(Scheme.GAMEPAD)
	elif event is InputEventKey:
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
func is_touch()    -> bool: return current_scheme == Scheme.TOUCH


## Button label for the active input scheme, for prompts ("Press %s to ..."): action -> text.
## Touch has no key to press, so touch prompts name the on-screen control instead.
func glyph(action: String) -> String:
	match current_scheme:
		Scheme.TOUCH:
			match action:
				"equip": return "USE"
				"ui_accept": return "TAP"
				"jump": return "SLIDE"
				"kick": return "KICK"
				"attack": return "ATTACK"
				"block": return "BLOCK"
				"AOE": return "BURST"
				"ui_menu": return "PAUSE"
				"restart": return "TAP"
				_: return action.to_upper()
		Scheme.GAMEPAD:
			match action:
				"equip", "ui_accept": return "A"
				"jump": return "B"
				"kick": return "RB"
				"AOE": return "LB"
				"attack": return "RT"
				"block": return "D-pad Down"
				"ui_menu": return "Start"
				"restart": return "X"
				_: return action.to_upper()
		_:
			match action:
				"equip": return "E"
				"ui_accept": return "Enter"
				"jump": return "Space"
				"kick": return "F"
				"AOE": return "Q"
				"attack": return "Left Mouse"
				"block": return "Right Mouse"
				"ui_menu": return "Esc"
				"restart": return "X"
				_: return action.to_upper()


# Android back button / gesture: with quit_on_go_back off it arrives as a notification. Turn it into
# the same 'cancel' every menu and the pause toggle already listen to.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		for pressed in [true, false]:
			var ev := InputEventAction.new()
			ev.action = "ui_cancel"
			ev.pressed = pressed
			ev.strength = 1.0 if pressed else 0.0
			Input.parse_input_event(ev)
