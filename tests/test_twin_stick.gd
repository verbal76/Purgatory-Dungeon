extends Node
## Twin-stick touch scheme (the default): floating move stick + a dominant ATTACK button that also aims (drag from it
## to turn at a rate), subordinate buttons on an arc around it. There is NO right look stick and NO look zone: empty
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
		await get_tree().physics_frame
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
	_response_tests()

	var view := Vector2(1602, 720)   # the Pixel 10 Pro XL: 2992x1344 window, 1280x720 expand canvas
	var tc: TouchControls = _new_layer(view)
	await _frames(3)
	_check(tc.is_twin() and tc.scheme == TouchControls.SCHEME_TWIN, "a fresh layer on a default install is twin-stick")
	_check(is_equal_approx(tc.aim_smoothing, 0.6), "Aim Smoothing defaults to 60%% (%.2f)" % tc.aim_smoothing)
	SettingsManager.gameplay_settings[TouchControls.KEY_AIM_SMOOTH] = 0.0   # the raw response tests below measure the unsmoothed path
	tc._apply_settings()
	_removal_tests(tc)
	await _ownership_tests(tc, view)
	await _aim_tests(tc, view)
	await _aim_filter_tests(tc, view)
	SettingsManager.gameplay_settings[TouchControls.KEY_AIM_SMOOTH] = 0.0
	tc._apply_settings()
	await _attack_drag_tests(tc, view)
	await _lifecycle_tests(tc, view)
	await _hit_tests(tc)
	await _scheme_switch_tests(tc, view)
	tc.queue_free()
	await _frames(2)
	SettingsManager.update_setting(TouchControls.KEY_AIM_SMOOTH, TouchControls.DEFAULT_AIM_SMOOTH)
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
	# Aim Smoothing: default, persisted, clamped, tolerant of older settings files without the key
	SettingsManager.gameplay_settings.erase(TouchControls.KEY_AIM_SMOOTH)   # an older settings file without the key
	_check(TouchControls.DEFAULT_AIM_SMOOTH == 60.0, "the Aim Smoothing default is 60% and lives in the touch layer (no entry in SettingsManager: an OTA must not touch the guarded settings code)")
	SettingsManager.update_setting(TouchControls.KEY_AIM_SMOOTH, 35.0)
	SettingsManager.gameplay_settings[TouchControls.KEY_AIM_SMOOTH] = -1.0
	SettingsManager.load_settings()
	_check(float(SettingsManager.gameplay_settings.get(TouchControls.KEY_AIM_SMOOTH, -1.0)) == 35.0, "Aim Smoothing is persisted and reloaded")
	var path2: String = SettingsManager._settings_path
	var parsed2: Variant = JSON.parse_string(FileAccess.get_file_as_string(path2))
	(parsed2 as Dictionary).erase(TouchControls.KEY_AIM_SMOOTH)
	var f2 := FileAccess.open(path2, FileAccess.WRITE)
	f2.store_string(JSON.stringify(parsed2))
	f2.close()
	SettingsManager.gameplay_settings.erase(TouchControls.KEY_AIM_SMOOTH)
	SettingsManager.load_settings()
	var probe := TouchControls.new()
	add_child(probe)
	probe._apply_settings()
	_check(is_equal_approx(probe.aim_smoothing, 0.6), "an older settings file without the key gets 60%% (%.2f)" % probe.aim_smoothing)
	SettingsManager.gameplay_settings[TouchControls.KEY_AIM_SMOOTH] = 500.0
	probe._apply_settings()
	_check(probe.aim_smoothing == 1.0, "a value above 100 clamps to 100%")
	SettingsManager.gameplay_settings[TouchControls.KEY_AIM_SMOOTH] = -40.0
	probe._apply_settings()
	_check(probe.aim_smoothing == 0.0, "a negative value clamps to 0%")
	probe.queue_free()
	SettingsManager.update_setting(TouchControls.KEY_AIM_SMOOTH, 60.0)


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


# ── look response ────────────────────────────────────────────────────────────────────────────────
func _response_tests() -> void:
	var dz: float = TouchControls.LOOK_DEADZONE
	_check(dz > 0.1 and dz < 0.15, "deadzone is about 0.12 (%.2f)" % dz)
	_check(TouchControls.look_response(Vector2(dz * 0.99, 0)) == Vector2.ZERO and TouchControls.look_response(Vector2(0, -dz)) == Vector2.ZERO, "inside the dead zone nothing turns")
	var prev: float = 0.0
	var mono := true
	var d: float = dz + 0.01
	while d <= 1.0:
		var rate: float = TouchControls.look_rates(TouchControls.look_response(Vector2(d, 0)), 1.0).x
		if rate < prev:
			mono = false
		prev = rate
		d += 0.01
	_check(mono and prev > 0.0, "yaw rate rises monotonically with deflection")
	var full: Vector2 = TouchControls.look_rates(TouchControls.look_response(Vector2(1, 0)), 1.0)
	_check(is_equal_approx(full.x, TouchControls.LOOK_MAX_YAW_RATE), "full deflection = the maximum yaw rate (%.2f rad/s)" % full.x)
	_check(is_equal_approx(TouchControls.look_rates(TouchControls.look_response(Vector2(3.0, 0)), 1.0).x, full.x), "pushing past the rim does not exceed the maximum")
	var half: float = TouchControls.look_rates(TouchControls.look_response(Vector2(0.5, 0)), 1.0).x
	_check(half < 0.5 * full.x, "non-linear: half deflection is well under half speed (%.2f vs %.2f)" % [half, full.x])
	var small: float = TouchControls.look_rates(TouchControls.look_response(Vector2(0.25, 0)), 1.0).x
	_check(small > 0.0 and small < 0.2 * full.x, "a small push is a slow, fine aim (%.2f rad/s)" % small)
	var py: Vector2 = TouchControls.look_rates(TouchControls.look_response(Vector2(0, 1)), 1.0)
	_check(py.y > 0.0 and py.y < full.x, "yaw rate is higher than pitch rate at equal deflection (%.2f vs %.2f)" % [full.x, py.y])
	_check(is_equal_approx(TouchControls.look_rates(TouchControls.look_response(Vector2(0.6, 0)), 2.0).x, 2.0 * TouchControls.look_rates(TouchControls.look_response(Vector2(0.6, 0)), 1.0).x), "sensitivity scales the rate")
	_check(TouchControls.look_rates(TouchControls.look_response(Vector2(-0.7, 0)), 1.0).x < 0.0, "pushing left turns the other way")


# ── the right look stick is gone, entirely ──────────────────────────────────────────────────────
func _removal_tests(tc: TouchControls) -> void:
	var consts: Dictionary = (TouchControls as Script).get_script_constant_map()
	for gone in ["LOOK_STICK_RADIUS", "LOOK_STICK_DONE_SECONDS"]:
		_check(not consts.has(gone), "constant %s no longer exists" % gone)
	_check(consts.has("AIM_DRAG_RADIUS"), "the ATTACK drag radius constant is AIM_DRAG_RADIUS")
	var props: Array = []
	for pr in tc.get_property_list():
		props.append(String(pr["name"]))
	for gone in ["look_zone", "look_default", "_look_index", "_look_base", "_look_vec", "_atk_aimed"]:
		_check(not props.has(gone), "property %s no longer exists" % gone)
	_check(props.has("_atk_vec") and props.has("_atk_origin") and props.has("_atk_index"), "the ATTACK drag state is the only look state")
	_check(not TouchOnboarding.STEPS_TWIN.has("look_stick") and TouchOnboarding.AIM_DONE_SECONDS > 0.0, "onboarding has no look_stick step")
	var src: String = FileAccess.get_file_as_string("res://scripts/touch/touch_controls.gd")
	_check(not src.contains("look_zone") and not src.contains("_look_index") and not src.contains("LOOK_STICK_RADIUS") and not src.contains("look_default"), "touch_controls.gd carries no right-stick code")


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
	_check(Input.is_action_pressed("move_right") and Input.is_action_pressed("attack"), "move stick + attack drag work together (%s)" % [_down_actions()])
	_check(not _real_motion().is_empty() and _real_motion().all(func(m): return m[0] > 0.0), "the attack drag turns right while the move finger is down (%d events)" % _real_motion().size())
	_check(tc._owners[0]["kind"] == TouchControls.Owner.STICK and tc._owners[1]["kind"] == TouchControls.Owner.BUTTON and tc._owners[1]["button"] == "attack", "each finger has exactly one owner")
	# no cross-talk: moving the move finger does not change the aim command and vice versa
	var cmd_before: Vector2 = tc._look_cmd
	_drag(0, s0 + Vector2(0, -100), Vector2(-100, -100))
	_check(tc._look_cmd == cmd_before and Input.is_action_pressed("move_forward"), "moving the move finger leaves the aim command alone")
	var move_before: float = Input.get_axis("move_left", "move_right")
	_drag(1, atk.center + Vector2(-90, 0), Vector2(-180, 0))
	_check(tc._look_cmd.x < 0.0 and is_equal_approx(Input.get_axis("move_left", "move_right"), move_before), "moving the attack finger leaves the movement alone")
	# a second finger on another button while the attack finger is dragging
	_touch(2, kick.center, true)
	await _frames(3)
	_check(Input.is_action_pressed("kick") and Input.is_action_pressed("attack") and tc._look_cmd.x < 0.0, "kick while dragging from ATTACK: both live, still aiming")
	# the attack finger leaves the button area and keeps controlling until it is lifted
	_drag(1, atk.center + Vector2(-600, 300), Vector2.ZERO)
	_motion.clear()
	await _frames(3)
	_check(Input.is_action_pressed("attack") and not _real_motion().is_empty() and _real_motion().all(func(m): return m[0] < 0.0), "far from the button the finger still aims and attack stays held")
	_touch(1, atk.center, false)
	await _frames(2)
	_check(tc._look_cmd == Vector2.ZERO and Input.is_action_pressed("kick") and Input.is_action_pressed("move_forward"), "lifting the attack finger only stops the aim (and releases attack)")
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
	_check(Input.is_action_pressed("move_forward") and Input.is_action_pressed("attack") and Input.is_action_pressed("block"), "move + attack-drag + block at once (%s)" % [_down_actions()])
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
		_check(tc._owners[7]["kind"] == TouchControls.Owner.NONE and tc._look_cmd == Vector2.ZERO, "a finger on empty screen %s is owned by nothing" % pt)
		_drag(7, pt + Vector2(120, -40), Vector2(120, -40))
		_drag(7, pt + Vector2(-300, 80), Vector2(-420, 120))
		await _frames(4)
		_check(_real_motion().is_empty() and _down_actions().is_empty() and tc._look_cmd == Vector2.ZERO, "dragging on empty screen %s turns nothing and presses nothing (%d events)" % [pt, _real_motion().size()])
		_touch(7, pt, false)
	# an empty-screen finger beside a live aim does not disturb it, and cannot take it over
	_touch(0, s0, true)
	_touch(1, atk.center, true)
	_drag(1, atk.center + Vector2(radius_of(tc), 0), Vector2.ZERO)
	var live_cmd: Vector2 = tc._look_cmd
	_touch(3, e0, true)
	_drag(3, e0 + Vector2(200, 0), Vector2(200, 0))
	_check(tc._owners[3]["kind"] == TouchControls.Owner.NONE and tc._look_cmd == live_cmd and tc._atk_index == 1, "a stray third finger on empty screen is ignored while moving and aiming")
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
	_check(tc._owners.is_empty() and tc._look_cmd == Vector2.ZERO and _down_actions().is_empty(), "all fingers up: no owners left")
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
	_check(tc._owners.is_empty() and tc._look_cmd == Vector2.ZERO and tc._atk_index == -1 and _down_actions().is_empty(), "a cancelled touch releases movement, attack and aim (%s)" % [_down_actions()])


func radius_of(tc: TouchControls) -> float:
	return TouchControls.AIM_DRAG_RADIUS * tc.ui_scale


# ── aim response with real input events (the ATTACK drag) ────────────────────────────────────────
func _aim_tests(tc: TouchControls, view: Vector2) -> void:
	var l0: Vector2 = _aim_point(tc)
	var radius: float = radius_of(tc)
	# deadzone: a tiny deflection does not turn
	_motion.clear()
	var settle: float = TouchControls.AIM_SETTLE_PX * tc.ui_scale
	_touch(0, l0, true)
	_drag(0, l0 + Vector2(settle + radius * TouchControls.AIM_ENGAGE * 0.9, 0), Vector2.ZERO)
	await _frames(4)
	_check(_real_motion().is_empty(), "below the engage threshold no look motion is sent (%d)" % _real_motion().size())
	# monotonic: deflection -> total px over 6 physics frames
	var totals: Array = []
	var last_events: int = 0
	for f in [0.3, 0.5, 0.75, 1.0]:
		_touch(0, l0, false)
		_touch(0, l0, true)
		_drag(0, l0 + Vector2(settle + radius * f, 0), Vector2.ZERO)
		_motion.clear()
		await _frames(6)
		var sum: float = 0.0
		for m in _real_motion():
			sum += float(m[0])
		totals.append(sum)
		last_events = _real_motion().size()
	_check(totals[0] > 0.0 and totals[0] < totals[1] and totals[1] < totals[2] and totals[2] < totals[3], "real look motion grows with deflection (%s)" % [totals])
	# full deflection: ~ LOOK_MAX_YAW_RATE rad/s -> px per second, at most one event per physics frame
	var expect_per_s: float = TouchControls.LOOK_MAX_YAW_RATE / TouchControls.LOOK_RAD_PER_MOUSE_PX * tc.look_gain
	var secs: float = 6.0 / float(Engine.physics_ticks_per_second)
	_check(absf(totals[3] - expect_per_s * secs) < expect_per_s * secs * 0.35, "full deflection turns at the documented rate (%.0f px vs ~%.0f)" % [totals[3], expect_per_s * secs])
	_check(last_events <= 7, "no more than one look event per physics frame (%d in 6 frames)" % last_events)
	# release stops
	_touch(0, l0, false)
	_motion.clear()
	await _frames(6)
	_check(_real_motion().is_empty() and tc._look_cmd == Vector2.ZERO, "releasing ATTACK stops the turning")
	# vertical drag sends vertical motion at the (lower) pitch rate
	_touch(0, l0, true)
	_drag(0, l0 + Vector2(0, settle + radius), Vector2.ZERO)
	_motion.clear()
	await _frames(3)
	var yv: float = 0.0
	for m in _real_motion():
		yv += float(m[1])
	_check(yv > 0.0, "dragging down sends vertical motion (the players have no pitch and ignore it)")
	_touch(0, l0, false)
	# the origin follows the thumb beyond the radius (never runs out of travel); reversing is immediate
	_touch(0, l0, true)
	_drag(0, l0 + Vector2(500, 0), Vector2.ZERO)
	_check(tc._atk_origin.distance_to(l0 + Vector2(500, 0)) <= radius + 0.01 and tc._atk_vec.length() <= 1.001, "the drag origin follows a thumb dragged far past the radius")
	_drag(0, l0 + Vector2(500 - radius * 2.0, 0), Vector2.ZERO)
	_check(tc._look_cmd.x < 0.0, "reversing after a long drag turns the other way at once")
	_touch(0, l0, false)

	# frame-rate independence: one second of the same deflection at different step sizes turns the same
	_touch(0, l0, true)
	_drag(0, l0 + Vector2(settle + radius * 0.8, 0), Vector2.ZERO)
	var sums: Dictionary = {}
	for hz in [20, 30, 60, 120, 144]:
		var acc := Vector2.ZERO
		for i in hz:
			acc += tc.look_step(1.0 / float(hz))
		sums[hz] = acc.x
	var ref: float = sums[60]
	var indep := true
	for hz in sums:
		if absf(sums[hz] - ref) > ref * 0.001:
			indep = false
	_check(indep and ref > 0.0, "the same turn per second at 20/30/60/120/144 Hz (%s)" % [sums])
	_check(tc.look_step(5.0).x <= tc.look_step(TouchControls.LOOK_MAX_STEP).x + 0.001, "a frame hitch cannot snap the camera (step capped at %.2f s)" % TouchControls.LOOK_MAX_STEP)
	# sensitivity setting scales the aim too
	var base_px: float = tc.look_step(1.0 / 30.0).x
	SettingsManager.gameplay_settings[TouchControls.KEY_LOOK] = 200.0
	tc._apply_settings()
	_check(absf(tc.look_step(1.0 / 30.0).x - 2.0 * base_px) < 0.001, "Look Sensitivity 200%% doubles the aim rate")
	SettingsManager.gameplay_settings[TouchControls.KEY_LOOK] = 100.0
	tc._apply_settings()
	_touch(0, l0, false)
	_check(tc.look_step(1.0 / 30.0) == Vector2.ZERO, "no aim command, no look motion")
	await get_tree().create_timer(0.25).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
	_flush()


# ── jitter, hysteresis, smoothing ────────────────────────────────────────────────────────────────
func _aim_filter_tests(tc: TouchControls, view: Vector2) -> void:
	var atk: TouchButton = tc.buttons["attack"]
	var l0: Vector2 = atk.center
	var radius: float = radius_of(tc)
	var settle: float = TouchControls.AIM_SETTLE_PX * tc.ui_scale
	_check(TouchControls.AIM_ENGAGE == 0.20 and TouchControls.LOOK_DEADZONE == 0.12 and TouchControls.LOOK_CURVE_EXP == 2.0 and TouchControls.AIM_SETTLE_PX == 6.0, "documented aim constants: engage 0.20, exit 0.12, curve 2.0, settle 6 px")
	_check(TouchControls.AIM_SMOOTH_TAU_MAX == 0.12 and TouchControls.DEFAULT_AIM_SMOOTH == 60.0 and TouchControls.LOOK_MAX_YAW_RATE == 4.2, "documented smoothing / top rate constants: tau 120 ms at 100%, default 60%, 4.2 rad/s")
	var at := func(v: float) -> Vector2: return l0 + Vector2(settle + radius * v, 0)

	# 1) the thumb settling on the button: +-3 px jitter around touch-down is zero turn
	_motion.clear()
	_touch(0, l0, true)
	for j in [Vector2(3, 0), Vector2(-3, 0), Vector2(0, 3), Vector2(0, -3), Vector2(3, 3), Vector2(-3, -3), Vector2(2, -2), Vector2(-2, 2), Vector2(5.5, 0)]:
		_drag(0, l0 + j, Vector2.ZERO)
		_check(tc._look_cmd == Vector2.ZERO and tc._atk_vec == Vector2.ZERO, "jitter %s px around touch-down turns nothing" % j)
	await _frames(5)
	_check(_real_motion().is_empty() and Input.is_action_pressed("attack"), "...and sends no look motion while attack stays held")
	# 2) past the settle zone but under the engage threshold: still nothing
	_drag(0, at.call(0.15), Vector2.ZERO)
	_check(tc._look_cmd == Vector2.ZERO and not tc._atk_engaged, "a 0.15 deflection (%.0f px) does not engage" % (settle + radius * 0.15))
	# 3) a slow deliberate drag turns monotonically and continuously (no jump at the engage point)
	var prev: float = 0.0
	var mono := true
	var max_jump: float = 0.0
	var engaged_at: float = -1.0
	var v: float = 0.15
	while v <= 0.98:
		_drag(0, at.call(v), Vector2.ZERO)
		var m: float = tc._look_cmd.length()
		if m < prev - 0.0001:
			mono = false
		if m > 0.0 and engaged_at < 0.0:
			engaged_at = v
		max_jump = maxf(max_jump, m - prev)
		prev = m
		v += 0.01
	_check(mono and prev > 0.9, "a slow drag turns monotonically up to nearly full rate (%.2f)" % prev)
	_check(engaged_at >= TouchControls.AIM_ENGAGE - 0.001 and engaged_at < TouchControls.AIM_ENGAGE + 0.02, "turning engages at about 0.20 deflection (%.2f)" % engaged_at)
	_check(max_jump < 0.06, "no step at the engage point: the largest rate change per 1%% of travel is %.3f of full" % max_jump)
	# 4) hysteresis: once engaged, hovering between exit and entry keeps turning; below exit stops and needs the entry again
	_drag(0, at.call(0.22), Vector2.ZERO)
	_check(tc._atk_engaged and tc._look_cmd != Vector2.ZERO, "engaged at 0.22")
	var stayed := true
	for k in 20:
		_drag(0, at.call(0.14 if k % 2 == 0 else 0.19), Vector2.ZERO)
		if tc._look_cmd == Vector2.ZERO:
			stayed = false
	_check(stayed, "hovering between 0.14 and 0.19 after engaging keeps turning (no chatter)")
	_drag(0, at.call(0.11), Vector2.ZERO)
	_check(tc._look_cmd == Vector2.ZERO and not tc._atk_engaged, "falling below 0.12 stops the turn")
	var quiet := true
	for k in 20:
		_drag(0, at.call(0.14 if k % 2 == 0 else 0.19), Vector2.ZERO)
		if tc._look_cmd != Vector2.ZERO:
			quiet = false
	_check(quiet, "hovering between 0.14 and 0.19 while disengaged stays still (no chatter)")
	_drag(0, at.call(0.21), Vector2.ZERO)
	_check(tc._atk_engaged and tc._look_cmd != Vector2.ZERO, "crossing 0.20 engages again")
	_touch(0, l0, false)
	await get_tree().create_timer(0.25).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
	_flush()

	# 5) smoothing: exponential low-pass, 63% after tau, frame-rate independent
	SettingsManager.gameplay_settings[TouchControls.KEY_AIM_SMOOTH] = 100.0
	tc._apply_settings()
	_check(is_equal_approx(tc.aim_smoothing, 1.0), "slider 100% = full smoothing")
	_touch(0, l0, true)
	_drag(0, at.call(1.0), Vector2.ZERO)
	var target: float = tc._look_cmd.x
	_check(target > 0.99, "full deflection target is 1.0 (%.2f)" % target)
	var tau: float = TouchControls.AIM_SMOOTH_TAU_MAX
	var finals: Dictionary = {}
	var totals: Dictionary = {}
	for hz in [20, 30, 60, 120, 144]:
		tc._aim_smoothed = Vector2.ZERO
		var steps_tau: int = int(round(float(hz) * tau))
		var acc: float = 0.0
		for i in steps_tau:
			acc += tc.look_step(1.0 / float(hz)).x
		var t_actual: float = float(steps_tau) / float(hz)
		_check(absf(tc._aim_smoothed.x - target * (1.0 - exp(-t_actual / tau))) < 0.0005, "%d Hz: the step response follows 1-exp(-t/tau) (%.3f at %.3f s)" % [hz, tc._aim_smoothed.x, t_actual])
		tc._aim_smoothed = Vector2.ZERO
		var half_s: int = int(round(float(hz) * 0.5))
		var acc2: float = 0.0
		for i in half_s:
			acc2 += tc.look_step(1.0 / float(hz)).x
		finals[hz] = tc._aim_smoothed.x
		totals[hz] = acc2
	var f_ref: float = finals[60]
	var t_ref: float = totals[60]
	var indep := true
	for hz in finals:
		if absf(finals[hz] - f_ref) > 0.0005:
			indep = false
		if absf(totals[hz] - t_ref) > t_ref * 0.10:
			indep = false
	_check(indep, "after 0.5 s the smoothed command is identical at 20-144 Hz and the turn within 10%% (%s %s)" % [finals, totals])
	_check(absf(finals[60] - (1.0 - exp(-0.5 / tau))) < 0.0005, "...and equals 1-exp(-0.5/tau)")
	# 60% = 72 ms
	SettingsManager.gameplay_settings[TouchControls.KEY_AIM_SMOOTH] = 60.0
	tc._apply_settings()
	tc._aim_smoothed = Vector2.ZERO
	for i in 9:
		tc.look_step(0.008)
	_check(absf(tc._aim_smoothed.x - target * (1.0 - exp(-1.0))) < 0.0005, "60%% smoothing reaches 63%% after 72 ms (%.3f)" % tc._aim_smoothed.x)
	_check(tc.look_step(5.0).x > 0.0 and tc._aim_smoothed.x < 0.99, "a frame hitch advances the filter by at most LOOK_MAX_STEP")
	# 0% = the raw, unsmoothed path
	SettingsManager.gameplay_settings[TouchControls.KEY_AIM_SMOOTH] = 0.0
	tc._apply_settings()
	tc._aim_smoothed = Vector2.ZERO
	var px: Vector2 = tc.look_step(1.0 / 30.0)
	var want_px: Vector2 = TouchControls.look_rates(tc._look_cmd, tc.look_gain) / TouchControls.LOOK_RAD_PER_MOUSE_PX / 30.0
	_check(px.distance_to(want_px) < 0.0001 and tc._aim_smoothed == tc._look_cmd, "slider 0%% is the raw path: the first step already turns at the full command")
	_touch(0, l0, false)
	await get_tree().create_timer(0.25).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
	_flush()
	# 6) release / cancel / background zero the smoothed command at once (no coasting)
	SettingsManager.gameplay_settings[TouchControls.KEY_AIM_SMOOTH] = 100.0
	tc._apply_settings()
	for how in ["release", "cancel", "background", "release_all"]:
		_touch(1, l0, true)
		_drag(1, at.call(1.0), Vector2.ZERO)
		for i in 6:
			tc.look_step(1.0 / 30.0)
		_check(tc._aim_smoothed.x > 0.3, "[%s] the smoothed aim is live before" % how)
		match how:
			"release": _touch(1, l0, false)
			"cancel":
				var cancel := InputEventScreenTouch.new()
				cancel.index = 1
				cancel.pressed = false
				cancel.canceled = true
				Input.parse_input_event(cancel)
				_flush()
			"background": tc.notification(NOTIFICATION_APPLICATION_PAUSED)
			_: tc.release_all()
		_check(tc._aim_smoothed == Vector2.ZERO and tc._look_cmd == Vector2.ZERO and tc.look_step(1.0 / 30.0) == Vector2.ZERO, "[%s] the aim is exactly zero immediately, no coasting" % how)
		_motion.clear()
		await _frames(4)
		_check(_real_motion().is_empty(), "[%s] nothing keeps turning" % how)
		_touch(1, l0, false)
		await get_tree().create_timer(0.25).timeout
		await get_tree().process_frame
		await get_tree().process_frame
		await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
		_flush()
	# 7) back inside the dead zone with the finger down: the smoothed tail decays to exactly zero
	_touch(0, l0, true)
	_drag(0, at.call(1.0), Vector2.ZERO)
	for i in 6:
		tc.look_step(1.0 / 30.0)
	_drag(0, at.call(0.05), Vector2.ZERO)
	_check(tc._look_cmd == Vector2.ZERO and tc._aim_smoothed != Vector2.ZERO, "back in the dead zone the target is zero and the filter is still decaying")
	var n: int = 0
	while tc._aim_smoothed != Vector2.ZERO and n < 200:
		tc.look_step(1.0 / 30.0)
		n += 1
	_check(tc._aim_smoothed == Vector2.ZERO and n < 60, "the tail ends at exactly zero (%d steps)" % n)
	_touch(0, l0, false)
	await get_tree().create_timer(0.25).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
	_flush()
	# Classic ignores the setting entirely (it has no rate path)
	_check(tc.is_twin(), "smoothing tests ran on twin-stick")


# ── attack + drag ────────────────────────────────────────────────────────────────────────────────
func _attack_drag_tests(tc: TouchControls, view: Vector2) -> void:
	var atk: TouchButton = tc.buttons["attack"]
	_attack_events.clear()
	_motion.clear()
	_touch(0, atk.center + Vector2(10, 5), true)
	_check(Input.is_action_pressed("attack") and tc._atk_index == 0, "touching ATTACK presses attack")
	var radius: float = TouchControls.AIM_DRAG_RADIUS * tc.ui_scale
	# a jitter inside the dead zone does not turn
	_drag(0, atk.center + Vector2(10 + 6, 5), Vector2(6, 0))
	await _frames(3)
	_check(_real_motion().is_empty(), "finger jitter on ATTACK does not turn")
	# drag far outside the button and back: attack never releases, the camera turns while it is down
	var path: Array = [Vector2(70, 0), Vector2(200, -50), Vector2(400, -100), Vector2(-300, 40), Vector2(-60, 0)]
	var turned_right := false
	var turned_left := false
	for off in path:
		_drag(0, atk.center + off, Vector2.ZERO)
		_motion.clear()
		await _frames(3)
		_check(Input.is_action_pressed("attack"), "attack stays pressed while dragging to %s" % off)
		for m in _real_motion():
			if m[0] > 0.0:
				turned_right = true
			if m[0] < 0.0:
				turned_left = true
	_check(turned_right and turned_left, "dragging from ATTACK turns right and left")
	_check(_attack_events == [true], "exactly one attack press and no release/re-press while dragging (%s)" % [_attack_events])
	_check(tc._owners[0]["kind"] == TouchControls.Owner.BUTTON and tc._owners[0]["button"] == "attack", "the dragging finger is still the attack button's")
	_touch(0, atk.center, false)
	await get_tree().create_timer(0.25).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
	_flush()
	_attack_events.clear()
	# the aim response curve, measured from the touch-down point
	_touch(0, atk.center, true)
	_drag(0, atk.center + Vector2(TouchControls.AIM_SETTLE_PX * tc.ui_scale + radius * 0.5, 0), Vector2.ZERO)
	var want: Vector2 = TouchControls.look_response(Vector2(0.5, 0))
	_check(tc._look_cmd.distance_to(want) < 0.001, "the attack drag uses the aim response (%s vs %s)" % [tc._look_cmd, want])
	# releasing ATTACK ends the drag and the turning, and then releases attack
	_touch(0, atk.center + Vector2(radius * 0.5, 0), false)
	_check(tc._look_cmd == Vector2.ZERO and tc._atk_index == -1, "releasing ATTACK ends the drag immediately")
	_motion.clear()
	await _frames(4)
	_check(_real_motion().is_empty(), "no turning after ATTACK is released")
	await get_tree().create_timer(0.25).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
	_flush()
	_check(not Input.is_action_pressed("attack") and _attack_events == [true, false], "attack released once after the drag (%s)" % [_attack_events])
	# a quick tap on ATTACK still lasts long enough for polling code
	_touch(0, atk.center, true)
	_touch(0, atk.center, false)
	_check(Input.is_action_pressed("attack"), "a tap on ATTACK is still stretched to MIN_PRESS_MS")
	await get_tree().create_timer(0.25).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame   # the deferred release runs in the layer's _process: a frame hitch must not skip it
	_flush()
	_check(not Input.is_action_pressed("attack"), "...and released")
	# same-direction wandering across the whole screen never exceeds full deflection
	_touch(0, atk.center, true)
	_drag(0, atk.center + Vector2(radius * 5.0, radius * 4.0), Vector2.ZERO)
	_check(tc._look_cmd.length() <= 1.0 + 0.0001 and tc._look_cmd.length() > 0.9, "a far drag is limited to full deflection (%s)" % tc._look_cmd)
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
	var radius: float = TouchControls.AIM_DRAG_RADIUS * tc.ui_scale
	for mode in ["background", "focus_out", "window_focus_out", "pause"]:
		_touch(0, s0, true)
		_drag(0, s0 + Vector2(100, 0), Vector2(100, 0))
		_touch(1, atk.center, true)
		_drag(1, atk.center + Vector2(radius, 0), Vector2.ZERO)
		_touch(2, (tc.buttons["block"] as TouchButton).center, true)
		await _frames(2)
		_check(Input.is_action_pressed("move_right") and Input.is_action_pressed("attack") and Input.is_action_pressed("block") and tc._look_cmd != Vector2.ZERO, "[%s] move + attack-drag + block all live" % mode)
		match mode:
			"background": tc.notification(NOTIFICATION_APPLICATION_PAUSED)
			"focus_out": tc.notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
			"window_focus_out": tc.notification(NOTIFICATION_WM_WINDOW_FOCUS_OUT)
			_: get_tree().paused = true
		await _frames(2)
		_flush()
		_check(_down_actions().is_empty(), "[%s] every held action is released (%s)" % [mode, _down_actions()])
		_check(tc._look_cmd == Vector2.ZERO and tc._atk_index == -1 and tc._owners.is_empty() and tc._atk_vec == Vector2.ZERO and not tc._stick_active, "[%s] look velocity and every finger are reset" % mode)
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
	_check(tc._look_cmd == Vector2.ZERO and _down_actions().is_empty(), "disabling the layer stops the aim and releases attack")
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
	_check(looked.size() >= 1 and absf(float(looked[0][0]) - 100.0 * TouchControls.LOOK_BASE_GAIN) < 0.01, "Classic: a 100 px swipe turns like %.0f mouse px" % (100.0 * TouchControls.LOOK_BASE_GAIN))
	_motion.clear()
	await _frames(5)
	_check(_real_motion().is_empty() and tc._look_cmd == Vector2.ZERO, "Classic: holding a finger still does not keep turning")
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
	_drag(0, atk.center + Vector2(80, 0), Vector2.ZERO)
	for i in 30:
		await get_tree().physics_frame
	_flush()
	_check(tc.look_time >= TouchOnboarding.AIM_DONE_SECONDS, "holding the drag out accumulates look_time (%.2f)" % tc.look_time)
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
	for key in [TouchControls.KEY_OPACITY, TouchControls.KEY_SCALE, TouchControls.KEY_LOOK, TouchControls.KEY_AIM_SMOOTH]:
		_check(scr._sliders.has(key), "the %s slider is there" % key)
	var live: TouchControls = _new_layer(Vector2(1602, 720))
	await _frames(2)
	var sl: HSlider = scr._sliders[TouchControls.KEY_AIM_SMOOTH]
	_check(sl.min_value == 0.0 and sl.max_value == 100.0 and is_equal_approx(sl.value, 60.0), "the Aim Smoothing slider is 0-100 and starts at the saved 60 (%.0f)" % sl.value)
	sl.value = 25.0
	_check(is_equal_approx(float(SettingsManager.gameplay_settings.get(TouchControls.KEY_AIM_SMOOTH)), 25.0), "moving the slider writes TouchAimSmoothing")
	await get_tree().create_timer(0.7).timeout
	_check(is_equal_approx(live.aim_smoothing, 0.25), "...and the live layer applies it without a restart (%.2f)" % live.aim_smoothing)
	live.queue_free()
	SettingsManager.update_setting(TouchControls.KEY_AIM_SMOOTH, 60.0)
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
	var radius: float = TouchControls.AIM_DRAG_RADIUS * tc.ui_scale
	var yaw0: float = player.rotation.y
	# empty right-side screen does nothing to the real player
	var e0: Vector2 = Vector2(1602.0 * 0.55, 720.0 * 0.35)
	_touch(5, e0, true)
	_drag(5, e0 + Vector2(300, 0), Vector2(300, 0))
	await _frames(12)
	_check(absf(player.rotation.y - yaw0) < 0.0001 and not Input.is_action_pressed("attack"), "[%s] dragging on empty right-side screen does not turn the player or attack" % cls)
	_touch(5, e0, false)
	# ATTACK drag, right
	_touch(0, l0, true)
	_drag(0, l0 + Vector2(radius, 0), Vector2.ZERO)
	await _frames(15)
	var yaw1: float = player.rotation.y
	_check(yaw1 < yaw0 - 0.5, "[%s] dragging from ATTACK right turns the player right (yaw %.2f -> %.2f)" % [cls, yaw0, yaw1])
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
	_check(player.rotation.y > yaw2 + 0.5, "[%s] dragging from ATTACK left turns the player left (%.2f -> %.2f)" % [cls, yaw2, player.rotation.y])
	_touch(0, l0, false)
	await _frames(3)
	# half deflection is slower than full
	var y3: float = player.rotation.y
	_touch(0, l0, true)
	_drag(0, l0 + Vector2(radius * 0.5, 0), Vector2.ZERO)
	await _frames(10)
	var half_turn: float = y3 - player.rotation.y
	_touch(0, l0, false)
	await _frames(3)
	var y4: float = player.rotation.y
	_touch(0, l0, true)
	_drag(0, l0 + Vector2(radius, 0), Vector2.ZERO)
	await _frames(10)
	var full_turn: float = y4 - player.rotation.y
	_touch(0, l0, false)
	await _frames(3)
	_check(half_turn > 0.01 and full_turn > half_turn * 2.0, "[%s] half deflection turns slower than full (%.2f vs %.2f rad)" % [cls, half_turn, full_turn])
	# ATTACK drag turns the player while attack is held
	var atk: TouchButton = tc.buttons["attack"]
	_attack_events.clear()
	var y5: float = player.rotation.y
	_touch(1, atk.center, true)
	_drag(1, atk.center + Vector2(-radius, 0), Vector2.ZERO)
	await _frames(12)
	_check(Input.is_action_pressed("attack"), "[%s] attack is held during the drag" % cls)
	_check(player.rotation.y > y5 + 0.4, "[%s] dragging from ATTACK turns the player left while attacking (%.2f -> %.2f)" % [cls, y5, player.rotation.y])
	_check(_attack_events == [true], "[%s] no attack release/re-press during the drag (%s)" % [cls, _attack_events])
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
