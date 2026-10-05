extends Node
## The touch layer drives the SAME semantic actions as keyboard and gamepad. Needs
## PURGATORY_FORCE_TOUCH=1 (run_tests.sh sets it): the layer only exists on touch platforms.

var _fails: int = 0
var _checks: int = 0
var _probe_motion: Array = []   # [relative.x, device] of every mouse-motion event that reaches the game
var _probe: Node


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _flush() -> void:
	Input.flush_buffered_events()


func _touch(index: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = pressed
	Input.parse_input_event(e)
	_flush()


func _drag(index: int, pos: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = pos
	e.relative = rel
	Input.parse_input_event(e)
	_flush()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _any_action_down() -> Array:
	var down: Array = []
	for a in ["move_left", "move_right", "move_forward", "move_back", "attack", "kick", "jump", "block", "AOE", "equip", "minimap", "ui_menu"]:
		if Input.is_action_pressed(a):
			down.append(a)
	return down


class Probe extends Node:
	var sink: Array
	func _unhandled_input(event: InputEvent) -> void:
		if event is InputEventMouseMotion:
			sink.append([(event as InputEventMouseMotion).relative.x, (event as InputEventMouseMotion).device])


func _ready() -> void:
	if OS.get_environment("PURGATORY_FORCE_TOUCH") != "1":
		printerr("FAIL: run with PURGATORY_FORCE_TOUCH=1")
		get_tree().quit(2)
		return
	Input.use_accumulated_input = false
	# This file proves the CLASSIC scheme (swipe look, original cluster) is exactly what it was; twin-stick is
	# covered by test_twin_stick.gd. Twin-stick is the default, so pick Classic explicitly.
	SettingsManager.gameplay_settings[TouchControls.KEY_SCHEME] = TouchControls.SCHEME_CLASSIC
	# Fresh tutorial state so onboarding is testable.
	SettingsManager.gameplay_settings.erase(TouchOnboarding.SETTINGS_KEY)
	SettingsManager.gameplay_settings.erase(TouchOnboarding.SHOWS_KEY)
	_probe = Probe.new()
	_probe.sink = _probe_motion
	add_child(_probe)

	# --- Pure layout: every button inside the safe area, no overlaps, all common phone shapes ----------
	for view in [Vector2(1280, 720), Vector2(1600, 720), Vector2(1680, 720), Vector2(1800, 720), Vector2(960, 720), Vector2(1280, 600)]:
		for insets in [Vector4(0, 0, 0, 0), Vector4(48, 0, 48, 20), Vector4(90, 0, 24, 30)]:
			for s in [0.7, 1.0, 1.5]:
				var lay: Dictionary = TouchControls.compute_layout(view, insets, s)
				var safe: Rect2 = lay["safe"]
				var names: Array = lay["buttons"].keys()
				var ok_in := true
				for n in names:
					var spec: Array = lay["buttons"][n]
					var c: Vector2 = spec[0]
					var r: float = spec[1]
					if c.x - r < safe.position.x - 0.5 or c.x + r > safe.end.x + 0.5 or c.y - r < safe.position.y - 0.5 or c.y + r > safe.end.y + 0.5:
						ok_in = false
				_check(ok_in, "all buttons inside the safe area (view %s insets %s scale %.1f)" % [view, insets, s])
				var ok_sep := true
				for i in names.size():
					for j in range(i + 1, names.size()):
						var a: Array = lay["buttons"][names[i]]
						var b: Array = lay["buttons"][names[j]]
						if (a[0] as Vector2).distance_to(b[0]) < float(a[1]) + float(b[1]) - 0.5:
							ok_sep = false
				if s <= 1.0:   # 150% buttons are allowed to crowd small screens; the defaults must not overlap
					_check(ok_sep, "no two buttons overlap (view %s scale %.1f)" % [view, s])
				var sd: Vector2 = lay["stick_default"]
				_check(safe.has_point(sd), "the idle stick marker is inside the safe area (view %s)" % view)
	# Phone safe area: a cutout on the left of a 2992x1344 panel pushes the layout in.
	var ins := TouchControls.insets_from_safe_area(Vector2(2992, 1344), Rect2(120, 0, 2752, 1344), Vector2(1600, 720))
	_check(is_equal_approx(ins.x, 120.0 * 1600.0 / 2992.0) and is_equal_approx(ins.z, 120.0 * 1600.0 / 2992.0) and ins.y == 0.0 and ins.w == 0.0, "safe-area insets are converted to virtual pixels (%s)" % ins)

	# --- The live layer ------------------------------------------------------------------------------------
	var tc := TouchControls.new()
	tc.layout_override_insets = Vector4(0, 0, 0, 0)
	tc.view_override = Vector2(1600, 720)   # a 20:9 phone in virtual pixels (the headless window is tiny)
	add_child(tc)
	await _frames(2)
	var view: Vector2 = tc.view_size()
	_check(InputMap.action_get_events("attack").all(func(e): return not (e is InputEventMouseButton)), "mouse buttons are not bound to attack on touch (a tap must not attack)")
	_check(not InputMap.action_get_events("attack").is_empty() and not InputMap.action_get_events("move_left").is_empty(), "other bindings (keyboard/gamepad) remain")

	# Left stick -> movement actions.
	var s0: Vector2 = Vector2(view.x * 0.15, view.y * 0.7)
	_touch(0, s0, true)
	_drag(0, s0 + Vector2(100, 0), Vector2(100, 0))
	_check(Input.is_action_pressed("move_right") and not Input.is_action_pressed("move_left"), "stick right -> move_right")
	_check(Input.get_axis("move_left", "move_right") > 0.95, "full stick = full strength (%.2f)" % Input.get_axis("move_left", "move_right"))
	_drag(0, s0 + Vector2(100, -100), Vector2(0, -100))
	_check(Input.is_action_pressed("move_forward"), "stick up -> move_forward")
	_drag(0, tc._stick_base + Vector2(8, -8), Vector2(-90, 90))   # the floating base followed the thumb
	_check(_any_action_down().is_empty(), "inside the dead zone nothing moves (%s)" % [_any_action_down()])
	_drag(0, tc._stick_base + Vector2(-60, 0), Vector2(-70, 10))
	_check(Input.is_action_pressed("move_left") and Input.get_axis("move_left", "move_right") < -0.2 and Input.get_axis("move_left", "move_right") > -0.95, "a partial push is analog (%.2f)" % Input.get_axis("move_left", "move_right"))
	_touch(0, s0, false)
	_check(_any_action_down().is_empty(), "releasing the stick releases every direction")

	# Right side -> look as mouse-look motion; no actions fire.
	_probe_motion.clear()
	var l0: Vector2 = Vector2(view.x * 0.55, view.y * 0.30)   # in the look zone, clear of every button
	_touch(1, l0, true)
	_drag(1, l0 + Vector2(100, 0), Vector2(100, 0))
	_touch(1, l0, false)
	var looked: Array = _probe_motion.filter(func(m): return m[1] != InputEvent.DEVICE_ID_EMULATION)
	_check(looked.size() >= 1 and absf(float(looked[0][0]) - 100.0 * TouchControls.LOOK_BASE_GAIN) < 0.01, "a 100 px swipe turns like %.0f mouse px (%s)" % [100.0 * TouchControls.LOOK_BASE_GAIN, looked])
	_check(_any_action_down().is_empty(), "swiping to look triggers no action")
	# Sensitivity setting scales it.
	SettingsManager.gameplay_settings[TouchControls.KEY_LOOK] = 200.0
	tc._apply_settings()
	_probe_motion.clear()
	_touch(1, l0, true)
	_drag(1, l0 + Vector2(50, 0), Vector2(50, 0))
	_touch(1, l0, false)
	looked = _probe_motion.filter(func(m): return m[1] != InputEvent.DEVICE_ID_EMULATION)
	_check(looked.size() >= 1 and absf(float(looked[0][0]) - 50.0 * TouchControls.LOOK_BASE_GAIN * 2.0) < 0.01, "look sensitivity setting scales the swipe")
	SettingsManager.gameplay_settings[TouchControls.KEY_LOOK] = 100.0
	tc._apply_settings()

	# Buttons -> the right semantic actions.
	for pair in [["attack", "attack"], ["kick", "kick"], ["jump", "jump"], ["block", "block"], ["AOE", "AOE"], ["ui_menu", "ui_menu"]]:
		var b: TouchButton = tc.buttons[pair[0]]
		_touch(2, b.center, true)
		_check(Input.is_action_pressed(pair[1]), "button %s presses action %s" % [pair[0], pair[1]])
		_check(_any_action_down() == [pair[1]], "button %s presses only its action (%s)" % [pair[0], _any_action_down()])
		_touch(2, b.center, false)
		await get_tree().create_timer(0.12).timeout
		_flush()
		_check(not Input.is_action_pressed(pair[1]), "button %s releases %s" % [pair[0], pair[1]])
	# A very short tap still lasts long enough for polling gameplay code to see it.
	var att: TouchButton = tc.buttons["attack"]
	_touch(2, att.center, true)
	_touch(2, att.center, false)
	_check(Input.is_action_pressed("attack"), "a tap is stretched so Input.is_action_just_pressed can see it")
	await get_tree().create_timer(0.12).timeout
	_flush()
	_check(not Input.is_action_pressed("attack"), "...and released afterwards")
	# Minimap is a toggle.
	var mm: TouchButton = tc.buttons["minimap"]
	_touch(2, mm.center, true)
	_touch(2, mm.center, false)
	_check(Input.is_action_pressed("minimap"), "map button toggles the minimap on")
	_touch(2, mm.center, true)
	_touch(2, mm.center, false)
	_check(not Input.is_action_pressed("minimap"), "...and off")

	# Everything at once: move + look + hold attack.
	_touch(0, s0, true)
	_drag(0, s0 + Vector2(100, 0), Vector2(100, 0))
	_touch(1, l0, true)
	_probe_motion.clear()
	_drag(1, l0 + Vector2(40, 0), Vector2(40, 0))
	_touch(2, att.center, true)
	_check(Input.is_action_pressed("move_right") and Input.is_action_pressed("attack") and not _probe_motion.is_empty(), "move + look + attack work at the same time")
	# Background / focus loss clears every held input and forgets the fingers.
	tc.notification(NOTIFICATION_APPLICATION_PAUSED)
	_flush()
	_check(_any_action_down().is_empty(), "app pause releases all touch input (%s)" % [_any_action_down()])
	_drag(0, s0 + Vector2(100, 0), Vector2(100, 0))
	_check(_any_action_down().is_empty(), "a stale finger does not resume movement after resume")
	_touch(0, s0, false)
	_touch(1, l0, false)
	_touch(2, att.center, false)

	# Pause menus: the layer hides and lets go.
	_touch(0, s0, true)
	_drag(0, s0 + Vector2(100, 0), Vector2(100, 0))
	get_tree().paused = true
	await _frames(2)
	_check(_any_action_down().is_empty() and not tc.get_node("TouchRoot").visible, "pausing hides the layer and releases input")
	_touch(0, att.center, true)
	_check(not Input.is_action_pressed("attack"), "touches are ignored while paused (they belong to the menu)")
	_touch(0, att.center, false)
	get_tree().paused = false
	await _frames(2)
	_check(tc.get_node("TouchRoot").visible, "the layer returns after the pause")

	# Contextual USE.
	var use_b: TouchButton = tc.buttons["equip"]
	_check(not use_b.visible, "USE is hidden until something usable is in range")
	tc.set_use_context(true, "OPEN")
	_check(use_b.visible and use_b.label == "OPEN", "USE appears with its label")
	_touch(3, use_b.center, true)
	_check(Input.is_action_pressed("equip"), "USE presses equip")
	_touch(3, use_b.center, false)
	await get_tree().create_timer(0.12).timeout
	tc.set_use_context(false)
	_check(not use_b.visible, "USE disappears when out of range")

	# --- Onboarding: one hint at a time, completed by doing, never repeated -------------------------------
	var ob: TouchOnboarding = tc.onboarding
	_check(not ob.is_done("move"), "onboarding starts fresh")
	ob._choose_next()
	_check(ob.active == "move", "the first hint is movement (%s)" % ob.active)
	tc.move_time = 1.0
	ob._process(0.016)
	_check(ob.is_done("move") and ob.active != "move", "moving completes the movement hint")
	ob._choose_next()
	_check(ob.active == "look", "then the look hint (%s)" % ob.active)
	tc.look_total = 500.0
	ob._process(0.016)
	_check(ob.is_done("look") and ob.active != "look", "swiping completes the look hint")
	ob._choose_next()
	_check(ob.active == "", "no attack hint while no enemy is near")
	var tc2 := TouchControls.new()
	tc2.layout_override_insets = Vector4(0, 0, 0, 0)
	tc2.view_override = Vector2(1600, 720)
	add_child(tc2)
	await _frames(2)
	tc2.onboarding._choose_next()
	_check(tc2.onboarding.active != "move" and tc2.onboarding.active != "look", "a completed hint does not return in a new session (%s)" % tc2.onboarding.active)
	_check(SettingsManager.gameplay_settings.get(TouchOnboarding.SETTINGS_KEY, {}).get("move", false), "completion is persisted in the settings")
	# Ignored hints retire themselves.
	var shows_before: int = int(SettingsManager.gameplay_settings.get(TouchOnboarding.SHOWS_KEY, {}).get("use", 0))
	for i in TouchOnboarding.MAX_SHOWS:
		ob._count_show("use")
	_check(ob.is_done("use") and shows_before == 0, "a hint shown %d times without being used retires" % TouchOnboarding.MAX_SHOWS)
	tc2.queue_free()

	# Hints never sit on a button the player has to press.
	tc.set_use_context(true, "OPEN")
	for step in ["attack", "use", "block", "burst", "move", "look"]:
		ob._activate(step)
		await _frames(2)
		ob._position_label()
		var lbl_rect := Rect2(ob._label.position, ob._label.size)
		var hit := ""
		for action in tc.buttons:
			var b: TouchButton = tc.buttons[action]
			if b.visible and lbl_rect.intersects(Rect2(b.center - Vector2(b.radius, b.radius), Vector2(b.radius, b.radius) * 2.0)):
				hit = action
		_check(hit == "", "the '%s' hint does not cover a button (covers '%s')" % [step, hit])
		ob._deactivate()
	tc.set_use_context(false)

	# A chest the player can open asks for the USE button, and gives it back when they walk away.
	var chest := (load("res://scripts/chest.gd") as GDScript).new() as StaticBody3D
	chest.set("color", "bronze")
	add_child(chest)
	await _frames(2)
	var body := CharacterBody3D.new()
	body.add_to_group("player")
	add_child(body)
	tc.set_use_context(false)   # baseline: nothing else asking
	var base_ctx: int = tc._use_context
	chest._on_body_near(body)
	_check(not tc.buttons["equip"].visible, "no USE button at a chest the player has no key for")
	PlayerWallet.add_key("bronze")
	chest._on_body_near(body)
	_check(tc.buttons["equip"].visible and tc.buttons["equip"].label == "OPEN", "USE (OPEN) shown at a chest the player can open")
	chest._on_body_leave(body)
	_check(tc._use_context == base_ctx, "USE button released when the player walks away (%d vs %d)" % [tc._use_context, base_ctx])
	chest.queue_free()
	body.queue_free()
	await _frames(2)

	# Teardown: nothing may be left pressed.
	tc.queue_free()
	await _frames(2)
	_check(_any_action_down().is_empty(), "removing the layer leaves nothing pressed")
	SettingsManager.update_setting(TouchControls.KEY_SCHEME, TouchControls.DEFAULT_SCHEME)   # leave the shared scratch settings as found
	print("test_touch_controls: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
