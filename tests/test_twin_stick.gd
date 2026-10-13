extends Node
## Twin-stick touch scheme (the default): floating move stick + a dominant ATTACK button that also looks (drag from it
## turns through the Classic swipe path times a compact-input gain), subordinate buttons on an arc around it. There is NO right look stick and NO look zone: empty
## right-side screen is inert. Classic (swipe look) stays selectable and unchanged.
##
## Needs PURGATORY_FORCE_TOUCH=1 (run_tests.sh sets it). With TWIN_CLASS=barbarian|mage the second half of the
## file boots the real game scene and proves the ATTACK drag turns that class's real player.

const MAIN_SCENE := "res://scenes/Purgatory_Dungeon_main_game_file.tscn"

var _fails: int = 0
var _checks: int = 0
var _motion: Array = []        # [relative.x, relative.y, device] of every mouse-motion event that reaches the game
var _attack_events: Array = [] # true/false for every attack action press / release that reaches the game
var _probe: Node


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _flush() -> void:
	Input.flush_buffered_events()


var _last_pos: Dictionary = {}   # finger index -> last reported position (a real drag event carries the movement since the previous one)


func _touch(index: int, pos: Vector2, pressed: bool) -> void:
	_last_pos[index] = pos
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = pressed
	Input.parse_input_event(e)
	_flush()


func _drag(index: int, pos: Vector2, rel: Vector2 = Vector2.ZERO) -> void:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = pos
	e.relative = rel if rel != Vector2.ZERO else pos - Vector2(_last_pos.get(index, pos))
	_last_pos[index] = pos
	Input.parse_input_event(e)
	_flush()


## Waits n physics ticks AND n rendered frames (the engine may run several ticks inside one long frame, or several
## frames inside one tick; the aim is integrated per rendered frame).
func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
		await get_tree().process_frame
	_flush()


func _down_actions() -> Array:
	var down: Array = []
	for a in ["move_left", "move_right", "move_forward", "move_back", "attack", "kick", "jump", "block", "AOE", "equip", "minimap", "ui_menu"]:
		if Input.is_action_pressed(a):
			down.append(a)
	return down


func _real_motion() -> Array:
	return _motion.filter(func(m): return m[2] != InputEvent.DEVICE_ID_EMULATION)


class Probe extends Node:
	var motion: Array
	var attack: Array
	func _input(event: InputEvent) -> void:
		if event is InputEventMouseMotion:
			var m := event as InputEventMouseMotion
			motion.append([m.relative.x, m.relative.y, m.device])
		elif event is InputEventAction and (event as InputEventAction).action == "attack":
			attack.append((event as InputEventAction).pressed)


## A layer that pretends to run on a Pixel-class panel: 480 dpi, physical height = 1344/720 of the virtual height.
func _new_layer(view: Vector2, insets: Vector4 = Vector4(0, 0, 0, 0)) -> TouchControls:
	var tc := TouchControls.new()
	tc.layout_override_insets = insets
	tc.view_override = view
	tc.dpi_override = 480.0
	tc.screen_override = view * (1344.0 / 720.0)
	add_child(tc)
	return tc


func _ready() -> void:
	if OS.get_environment("PURGATORY_FORCE_TOUCH") != "1":
		printerr("FAIL: run with PURGATORY_FORCE_TOUCH=1")
		get_tree().quit(2)
		return
	Input.use_accumulated_input = false
	var cls: String = OS.get_environment("TWIN_CLASS")
	if cls != "":
		await _real_player_test(cls)
	else:
		await _layer_tests()
	print("test_twin_stick%s: %d checks, %d failures" % ["" if cls == "" else " (" + cls + ")", _checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


# ══════════════════════════════════════════════════════════════════════════════════════════════════
func _layer_tests() -> void:
	_probe = Probe.new()
	_probe.motion = _motion
	_probe.attack = _attack_events
	add_child(_probe)
	SettingsManager.gameplay_settings.erase(TouchOnboarding.SETTINGS_KEY)
	SettingsManager.gameplay_settings.erase(TouchOnboarding.SHOWS_KEY)

	_settings_tests()
	_layout_tests()
	_compact_gain_tests()

	var view := Vector2(1602, 720)   # the Pixel 10 Pro XL: 2992x1344 window, 1280x720 expand canvas
	var tc: TouchControls = _new_layer(view)
	await _frames(3)
	_check(tc.is_twin() and tc.scheme == TouchControls.SCHEME_TWIN, "a fresh layer on a default install is twin-stick")
	_removal_tests(tc)
	await _ownership_tests(tc, view)
	await _look_path_tests(tc, view)
	await _attack_drag_tests(tc, view)
	await _lifecycle_tests(tc, view)
	await _hit_tests(tc)
	await _scheme_switch_tests(tc, view)
	tc.queue_free()
	await _frames(2)
	await _onboarding_tests()
	await _options_tests()
	_check(_down_actions().is_empty(), "nothing is left pressed at the end")


# ── settings: default, persisted, existing installs ──────────────────────────────────────────────
func _settings_tests() -> void:
	_check(SettingsManager.gameplay_settings.get(TouchControls.KEY_SCHEME, "") == "twin", "the default control scheme is twin-stick (%s)" % SettingsManager.gameplay_settings.get(TouchControls.KEY_SCHEME, ""))
	_check(TouchControls.DEFAULT_SCHEME == TouchControls.SCHEME_TWIN, "DEFAULT_SCHEME is twin")
	SettingsManager.update_setting(TouchControls.KEY_SCHEME, "classic")
	SettingsManager.gameplay_settings[TouchControls.KEY_SCHEME] = "scrambled-in-memory"
	SettingsManager.load_settings()
	_check(SettingsManager.gameplay_settings.get(TouchControls.KEY_SCHEME) == "classic", "Classic is persisted to settings.json and reloaded")
	SettingsManager.update_setting(TouchControls.KEY_SCHEME, "twin")
	SettingsManager.gameplay_settings[TouchControls.KEY_SCHEME] = "scrambled-in-memory"
	SettingsManager.load_settings()
	_check(SettingsManager.gameplay_settings.get(TouchControls.KEY_SCHEME) == "twin", "twin-stick is persisted and reloaded")
	# An install from before this setting existed: no key in the file at all.
	var path: String = SettingsManager._settings_path
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(parsed is Dictionary and (parsed as Dictionary).has(TouchControls.KEY_SCHEME), "the scheme is stored under %s in settings.json" % TouchControls.KEY_SCHEME)
	(parsed as Dictionary).erase(TouchControls.KEY_SCHEME)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(parsed))
	f.close()
	SettingsManager.gameplay_settings.erase(TouchControls.KEY_SCHEME)
	SettingsManager.load_settings()
	_check(TouchControls.scheme_from(SettingsManager.gameplay_settings.get(TouchControls.KEY_SCHEME, TouchControls.DEFAULT_SCHEME)) == "twin", "an existing install with no saved key gets twin-stick")
	_check(TouchControls.scheme_from("") == "twin" and TouchControls.scheme_from(null) == "twin" and TouchControls.scheme_from("Classic") == "classic" and TouchControls.scheme_from("garbage") == "twin", "scheme_from normalises stored values")
	SettingsManager.update_setting(TouchControls.KEY_SCHEME, "twin")
	# The removed Aim Smoothing setting: a stale key in an older settings file is harmless and nothing reads it any more.
	SettingsManager.gameplay_settings["TouchAimSmoothing"] = 60.0
	var probe := TouchControls.new()
	add_child(probe)
	probe._apply_settings()
	_check(not ("aim_smoothing" in probe) and is_equal_approx(probe.look_gain, 1.0), "a stale TouchAimSmoothing key is ignored")
	probe.queue_free()
	SettingsManager.gameplay_settings.erase("TouchAimSmoothing")


# ── layout ───────────────────────────────────────────────────────────────────────────────────────
func _layout_tests() -> void:
	# [virtual canvas, physical panel, caption]: the panel only matters for px per mm (480 dpi everywhere).
	var cases: Array = [
		[Vector2(1280, 720), Vector2(1920, 1080), "1280x720 canvas on a 16:9 panel"],
		[Vector2(1603, 720), Vector2(2992, 1344), "1496x672 window shape (Pixel, 20:9)"],
		[Vector2(1602, 720), Vector2(2992, 1344), "Pixel 10 Pro XL 2992x1344 -> 1602x720"],
		[Vector2(1600, 720), Vector2(2400, 1080), "2400x1080 -> 1600x720"],
		[Vector2(1800, 720), Vector2(3000, 1200), "very wide 2.5:1"],
		[Vector2(1600, 720), 11.1, "small 6.3in phone (2424x1080, 422 dpi): 11.1 px/mm"],
		[Vector2(1602, 720), 12.0, "dense compact phone: 12 px/mm"],
	]
	for cse in cases:
		var view: Vector2 = cse[0]
		var ppmm: float = float(cse[1]) if cse[1] is float else TouchControls.px_per_mm(view, cse[1], 480.0)
		for insets in [Vector4(0, 0, 0, 0), Vector4(48, 0, 48, 20), Vector4(90, 0, 24, 30), Vector4(0, 40, 80, 0)]:
			for s in [0.7, 1.0, 1.5]:
				var tag := "%s insets %s size %.1f" % [cse[2], insets, s]
				var lay: Dictionary = TouchControls.compute_layout(view, insets, s, "twin", ppmm)
				var safe: Rect2 = lay["safe"]
				var names: Array = lay["buttons"].keys()
				_check(names.size() == 8, "twin layout places all 8 controls (%d) %s" % [names.size(), tag])
				var inside := true
				for n in names:
					var c: Vector2 = lay["buttons"][n][0]
					var r: float = lay["buttons"][n][1]
					if c.x - r < safe.position.x - 0.5 or c.x + r > safe.end.x + 0.5 or c.y - r < safe.position.y - 0.5 or c.y + r > safe.end.y + 0.5:
						inside = false
				_check(inside, "every control inside the safe area: %s" % tag)
				if s <= 1.0:
					var sep := true
					var bad := ""
					for i in names.size():
						for j in range(i + 1, names.size()):
							var a: Array = lay["buttons"][names[i]]
							var b: Array = lay["buttons"][names[j]]
							if (a[0] as Vector2).distance_to(b[0]) < float(a[1]) + float(b[1]) - 0.5:
								sep = false
								bad = "%s/%s" % [names[i], names[j]]
					_check(sep, "no two controls overlap (%s): %s" % [bad, tag])
					# the idle move-stick marker stays clear of every button and inside the safe area; there is no other marker
					var m: Vector2 = lay["stick_default"]
					_check(safe.has_point(m), "stick_default marker is inside the safe area: %s" % tag)
					var clear := true
					for n in names:
						if n == "equip":
							continue   # contextual, appears only at a chest
						var bb: Array = lay["buttons"][n]
						if m.distance_to(bb[0]) < TouchControls.STICK_RADIUS * s * 0.8 + float(bb[1]):
							clear = false
					_check(clear, "stick_default marker does not sit on a button: %s" % tag)
					_check(not lay.has("look_default") and not lay.has("look_zone"), "the layout has no look marker and no look zone: %s" % tag)
				# physical sizes
				var atk_mm: float = float(lay["buttons"]["attack"][1]) * 2.0 / ppmm
				_check(atk_mm >= TouchControls.ATTACK_MIN_MM - 0.01, "ATTACK is >= %.0f mm (%.1f mm): %s" % [TouchControls.ATTACK_MIN_MM, atk_mm, tag])
				for n in ["jump", "kick", "block", "AOE", "equip"]:
					var mm: float = float(lay["buttons"][n][1]) * 2.0 / ppmm
					_check(mm >= TouchControls.SUB_MIN_MM - 0.01, "%s is >= %.0f mm (%.1f mm): %s" % [n, TouchControls.SUB_MIN_MM, mm, tag])
					if n != "equip":
						var ratio: float = float(lay["buttons"]["attack"][1]) / float(lay["buttons"][n][1])
						_check(ratio >= 1.6 and ratio <= 2.0 + 0.001, "ATTACK is 1.6-2x a subordinate (%.2fx %s): %s" % [ratio, n, tag])
				# the arc is on the upper/left side of ATTACK (the right thumb hops, never crossing the move stick)
				if s <= 1.0:
					var ac: Vector2 = lay["buttons"]["attack"][0]
					var ar: float = lay["buttons"]["attack"][1]
					for n in ["jump", "kick", "block", "AOE"]:
						var c2: Vector2 = lay["buttons"][n][0]
						_check(c2.x <= ac.x + ar * 0.6 and c2.y <= ac.y + ar * 0.6, "%s sits on the upper/left side of ATTACK: %s" % [n, tag])
	# The only touch zone is the move stick's (left ~40%, lower 72%); there is no look zone anywhere.
	var lay2: Dictionary = TouchControls.compute_layout(Vector2(1602, 720), Vector4.ZERO, 1.0, "twin", 10.12)
	var sz: Rect2 = lay2["stick_zone"]
	_check(sz.position.x == 0.0 and is_equal_approx(sz.end.x, 1602.0 * 0.40), "the move zone is the left 40%")
	# Exact numbers at the Pixel shape (documented in docs/ANDROID.md)
	var pp: float = TouchControls.px_per_mm(Vector2(1602, 720), Vector2(2992, 1344), 480.0)
	_check(absf(pp - 10.123) < 0.01, "10.1 virtual px per mm on the Pixel (%.3f)" % pp)
	_check(is_equal_approx(float(lay2["buttons"]["attack"][1]), 100.0) and is_equal_approx(float(lay2["buttons"]["kick"][1]), 56.0), "ATTACK r=100 (19.8 mm), subordinates r=56 (11.1 mm)")
	# Classic is exactly the original layout (golden numbers from before twin-stick existed)
	var cl: Dictionary = TouchControls.compute_layout(Vector2(1280, 720), Vector4.ZERO, 1.0)
	var gold := {"attack": [Vector2(1060, 608), 84.0], "kick": [Vector2(1182, 516), 62.0], "jump": [Vector2(938, 512), 62.0],
		"block": [Vector2(1060, 418), 62.0], "AOE": [Vector2(808, 578), 58.0], "equip": [Vector2(888, 288), 74.0],
		"ui_menu": [Vector2(1204, 140), 38.0], "minimap": [Vector2(1204, 240), 38.0]}
	var same := true
	for n in gold:
		if (cl["buttons"][n][0] as Vector2).distance_to(gold[n][0]) > 0.01 or not is_equal_approx(float(cl["buttons"][n][1]), float(gold[n][1])):
			same = false
	_check(same, "Classic layout is the original one (%s)" % [cl["buttons"]])
	# A short canvas shrinks the twin cluster instead of colliding with Pause/Map
	var short: Dictionary = TouchControls.compute_layout(Vector2(1280, 600), Vector4.ZERO, 1.0, "twin", 8.4)
	var ok_short := true
	for n in ["jump", "kick", "block", "AOE", "equip", "attack"]:
		for m2 in ["ui_menu", "minimap"]:
			if (short["buttons"][n][0] as Vector2).distance_to(short["buttons"][m2][0]) < float(short["buttons"][n][1]) + float(short["buttons"][m2][1]):
				ok_short = false
	_check(ok_short, "on a 600 px tall canvas the cluster still clears Pause and Map")


# ── compact-input gain ───────────────────────────────────────────────────────────────────────────
func _compact_gain_tests() -> void:
	var consts: Dictionary = (TouchControls as Script).get_script_constant_map()
	_check(float(consts.get("COMPACT_GAIN_MIN", 0.0)) >= 1.0 and float(consts.get("COMPACT_GAIN_MAX", 0.0)) <= 3.5, "the compact gain is bounded (%s..%s)" % [consts.get("COMPACT_GAIN_MIN"), consts.get("COMPACT_GAIN_MAX")])
	var r: float = TouchControls.TWIN_ATTACK_R
	# 1280 wide canvas, 100% size: Classic's right-thumb sweep (half the width = 640) over the ATTACK diameter (200) = 3.2, clamped
	_check(is_equal_approx(TouchControls.compact_gain(1280.0, r), TouchControls.COMPACT_GAIN_MAX), "1280 px canvas, 100%% size: 640 / 200 = 3.2 -> clamped to %.1f" % TouchControls.COMPACT_GAIN_MAX)
	_check(is_equal_approx(TouchControls.compact_gain(1602.0, r), TouchControls.COMPACT_GAIN_MAX), "a wider (20:9) canvas is clamped to the same maximum")
	var g_big: float = TouchControls.compact_gain(1280.0, r * 1.5)
	_check(is_equal_approx(g_big, 0.5 * 1280.0 / (2.0 * r * 1.5)) and g_big < TouchControls.COMPACT_GAIN_MAX, "a bigger ATTACK button (more travel) needs less gain (%.2f)" % g_big)
	_check(is_equal_approx(TouchControls.compact_gain(1280.0, r * 10.0), TouchControls.COMPACT_GAIN_MIN) and is_equal_approx(TouchControls.compact_gain(1280.0, 0.0), TouchControls.COMPACT_GAIN_MIN), "the gain never falls below %.1f" % TouchControls.COMPACT_GAIN_MIN)
	# The camera needed for a half turn / a full turn, in thumb travel on the ATTACK button (mouse px = px x LOOK_BASE_GAIN x gain; 0.0025 rad per mouse px)
	var rad_per_px: float = TouchControls.LOOK_BASE_GAIN * 0.0025 * TouchControls.compact_gain(1280.0, r)
	var diameter: float = 2.0 * r
	_check(PI / rad_per_px <= 1.6 * diameter, "a 180 degree turn takes %.0f px of thumb travel at 100%% sensitivity: at most 1.6 ATTACK diameters (%.0f px)" % [PI / rad_per_px, diameter])
	_check(0.5 * PI / rad_per_px <= 0.8 * diameter, "a 90 degree turn fits in under one ATTACK radius-pair of travel (%.0f px)" % (0.5 * PI / rad_per_px))


# ── the right look stick is gone, entirely ──────────────────────────────────────────────────────
func _removal_tests(tc: TouchControls) -> void:
	var consts: Dictionary = (TouchControls as Script).get_script_constant_map()
	for gone in ["LOOK_STICK_RADIUS", "LOOK_STICK_DONE_SECONDS"]:
		_check(not consts.has(gone), "constant %s no longer exists" % gone)
	for gone2 in ["AIM_DRAG_RADIUS", "AIM_ENGAGE", "AIM_SETTLE_PX", "AIM_SMOOTH_TAU_MAX", "LOOK_DEADZONE", "LOOK_CURVE_EXP", "LOOK_MAX_YAW_RATE", "LOOK_PITCH_RATIO", "LOOK_RAD_PER_MOUSE_PX", "KEY_AIM_SMOOTH", "DEFAULT_AIM_SMOOTH"]:
		_check(not consts.has(gone2), "rate-control constant %s no longer exists (the ATTACK drag is displacement-based)" % gone2)
	var props: Array = []
	for pr in tc.get_property_list():
		props.append(String(pr["name"]))
	for gone in ["look_zone", "look_default", "_look_index", "_look_base", "_look_vec", "_atk_aimed", "_atk_vec", "_atk_origin", "_atk_engaged", "_atk_settled", "_look_cmd", "_aim_smoothed", "aim_smoothing", "_overlay_draw"]:
		_check(not props.has(gone), "property %s no longer exists" % gone)
	_check(props.has("_atk_index") and props.has("_atk_down_pos") and props.has("attack_look_gain"), "the ATTACK finger state is the only look state")
	_check(not TouchOnboarding.STEPS_TWIN.has("look_stick") and TouchOnboarding.AIM_DONE_SECONDS > 0.0, "onboarding has no look_stick step")
	var src: String = FileAccess.get_file_as_string("res://scripts/touch/touch_controls.gd")
	_check(not src.contains("look_zone") and not src.contains("_look_index") and not src.contains("LOOK_STICK_RADIUS") and not src.contains("look_default"), "touch_controls.gd carries no right-stick code")
	_check(not src.contains("look_step") and not src.contains("look_response") and not src.contains("exp(-dt") and not src.contains("_aim_smoothed"), "touch_controls.gd has no rate / smoothing code downstream of the ATTACK drag")
	var a: int = src.find("func _attack_move")
	var b: int = src.find("\nfunc ", a + 10)
	_check(a >= 0 and src.substr(a, b - a).contains("_look(rel, attack_look_gain)"), "the ATTACK drag feeds the Classic _look path (with the compact gain)")


# ── ownership ────────────────────────────────────────────────────────────────────────────────────
func _aim_point(tc: TouchControls) -> Vector2:
	return (tc.buttons["attack"] as TouchButton).center


## A point on empty right-hand screen: clear of every button and outside the move zone.
func _empty_right_point(tc: TouchControls) -> Vector2:
	var v: Vector2 = tc.view_size()
	return Vector2(v.x * 0.55, v.y * 0.35)


func _ownership_tests(tc: TouchControls, view: Vector2) -> void:
	var s0: Vector2 = Vector2(view.x * 0.12, view.y * 0.72)
	var atk: TouchButton = tc.buttons["attack"]
	var kick: TouchButton = tc.buttons["kick"]
	var blk: TouchButton = tc.buttons["block"]
	var e0: Vector2 = _empty_right_point(tc)
	_check(tc._nearest_button(e0) == null and not tc.stick_zone.has_point(e0), "the empty right-side probe point is on no button and not in the move zone")

	# move stick + ATTACK drag together
	_motion.clear()
	_touch(0, s0, true)
	_drag(0, s0 + Vector2(100, 0), Vector2(100, 0))
	_touch(1, atk.center, true)
	_drag(1, atk.center + Vector2(90, 0), Vector2(90, 0))
	await _frames(4)
	_check(Input.is_action_pressed("move_right") and not Input.is_action_pressed("attack") and tc.attack_pulses == 0, "move stick + attack drag work together, and the drag never attacks (%s)" % [_down_actions()])
	_check(not _real_motion().is_empty() and _real_motion().all(func(m): return m[0] > 0.0), "the attack drag turns right while the move finger is down (%d events)" % _real_motion().size())
	_check(tc._owners[0]["kind"] == TouchControls.Owner.STICK and tc._owners[1]["kind"] == TouchControls.Owner.BUTTON and tc._owners[1]["button"] == "attack", "each finger has exactly one owner")
	# no cross-talk: moving the move finger does not change the aim command and vice versa
	_motion.clear()
	_drag(0, s0 + Vector2(0, -100), Vector2(-100, -100))
	_check(_real_motion().is_empty() and Input.is_action_pressed("move_forward"), "moving the move finger does not turn the camera")
	var move_before: float = Input.get_axis("move_left", "move_right")
	_drag(1, atk.center + Vector2(-90, 0), Vector2(-180, 0))
	_check(_real_motion().size() == 1 and _real_motion()[0][0] < 0.0 and is_equal_approx(Input.get_axis("move_left", "move_right"), move_before), "moving the attack finger leaves the movement alone")
	# a second finger on another button while the attack finger is dragging
	_touch(2, kick.center, true)
	await _frames(3)
	_check(Input.is_action_pressed("kick") and not Input.is_action_pressed("attack") and tc._atk_gesture == TouchControls.Gesture.LOOK, "kick while dragging from ATTACK: both live, still looking, no attack")
	# the attack finger leaves the button area and keeps controlling until it is lifted
	_motion.clear()
	_drag(1, atk.center + Vector2(-600, 300), Vector2.ZERO)
	await _frames(3)
	_check(not Input.is_action_pressed("attack") and not _real_motion().is_empty() and _real_motion().all(func(m): return m[0] < 0.0), "far from the button the finger still aims and never attacks")
	_touch(1, atk.center, false)
	await _frames(2)
	_check(tc._atk_gesture == TouchControls.Gesture.NONE and tc._atk_index == -1 and Input.is_action_pressed("kick") and Input.is_action_pressed("move_forward"), "lifting the attack finger only ends the look (and releases attack)")
	_touch(2, kick.center, false)
	_touch(0, s0, false)
	await get_tree().create_timer(0.25).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
	_flush()
	_check(_down_actions().is_empty() and tc._owners.is_empty(), "all released (%s)" % [_down_actions()])

	# move + ATTACK drag + a second button (block)
	_motion.clear()
	_touch(0, s0, true)
	_drag(0, s0 + Vector2(0, -100), Vector2(0, -100))
	_touch(1, atk.center, true)
	_drag(1, atk.center + Vector2(-80, 0), Vector2(-80, 0))
	_touch(2, blk.center, true)
	await _frames(4)
	_check(Input.is_action_pressed("move_forward") and not Input.is_action_pressed("attack") and Input.is_action_pressed("block"), "move + attack-drag + block at once (%s)" % [_down_actions()])
	_check(not _real_motion().is_empty() and _real_motion().all(func(m): return m[0] < 0.0), "the attack drag turns left meanwhile")
	_touch(2, blk.center, false)
	_touch(1, atk.center, false)
	_touch(0, s0, false)
	await get_tree().create_timer(0.25).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
	_flush()
	_check(_down_actions().is_empty(), "all released after the three-finger test (%s)" % [_down_actions()])

	# THERE IS NO RIGHT LOOK ZONE: a finger that is not on a button and not in the move zone does nothing, however it moves
	var empty_points: Array = [e0, Vector2(view.x * 0.45, view.y * 0.10), Vector2(view.x * 0.62, view.y * 0.62), Vector2(view.x * 0.93, view.y * 0.20), Vector2(view.x * 0.70, view.y * 0.50), Vector2(30, 20)]
	for pt in empty_points:
		if tc._nearest_button(pt) != null or tc.stick_zone.has_point(pt):
			continue
		_motion.clear()
		_touch(7, pt, true)
		_check(tc._owners[7]["kind"] == TouchControls.Owner.NONE and tc._atk_gesture == TouchControls.Gesture.NONE, "a finger on empty screen %s is owned by nothing" % pt)
		_drag(7, pt + Vector2(120, -40), Vector2(120, -40))
		_drag(7, pt + Vector2(-300, 80), Vector2(-420, 120))
		await _frames(4)
		_check(_real_motion().is_empty() and _down_actions().is_empty() and tc._atk_gesture == TouchControls.Gesture.NONE, "dragging on empty screen %s turns nothing and presses nothing (%d events)" % [pt, _real_motion().size()])
		_touch(7, pt, false)
	# an empty-screen finger beside a live aim does not disturb it, and cannot take it over
	_touch(0, s0, true)
	_touch(1, atk.center, true)
	_drag(1, atk.center + Vector2(radius_of(tc), 0), Vector2.ZERO)
	_motion.clear()
	_touch(3, e0, true)
	_drag(3, e0 + Vector2(200, 0), Vector2(200, 0))
	_check(tc._owners[3]["kind"] == TouchControls.Owner.NONE and _real_motion().is_empty() and tc._atk_gesture == TouchControls.Gesture.LOOK and tc._atk_index == 1, "a stray third finger on empty screen is ignored while moving and aiming")
	# a second finger in the (occupied) move zone is ignored too
	_touch(4, s0 + Vector2(40, 0), true)
	_check(tc._owners[4]["kind"] == TouchControls.Owner.NONE, "a second finger in the occupied move zone does nothing")
	for i in 5:
		_touch(i, Vector2.ZERO, false)
	await get_tree().create_timer(0.25).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
	_flush()
	_check(tc._owners.is_empty() and tc._atk_gesture == TouchControls.Gesture.NONE and _down_actions().is_empty(), "all fingers up: no owners left")
	# the engine's cancel path (a pointer cancelled by the OS) is a clean release too
	_touch(0, s0, true)
	_drag(0, s0 + Vector2(100, 0), Vector2(100, 0))
	_touch(1, atk.center, true)
	_drag(1, atk.center + Vector2(radius_of(tc), 0), Vector2.ZERO)
	for i in 2:
		var cancel := InputEventScreenTouch.new()
		cancel.index = i
		cancel.pressed = false
		cancel.canceled = true
		Input.parse_input_event(cancel)
		_flush()
	await get_tree().create_timer(0.25).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
	_flush()
	_check(tc._owners.is_empty() and tc._atk_gesture == TouchControls.Gesture.NONE and tc._atk_index == -1 and _down_actions().is_empty(), "a cancelled touch releases movement, attack and look (%s)" % [_down_actions()])


func radius_of(tc: TouchControls) -> float:
	return (tc.buttons["attack"] as TouchButton).radius


# ── ATTACK drag with real input events ─────────────────────────────────────────────────────────────
func _motion_x() -> float:
	var sum: float = 0.0
	for m in _real_motion():
		sum += float(m[0])
	return sum


# ── the ATTACK drag IS the Classic look path, times the compact gain ────────────────────────────
func _look_path_tests(tc: TouchControls, view: Vector2) -> void:
	var l0: Vector2 = _aim_point(tc)
	var slop: float = tc._atk_slop_px
	var gain: float = tc.attack_look_gain
	var per_px: float = TouchControls.LOOK_BASE_GAIN * tc.look_gain * gain   # mouse px per px of thumb travel beyond the slop circle
	_check(is_equal_approx(gain, TouchControls.compact_gain(view.x, radius_of(tc))), "the layer's compact gain comes from the canvas width and the ATTACK radius (%.2f)" % gain)
	await get_tree().create_timer(0.25).timeout   # let any deferred release of an earlier test pass
	_flush()

	# 1. inside the slop circle nothing turns; the event that leaves it contributes only the movement beyond the circle
	_motion.clear()
	_touch(0, l0, true)
	_drag(0, l0 + Vector2(slop * 0.9, 0))
	_check(_real_motion().is_empty(), "inside the slop circle the camera does not move")
	_drag(0, l0 + Vector2(slop + 10.0, 0))
	_check(_real_motion().size() == 1 and absf(_motion_x() - 10.0 * per_px) < 0.01, "the first look event is the movement beyond the slop circle x the Classic gain (%.2f vs %.2f px)" % [_motion_x(), 10.0 * per_px])

	# 2. then every pixel of thumb movement is a pixel of Classic look times the gain: linear, immediate, no curve
	_motion.clear()
	for i in 20:
		_drag(0, l0 + Vector2(slop + 10.0 + 5.0 * float(i + 1), 0))
	_check(_real_motion().size() == 20 and absf(_motion_x() - 100.0 * per_px) < 0.05, "100 px of drag = 100 px of Classic look x %.2f (%.1f vs %.1f)" % [gain, _motion_x(), 100.0 * per_px])
	_motion.clear()
	_drag(0, l0 + Vector2(slop + 10.0 + 100.0 + 2.0, 0))
	var one_px_event: float = _motion_x()
	_motion.clear()
	_drag(0, l0 + Vector2(slop + 10.0 + 100.0 + 2.0 + 40.0, 0))
	_check(absf(_motion_x() - 20.0 * one_px_event) < 0.05, "a 40 px movement turns exactly 20 x a 2 px movement (no response curve)")
	# the same call the Classic swipe uses gives the same pixels (the ATTACK drag differs only by the gain)
	_motion.clear()
	tc._look(Vector2(40, 0))
	var classic_px: float = _motion_x()
	_check(absf(classic_px * gain - 40.0 * per_px) < 0.05, "Classic's own look call for the same 40 px turns 1/%.2f as far" % gain)

	# 3. a still thumb does not turn the camera: no coasting, no drift, no deflection-rate (the old stick behaviour)
	_motion.clear()
	await _frames(12)
	_check(_real_motion().is_empty(), "holding the thumb still turns nothing, however long (12 frames)")
	# 4. reversing is immediate and symmetric
	_motion.clear()
	_drag(0, l0 + Vector2(slop + 112.0, 0))
	_check(_real_motion().size() == 1 and _motion_x() < 0.0 and absf(_motion_x() + 40.0 * per_px) < 0.05, "reversing 40 px turns back by the same amount on that very event")
	# 5. no travel limit: far past the button the finger keeps turning in proportion
	_motion.clear()
	_drag(0, l0 + Vector2(900.0, 0))
	var far_dx: float = 900.0 - (slop + 112.0)
	_check(absf(_motion_x() - far_dx * per_px) < 0.1, "the thumb can leave the button: %.0f px further still turns %.0f px (no saturation)" % [far_dx, far_dx * per_px])
	# 6. releasing does not jump or coast
	_motion.clear()
	_touch(0, l0 + Vector2(900.0, 0), false)
	await _frames(6)
	_check(_real_motion().is_empty() and tc._atk_gesture == TouchControls.Gesture.NONE and tc._atk_index == -1, "lifting the thumb: no release jump, no coasting, the gesture is over")
	await get_tree().create_timer(0.25).timeout
	_flush()

	# 7. re-engagement: touching down again works at once and needs a fresh slop circle
	_motion.clear()
	_touch(0, l0, true)
	_drag(0, l0 + Vector2(slop * 0.5, 0))
	_check(_real_motion().is_empty(), "a new touch starts with a fresh slop circle")
	_drag(0, l0 + Vector2(slop + 30.0, 0))
	_check(absf(_motion_x() - 30.0 * per_px) < 0.01, "...and then turns exactly like the first one")
	# 8. Look Sensitivity is the single fine-adjustment, a plain multiplier (it does not stack with anything else)
	SettingsManager.gameplay_settings[TouchControls.KEY_LOOK] = 200.0
	tc._apply_settings()
	_check(is_equal_approx(tc.attack_look_gain, gain), "changing Look Sensitivity does not touch the compact gain")
	_motion.clear()
	_drag(0, l0 + Vector2(slop + 60.0, 0))
	_check(absf(_motion_x() - 30.0 * TouchControls.LOOK_BASE_GAIN * 2.0 * gain) < 0.05, "Look Sensitivity 200%% doubles the turn (%.1f px)" % _motion_x())
	SettingsManager.gameplay_settings[TouchControls.KEY_LOOK] = 100.0
	tc._apply_settings()
	# 9. vertical movement is passed on exactly as Classic does (the players ignore pitch), and never moves yaw
	_motion.clear()
	_drag(0, l0 + Vector2(slop + 60.0, 40.0))
	_check(_real_motion().size() == 1 and _real_motion()[0][0] == 0.0 and _real_motion()[0][1] > 0.0, "a vertical drag adds no yaw (the game has no pitch)")
	# 10. the camera is only ever turned by drag events: the rendered frames add nothing of their own
	_motion.clear()
	await _frames(8)
	_check(_real_motion().is_empty(), "no look event without a finger movement (frame rate cannot matter)")
	_touch(0, l0, false)
	await get_tree().create_timer(0.25).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	_flush()


# ── attack + drag ────────────────────────────────────────────────────────────────────────────────
func _attack_drag_tests(tc: TouchControls, view: Vector2) -> void:
	var atk: TouchButton = tc.buttons["attack"]
	_attack_events.clear()
	_motion.clear()
	tc.now_override_ms = Time.get_ticks_msec()   # frozen while the thumb rests (slow frames must not turn the rest into a hold)
	_touch(0, atk.center + Vector2(10, 5), true)
	_check(not Input.is_action_pressed("attack") and tc._atk_index == 0 and tc._atk_gesture == TouchControls.Gesture.PENDING, "touching ATTACK presses nothing yet: the gesture decides")
	# a jitter inside the slop circle does not turn
	_drag(0, atk.center + Vector2(10 + 6, 5), Vector2(6, 0))
	await _frames(3)
	_check(_real_motion().is_empty(), "finger jitter on ATTACK does not turn")
	tc.now_override_ms = -1
	# drag far outside the button and back: it is a look gesture, it never attacks, and the camera turns while it is down
	var path: Array = [Vector2(70, 0), Vector2(200, -50), Vector2(400, -100), Vector2(-300, 40), Vector2(-60, 0)]
	var turned_right := false
	var turned_left := false
	for off in path:
		_motion.clear()
		_drag(0, atk.center + off, Vector2.ZERO)
		await _frames(3)
		_check(not Input.is_action_pressed("attack"), "dragging to %s never attacks" % off)
		for m in _real_motion():
			if m[0] > 0.0:
				turned_right = true
			if m[0] < 0.0:
				turned_left = true
	_check(turned_right and turned_left, "dragging from ATTACK turns right and left")
	_check(_attack_events.is_empty() and tc.attack_pulses == 0, "no attack press at all while dragging (%s)" % [_attack_events])
	_check(tc._owners[0]["kind"] == TouchControls.Owner.BUTTON and tc._owners[0]["button"] == "attack", "the dragging finger is still the attack button's")
	_touch(0, atk.center, false)
	await get_tree().create_timer(0.25).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
	_flush()
	_attack_events.clear()
	# a drag from ATTACK is a look gesture from the first pixel beyond the slop circle
	_touch(0, atk.center, true)
	_drag(0, atk.center + Vector2(tc._atk_slop_px + 20.0, 0), Vector2.ZERO)
	_check(tc._atk_gesture == TouchControls.Gesture.LOOK, "the attack drag is a look gesture")
	# releasing ATTACK ends the drag and the turning, and then releases attack
	_touch(0, atk.center + Vector2(60, 0), false)
	_check(tc._atk_gesture == TouchControls.Gesture.NONE and tc._atk_index == -1, "releasing ATTACK ends the drag immediately")
	_motion.clear()
	await _frames(4)
	_check(_real_motion().is_empty(), "no turning after ATTACK is released")
	await get_tree().create_timer(0.25).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
	_flush()
	_check(not Input.is_action_pressed("attack") and _attack_events.is_empty(), "nothing attacked on lift-off after a drag (%s)" % [_attack_events])
	# a quick tap on ATTACK attacks once, and the press lasts long enough for polling code
	_touch(0, atk.center, true)
	_touch(0, atk.center, false)
	_check(Input.is_action_pressed("attack") and tc.attack_pulses == 1, "a tap on ATTACK is one attack pulse, long enough for polling code (%d)" % tc.attack_pulses)
	await get_tree().create_timer(0.25).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
	_flush()
	_check(not Input.is_action_pressed("attack"), "...and released")
	# a long drag across the whole screen keeps looking, never attacks
	_attack_events.clear()
	_touch(0, atk.center, true)
	_drag(0, atk.center + Vector2(-500.0, -300.0), Vector2.ZERO)
	_check(tc._atk_gesture == TouchControls.Gesture.LOOK and _attack_events.is_empty(), "a far drag is still a look gesture and never attacks")
	_touch(0, Vector2.ZERO, false)
	await get_tree().create_timer(0.25).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
	_flush()


# ── lifecycle ────────────────────────────────────────────────────────────────────────────────────
func _lifecycle_tests(tc: TouchControls, view: Vector2) -> void:
	var s0: Vector2 = Vector2(view.x * 0.12, view.y * 0.72)
	var atk: TouchButton = tc.buttons["attack"]
	var radius: float = atk.radius
	for mode in ["background", "focus_out", "window_focus_out", "pause"]:
		_touch(0, s0, true)
		_drag(0, s0 + Vector2(100, 0), Vector2(100, 0))
		_touch(1, atk.center, true)
		_drag(1, atk.center + Vector2(radius, 0), Vector2.ZERO)
		_touch(2, (tc.buttons["block"] as TouchButton).center, true)
		await _frames(2)
		_check(Input.is_action_pressed("move_right") and Input.is_action_pressed("block") and tc._atk_gesture == TouchControls.Gesture.LOOK, "[%s] move + attack-drag + block all live" % mode)
		match mode:
			"background": tc.notification(NOTIFICATION_APPLICATION_PAUSED)
			"focus_out": tc.notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
			"window_focus_out": tc.notification(NOTIFICATION_WM_WINDOW_FOCUS_OUT)
			_: get_tree().paused = true
		await _frames(2)
		_flush()
		_check(_down_actions().is_empty(), "[%s] every held action is released (%s)" % [mode, _down_actions()])
		_check(tc._atk_gesture == TouchControls.Gesture.NONE and tc._atk_index == -1 and tc._owners.is_empty() and not tc._stick_active, "[%s] the look gesture and every finger are reset" % mode)
		_motion.clear()
		await _frames(5)
		_check(_real_motion().is_empty(), "[%s] nothing keeps turning" % mode)
		if mode == "pause":
			get_tree().paused = false
			await _frames(2)
		# stale drags from the fingers that "were down" do nothing after coming back
		_drag(1, atk.center + Vector2(radius, 0), Vector2.ZERO)
		_drag(0, s0 + Vector2(100, 0), Vector2.ZERO)
		_drag(1, atk.center + Vector2(radius, 0), Vector2.ZERO)
		await _frames(3)
		_check(_real_motion().is_empty() and _down_actions().is_empty(), "[%s] stale fingers cannot resume turning, moving or attacking (%s)" % [mode, _down_actions()])
		for i in 3:
			_touch(i, Vector2.ZERO, false)
	var got := [false]
	tc.released_all.connect(func() -> void: got[0] = true, CONNECT_ONE_SHOT)
	tc.release_all()
	_check(got[0], "released_all is emitted")
	# disabling the layer (death / run end screens) releases too
	_touch(2, atk.center, true)
	_drag(2, atk.center + Vector2(radius, 0), Vector2.ZERO)
	tc.set_enabled(false)
	_check(tc._atk_gesture == TouchControls.Gesture.NONE and _down_actions().is_empty(), "disabling the layer ends the look and releases attack")
	tc.set_enabled(true)
	_touch(2, Vector2.ZERO, false)


# ── hit routing: a point on a drawn button is that button ────────────────────────────────────────
func _hit_tests(tc: TouchControls) -> void:
	var ok := true
	var bad := ""
	for action in tc.buttons:
		var b: TouchButton = tc.buttons[action]
		if action == "equip":
			continue
		for i in 8:
			var a: float = TAU * float(i) / 8.0
			var p: Vector2 = b.center + Vector2(cos(a), sin(a)) * b.radius * 0.92
			var hit: TouchButton = tc._nearest_button(p)
			if hit == null or hit.action != b.action:
				ok = false
				bad = "%s@%.0fdeg->%s" % [action, rad_to_deg(a), "" if hit == null else hit.action]
		if tc._nearest_button(b.center).action != b.action:
			ok = false
	_check(ok, "every point on a drawn button resolves to that button (%s)" % bad)
	var atk: TouchButton = tc.buttons["attack"]
	_check(tc._nearest_button(atk.center + Vector2(0, atk.radius * 1.15)).action == "attack", "the slop around ATTACK is ATTACK")


# ── switching scheme live ────────────────────────────────────────────────────────────────────────
func _scheme_switch_tests(tc: TouchControls, view: Vector2) -> void:
	var twin_attack_r: float = (tc.buttons["attack"] as TouchButton).radius
	var s0: Vector2 = Vector2(view.x * 0.12, view.y * 0.72)
	_touch(0, s0, true)
	_drag(0, s0 + Vector2(100, 0), Vector2(100, 0))
	SettingsManager.update_setting(TouchControls.KEY_SCHEME, "classic")
	await get_tree().create_timer(0.7).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
	_flush()
	_check(not tc.is_twin() and tc.scheme == "classic", "choosing Classic switches the live layer")
	_check(_down_actions().is_empty() and tc._owners.is_empty(), "switching releases every finger and action (%s)" % [_down_actions()])
	_touch(0, s0, false)
	var cl: Dictionary = TouchControls.compute_layout(tc.view_size(), Vector4.ZERO, tc.ui_scale)
	var same := true
	for a in cl["buttons"]:
		var b: TouchButton = tc.buttons[a]
		if b.center.distance_to(cl["buttons"][a][0]) > 0.01 or not is_equal_approx(b.radius, float(cl["buttons"][a][1])):
			same = false
	_check(same and not is_equal_approx((tc.buttons["attack"] as TouchButton).radius, twin_attack_r), "Classic re-lays the buttons out exactly as before")
	# classic behaviour: swipe look = mouse-look motion per drag event, no rate
	var l0: Vector2 = Vector2(view.x * 0.55, view.y * 0.30)
	_motion.clear()
	_touch(1, l0, true)
	_drag(1, l0 + Vector2(100, 0), Vector2(100, 0))
	var looked: Array = _real_motion()
	_check(looked.size() >= 1 and absf(float(looked[0][0]) - 100.0 * TouchControls.LOOK_BASE_GAIN) < 0.01, "Classic: a 100 px swipe turns like %.0f mouse px (no compact gain: %.1f)" % [100.0 * TouchControls.LOOK_BASE_GAIN, tc.attack_look_gain])
	_check(is_equal_approx(tc.attack_look_gain, 1.0), "Classic carries no compact gain")
	_motion.clear()
	await _frames(5)
	_check(_real_motion().is_empty(), "Classic: holding a finger still does not keep turning")
	_touch(1, l0, false)
	# classic attack: dragging from ATTACK does NOT look
	var atk: TouchButton = tc.buttons["attack"]
	_touch(2, atk.center, true)
	_motion.clear()
	_drag(2, atk.center + Vector2(120, 0), Vector2(120, 0))
	await _frames(3)
	_check(Input.is_action_pressed("attack") and _real_motion().is_empty(), "Classic: dragging from ATTACK does not turn the camera")
	_touch(2, atk.center, false)
	await get_tree().create_timer(0.25).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
	_flush()
	# and back to twin, also while the tree is paused (Options opened from the pause menu)
	get_tree().paused = true
	SettingsManager.update_setting(TouchControls.KEY_SCHEME, "twin")
	await get_tree().create_timer(0.7, true, false, true).timeout
	get_tree().paused = false
	_check(tc.is_twin() and is_equal_approx((tc.buttons["attack"] as TouchButton).radius, twin_attack_r), "twin-stick returns, applied even while paused")
	await _frames(2)


# ── onboarding ───────────────────────────────────────────────────────────────────────────────────
func _onboarding_tests() -> void:
	SettingsManager.gameplay_settings.erase(TouchOnboarding.SETTINGS_KEY)
	SettingsManager.gameplay_settings.erase(TouchOnboarding.SHOWS_KEY)
	var tc: TouchControls = _new_layer(Vector2(1602, 720))
	await _frames(3)
	var ob: TouchOnboarding = tc.onboarding
	_check(tc.is_twin(), "onboarding test runs on twin-stick")
	ob._choose_next()
	_check(ob.active == "move" and ob._label.text.to_lower().contains("left") and ob._label.text.to_lower().contains("move"), "twin hint 1: move with the left stick (%s)" % ob._label.text)
	tc.move_time = 1.0
	ob._process(0.016)
	_check(ob.is_done("move") and ob.active == "", "moving completes the move hint")
	ob._choose_next()
	_check(ob.active == "aim" and ob._label.text == "Drag from Attack to look and aim", "twin hint 2: look and aim by dragging from Attack (%s)" % ob._label.text)
	_check((tc.buttons["attack"] as TouchButton).highlighted, "the aim hint pulses the ATTACK button")
	var steps_twin: Array = TouchOnboarding.STEPS_TWIN
	_check(not steps_twin.has("look_stick") and not TouchOnboarding.TEXT_TWIN.has("look_stick"), "no right-stick hint step or text is left")
	tc.look_time = 1.0   # the ATTACK drag has been held out long enough
	ob._process(0.016)
	_check(ob.is_done("aim") and not ob.is_done("look") and ob.active == "", "an ATTACK drag completes the aim hint")
	ob._choose_next()
	_check(ob.active == "", "no attack hint while no enemy is near")
	var texts := {}
	for step in ["attack", "use", "block", "burst"]:
		texts[step] = ob.text_for(step)
	_check(texts["attack"].to_lower().contains("attack"), "attack hint text (%s)" % texts["attack"])
	_check(texts["block"].to_lower().contains("block") and texts["burst"].to_lower().contains("burst") and texts["use"].to_lower().contains("use"), "block / burst / use hint texts")
	ob._on_action("attack")
	_check(ob.is_done("attack"), "pressing attack completes the attack hint")
	var tx: Dictionary = SettingsManager.gameplay_settings.get(TouchOnboarding.SETTINGS_KEY, {})
	_check(tx.get("move", false) and tx.get("aim", false), "completion is persisted in the settings")
	for i in TouchOnboarding.MAX_SHOWS:
		ob._count_show("block")
	_check(ob.is_done("block"), "an ignored twin hint retires after %d showings" % TouchOnboarding.MAX_SHOWS)
	# a real ATTACK drag held out for a while completes the aim hint (and the old right-stick flag is never read)
	SettingsManager.gameplay_settings[TouchOnboarding.SETTINGS_KEY] = {"move": true, "look_stick": true, "attack": true}
	SettingsManager.gameplay_settings.erase(TouchOnboarding.SHOWS_KEY)
	tc.look_time = 0.0
	ob._deactivate()
	ob._choose_next()
	_check(ob.active == "aim", "an install that finished the removed right-stick hint is taught the ATTACK drag (the stale flag is ignored)")
	var atk: TouchButton = tc.buttons["attack"]
	_touch(0, atk.center, true)
	for i in 150:   # about a second of dragging back and forth
		await get_tree().process_frame
		_drag(0, atk.center + Vector2(40.0 + 30.0 * sin(float(i) * 0.3), 0), Vector2.ZERO)
	_flush()
	_check(tc.look_time >= 0.5, "dragging accumulates look_time (%.2f)" % tc.look_time)
	tc.look_time = TouchOnboarding.AIM_DONE_SECONDS
	ob._process(0.016)
	_check(ob.is_done("aim"), "...which completes the aim hint")
	_touch(0, atk.center, false)
	await get_tree().create_timer(0.25).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
	_flush()

	# hints never sit on a control, for both schemes, with the USE button showing, at several shapes
	tc.queue_free()
	await _frames(2)
	for scheme in ["twin", "classic"]:
		SettingsManager.gameplay_settings[TouchControls.KEY_SCHEME] = scheme
		for view in [Vector2(1280, 720), Vector2(1602, 720), Vector2(1800, 720)]:
			var t2: TouchControls = _new_layer(view)
			await _frames(3)
			t2.set_use_context(true, "OPEN")
			var o2: TouchOnboarding = t2.onboarding
			var steps: Array = ["move", "aim", "attack", "use", "block", "burst"] if scheme == "twin" else ["move", "look", "attack", "use", "block", "burst"]
			for step in steps:
				o2._activate(step)
				await _frames(2)
				o2._position_label()
				var rect := Rect2(o2._label.position, o2._label.size)
				var hit := ""
				for action in t2.buttons:
					var b: TouchButton = t2.buttons[action]
					if b.visible and rect.intersects(Rect2(b.center - Vector2(b.radius, b.radius), Vector2(b.radius, b.radius) * 2.0)):
						hit = action
				_check(hit == "", "[%s %s] the '%s' hint does not cover a button (covers '%s') rect %s" % [scheme, view, step, hit, rect])
				_check(Rect2(Vector2.ZERO, view).encloses(rect), "[%s %s] the '%s' hint is on screen" % [scheme, view, step])
				o2._deactivate()
			if scheme == "classic":
				o2._activate("look")
				_check(o2._label.text == "Swipe on this side to look around", "Classic keeps its swipe wording (%s)" % o2._label.text)
			t2.queue_free()
			await _frames(2)
	SettingsManager.gameplay_settings[TouchControls.KEY_SCHEME] = "twin"


# ── Options: the selector ────────────────────────────────────────────────────────────────────────
func _options_tests() -> void:
	SettingsManager.update_setting(TouchControls.KEY_SCHEME, "twin")
	var scr := (load("res://scenes/OptionsScreen.tscn") as PackedScene).instantiate()
	add_child(scr)
	for i in 8:
		await get_tree().process_frame
	var tw := scr.find_child("Scheme_twin", true, false) as Button
	var cl := scr.find_child("Scheme_classic", true, false) as Button
	_check(tw != null and cl != null, "Options > Gameplay > Touch Controls has a Twin-stick and a Classic selector")
	if tw != null and cl != null:
		_check(tw.button_pressed and not cl.button_pressed, "the selector shows the saved scheme (twin)")
		_check(tw.text == "Twin-stick" and cl.text == "Classic", "selector labels are Twin-stick / Classic")
		cl.button_pressed = true
		_check(SettingsManager.gameplay_settings.get(TouchControls.KEY_SCHEME) == "classic", "choosing Classic sets the setting")
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SettingsManager._settings_path))
		_check(parsed is Dictionary and parsed.get(TouchControls.KEY_SCHEME) == "classic", "...and saves it to settings.json")
		tw.button_pressed = true
		_check(SettingsManager.gameplay_settings.get(TouchControls.KEY_SCHEME) == "twin", "choosing Twin-stick sets it back")
		_check(not cl.button_pressed, "the selector is exclusive")
	for key in [TouchControls.KEY_OPACITY, TouchControls.KEY_SCALE, TouchControls.KEY_LOOK]:
		_check(scr._sliders.has(key), "the %s slider is there" % key)
	_check(not scr._sliders.has("TouchAimSmoothing"), "the removed Aim Smoothing slider is gone (the ATTACK drag has no smoothing to adjust)")
	_check(scr.find_child("Scheme_twin", true, false) != null, "the scheme selector is still there")
	scr.queue_free()
	# reopening reads the saved value
	SettingsManager.update_setting(TouchControls.KEY_SCHEME, "classic")
	var scr2 := (load("res://scenes/OptionsScreen.tscn") as PackedScene).instantiate()
	add_child(scr2)
	for i in 8:
		await get_tree().process_frame
	var cl2 := scr2.find_child("Scheme_classic", true, false) as Button
	_check(cl2 != null and cl2.button_pressed, "reopening Options shows Classic when it is saved")
	scr2.queue_free()
	SettingsManager.update_setting(TouchControls.KEY_SCHEME, "twin")


# ══════════════════════════════════════════════════════════════════════════════════════════════════
# The real Barbarian / Mage: the ATTACK drag turns the actual player; empty right-side screen does not.
func _real_player_test(cls: String) -> void:
	_probe = Probe.new()
	_probe.motion = _motion
	_probe.attack = _attack_events
	add_child(_probe)
	SaveManager.load_slot(0)
	SaveManager.create_initial_identity("TwinTester", cls)
	GlobalRunData.character_class = cls
	var main: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	add_child(main)
	await _frames(150)
	var tcs := get_tree().get_nodes_in_group(TouchControls.GROUP)
	_check(tcs.size() == 1, "the run has one touch layer (%d)" % tcs.size())
	var tc: TouchControls = tcs[0]
	var player := get_tree().get_first_node_in_group("player") as Node3D
	_check(player != null, "%s player exists" % cls)
	_check(tc.is_twin(), "the run starts in twin-stick (default)")
	if player == null or tc == null:
		return
	# The headless window is tiny: lay the live layer out as on the Pixel (1602x720 canvas).
	tc.view_override = Vector2(1602, 720)
	tc.layout_override_insets = Vector4.ZERO
	tc.dpi_override = 480.0
	tc.screen_override = Vector2(2992, 1344)
	tc._relayout()
	var l0: Vector2 = (tc.buttons["attack"] as TouchButton).center
	var radius: float = (tc.buttons["attack"] as TouchButton).radius
	var per_px_rad: float = TouchControls.LOOK_BASE_GAIN * tc.look_gain * tc.attack_look_gain * 0.0025   # radians per px of thumb travel beyond the slop circle
	var slop: float = tc._atk_slop_px
	var yaw0: float = player.rotation.y
	# the turn is shown on the frame the motion arrives, not at the next 30 Hz physics tick
	var y_pre: float = player.rotation.y
	var mm := InputEventMouseMotion.new()
	mm.device = 0
	mm.relative = Vector2(40, 0)
	Input.parse_input_event(mm)
	_flush()
	_check(absf(angle_difference(y_pre, player.rotation.y) + 40.0 * 0.0025) < 0.002, "[%s] a look event turns the camera at once, with no wait for the physics tick (%.4f rad)" % [cls, angle_difference(y_pre, player.rotation.y)])
	if cls == "barbarian":
		# the view stays locked while blocking, exactly as the tick always did (the yaw still accumulates)
		player.set("_is_blocking", true)
		var y_blk: float = player.rotation.y
		Input.parse_input_event(mm)
		_flush()
		_check(is_equal_approx(player.rotation.y, y_blk), "[barbarian] the view stays locked while blocking")
		player.set("_is_blocking", false)
	await _frames(3)   # the next physics tick applies the yaw that accumulated while blocking
	yaw0 = player.rotation.y
	# empty right-side screen does nothing to the real player
	var e0: Vector2 = Vector2(1602.0 * 0.55, 720.0 * 0.35)
	_touch(5, e0, true)
	_drag(5, e0 + Vector2(300, 0), Vector2(300, 0))
	await _frames(12)
	_check(absf(player.rotation.y - yaw0) < 0.0001 and not Input.is_action_pressed("attack"), "[%s] dragging on empty right-side screen does not turn the player or attack (dy %.5f attack %s)" % [cls, player.rotation.y - yaw0, Input.is_action_pressed("attack")])
	_touch(5, e0, false)
	# ATTACK drag, right: the turn is the thumb travel beyond the slop circle x the Classic gain, and it stops with the thumb
	_touch(0, l0, true)
	_drag(0, l0 + Vector2(radius, 0), Vector2.ZERO)
	await _frames(15)
	var yaw1: float = player.rotation.y
	var want_turn: float = (radius - slop) * per_px_rad
	_check(absf((yaw0 - yaw1) - want_turn) < want_turn * 0.15 and want_turn > 0.5, "[%s] dragging from ATTACK right turns the player right by %.2f rad (yaw %.2f -> %.2f)" % [cls, want_turn, yaw0, yaw1])
	await _frames(8)
	_check(absf(player.rotation.y - yaw1) < 0.0001, "[%s] a held-still thumb keeps nothing turning" % cls)
	# release: stops
	_touch(0, l0, false)
	await _frames(6)
	var yaw2: float = player.rotation.y
	await _frames(8)
	_check(absf(player.rotation.y - yaw2) < 0.0001, "[%s] releasing ATTACK stops the turn" % cls)
	# left
	_touch(0, l0, true)
	_drag(0, l0 + Vector2(-radius, 0), Vector2.ZERO)
	await _frames(15)
	_check(absf((player.rotation.y - yaw2) - want_turn) < want_turn * 0.15, "[%s] dragging from ATTACK left turns the player left by %.2f rad (%.2f -> %.2f)" % [cls, want_turn, yaw2, player.rotation.y])
	_touch(0, l0, false)
	await _frames(3)
	# the turn is proportional to the thumb travel
	var y3: float = player.rotation.y
	_touch(0, l0, true)
	_drag(0, l0 + Vector2(slop + 40.0, 0), Vector2.ZERO)
	await _frames(6)
	var short_turn: float = y3 - player.rotation.y
	_touch(0, l0, false)
	await _frames(3)
	var y4: float = player.rotation.y
	_touch(0, l0, true)
	_drag(0, l0 + Vector2(slop + 80.0, 0), Vector2.ZERO)
	await _frames(6)
	var long_turn: float = y4 - player.rotation.y
	_touch(0, l0, false)
	await _frames(3)
	_check(short_turn > 0.1 and absf(long_turn - 2.0 * short_turn) < short_turn * 0.15, "[%s] twice the thumb travel turns twice as far (%.2f vs %.2f rad)" % [cls, short_turn, long_turn])
	# ATTACK drag turns the player while attack is held
	var atk: TouchButton = tc.buttons["attack"]
	_attack_events.clear()
	var y5: float = player.rotation.y
	_touch(1, atk.center, true)
	_drag(1, atk.center + Vector2(-radius, 0), Vector2.ZERO)
	await _frames(12)
	_check(not Input.is_action_pressed("attack"), "[%s] attack is not pressed during the drag" % cls)
	_check(player.rotation.y > y5 + 0.4, "[%s] dragging from ATTACK turns the player left while attacking (%.2f -> %.2f)" % [cls, y5, player.rotation.y])
	_check(_attack_events.is_empty(), "[%s] no attack press at all during the drag (%s)" % [cls, _attack_events])
	_touch(1, atk.center, false)
	await get_tree().create_timer(0.2).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
	_flush()
	var y6: float = player.rotation.y
	await _frames(6)
	_check(absf(player.rotation.y - y6) < 0.0001 and not Input.is_action_pressed("attack"), "[%s] releasing ATTACK stops the turn and the attack" % cls)
	tc.release_all()
