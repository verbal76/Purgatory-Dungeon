extends Node
## The Attack-drag aim must turn the camera evenly whatever the frame pacing. Evidence from the Pixel: 21-41 fps, 1% lows
## of 7-14 fps, worst frames 126-191 ms, and an uneven camera ("hesitates, then catches up"). The cause (measured with
## tools/aim_pacing_probe.gd in the real engine loop): the aim was applied from the 30 Hz physics tick and the players only
## showed the yaw at the next tick, so rendered frames saw 0, 1 or several back-to-back ticks.
##
## This test is a deterministic MODEL of the main loop, driven with explicit frame times and the REAL TouchControls
## (look_step, smoothing, hysteresis) and the real mouse-motion event path. It honestly simulates only the engine loop:
##   legacy  = aim applied per 30 Hz physics tick (catch-up ticks, max 8 per frame), events delivered at the NEXT frame
##             start, the camera showing the yaw as of the last tick
##   current = aim integrated per rendered frame with the real delta (TouchControls._aim_frame), delivered the same frame,
##             the camera showing the yaw at once
## The engine-coupled part is covered by the real Barbarian/Mage checks in test_twin_stick.gd and by the probe tool.
## Needs PURGATORY_FORCE_TOUCH=1 (run_tests.sh sets it).

const TICK := 1.0 / 30.0

var _fails: int = 0
var _checks: int = 0
var _yaw: float = 0.0
var _probe: Node


class Probe extends Node:
	var owner_test: Node
	func _input(event: InputEvent) -> void:
		if event is InputEventMouseMotion and (event as InputEventMouseMotion).device != InputEvent.DEVICE_ID_EMULATION:
			owner_test.set("_yaw", float(owner_test.get("_yaw")) - (event as InputEventMouseMotion).relative.x * 0.0025)


class Counter extends Node:
	var sink: Array
	func _input(event: InputEvent) -> void:
		if event is InputEventMouseMotion and (event as InputEventMouseMotion).device != InputEvent.DEVICE_ID_EMULATION:
			sink[0] += 1


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _flush() -> void:
	Input.flush_buffered_events()


func _new_layer() -> TouchControls:
	var tc := TouchControls.new()
	tc.layout_override_insets = Vector4.ZERO
	tc.view_override = Vector2(1602, 720)
	tc.dpi_override = 480.0
	tc.screen_override = Vector2(2992, 1344)
	add_child(tc)
	return tc


func _hold_drag(tc: TouchControls, v: float) -> void:
	var atk: TouchButton = tc.buttons["attack"]
	tc._touch_down(1, atk.center)
	tc._touch_move(1, atk.center + Vector2(TouchControls.AIM_SETTLE_PX + TouchControls.AIM_DRAG_RADIUS * v, 0), Vector2.ZERO)


## Frame-time sequences (seconds) covering `total` seconds.
func _sequence(kind: String, total: float) -> Array:
	var out: Array = []
	var t: float = 0.0
	var i: int = 0
	while t < total:
		var dt: float = 0.0167
		match kind:
			"60": dt = 1.0 / 60.0
			"41": dt = 1.0 / 41.0
			"30": dt = 1.0 / 30.0
			"21": dt = 1.0 / 21.0
			"spiky16": dt = 0.150 if i % 10 == 9 else 0.016
			"spiky30": dt = 0.190 if i % 8 == 7 else 0.030
			"jitter": dt = [0.012, 0.045, 0.020, 0.090, 0.016, 0.033, 0.126][i % 7]
		out.append(dt)
		t += dt
		i += 1
	return out


## Runs the model; returns the [[t, yaw_shown]] samples. `mode` is "legacy" or "current".
func _run(tc: TouchControls, mode: String, frames: Array) -> Array:
	_yaw = 0.0
	tc._aim_smoothed = Vector2.ZERO
	var samples: Array = []
	var t: float = 0.0
	var acc: float = 0.0
	var shown: float = 0.0
	for dt in frames:
		t += dt
		if mode == "legacy":
			_flush()   # events emitted by the previous frame's ticks reach the player now
			acc += dt
			var steps: int = mini(int(acc / TICK), 8)   # max_physics_steps_per_frame
			acc -= float(steps) * TICK
			for k in steps:
				tc.look_step(TICK)   # what TouchControls._physics_process did
				shown = _yaw          # the player applied rotation.y inside the tick
		else:
			tc._aim_frame(dt)         # the real per-frame path: look_step(real dt) + immediate delivery
			shown = _yaw
		samples.append([t, shown])
	return samples


func _yaw_at(samples: Array, t: float) -> float:
	var y: float = 0.0
	for s in samples:
		if float(s[0]) > t:
			break
		y = float(s[1])
	return y


## Metrics over [1 s, end]: mean rate (deg/s), per-frame max jump relative to rate x frame time, share of still frames.
func _metrics(samples: Array, frames: Array) -> Dictionary:
	var t_end: float = float(samples[samples.size() - 1][0])
	var rate: float = absf(_yaw_at(samples, t_end) - _yaw_at(samples, 1.0)) / (t_end - 1.0) * 180.0 / PI
	var max_rel: float = 0.0
	var still: int = 0
	var counted: int = 0
	var max_jump: float = 0.0
	for i in range(1, samples.size()):
		if float(samples[i][0]) < 1.0:
			continue
		var dy: float = absf(float(samples[i][1]) - float(samples[i - 1][1])) * 180.0 / PI
		counted += 1
		if dy < 0.0005:
			still += 1
		max_jump = maxf(max_jump, dy)
		max_rel = maxf(max_rel, dy / maxf(rate * float(frames[i]), 0.0001))
	return {"rate": rate, "max_rel": max_rel, "still": float(still) / maxf(float(counted), 1.0), "max_jump": max_jump}


func _ready() -> void:
	if OS.get_environment("PURGATORY_FORCE_TOUCH") != "1":
		printerr("FAIL: run with PURGATORY_FORCE_TOUCH=1")
		get_tree().quit(2)
		return
	Input.use_accumulated_input = false
	_probe = Probe.new()
	_probe.owner_test = self
	add_child(_probe)
	await _model_tests()
	await _behaviour_tests()
	print("test_aim_pacing: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _model_tests() -> void:
	var tc: TouchControls = _new_layer()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(not tc.is_physics_processing(), "the aim is no longer driven from the physics tick")
	_check(tc.is_processing(), "the aim is integrated on the rendered frame")
	for smooth in [0.0, 60.0]:
		SettingsManager.gameplay_settings[TouchControls.KEY_AIM_SMOOTH] = smooth
		tc._apply_settings()
		tc.release_all()
		_hold_drag(tc, 0.6)
		var vec_rate: float = TouchControls.look_rates(tc._look_cmd, 1.0).x * 180.0 / PI
		var rates: Array = []
		var tag := "smoothing %.0f%%" % smooth
		for kind in ["60", "41", "30", "21", "spiky16", "spiky30", "jitter"]:
			var frames: Array = _sequence(kind, 6.0)
			var cur: Array = _run(tc, "current", frames)
			var m: Dictionary = _metrics(cur, frames)
			rates.append(m["rate"])
			_check(absf(m["rate"] - vec_rate) < vec_rate * 0.03, "[%s %s] the same finger turns %.1f deg/s (analytic %.1f) within 3%%" % [tag, kind, m["rate"], vec_rate])
			_check(m["still"] == 0.0, "[%s %s] no hesitation frames (%.0f%% still)" % [tag, kind, m["still"] * 100.0])
			_check(m["max_rel"] < 1.2, "[%s %s] every frame turns in proportion to its own duration (max %.2fx rate x frame time)" % [tag, kind, m["max_rel"]])
			var leg: Array = _run(tc, "legacy", frames)
			var ml: Dictionary = _metrics(leg, frames)
			if smooth == 0.0:
				print("  model %-8s current: rate %5.1f d/s still %3.0f%% max %.2fx | legacy: rate %5.1f d/s still %3.0f%% max %.2fx jump %.1f deg" % [kind, m["rate"], m["still"] * 100.0, m["max_rel"], ml["rate"], ml["still"] * 100.0, ml["max_rel"], ml["max_jump"]])
				if kind == "60" or kind == "41":
					_check(ml["still"] > 0.2, "[model] the legacy tick cadence left the camera still in %.0f%% of %s fps frames" % [ml["still"] * 100.0, kind])
				if kind == "spiky16" or kind == "jitter":
					_check(ml["max_rel"] > 1.5 * m["max_rel"], "[model] the legacy catch-up burst was %.1fx proportional vs %.1fx now (%s)" % [ml["max_rel"], m["max_rel"], kind])
				if kind.begins_with("spiky"):
					_check(ml["still"] > 0.05, "[model] the legacy pipeline stood still in %.0f%% of frames under spikes (%s)" % [ml["still"] * 100.0, kind])
		var lo: float = rates.min()
		var hi: float = rates.max()
		_check((hi - lo) / hi < 0.03, "[%s] the turn rate is the same at every fps and under spikes (%.1f-%.1f deg/s)" % [tag, lo, hi])
		tc.release_all()
	# latency: the very first frame after touch-down already turns (smoothing off)
	SettingsManager.gameplay_settings[TouchControls.KEY_AIM_SMOOTH] = 0.0
	tc._apply_settings()
	tc.release_all()
	_yaw = 0.0
	_hold_drag(tc, 0.6)
	tc._aim_frame(0.016)
	_check(absf(_yaw) > 0.0, "the first frame after the drag turns at once (no extra frame of latency)")
	tc.release_all()
	tc.queue_free()
	await get_tree().process_frame


func _behaviour_tests() -> void:
	var tc: TouchControls = _new_layer()
	await get_tree().process_frame
	SettingsManager.gameplay_settings[TouchControls.KEY_AIM_SMOOTH] = 60.0
	tc._apply_settings()
	# bounded burst: one frame never turns more than rate x LOOK_MAX_STEP, however long it was
	_hold_drag(tc, 1.2)
	for i in 8:
		tc._aim_frame(0.016)
	_yaw = 0.0
	tc._aim_frame(5.0)
	var full_rate: float = TouchControls.LOOK_MAX_YAW_RATE * tc.look_gain
	_check(absf(_yaw) <= full_rate * TouchControls.LOOK_MAX_STEP + 0.0001, "a 5 s frame (pause / resume) turns at most rate x %.2f s (%.3f rad)" % [TouchControls.LOOK_MAX_STEP, absf(_yaw)])
	# release / cancel / background / release_all / disable: zero immediately, nothing more turns
	for how in ["release", "cancel", "background", "release_all", "disable"]:
		tc.release_all()
		_yaw = 0.0
		_hold_drag(tc, 1.0)
		for i in 6:
			tc._aim_frame(0.016)
		_check(absf(_yaw) > 0.0, "[%s] turning before" % how)
		match how:
			"release": tc._touch_up(1)
			"cancel":
				var c := InputEventScreenTouch.new()
				c.index = 1
				c.pressed = false
				c.canceled = true
				Input.parse_input_event(c)
				_flush()
			"background": tc.notification(NOTIFICATION_APPLICATION_PAUSED)
			"release_all": tc.release_all()
			_: tc.set_enabled(false)
		_yaw = 0.0
		tc._aim_frame(0.016)
		tc._aim_frame(0.2)
		_check(_yaw == 0.0 and tc._aim_smoothed == Vector2.ZERO, "[%s] nothing turns after it, in this or later frames" % how)
		tc.set_enabled(true)
	# pause / resume: no motion while paused, and no jump on the first frames back
	tc.release_all()
	_hold_drag(tc, 1.0)
	_yaw = 0.0
	get_tree().paused = true
	for i in 6:
		await get_tree().process_frame
	_check(_yaw == 0.0 and tc._look_cmd == Vector2.ZERO, "pausing releases the drag: nothing turned while paused")
	get_tree().paused = false
	for i in 4:
		await get_tree().process_frame
	_check(_yaw == 0.0, "the first frames after resume do not jump the camera")
	# the real _process path: at most one motion event per rendered frame, delivered at once
	tc.release_all()
	_hold_drag(tc, 0.8)
	_yaw = 0.0
	var events: Array = [0]
	var counter := Counter.new()
	counter.sink = events
	add_child(counter)
	for i in 20:
		await get_tree().process_frame
	_check(events[0] > 0 and events[0] <= 21, "the live layer sent one look event per rendered frame (%d in 20 frames)" % events[0])
	_check(absf(_yaw) > 0.05, "...and the camera turned (%.3f rad)" % _yaw)
	tc.release_all()
	# The ATTACK gesture classification (tap / hold = one attack, drag = look) must cost the camera nothing: the drag that
	# leaves the slop circle is a look gesture on the very event, the camera turns in the first rendered frame after it
	# (no hold-intent wait, no extra frame), and the whole drag attacks zero times, however long it lasts.
	SettingsManager.gameplay_settings[TouchControls.KEY_AIM_SMOOTH] = 0.0
	tc._apply_settings()
	var pulses0: int = tc.attack_pulses
	var atk: TouchButton = tc.buttons["attack"]
	_yaw = 0.0
	tc._touch_down(1, atk.center)
	tc._touch_move(1, atk.center + Vector2(TouchControls.AIM_SETTLE_PX + TouchControls.AIM_DRAG_RADIUS * 0.5, 0), Vector2.ZERO)
	_check(tc._atk_gesture == TouchControls.Gesture.LOOK, "the drag is a look gesture on its first event (classification adds no wait)")
	await get_tree().process_frame
	_check(absf(_yaw) > 0.0, "...and the camera turned in the first frame after the drag event (%.5f rad)" % _yaw)
	for i in 40:
		await get_tree().process_frame
	await get_tree().create_timer(0.4).timeout   # well past ATTACK_INTENT_MS in real time
	_check(tc.attack_pulses == pulses0 and not Input.is_action_pressed("attack"), "...and a long drag attacks zero times")
	tc.release_all()
	counter.queue_free()
	tc.queue_free()
