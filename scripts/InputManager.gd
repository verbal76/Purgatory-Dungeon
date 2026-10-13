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

const Glyphs := preload("res://scripts/controller_glyphs.gd")
const GraphicsQuality := preload("res://scripts/graphics_quality.gd")

enum Scheme { KEYBOARD, GAMEPAD, TOUCH }

var current_scheme : Scheme = Scheme.KEYBOARD
# Which family of pad the prompts are drawn for (Glyphs.Style: Xbox, PlayStation, Switch or Steam Deck / Steam Controller). Follows the pad last used, unless the
# player fixed it in Options > Controls (prompt_override: 0 = automatic, 1 Xbox, 2 PlayStation, 3 Switch, 4 Steam Deck).
var controller_style : int = Glyphs.Style.XBOX
var prompt_override : int = 0
var _detected_style : int = Glyphs.Style.XBOX
const OVERRIDE_STYLES := [-1, Glyphs.Style.XBOX, Glyphs.Style.PLAYSTATION, Glyphs.Style.SWITCH, Glyphs.Style.DECK]
const OVERRIDE_KEY := "ControllerPrompts"

signal input_method_changed(scheme: Scheme)
signal controller_style_changed(style: int)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	prompt_override = clampi(int(SettingsManager.get_setting(OVERRIDE_KEY, 0.0)), 0, OVERRIDE_STYLES.size() - 1)
	_apply_style()
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	# Phones start on touch prompts (and the Android back button must not quit the game).
	if TouchControls.is_touch_platform():
		current_scheme = Scheme.TOUCH
		MobileUi.install(get_tree())
		AppLifecycle.install(get_tree())
		PerfOverlay.install(get_tree())
	else:
		# Desktop (and Steam Deck): the 3D scene's resolution follows Options > Video > Graphics Quality (Medium by default on a Deck).
		# Deferred: SettingsManager has loaded the saved level by the time this runs.
		GraphicsQuality.apply.call_deferred(get_tree().root)


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		_set_scheme(Scheme.TOUCH)
	elif event is InputEventMouseMotion or event is InputEventMouseButton:
		# Mouse events a finger emulates are not a real mouse: stay on touch.
		if event.device == InputEvent.DEVICE_ID_EMULATION:
			return
		if TouchControls.is_touch_platform():
			return
		# Mixed input (Steam Deck trackpads and gyro send mouse motion while a pad is in use): moving the mouse never flips a controller's prompts
		# back to key caps; a deliberate click, or a key, does.
		if event is InputEventMouseMotion and current_scheme == Scheme.GAMEPAD:
			return
		_set_scheme(Scheme.KEYBOARD)
	elif event is InputEventJoypadButton or event is InputEventJoypadMotion:
		# Ignore analog stick drift (and a light brush of a stick or trigger) so prompts do not flicker; a real push, or any button, switches.
		if event is InputEventJoypadMotion and absf(event.axis_value) < (0.2 if current_scheme == Scheme.GAMEPAD else 0.5):
			return
		_set_controller_style(Glyphs.style_for_joy_name(Input.get_joy_name(event.device)))
		_set_scheme(Scheme.GAMEPAD)
	elif event is InputEventKey:
		_set_scheme(Scheme.KEYBOARD)


func _set_controller_style(style: int) -> void:
	_detected_style = style
	_apply_style()


## Options > Controls > Controller Prompts: 0 = follow the pad in use, otherwise draw prompts for that family. Saved with the other settings.
func set_prompt_override(value: int) -> void:
	prompt_override = clampi(value, 0, OVERRIDE_STYLES.size() - 1)
	SettingsManager.update_setting(OVERRIDE_KEY, float(prompt_override))
	_apply_style()


func _apply_style() -> void:
	var style: int = _detected_style if prompt_override == 0 else int(OVERRIDE_STYLES[prompt_override])
	if controller_style == style:
		return
	controller_style = style
	controller_style_changed.emit(style)


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
				"jump": return "REPULSE"
				"kick": return "KICK"
				"attack": return "ATTACK"
				"block": return "BLOCK"
				"AOE": return "BURST"
				"ui_menu": return "PAUSE"
				"restart": return "TAP"
				_: return action.to_upper()
		Scheme.GAMEPAD:
			# Read from the InputMap, so a remap in Options is followed, and in the label set of the pad in use.
			if action == "restart":
				return Glyphs.text("x", controller_style)
			var token: String = Glyphs.token_for_action(action)
			return Glyphs.text(token, controller_style) if token != "" else action.to_upper()
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
