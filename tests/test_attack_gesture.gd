extends Node
## The twin-stick ATTACK button is also the look surface, so a touch on it is classified before it attacks, and an attack
## state can never outlive the finger that started it. Contract (scripts/touch/touch_controls.gd, docs/ANDROID.md):
##   TAP  = exactly one attack            HOLD (no drag) = exactly one attack after ATTACK_INTENT_MS, never repeating
##   DRAG = zero attacks, camera at once  DRAG BACK to the centre = still look, zero attacks; a new attack needs a new touch
##   touch-up / cancel / lost pointer / background / focus / pause / hide / exit_tree clear everything, no attack on the way out
## And the owner decision this file pins: the Rapid Attack (hold-to-charge, then automatic fire) no longer exists on any
## control scheme. One press (or one touch gesture) is exactly one attack; holding never charges, repeats or changes anything,
## the players have no charge / hold state and no ability bar, and a release lost while the tree was paused cannot start anything.
##
## Two parts, selected by ATTACK_CLASS (run_tests.sh runs both):
##   unset           the real TouchControls driven by synthetic InputEventScreenTouch / ScreenDrag events on a controllable clock
##   barbarian/mage  the real player in the real run, same events, real time: bolts / attacks counted over seconds
## Needs PURGATORY_FORCE_TOUCH=1 (run_tests.sh sets it).

var _fails: int = 0
var _checks: int = 0
var _clock: int = 100000
var _attack_events: Array = []     # attack action press (true) / release (false) events as the game sees them
var _motion: Array = []            # mouse-look motion events as the game sees them: [dx, dy, device]
var _probe: Node


class Probe extends Node:
	var motion: Array
	var attack: Array
	func _input(event: InputEvent) -> void:
		if event is InputEventMouseMotion:
			var m := event as InputEventMouseMotion
			motion.append([m.relative.x, m.relative.y, m.device])
		elif event is InputEventAction and (event as InputEventAction).action == "attack":
			attack.append((event as InputEventAction).pressed)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _flush() -> void:
	Input.flush_buffered_events()


var _last_pos: Dictionary = {}   # finger index -> last reported position (a real drag event carries the movement since the previous one)


func _touch(index: int, pos: Vector2, pressed: bool, canceled: bool = false) -> void:
	_last_pos[index] = pos
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = pressed
	e.canceled = canceled
	Input.parse_input_event(e)
	_flush()


func _drag(index: int, pos: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = pos
	e.relative = pos - Vector2(_last_pos.get(index, pos))
	_last_pos[index] = pos
	Input.parse_input_event(e)
	_flush()


func _presses() -> int:
	return _attack_events.count(true)


func _real_motion() -> Array:
	return _motion.filter(func(m): return m[2] != InputEvent.DEVICE_ID_EMULATION)


func _reset_counts() -> void:
	_attack_events.clear()
	_motion.clear()


## Advance the layer's clock by `ms` in rendered frames of at most `step` ms (the layer's own _process runs in each one).
func _adv(tc: TouchControls, ms: int, step: int = 50) -> void:
	var left: int = ms
	while left > 0:
		var d: int = mini(step, left)
		_clock += d
		tc.now_override_ms = _clock
		left -= d
		await get_tree().process_frame
		_flush()


func _new_layer() -> TouchControls:
	var tc := TouchControls.new()
	tc.layout_override_insets = Vector4.ZERO
	tc.view_override = Vector2(1602, 720)
	tc.dpi_override = 480.0
	tc.screen_override = Vector2(2992, 1344)
	tc.now_override_ms = _clock
	add_child(tc)
	return tc


func _ready() -> void:
	if OS.get_environment("PURGATORY_FORCE_TOUCH") != "1":
		printerr("FAIL: run with PURGATORY_FORCE_TOUCH=1")
		get_tree().quit(2)
		return
	Input.use_accumulated_input = false
	_probe = Probe.new()
	_probe.motion = _motion
	_probe.attack = _attack_events
	add_child(_probe)
	var cls: String = OS.get_environment("ATTACK_CLASS")
	if cls != "":
		await _player_tests(cls)
	else:
		await _layer_tests()
	print("test_attack_gesture%s: %d checks, %d failures" % ["" if cls == "" else " (" + cls + ")", _checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


# ══════════════════════════════════════════════════════════════════════════════════════════════════
func _layer_tests() -> void:
	SettingsManager.gameplay_settings[TouchControls.KEY_SCHEME] = TouchControls.SCHEME_TWIN
	var tc: TouchControls = _new_layer()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(tc.is_twin(), "twin-stick scheme")
	await _constants_tests(tc)
	await _tap_hold_tests(tc)
	await _drag_tests(tc)
	await _end_of_touch_tests(tc)
	await _lost_pointer_tests(tc)
	_check(tc.attack_failsafe_releases == 0, "no normal path needed the fail-safe (%d forced releases)" % tc.attack_failsafe_releases)
	tc.queue_free()
	await get_tree().process_frame
	await _lifecycle_tests()
	await _failsafe_tests()
	await _small_ui_tests()
	await _classic_tests()


func _constants_tests(tc: TouchControls) -> void:
	var tick_ms: float = 1000.0 / float(Engine.physics_ticks_per_second)
	_check(TouchControls.ATTACK_INTENT_MS >= 100 and TouchControls.ATTACK_INTENT_MS <= 200, "hold-intent time is %d ms (120-180 ms class)" % TouchControls.ATTACK_INTENT_MS)
	_check(float(TouchControls.ATTACK_PULSE_MS) >= 2.0 * tick_ms, "the attack pulse (%d ms) spans at least two physics ticks (%.1f ms each)" % [TouchControls.ATTACK_PULSE_MS, tick_ms])
	_check(not ("charge" in tc.buttons["attack"]), "the ATTACK button has no hold-to-charge ring any more")
	_check(TouchControls.ATTACK_PULSE_MAX_MS > TouchControls.ATTACK_PULSE_MS and TouchControls.ATTACK_PULSE_MAX_MS <= 300, "the hard cap on a scheduled release is %d ms" % TouchControls.ATTACK_PULSE_MAX_MS)
	var c: Vector2 = (tc.buttons["attack"] as TouchButton).center
	_touch(0, c, true)
	_check(tc._atk_slop_px >= TouchControls.ATTACK_SLOP_MIN_PX and tc._atk_slop_px <= TouchControls.ATTACK_SLOP_MAX_PX, "the slop radius (%.1f px) is inside its clamp" % tc._atk_slop_px)
	var mm: float = tc._atk_slop_px / tc.device_px_per_mm()
	_check(mm > 1.0 and mm < 2.2, "on the Pixel-class panel the slop is %.2f mm (~%.1f dp; Android's own touch slop is 8 dp)" % [mm, mm / 25.4 * 160.0])
	_touch(0, c, false)
	await _adv(tc, 200)
	_reset_counts()


func _tap_hold_tests(tc: TouchControls) -> void:
	var c: Vector2 = (tc.buttons["attack"] as TouchButton).center
	# TAP = exactly one attack, at the lift, never at the touch-down
	_reset_counts()
	_touch(0, c, true)
	_check(_presses() == 0 and not Input.is_action_pressed("attack"), "touch-down alone attacks nothing")
	await _adv(tc, 60)
	_check(_presses() == 0, "a finger resting 60 ms (under the intent time) has not attacked")
	_touch(0, c, false)
	_check(_presses() == 1 and Input.is_action_pressed("attack"), "the lift of a tap sends the one attack")
	await _adv(tc, 40)
	_check(Input.is_action_pressed("attack"), "...and the press lasts its full pulse (long enough for polling code)")
	await _adv(tc, 200)
	_check(_attack_events == [true, false] and not Input.is_action_pressed("attack"), "a tap is exactly one press and one release (%s)" % [_attack_events])
	_check(tc._owners.is_empty() and tc._atk_index == -1 and tc._held.is_empty() and tc._pending_release.is_empty(), "touch-up cleared every bit of attack state")
	# a very fast tap (down and up in the same frame)
	_reset_counts()
	_touch(0, c, true)
	_touch(0, c, false)
	await _adv(tc, 300)
	_check(_attack_events == [true, false], "a same-frame tap is still exactly one attack (%s)" % [_attack_events])

	# HOLD without dragging = ONE attack at the intent time, then nothing, however long it lasts
	_reset_counts()
	_touch(0, c, true)
	await _adv(tc, TouchControls.ATTACK_INTENT_MS - 50)
	_check(_presses() == 0, "held %d ms: not yet" % (TouchControls.ATTACK_INTENT_MS - 50))
	await _adv(tc, 100)
	_check(_presses() == 1, "held past the intent time: exactly one attack")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 100:   # five seconds, with the tremor of a resting thumb (inside the slop circle)
		await _adv(tc, 50)
		_drag(0, c + Vector2(rng.randf_range(-4.0, 4.0), rng.randf_range(-4.0, 4.0)))
	_check(_presses() == 1 and _attack_events == [true, false], "holding 5 s still never repeats (presses %d, events %s)" % [_presses(), _attack_events])
	_check(not Input.is_action_pressed("attack") and tc._held.is_empty(), "...and nothing is left pressed")
	_check(_real_motion().is_empty(), "...and the resting thumb did not turn the camera")
	_touch(0, c, false)
	await _adv(tc, 300)
	_check(_presses() == 1, "lifting after a hold sends no second attack")
	_check(tc._owners.is_empty() and tc._atk_index == -1 and tc._pending_release.is_empty(), "...and clears the gesture")

	# a hold that turns into a drag keeps its one attack and then looks (<= 1 attack per gesture)
	_reset_counts()
	_touch(0, c, true)
	await _adv(tc, 200)
	_check(_presses() == 1, "hold then...")
	_drag(0, c + Vector2(60, 0))
	await _adv(tc, 200)
	_check(tc._atk_gesture == TouchControls.Gesture.LOOK and not _real_motion().is_empty(), "...drag: the same finger now looks")
	await _adv(tc, 2000)
	_check(_presses() == 1, "...and that gesture never attacks again (%d)" % _presses())
	_touch(0, c + Vector2(60, 0), false)
	await _adv(tc, 300)
	_check(_presses() == 1 and tc._held.is_empty(), "lifting a hold-then-drag gesture: still one attack in total")


func _drag_tests(tc: TouchControls) -> void:
	var c: Vector2 = (tc.buttons["attack"] as TouchButton).center
	# DRAG = zero attacks; the camera answers in the very frame after the finger crosses the camera's engage distance
	_reset_counts()
	_touch(0, c, true)
	await _adv(tc, 20)
	_drag(0, c + Vector2(40, 0))
	_check(tc._atk_gesture == TouchControls.Gesture.LOOK, "a drag past the slop circle is a look gesture on the very event")
	var want_px: float = (40.0 - tc._atk_slop_px) * TouchControls.LOOK_BASE_GAIN * tc.look_gain * tc.attack_look_gain
	_check(_real_motion().size() == 1 and absf(float(_real_motion()[0][0]) - want_px) < 0.01, "...and the camera turns on that very event by the Classic path: the movement beyond the slop circle x gain (%s vs %.2f px)" % [_real_motion(), want_px])
	_check(_real_motion().all(func(m): return m[0] > 0.0), "...in the dragged direction")
	await _adv(tc, 3000)
	_check(_presses() == 0 and not Input.is_action_pressed("attack"), "dragging for 3 s: zero attacks")
	_touch(0, c + Vector2(40, 0), false)
	await _adv(tc, 400)
	_check(_presses() == 0 and tc._atk_gesture == TouchControls.Gesture.NONE, "lifting after a drag: zero attacks, the gesture is over")

	# DRAG then back to the centre: look once, look until the lift
	for back_after in [30, 400]:
		_reset_counts()
		_touch(0, c, true)
		await _adv(tc, 10)
		_drag(0, c + Vector2(30, 0))
		await _adv(tc, back_after)
		_drag(0, c)   # back exactly on the touch-down point
		_check(tc._atk_gesture == TouchControls.Gesture.LOOK, "[back after %d ms] returning to the centre keeps it a look gesture" % back_after)
		await _adv(tc, 3000)
		_check(_presses() == 0, "[back after %d ms] resting back on the button for 3 s: zero attacks" % back_after)
		_touch(0, c, false)
		await _adv(tc, 400)
		_check(_presses() == 0 and tc._held.is_empty(), "[back after %d ms] lifting there: zero attacks" % back_after)
	# a tiny excursion past the slop circle (and back at once) is still look
	_reset_counts()
	_touch(0, c, true)
	_drag(0, c + Vector2(tc._atk_slop_px + 1.0, 0))
	_drag(0, c)
	_touch(0, c, false)
	await _adv(tc, 400)
	_check(_presses() == 0, "a flick just past the slop circle and back is a look gesture, not a tap")
	# ...but a wobble inside it is still a tap
	_reset_counts()
	_touch(0, c, true)
	_drag(0, c + Vector2(tc._atk_slop_px - 1.0, 0))
	_touch(0, c + Vector2(tc._atk_slop_px - 1.0, 0), false)
	await _adv(tc, 400)
	_check(_attack_events == [true, false], "a wobble inside the slop circle is still a tap (%s)" % [_attack_events])
	# a lift far from the touch-down point (the drags were dropped) is look as well
	_reset_counts()
	_touch(0, c, true)
	_touch(0, c + Vector2(80, 0), false)
	await _adv(tc, 400)
	_check(_presses() == 0, "a lift far from the touch-down point sends no attack even if no drag event arrived")

	# a NEW touch is needed for the next attack
	_reset_counts()
	_touch(0, c, true)
	_drag(0, c + Vector2(50, 0))
	await _adv(tc, 500)
	_touch(0, c + Vector2(50, 0), false)
	await _adv(tc, 100)
	_check(_presses() == 0, "drag gesture: zero")
	_touch(1, c, true)
	await _adv(tc, 50)
	_touch(1, c, false)
	await _adv(tc, 300)
	_check(_attack_events == [true, false], "...a new touch (tap) attacks exactly once (%s)" % [_attack_events])
	await _adv(tc, 300)
	_touch(1, c, true)
	await _adv(tc, 50)
	_touch(1, c, false)
	await _adv(tc, 300)
	_check(_presses() == 2, "...and each further tap is one more attack, no more (%d)" % _presses())
	# the stick finger and the ATTACK finger do not interfere
	var s0 := Vector2(1602.0 * 0.12, 720.0 * 0.72)
	_reset_counts()
	_touch(0, s0, true)
	_drag(0, s0 + Vector2(100, 0))
	_touch(1, c, true)
	await _adv(tc, 60)
	_touch(1, c, false)
	await _adv(tc, 300)
	_check(_presses() == 1 and Input.is_action_pressed("move_right"), "tap while walking: one attack, walking continues")
	_touch(0, s0, false)
	await _adv(tc, 100)


func _end_of_touch_tests(tc: TouchControls) -> void:
	var c: Vector2 = (tc.buttons["attack"] as TouchButton).center
	# cancelled pointer (the engine's ACTION_CANCEL): no attack, everything cleared
	for phase in ["pending", "look"]:
		_reset_counts()
		_touch(0, c, true)
		if phase == "look":
			_drag(0, c + Vector2(50, 0))
		await _adv(tc, 60)
		_touch(0, c, false, true)
		await _adv(tc, 400)
		_check(_presses() == 0 and tc._owners.is_empty() and tc._atk_index == -1 and tc._atk_gesture == TouchControls.Gesture.NONE, "[%s] a cancelled pointer attacks nothing and clears the gesture" % phase)
	_reset_counts()
	_touch(0, c, true)
	await _adv(tc, 60)
	_touch(0, c, true, true)   # pressed AND cancelled: still a cancel
	await _adv(tc, 400)
	_check(_presses() == 0 and tc._owners.is_empty(), "a press event flagged as cancelled attacks nothing")
	# cancelled after the hold fired: the one attack ends on schedule
	_reset_counts()
	_touch(0, c, true)
	await _adv(tc, 160)
	_touch(0, c, false, true)
	await _adv(tc, 400)
	_check(_attack_events == [true, false] and tc._owners.is_empty() and not Input.is_action_pressed("attack"), "cancel after a fired hold: the one attack ends cleanly (%s)" % [_attack_events])
	# touch-up during the pulse: nothing stays down
	_reset_counts()
	_touch(0, c, true)
	await _adv(tc, 160)
	_touch(0, c, false)
	_check(Input.is_action_pressed("attack"), "(the pulse of a fired hold is still in flight at the lift)")
	await _adv(tc, 200)
	_check(not Input.is_action_pressed("attack") and _attack_events == [true, false] and tc._held.is_empty(), "lifting during the pulse leaves nothing pressed")


func _lost_pointer_tests(tc: TouchControls) -> void:
	var c: Vector2 = (tc.buttons["attack"] as TouchButton).center
	# the same finger index goes down again with no lift in between (the lift was lost)
	_reset_counts()
	_touch(3, c, true)
	await _adv(tc, 100)
	_touch(3, c, true)
	await _adv(tc, 60)
	_check(_presses() == 0 and tc._owners.size() == 1, "a re-used index drops the lost finger without attacking (%d presses)" % _presses())
	_touch(3, c, false)
	await _adv(tc, 300)
	_check(_attack_events == [true, false], "...and the new finger's tap is the one attack (%s)" % [_attack_events])
	# another finger lands on ATTACK while the first one is gone without a trace: the new finger owns the gesture
	_reset_counts()
	_touch(1, c, true)
	await _adv(tc, 80)
	_touch(2, c, true)
	_check(tc._atk_index == 2 and not tc._owners.has(1), "a finger landing on ATTACK takes the gesture over from a lost one")
	await _adv(tc, 60)
	_drag(1, c + Vector2(200, 0))   # the old index still reports: ignored
	_touch(1, c, false)
	await get_tree().process_frame
	_flush()
	_check(_real_motion().is_empty() and _presses() == 0, "late events of the lost finger do nothing")
	_touch(2, c, false)
	await _adv(tc, 300)
	_check(_attack_events == [true, false] and tc._owners.is_empty(), "...the second finger's tap is the one attack (%s)" % [_attack_events])
	# a finger that vanishes after its attack fired (no lift ever): the attack still ends by itself
	_reset_counts()
	_touch(4, c, true)
	await _adv(tc, 200)
	await _adv(tc, 1000)
	_check(_attack_events == [true, false] and not Input.is_action_pressed("attack"), "a finger that never lifts cannot keep an attack alive (%s)" % [_attack_events])
	_touch(4, c, false)
	await _adv(tc, 100)
	# a drag for an index that never touched down is ignored
	_reset_counts()
	_drag(7, c + Vector2(80, 0))
	await get_tree().process_frame
	_flush()
	_check(_real_motion().is_empty() and tc._owners.is_empty(), "a drag with no touch-down turns and attacks nothing")


# ── lifecycle: every way the finger can stop mattering ───────────────────────────────────────────
func _lifecycle_tests() -> void:
	SettingsManager.gameplay_settings[TouchControls.KEY_SCHEME] = TouchControls.SCHEME_TWIN
	var tc: TouchControls = _new_layer()
	await get_tree().process_frame
	var c: Vector2 = (tc.buttons["attack"] as TouchButton).center
	for mode in ["app_paused", "app_focus_out", "window_focus_out", "app_resumed", "app_focus_in", "tree_paused", "hidden", "disabled", "scheme_change", "freed"]:
		for phase in ["pending", "fired"]:
			_reset_counts()
			_touch(0, c, true)
			await _adv(tc, 60 if phase == "pending" else 160)
			_check(Input.is_action_pressed("attack") == (phase == "fired"), "[%s/%s] the state before: attack %s" % [mode, phase, "in flight" if phase == "fired" else "not pressed"])
			match mode:
				"app_paused": tc.notification(NOTIFICATION_APPLICATION_PAUSED)
				"app_focus_out": tc.notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
				"window_focus_out": tc.notification(NOTIFICATION_WM_WINDOW_FOCUS_OUT)
				"app_resumed": tc.notification(NOTIFICATION_APPLICATION_RESUMED)
				"app_focus_in": tc.notification(NOTIFICATION_APPLICATION_FOCUS_IN)
				"tree_paused": get_tree().paused = true
				"hidden": tc.hide()
				"disabled": tc.set_enabled(false)
				"scheme_change":
					SettingsManager.gameplay_settings[TouchControls.KEY_SCHEME] = TouchControls.SCHEME_CLASSIC
					tc.set_scheme(TouchControls.SCHEME_CLASSIC)
				"freed": tc.get_parent().remove_child(tc)
			await get_tree().process_frame
			_flush()
			_check(not Input.is_action_pressed("attack"), "[%s/%s] nothing is attacking after it" % [mode, phase])
			_check(tc._owners.is_empty() and tc._atk_index == -1 and tc._held.is_empty() and tc._pending_release.is_empty() and tc._atk_gesture == TouchControls.Gesture.NONE, "[%s/%s] every finger and state is forgotten" % [mode, phase])
			var before: int = _presses()
			if mode != "freed":
				await _adv(tc, 1200)   # the finger is still down on the screen
			else:
				await get_tree().process_frame
			_check(_presses() == before and not Input.is_action_pressed("attack"), "[%s/%s] a finger still resting there attacks nothing later (%d -> %d)" % [mode, phase, before, _presses()])
			_touch(0, c, false)
			await get_tree().process_frame
			_flush()
			_check(_presses() == before, "[%s/%s] its late lift attacks nothing" % [mode, phase])
			match mode:
				"tree_paused": get_tree().paused = false
				"hidden": tc.show()
				"disabled": tc.set_enabled(true)
				"scheme_change":
					SettingsManager.gameplay_settings[TouchControls.KEY_SCHEME] = TouchControls.SCHEME_TWIN
					tc.set_scheme(TouchControls.SCHEME_TWIN)
				"freed":
					tc.free()
					tc = _new_layer()
					await get_tree().process_frame
			await _adv(tc, 100)
			c = (tc.buttons["attack"] as TouchButton).center
	# the layer works normally after all of that
	_reset_counts()
	_touch(0, c, true)
	await _adv(tc, 50)
	_touch(0, c, false)
	await _adv(tc, 300)
	_check(_attack_events == [true, false], "after every interruption a tap is still exactly one attack (%s)" % [_attack_events])
	_check(tc.attack_failsafe_releases == 0, "no interruption needed the fail-safe (%d)" % tc.attack_failsafe_releases)
	# a hidden layer takes no touches at all
	tc.hide()
	_reset_counts()
	_touch(0, c, true)
	await _adv(tc, 400)
	_touch(0, c, false)
	_check(_presses() == 0 and tc._owners.is_empty(), "a hidden layer ignores touches")
	tc.show()
	tc.queue_free()
	await get_tree().process_frame


# ── the fail-safe itself: inject the stuck states the field defect would have produced ──────────────
func _failsafe_tests() -> void:
	var tc: TouchControls = _new_layer()
	await get_tree().process_frame
	# 1) attack "held" with no finger and no scheduled release (the leak)
	_reset_counts()
	tc._held["attack"] = 1.0
	tc._press_ms["attack"] = _clock
	Input.action_press("attack")
	_check(Input.is_action_pressed("attack"), "(injected: attack stuck down with no finger)")
	await _adv(tc, 50)
	_check(not Input.is_action_pressed("attack") and not tc._held.has("attack") and tc.attack_failsafe_releases >= 1, "the fail-safe releases an attack no finger owns (%d forced)" % tc.attack_failsafe_releases)
	# 2) a scheduled release that never comes due (clock anomaly): the hard cap ends it
	var forced: int = tc.attack_failsafe_releases
	tc._held["attack"] = 1.0
	tc._press_ms["attack"] = _clock - 1000
	tc._pending_release["attack"] = _clock + 10000000
	Input.action_press("attack")
	await _adv(tc, 50)
	_check(not Input.is_action_pressed("attack") and tc._pending_release.is_empty() and tc.attack_failsafe_releases > forced, "a pending release past ATTACK_PULSE_MAX_MS is cut off")
	# 3) the engine's own state disagrees with ours shortly after our release
	forced = tc.attack_failsafe_releases
	tc._attack_release_ms = _clock - 200
	Input.action_press("attack")
	await _adv(tc, 50)
	_check(not Input.is_action_pressed("attack") and tc.attack_failsafe_releases > forced, "an engine attack state that outlived our release is set straight")
	# 4) a stuck move axis with no stick finger
	forced = tc.attack_failsafe_releases
	tc._held["move_left"] = 1.0
	Input.action_press("move_left")
	await _adv(tc, 50)
	_check(not Input.is_action_pressed("move_left") and tc.attack_failsafe_releases > forced, "a stuck move axis with no stick finger is released")
	# 5) other held buttons with no owner (block)
	forced = tc.attack_failsafe_releases
	tc._held["block"] = 1.0
	tc._press_ms["block"] = _clock
	Input.action_press("block")
	await _adv(tc, 50)
	_check(not Input.is_action_pressed("block") and tc.attack_failsafe_releases > forced, "any held button without a live finger is released")
	# 6) a genuinely held button is NOT touched
	forced = tc.attack_failsafe_releases
	var blk: Vector2 = (tc.buttons["block"] as TouchButton).center
	_touch(5, blk, true)
	await _adv(tc, 1000)
	_check(Input.is_action_pressed("block") and tc.attack_failsafe_releases == forced, "a held block with its finger down is left alone")
	_touch(5, blk, false)
	await _adv(tc, 200)
	_check(not Input.is_action_pressed("block"), "...and released with the finger")
	tc.queue_free()
	await get_tree().process_frame


## At the smallest UI size the camera must still never turn under a still-undecided (or attacking) gesture.
func _small_ui_tests() -> void:
	SettingsManager.gameplay_settings[TouchControls.KEY_SCALE] = 60.0
	var tc: TouchControls = _new_layer()
	await get_tree().process_frame
	_check(is_equal_approx(tc.ui_scale, 0.6), "UI size 60%")
	var c: Vector2 = (tc.buttons["attack"] as TouchButton).center
	_reset_counts()
	_touch(0, c, true)
	for step in 40:   # a slow drag, 1 px at a time
		_drag(0, c + Vector2(float(step + 1), 0.0))
		if not _real_motion().is_empty():
			_check(tc._atk_gesture == TouchControls.Gesture.LOOK, "the camera only ever turns under a look gesture (at %d px, slop %.1f px)" % [step + 1, tc._atk_slop_px])
			break
		_check(tc._atk_gesture != TouchControls.Gesture.LOOK, "no camera turn and no look gesture inside the slop circle (%d px)" % (step + 1))
	await _adv(tc, 1500)
	_touch(0, c + Vector2(40, 0), false)
	await _adv(tc, 300)
	_check(_presses() == 0, "a slow drag at 60% size: zero attacks")
	tc.queue_free()
	await get_tree().process_frame
	SettingsManager.gameplay_settings[TouchControls.KEY_SCALE] = 100.0


# ── Classic scheme: press / hold / release, one press = one attack (holding never charges), never leaked ───────────
func _classic_tests() -> void:
	SettingsManager.gameplay_settings[TouchControls.KEY_SCHEME] = TouchControls.SCHEME_CLASSIC
	var tc: TouchControls = _new_layer()
	await get_tree().process_frame
	_check(not tc.is_twin(), "classic scheme")
	var c: Vector2 = (tc.buttons["attack"] as TouchButton).center
	_reset_counts()
	_touch(0, c, true)
	_check(Input.is_action_pressed("attack"), "Classic: touching ATTACK presses attack at once (unchanged)")
	await _adv(tc, 2000)
	_check(Input.is_action_pressed("attack") and _presses() == 1, "Classic: holding keeps it held (nothing charges): one press")
	_touch(0, c, false)
	await _adv(tc, 200)
	_check(not Input.is_action_pressed("attack") and _attack_events == [true, false], "Classic: the lift releases it")
	# a lost lift: the index goes down again, or another finger lands on the button: one owner only
	_reset_counts()
	_touch(1, c, true)
	await _adv(tc, 100)
	_touch(1, c, true)
	_check(tc._owners.size() == 1, "Classic: a re-used index leaves one owner of the button")
	_touch(2, c, true)
	_check(tc._owners.size() == 1 and tc._owners.has(2), "Classic: a second finger on the button takes it over")
	_touch(1, c, false)   # the old finger's late lift must not release the new finger's button
	await _adv(tc, 200)
	_check(Input.is_action_pressed("attack"), "Classic: the lost finger's late lift does not release the new finger's attack")
	_touch(2, c, false)
	await _adv(tc, 200)
	_check(not Input.is_action_pressed("attack") and tc._held.is_empty(), "Classic: ...and the live finger's lift does")
	# Classic: the background releases a held attack and a late lift attacks nothing
	_reset_counts()
	_touch(0, c, true)
	await _adv(tc, 500)
	tc.notification(NOTIFICATION_APPLICATION_PAUSED)
	await _adv(tc, 100)
	_check(not Input.is_action_pressed("attack"), "Classic: backgrounding releases a held attack")
	_touch(0, c, false)
	await _adv(tc, 200)
	_check(_attack_events == [true, false] and tc.attack_failsafe_releases == 0, "Classic: one press/release pair, no fail-safe needed (%s)" % [_attack_events])
	tc.queue_free()
	await get_tree().process_frame
	SettingsManager.gameplay_settings[TouchControls.KEY_SCHEME] = TouchControls.SCHEME_TWIN


# ══════════════════════════════════════════════════════════════════════════════════════════════════
# The real player in the real run (real time): one press = one attack, end to end, and no Rapid Attack anywhere.
var _bolts: int = 0
var _swings: int = 0                # rising edges of the player's _is_attacking: one per attack
var _was_attacking: bool = false
var _player: Node = null


# A bolt is "fired" when a pooled bolt is activated: it is renamed "MageFireball_<n>" (idle ones are "MageBolt_Idle_<id>"). A bolt that is
# built on demand (the pool grows) enters the tree under its idle name and is renamed at once, so the rename is the one signal for both.
func _on_child(n: Node) -> void:
	if n.name.begins_with("MageFireball_"):
		_bolts += 1


func _wait(sec: float) -> void:
	var t_end: int = Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < t_end:
		await get_tree().process_frame
		_flush()
		if _player != null:
			var a: bool = _player.get("_is_attacking") == true
			if a and not _was_attacking:
				_swings += 1
			_was_attacking = a


## The attack action as a real device sends it (an InputEventAction through the input pipeline, like a mouse button).
func _attack_action(pressed: bool) -> void:
	var e := InputEventAction.new()
	e.action = "attack"
	e.pressed = pressed
	Input.parse_input_event(e)
	_flush()


func _reset_attacks() -> void:
	_reset_counts()
	_bolts = 0
	_swings = 0


func _player_tests(cls: String) -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	GlobalRunData.character_class = cls
	var main: Node = (load("res://scenes/Purgatory_Dungeon_main_game_file.tscn") as PackedScene).instantiate()
	add_child(main)
	for i in 150:
		await get_tree().physics_frame
		await get_tree().process_frame
	var manager = main.get_node_or_null("EnemyManager")
	if manager != null:
		manager.set_physics_process(false)
		for e in manager._active_enemies:
			if is_instance_valid(e):
				e.queue_free()
		manager._active_enemies.clear()
	_player = get_tree().get_first_node_in_group("player")
	var tcs := get_tree().get_nodes_in_group(TouchControls.GROUP)
	_check(_player != null and tcs.size() == 1, "[%s] the run has its player and one touch layer" % cls)
	if _player == null or tcs.size() != 1:
		return
	var tc: TouchControls = tcs[0]
	tc.view_override = Vector2(1602, 720)
	tc.layout_override_insets = Vector4.ZERO
	tc.dpi_override = 480.0
	tc.screen_override = Vector2(2992, 1344)
	tc.now_override_ms = -1   # real time
	tc._relayout()
	_check(tc.is_twin(), "[%s] twin-stick (default)" % cls)
	get_tree().node_renamed.connect(_on_child)
	var c: Vector2 = (tc.buttons["attack"] as TouchButton).center
	await _wait(0.5)

	# THE RAPID ATTACK DOES NOT EXIST: no ability, charge, hold state, timers or bar on the player; no ring on the button.
	for gone in ["rapid_attack_charge_time", "rapid_attack_duration", "rapid_attack_cooldown", "rapid_attack_attack_rate",
			"_rapid_attack_charge", "_rapid_attack_active", "_rapid_attack_timer", "_rapid_attack_cooldown_remain",
			"_rapid_attack_attack_timer", "_rapid_attack_bar_label", "_attack_held"]:
		_check(not (gone in _player), "[%s] the player has no '%s'" % [cls, gone])
	for gone_method in ["_start_rapid_attack", "_end_rapid_attack", "_start_mage_rapid_attack", "_end_mage_rapid_attack",
			"_fire_rapid_attack_bolts", "_refresh_rapid_attack_bar"]:
		_check(not _player.has_method(gone_method), "[%s] the player has no %s()" % [cls, gone_method])
	var vitals = _player.get("_vitals")
	_check(vitals != null and not ("ability_bar" in vitals) and not vitals.has_method("set_ability"), "[%s] the HUD has health only: no ability bar" % cls)
	_check(not ("charge" in tc.buttons["attack"]), "[%s] the ATTACK button has no charge ring" % cls)

	# TAP: one attack (one bolt for the Mage)
	_reset_attacks()
	_touch(0, c, true)
	await _wait(0.06)
	_touch(0, c, false)
	await _wait(1.6)
	_check(_presses() == 1, "[%s] a tap sends one attack press (%d)" % [cls, _presses()])
	_check(_swings == 1, "[%s] a tap is exactly one attack (%d)" % [cls, _swings])
	if cls == "mage":
		_check(_bolts == 1, "[mage] a tap fires exactly one bolt (%d)" % _bolts)

	# HOLD 3.5 s without dragging, then lift: one attack, never a repeat, not after the lift either
	_reset_attacks()
	_touch(0, c, true)
	await _wait(3.5)
	_check(_presses() == 1, "[%s] holding 3.5 s: still exactly one attack press (%d)" % [cls, _presses()])
	_check(_swings == 1, "[%s] holding 3.5 s: exactly one attack (%d)" % [cls, _swings])
	if cls == "mage":
		_check(_bolts == 1, "[mage] holding 3.5 s: exactly one bolt (%d)" % _bolts)
	_touch(0, c, false)
	await _wait(3.0)
	_check(_presses() == 1 and _swings == 1, "[%s] ...and nothing fires after the finger leaves (presses %d, attacks %d)" % [cls, _presses(), _swings])
	if cls == "mage":
		_check(_bolts == 1, "[mage] no bolt after the lift (%d)" % _bolts)

	# DRAG (look) for 4 s, then lift: no attack at any time, and the camera really turned
	_reset_attacks()
	var yaw0: float = _player.rotation.y
	_touch(0, c, true)
	_drag(0, c + Vector2(60, 0))
	await _wait(4.0)
	_check(absf(_player.rotation.y - yaw0) > 0.3, "[%s] the look drag turns the real player (%.2f rad)" % [cls, _player.rotation.y - yaw0])
	_check(_presses() == 0 and _swings == 0, "[%s] 4 s of looking: zero attacks" % cls)
	if cls == "mage":
		_check(_bolts == 0, "[mage] 4 s of looking fires no bolt (%d)" % _bolts)
	_drag(0, c)   # back to the centre: still look
	await _wait(1.0)
	_touch(0, c, false)
	await _wait(3.0)
	_check(_presses() == 0 and _swings == 0, "[%s] drag back to the centre and lift: still zero attacks" % cls)
	if cls == "mage":
		_check(_bolts == 0, "[mage] no bolt after the look gesture (%d)" % _bolts)

	# DESKTOP / CONTROLLER: the attack action held for 4 s (a mouse button or trigger that is kept down) is one attack too.
	_reset_attacks()
	_attack_action(true)
	await _wait(4.0)
	_attack_action(false)
	await _wait(1.5)
	_check(_swings == 1, "[%s] the attack action held 4 s is exactly one attack (%d)" % [cls, _swings])
	if cls == "mage":
		_check(_bolts == 1, "[mage] the attack action held 4 s fires exactly one bolt (%d)" % _bolts)

	# CLASSIC, hold across an interruption: hold, pause / background (the release is delivered into a paused tree), come
	# back: nothing fired in between and the next plain tap is exactly one attack.
	_reset_attacks()
	SettingsManager.gameplay_settings[TouchControls.KEY_SCHEME] = TouchControls.SCHEME_CLASSIC
	tc.set_scheme(TouchControls.SCHEME_CLASSIC)
	await _wait(0.3)
	var cc: Vector2 = (tc.buttons["attack"] as TouchButton).center
	_touch(0, cc, true)
	await _wait(3.0)
	_check(_swings == 1, "[%s] (Classic) holding 3 s is exactly one attack (%d)" % [cls, _swings])
	if cls == "mage":
		_check(_bolts == 1, "[mage] (Classic) holding 3 s fires exactly one bolt (%d)" % _bolts)
	get_tree().paused = true   # the pause menu / the phone going to the background
	await _wait(0.3)
	_touch(0, cc, false)
	get_tree().paused = false
	await _wait(1.5)
	_check(_swings == 1, "[%s] (Classic) the interrupted hold started nothing (%d attacks)" % [cls, _swings])
	_touch(0, cc, true)
	await _wait(0.12)
	_touch(0, cc, false)
	await _wait(2.0)
	_check(_swings == 2, "[%s] (Classic) the next plain tap is exactly one more attack (%d attacks in all)" % [cls, _swings])
	if cls == "mage":
		_check(_bolts == 2, "[mage] (Classic) the tap fired exactly one more bolt (%d bolts in all)" % _bolts)
	_check(tc.attack_failsafe_releases == 0, "[%s] no fail-safe release was needed in the whole run (%d)" % [cls, tc.attack_failsafe_releases])
	SettingsManager.gameplay_settings[TouchControls.KEY_SCHEME] = TouchControls.SCHEME_TWIN
	tc.set_scheme(TouchControls.SCHEME_TWIN)
	tc.release_all()
