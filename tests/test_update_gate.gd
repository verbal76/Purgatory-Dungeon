extends Node
## Automatic update at cold launch (scripts/update_gate.gd), driven through a stand-in for the native client's PUBLIC API
## (check_now / update_state / status_snapshot). The native client itself (verification, rollback, runtime compatibility, ...)
## is unchanged and proven by test_ota_core / test_about / tests/ota_e2e.py; here we prove the game-layer behaviour:
## the check starts at once, the hand-off is bounded, failures fall into the installed game, a found update is announced and
## applied with ONE restart, and a restart can never loop.

const Gate = preload("res://scripts/update_gate.gd")

var _fails: int = 0
var _checks: int = 0
var _fake_t: float = 0.0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


## A stand-in client: scripted outcome of check_now() after `delay` fake seconds.
class FakeBoot extends Node:
	var ota_enabled := true
	var state := "unchecked"
	var steps: Array = []            # [fake seconds from the start, state] the client moves through
	var final_result := "up_to_date"
	var staged_id := ""
	var staged_version := ""
	var clock: Callable
	var calls := 0
	func check_now() -> String:
		calls += 1
		var t0: float = clock.call()
		state = "checking"
		for st in steps:
			while float(clock.call()) - t0 < float(st[0]):
				await get_tree().process_frame
			state = str(st[1])
		if final_result == "pending_restart":
			state = "pending_restart"
		return state
	func update_state() -> String:
		return state
	func status_snapshot() -> Dictionary:
		return {"state": state, "staged_ota_id": staged_id, "staged_version": staged_version}


func _process(delta: float) -> void:
	_fake_t += delta * 4.0   # fake seconds run 4x faster than real ones: the 30 s cap takes 7.5 s


func _clock() -> float:
	return _fake_t


func _gate(boot: FakeBoot, marker: String) -> Node:
	var g: Node = Gate.new()
	g.clock_fn = Callable(self, "_clock")
	g.marker_path = marker
	add_child(g)
	boot.clock = Callable(self, "_clock")
	add_child(boot)
	return g


func _ready() -> void:
	var dir: String = OS.get_environment("PURGATORY_SAVE_ROOT")
	var marker: String = (dir if dir != "" else "user://") + "/gate_test_marker.json"
	DirAccess.make_dir_recursive_absolute(marker.get_base_dir())
	if FileAccess.file_exists(marker):
		DirAccess.remove_absolute(marker)

	# 0. no client (desktop / OTA off): nothing starts, the splash is untouched
	var g0: Node = Gate.new()
	add_child(g0)
	_check(g0.start(null) == false and not g0.started, "without a running OTA client the gate does nothing (desktop / OTA off)")
	var off := FakeBoot.new()
	off.ota_enabled = false
	_check(g0.start(off) == false, "a client that is switched off is not driven")
	await g0.settle(self)
	_check(g0.caption_text == "", "...and settle returns at once with nothing shown")

	# 1. no update
	var b1 := FakeBoot.new()
	b1.steps = [[0.2, "up_to_date"]]
	b1.final_result = "up_to_date"
	var g1: Node = _gate(b1, marker)
	_check(g1.start(b1) and b1.calls == 1, "the check starts at once, through the client's own check_now (%d call)" % b1.calls)
	var t: float = _fake_t
	await g1.settle(self)
	_check(g1.check_finished and g1.check_result == "up_to_date", "no update: the check finished up to date")
	_check(g1.caption_text == "" and not g1.restart_issued, "no update: nothing is shown and nothing restarts")
	_check(_fake_t - t < Gate.CHECK_WAIT_SECONDS, "no update: start-up carries on within the cap (%.2f fake s)" % (_fake_t - t))
	g1.queue_free()
	b1.queue_free()

	# 2/3. failures fall into the installed game without a message or a restart
	for outcome in ["offline", "failed", "incompatible", "rejected"]:
		var b2 := FakeBoot.new()
		b2.steps = [[0.3, outcome]]
		b2.final_result = outcome
		var g2: Node = _gate(b2, marker)
		g2.start(b2)
		await g2.settle(self)
		_check(not g2.restart_issued and g2.caption_text == "", "%s: the installed game starts normally, nothing is shown, no restart" % outcome)
		g2.queue_free()
		b2.queue_free()

	# 4. a stalled check does not hold the player past the cap (and keeps running behind the menu)
	var b3 := FakeBoot.new()
	b3.steps = [[1000.0, "offline"]]
	var g3: Node = _gate(b3, marker)
	g3.start(b3)
	t = _fake_t
	await g3.settle(self)
	_check(_fake_t - t <= Gate.CHECK_WAIT_SECONDS + 1.0 and not g3.check_finished and not g3.restart_issued, "a stalled check releases start-up after about %.0f s (%.2f fake s)" % [Gate.CHECK_WAIT_SECONDS, _fake_t - t])
	g3.queue_free()
	b3.queue_free()

	# 5. an update is found, downloaded, verified and staged: announced, then ONE restart for it
	var restarts: Array = []
	var b4 := FakeBoot.new()
	b4.steps = [[0.5, "downloading"], [2.0, "pending_restart"]]
	b4.final_result = "pending_restart"
	b4.staged_id = "dev-000099"
	b4.staged_version = "8.3"
	var g4: Node = _gate(b4, marker)
	g4.restart_fn = func() -> void: restarts.append(1)
	var seen: Array = []
	g4.start(b4)
	var task := _watch_captions(g4, seen)
	t = _fake_t
	await g4.settle(self)
	task = null
	_check(seen.has("Downloading update..."), "an update was found: the player is told it is downloading (%s)" % [seen])
	var applied := false
	for s in seen:
		if str(s).begins_with("Applying update v8.3"):
			applied = true
	_check(applied, "verified and staged: the player is told it is being applied (v8.3)")
	_check(restarts.size() == 1 and g4.restart_issued, "...and the app restarts exactly once")
	_check(FileAccess.file_exists(marker) and str(JSON.parse_string(FileAccess.get_file_as_string(marker)).get("restarted_for", "")) == "dev-000099", "...remembering which update it restarted for")
	g4.queue_free()

	# 6. loop guard: the same update is still staged after the restart (the mount was refused): no second restart
	var b5 := FakeBoot.new()
	b5.steps = [[0.2, "pending_restart"]]
	b5.final_result = "pending_restart"
	b5.staged_id = "dev-000099"
	b5.staged_version = "8.3"
	var g5: Node = _gate(b5, marker)
	var restarts2: Array = []
	g5.restart_fn = func() -> void: restarts2.append(1)
	g5.start(b5)
	var seen2: Array = []
	var task2 := _watch_captions(g5, seen2)
	await g5.settle(self)
	task2 = null
	_check(restarts2.is_empty() and not g5.restart_issued, "an update that did not take is not restarted for again (no restart loop)")
	_check(seen2.size() > 0 and str(seen2[0]).begins_with("Update ready"), "...the player is told it is ready and to restart Purgatory (%s)" % [seen2])
	g5.queue_free()
	b5.queue_free()

	# 7. a different, newer update after that one gets its own restart; and 'up to date' clears the marker
	var b6 := FakeBoot.new()
	b6.steps = [[0.2, "pending_restart"]]
	b6.final_result = "pending_restart"
	b6.staged_id = "dev-000100"
	b6.staged_version = "8.4"
	var g6: Node = _gate(b6, marker)
	var restarts3: Array = []
	g6.restart_fn = func() -> void: restarts3.append(1)
	g6.start(b6)
	await g6.settle(self)
	_check(restarts3.size() == 1, "a newer update gets its own restart")
	g6.queue_free()
	b6.queue_free()
	var b7 := FakeBoot.new()
	b7.steps = [[0.2, "up_to_date"]]
	var g7: Node = _gate(b7, marker)
	g7.start(b7)
	await g7.settle(self)
	_check(not FileAccess.file_exists(marker), "once the game is up to date the restart marker is cleared")
	g7.queue_free()
	b7.queue_free()

	# 8. a download that never finishes is capped
	var b8 := FakeBoot.new()
	b8.steps = [[0.2, "downloading"], [100000.0, "pending_restart"]]
	var g8: Node = _gate(b8, marker)
	g8.start(b8)
	t = _fake_t
	await g8.settle(self)
	_check(_fake_t - t <= Gate.DOWNLOAD_WAIT_SECONDS + Gate.CHECK_WAIT_SECONDS + 2.0 and not g8.restart_issued, "a stalled download releases start-up after the cap (%.1f fake s)" % (_fake_t - t))
	g8.queue_free()
	b8.queue_free()

	# 9. static guarantees: the gate only uses the client's public API and never touches OTA internals
	var src: String = FileAccess.get_file_as_string("res://scripts/update_gate.gd")
	_check(not src.contains(".core") and not src.contains(".updater") and not src.contains("HTTPRequest") and not src.contains("load_resource_pack"), "the gate never touches the OTA store, the updater or the network itself")
	var splash: String = FileAccess.get_file_as_string("res://scripts/studio_splash.gd")
	_check(splash.contains("_start_update_check()") and splash.contains("await update_gate.settle(self)"), "the splash starts the check on a cold launch and hands off through the gate")

	print("test_update_gate: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


## Records every distinct caption the gate shows (polled each frame).
func _watch_captions(g: Node, into: Array) -> Object:
	var w := CaptionWatcher.new()
	w.gate = g
	w.out = into
	add_child(w)
	return w


class CaptionWatcher extends Node:
	var gate: Node
	var out: Array
	func _process(_d: float) -> void:
		if gate != null and is_instance_valid(gate) and gate.caption_text != "" and (out.is_empty() or out[-1] != gate.caption_text):
			out.append(gate.caption_text)
