# ==============================================================================
# File Name: aim_pacing_probe.gd
# Path: res://tools/aim_pacing_probe.gd
#
# Dev tool (not shipped, not a test): measures how evenly the Attack-drag aim turns the REAL Barbarian in the REAL
# engine loop (real physics catch-up, real input flush) under scripted frame pacing. A pacer node that runs last in
# every frame sleeps to a scripted frame duration (steady 60 / 30 / 20 fps, or 16 ms frames with periodic 150 ms
# spikes like the Pixel's 1%-low frames), while a finger holds the same drag on ATTACK. Every rendered frame it
# samples the player's rotation.y (what the camera shows) against wall-clock time and reports, per scenario:
#   rate     mean turn rate between 1 s and the end (deg/s): the same finger must give the same rate at any fps
#   cv100    std / mean of the yaw change per 100 ms bin (0 = perfectly even)
#   maxjump  largest single-frame change (deg), and the same relative to the expected rate x frame time
#   still    share of rendered frames in which the camera did not move at all (hesitation)
#   lat      wall-clock ms from touch-down to the first visible motion
#   stop     deg turned in the 0.5 s after the finger lifts (must be ~0: no coasting)
# Run (no renderer needed):
#   PURGATORY_FORCE_TOUCH=1 PURGATORY_SAVE_ROOT=/tmp/pp nice -n 19 godot --headless --path . res://tools/aim_pacing_probe.tscn
# Env: PROBE_SECONDS (default 4), PROBE_SMOOTH (Aim Smoothing percent, default 60).
# The numbers depend on this machine's speed (the scene itself costs a few ms per frame), so compare runs side by side.
# ==============================================================================
extends Node

const MAIN_SCENE := "res://scenes/Purgatory_Dungeon_main_game_file.tscn"
# [name, base frame ms, spike ms, spike every N frames]
const SCENARIOS: Array = [
	["steady 60 fps", 16.7, 0.0, 0],
	["steady 41 fps", 24.4, 0.0, 0],
	["steady 30 fps", 33.3, 0.0, 0],
	["steady 21 fps", 47.6, 0.0, 0],
	["spiky: 16 ms + 150 ms every 10th", 16.0, 150.0, 10],
	["spiky: 30 ms + 190 ms every 8th", 30.0, 190.0, 8],
]
const DEFLECTION := 0.6   # the held drag, as a fraction of AIM_DRAG_RADIUS (after the settle zone)

var _player: Node3D = null
var _tc: TouchControls = null
var _pacer: Node = null
var _results: Array = []


class Pacer extends Node:
	var owner_probe: Node
	func _process(_d: float) -> void:
		owner_probe.call("_tick")


func _ready() -> void:
	SaveManager.load_slot(0)
	SaveManager.create_initial_identity("PacingProbe", "barbarian")
	GlobalRunData.character_class = "barbarian"
	add_child((load(MAIN_SCENE) as PackedScene).instantiate())
	for i in 150:
		await get_tree().physics_frame
	_player = get_tree().get_first_node_in_group("player") as Node3D
	_tc = get_tree().get_first_node_in_group(TouchControls.GROUP) as TouchControls
	if _player == null or _tc == null:
		printerr("probe: no player or touch layer")
		get_tree().quit(1)
		return
	_tc.view_override = Vector2(1602, 720)
	_tc.layout_override_insets = Vector4.ZERO
	_tc.dpi_override = 480.0
	_tc.screen_override = Vector2(2992, 1344)
	_tc._relayout()
	var sm: String = OS.get_environment("PROBE_SMOOTH")
	SettingsManager.gameplay_settings[TouchControls.KEY_AIM_SMOOTH] = float(sm) if sm != "" else 60.0
	_tc._apply_settings()
	_pacer = Pacer.new()
	(_pacer as Pacer).owner_probe = self
	_pacer.process_priority = 100000   # last in the frame: the sample is what the frame renders
	add_child(_pacer)
	_start_scenario(0)


var _idx: int = 0
var _phase: String = "idle"          # idle | settle | hold | tail
var _frame: int = 0
var _last_end_us: int = 0
var _t0_us: int = 0
var _release_us: int = 0
var _samples: Array = []             # [t_us, yaw]
var _yaw0: float = 0.0
var _unw: float = 0.0                # unwrapped yaw (rotation.y wraps at +-pi)
var _prev_raw: float = 0.0
var _hold_s: float = 4.0


func _start_scenario(i: int) -> void:
	_idx = i
	_phase = "settle"
	_frame = 0
	_samples.clear()
	_hold_s = float(OS.get_environment("PROBE_SECONDS")) if OS.get_environment("PROBE_SECONDS") != "" else 4.0
	_tc.release_all()


func _unwrapped() -> float:
	var raw: float = _player.rotation.y
	_unw += angle_difference(_prev_raw, raw)
	_prev_raw = raw
	return _unw


func _tick() -> void:
	var sc: Array = SCENARIOS[_idx]
	var yaw_now: float = _unwrapped()
	_frame += 1
	var now: int = Time.get_ticks_usec()
	match _phase:
		"settle":
			if _frame > 30:
				var atk: TouchButton = _tc.buttons["attack"]
				_tc._touch_down(1, atk.center)
				_tc._touch_move(1, atk.center + Vector2(TouchControls.AIM_SETTLE_PX + TouchControls.AIM_DRAG_RADIUS * DEFLECTION, 0), Vector2.ZERO)
				_phase = "hold"
				_t0_us = now
				_yaw0 = yaw_now
				_samples.clear()
		"hold":
			_samples.append([now, yaw_now])
			if now - _t0_us >= int(_hold_s * 1e6):
				_tc._touch_up(1)
				_release_us = now
				_phase = "tail"
		"tail":
			_samples.append([now, yaw_now])
			if now - _release_us >= 500000:
				_report(sc)
				_phase = "idle"
				if _idx + 1 < SCENARIOS.size():
					_start_scenario(_idx + 1)
				else:
					_finish()
				return
	# pacing: sleep so this frame lasts the scripted time (plus a spike every N frames)
	var target_ms: float = float(sc[1])
	if int(sc[3]) > 0 and _frame % int(sc[3]) == 0:
		target_ms += float(sc[2])
	var elapsed_us: int = Time.get_ticks_usec() - _last_end_us
	var remain: int = int(target_ms * 1000.0) - elapsed_us
	if remain > 0:
		OS.delay_usec(remain)
	_last_end_us = Time.get_ticks_usec()


func _yaw_at(t_us: int) -> float:
	var y: float = _yaw0
	for s in _samples:
		if int(s[0]) > t_us:
			break
		y = float(s[1])
	return y


func _report(sc: Array) -> void:
	var hold: Array = []
	for s in _samples:
		if int(s[0]) <= _release_us:
			hold.append(s)
	var n: int = hold.size()
	var deg: float = 180.0 / PI
	# steady rate between 1 s and the end of the hold
	var t_a: int = _t0_us + 1000000
	var yaw_a: float = _yaw_at(t_a)
	var yaw_b: float = _yaw_at(_release_us)
	var rate: float = absf(yaw_b - yaw_a) / ((_release_us - t_a) / 1e6) * deg
	# per 100 ms bins
	var deltas: Array = []
	var t: int = t_a
	while t + 100000 <= _release_us:
		deltas.append(absf(_yaw_at(t + 100000) - _yaw_at(t)) * deg)
		t += 100000
	var mean: float = 0.0
	for d in deltas:
		mean += d
	mean /= maxf(float(deltas.size()), 1.0)
	var varr: float = 0.0
	for d in deltas:
		varr += (d - mean) * (d - mean)
	var sd: float = sqrt(varr / maxf(float(deltas.size()), 1.0))
	# per-frame jumps and hesitations (frames after 1 s)
	var max_jump: float = 0.0
	var max_rel: float = 0.0
	var still: int = 0
	var counted: int = 0
	for i in range(1, n):
		if int(hold[i][0]) < t_a:
			continue
		var dy: float = absf(float(hold[i][1]) - float(hold[i - 1][1])) * deg
		var dt: float = float(int(hold[i][0]) - int(hold[i - 1][0])) / 1e6
		counted += 1
		if dy < 0.0005:
			still += 1
		max_jump = maxf(max_jump, dy)
		max_rel = maxf(max_rel, dy / maxf(rate * dt, 0.0001))
	var lat: float = -1.0
	for s in hold:
		if absf(float(s[1]) - _yaw0) > 0.001:
			lat = float(int(s[0]) - _t0_us) / 1000.0
			break
	var stop_deg: float = 0.0
	var y_rel: float = _yaw_at(_release_us)
	if _samples.size() > 0:
		stop_deg = absf(float(_samples[_samples.size() - 1][1]) - y_rel) * deg
	_results.append([sc[0], rate, sd / maxf(mean, 0.0001), max_jump, max_rel, float(still) / maxf(float(counted), 1.0), lat, stop_deg, n])


func _finish() -> void:
	print("")
	print("aim_pacing_probe: smoothing %.0f%%, drag %.2f of the radius, hold %.1f s" % [_tc.aim_smoothing * 100.0, DEFLECTION, _hold_s])
	print("%-36s %9s %7s %9s %8s %7s %8s %7s %6s" % ["scenario", "rate d/s", "cv100", "maxjump", "x expect", "still", "lat ms", "stop d", "frames"])
	for r in _results:
		print("%-36s %9.1f %7.2f %9.2f %8.2f %6.0f%% %8.0f %7.2f %6d" % [r[0], r[1], r[2], r[3], r[4], float(r[5]) * 100.0, r[6], r[7], r[8]])
	get_tree().quit(0)
