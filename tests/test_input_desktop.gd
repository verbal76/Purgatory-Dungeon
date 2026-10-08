extends Node
## Windows/desktop input must be untouched by the touch layer: bindings intact, no layer installed,
## InputManager still switches keyboard <-> gamepad and now also reports touch.

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _has_key(action: String, physical: int) -> bool:
	for e in InputMap.action_get_events(action):
		if e is InputEventKey and ((e as InputEventKey).physical_keycode == physical or (e as InputEventKey).keycode == physical):
			return true
	return false


func _has_mouse(action: String, button: int) -> bool:
	for e in InputMap.action_get_events(action):
		if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == button:
			return true
	return false


func _has_pad_button(action: String, button: int) -> bool:
	for e in InputMap.action_get_events(action):
		if e is InputEventJoypadButton and (e as InputEventJoypadButton).button_index == button:
			return true
	return false


func _has_pad_axis(action: String, axis: int) -> bool:
	for e in InputMap.action_get_events(action):
		if e is InputEventJoypadMotion and (e as InputEventJoypadMotion).axis == axis:
			return true
	return false


func _ready() -> void:
	if OS.get_environment("PURGATORY_FORCE_TOUCH") == "1":
		printerr("FAIL: this test checks the DESKTOP configuration; do not set PURGATORY_FORCE_TOUCH")
		get_tree().quit(2)
		return
	_check(not TouchControls.is_touch_platform(), "desktop is not a touch platform")
	_check(TouchControls.install(self) == null and get_tree().get_first_node_in_group(TouchControls.GROUP) == null, "no touch layer is installed on desktop")

	# Keyboard + mouse
	for pair in [["move_forward", KEY_W], ["move_back", KEY_S], ["move_left", KEY_A], ["move_right", KEY_D], ["jump", KEY_SPACE], ["kick", KEY_F], ["AOE", KEY_Q], ["equip", KEY_E], ["minimap", KEY_TAB]]:
		_check(_has_key(pair[0], pair[1]), "keyboard: %s is bound to its key" % pair[0])
	_check(_has_mouse("attack", MOUSE_BUTTON_LEFT) and _has_mouse("block", MOUSE_BUTTON_RIGHT), "mouse: attack = LMB, block = RMB")
	# Gamepad
	_check(_has_pad_axis("move_left", JOY_AXIS_LEFT_X) and _has_pad_axis("move_forward", JOY_AXIS_LEFT_Y), "gamepad: left stick moves")
	_check(_has_pad_axis("look_right", JOY_AXIS_RIGHT_X), "gamepad: right stick looks")
	_check(_has_pad_button("jump", JOY_BUTTON_B) and _has_pad_button("kick", JOY_BUTTON_RIGHT_SHOULDER) and _has_pad_button("AOE", JOY_BUTTON_LEFT_SHOULDER) and _has_pad_button("equip", JOY_BUTTON_A), "gamepad: B slide, RB kick, LB blast, A use")
	_check(_has_pad_axis("attack", JOY_AXIS_TRIGGER_RIGHT) and _has_pad_axis("minimap", JOY_AXIS_TRIGGER_LEFT), "gamepad: RT attack, LT map")
	_check(_has_pad_button("block", JOY_BUTTON_DPAD_DOWN) and _has_pad_button("ui_menu", JOY_BUTTON_START), "gamepad: D-pad down blocks, Start pauses")

	# InputManager schemes
	Input.use_accumulated_input = false
	var im: Node = get_node("/root/InputManager")
	var k := InputEventKey.new()
	k.keycode = KEY_W
	k.pressed = true
	im._input(k)
	_check(im.is_keyboard(), "a key press selects the keyboard scheme")
	var jb := InputEventJoypadButton.new()
	jb.button_index = JOY_BUTTON_A
	jb.pressed = true
	im._input(jb)
	_check(im.is_gamepad(), "a pad button selects the gamepad scheme")
	var mm := InputEventMouseMotion.new()
	mm.relative = Vector2(3, 0)
	im._input(mm)
	_check(im.is_keyboard(), "a real mouse selects the keyboard scheme")
	var tt := InputEventScreenTouch.new()
	tt.pressed = true
	im._input(tt)
	_check(im.is_touch(), "a screen touch selects the touch scheme")
	im._input(k)
	_check(im.is_keyboard(), "...and a key switches back")
	# Prompt text follows the scheme.
	im.current_scheme = im.Scheme.TOUCH
	_check(im.glyph("equip") == "USE" and im.glyph("ui_accept") == "TAP", "touch prompts name on-screen controls")
	im.current_scheme = im.Scheme.GAMEPAD
	_check(im.glyph("equip") == "A" and im.glyph("restart") == "X", "gamepad prompts name pad buttons")
	im.current_scheme = im.Scheme.KEYBOARD
	_check(im.glyph("equip") == "E" and im.glyph("kick") == "F", "keyboard prompts name keys")

	# The touch control scheme is a phone-only setting: whichever value is saved, the desktop gets no layer, no
	# selector in Options, and keeps its mouse look / click bindings.
	for scheme in ["twin", "classic"]:
		SettingsManager.gameplay_settings[TouchControls.KEY_SCHEME] = scheme
		_check(TouchControls.install(self) == null and get_tree().get_first_node_in_group(TouchControls.GROUP) == null, "desktop: no touch layer with scheme '%s'" % scheme)
		_check(_has_mouse("attack", MOUSE_BUTTON_LEFT) and _has_mouse("block", MOUSE_BUTTON_RIGHT) and _has_key("move_forward", KEY_W), "desktop: mouse and keyboard bindings unchanged with scheme '%s'" % scheme)
	var opts := (load("res://scenes/OptionsScreen.tscn") as PackedScene).instantiate()
	add_child(opts)
	for i in 6:
		await get_tree().process_frame
	_check(opts.find_child("Scheme_twin", true, false) == null and opts.find_child("Scheme_classic", true, false) == null, "desktop Options has no touch control scheme selector")
	opts.queue_free()
	SettingsManager.gameplay_settings[TouchControls.KEY_SCHEME] = TouchControls.DEFAULT_SCHEME

	# Window modes still apply on desktop (not gated away).
	_check(not (OS.has_feature("mobile") or TouchControls.is_touch_platform()), "window-mode code is active on desktop")

	print("test_input_desktop: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
