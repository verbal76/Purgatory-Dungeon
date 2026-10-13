extends Node
## Not a pass/fail test. Profiles the dungeon-entry sequence of the real main scene: phase timeline
## (marks recorded by the main game file and the generator), per-frame times from scene start to
## ENTRY_AFTER frames after the player is handed control, longest main-thread blocks.
## Run: PURGATORY_SAVE_ROOT=$(mktemp -d)/PurgetoryDungeon ENTRY_SEED=7 \
##   godot [--headless] --path . res://tests/entry_profile.tscn
## ENTRY_SEED (default 12345), ENTRY_CLASS (default barbarian), ENTRY_FPS (frame cap, default 60),
## ENTRY_AFTER (frames recorded after hand-over, default 120).

const MAIN_SCENE := "res://scenes/Purgatory_Dungeon_main_game_file.tscn"

var _main: Node = null
var _t0: int = 0
var _last: int = 0
var _frames := PackedFloat32Array()
var _frame_marks := PackedStringArray()
var _frame_end := PackedInt64Array()
var _count: int = 0
var _handover_frame: int = -1
var _after: int = 120
var _loading: Node = null
var _done := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # the loading screen pauses the tree; frames must still be recorded
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	var seed_s := OS.get_environment("ENTRY_SEED")
	GlobalRunData.seed_hash = int(seed_s) if seed_s != "" else 12345
	var cls := OS.get_environment("ENTRY_CLASS")
	GlobalRunData.character_class = cls if cls != "" else "barbarian"
	var fps := OS.get_environment("ENTRY_FPS")
	Engine.max_fps = int(fps) if fps != "" else 60
	var after := OS.get_environment("ENTRY_AFTER")
	_after = int(after) if after != "" else 120
	_frames.resize(40000)
	_frame_marks.resize(40000)
	_frame_end.resize(40000)
	await get_tree().process_frame
	await get_tree().process_frame
	var t_load := Time.get_ticks_usec()
	var packed := load(MAIN_SCENE) as PackedScene
	var t_inst := Time.get_ticks_usec()
	_main = packed.instantiate()
	_main.entry_profiling = true
	var t_add := Time.get_ticks_usec()
	_t0 = t_add
	add_child(_main)
	var t_end := Time.get_ticks_usec()
	print("ENTRY scene load %.1f ms, instantiate %.1f ms, add_child (incl. _ready up to first await) %.1f ms" % [
		(t_inst - t_load) / 1000.0, (t_add - t_inst) / 1000.0, (t_end - t_add) / 1000.0])
	_last = Time.get_ticks_usec()


func _label_now() -> String:
	if _main != null and "entry_marks" in _main and _main.entry_marks.size() > 0:
		return String(_main.entry_marks[_main.entry_marks.size() - 1][0])
	return "boot"


func _process(_d: float) -> void:
	if _main == null or _done:
		return
	var now := Time.get_ticks_usec()
	if _count < _frames.size():
		_frames[_count] = float(now - _last) / 1000.0
		_frame_marks[_count] = _label_now()
		_frame_end[_count] = now
		_count += 1
	_last = now
	if _loading == null:
		_loading = _find_loading()
	if _handover_frame < 0 and _loading != null and bool(_loading.get("is_fading")):
		_handover_frame = _count
		print("ENTRY hand-over (loading screen starts fading) at frame %d, %.0f ms after scene start" % [_count, (now - _t0) / 1000.0])
	if _handover_frame >= 0 and _count >= _handover_frame + _after:
		_done = true
		_report.call_deferred()
	elif _count >= _frames.size() - 1:
		_done = true
		_report.call_deferred()


func _find_loading() -> Node:
	var p := _main.get_node_or_null("Player")
	if p == null:
		return null
	for c in p.get_children():
		if c is CanvasLayer and c.get_script() != null and String(c.get_script().resource_path).ends_with("loading_screen.gd"):
			return c
	return null


func _report() -> void:
	var marks: Array = _main.entry_marks
	print("ENTRY ---- timeline (ms since scene start; delta = main-thread span since previous mark; nodes) ----")
	var prev := _t0
	for m in marks:
		var t: int = m[1]
		print("ENTRY %-24s t=%8.1f  delta=%8.1f  nodes=%d" % [m[0], (t - _t0) / 1000.0, (t - prev) / 1000.0, m[2]])
		prev = t
	var gen: Node = _main.get_node("DungeonGenerationFunction")
	var st: Dictionary = gen.gen_stats
	print("ENTRY generator: total %.1f ms, torch pass %.1f ms, attempts(ms)=%s, instantiated=%d overlap_checks=%d aabb_computed=%d modules=%d rooms=%d spawns=%d waypoints=%d torches=%d" % [
		float(st.get("total_ms", 0.0)), float(st.get("torch_ms", 0.0)), str(st.get("attempt_ms", [])),
		int(st.get("instantiated", 0)), int(st.get("overlap_checks", 0)), int(st.get("aabb_computed", 0)),
		gen.placed_modules.size(), gen.counted_piece_total, gen.registered_typed_spawns.size(),
		gen.registered_waypoints.size(), gen.registered_torches.size()])
	for k in st.keys():
		if String(k).begins_with("ms_"):
			print("ENTRY   gen phase %-28s %8.1f ms" % [k, float(st[k])])
	var lay := ""
	for mm in gen.placed_modules:
		var xf: Transform3D = mm.global_transform
		lay += "%s|%.2f,%.2f,%.2f|%.2f,%.2f;" % [mm.scene_file_path.get_file(), xf.origin.x, xf.origin.y, xf.origin.z, xf.basis.x.x, xf.basis.x.z]
	print("ENTRY layout_hash=%d modules=%d" % [lay.hash(), gen.placed_modules.size()])
	# Cost of one exploration update with nothing explored yet (the worst case, run every 0.5 s).
	for mm in gen.placed_modules:
		mm.set_meta("explored", false)
	var tx := Time.get_ticks_usec()
	for i in 20:
		gen.update_player_exploration()
	print("ENTRY exploration update: %.3f ms per call" % [float(Time.get_ticks_usec() - tx) / 20000.0])
	var total_frames := _count
	var h := maxi(_handover_frame, 0)
	var over33 := 0
	var over100 := 0
	var worst := 0.0
	var worst_i := 0
	var worst_after := 0.0
	var over33_after := 0
	var over100_after := 0
	for i in total_frames:
		var f := _frames[i]
		if f > 33.4:
			over33 += 1
			if i >= h: over33_after += 1
		if f > 100.0:
			over100 += 1
			if i >= h: over100_after += 1
		if f > worst:
			worst = f
			worst_i = i
		if i >= h and f > worst_after:
			worst_after = f
	print("ENTRY frames: total %d, hand-over at %d; >33ms: %d (after hand-over %d); >100ms: %d (after %d); worst %.1f ms at frame %d [%s]; worst after hand-over %.1f ms" % [
		total_frames, _handover_frame, over33, over33_after, over100, over100_after, worst, worst_i, _frame_marks[worst_i], worst_after])
	print("ENTRY ---- frames > 20 ms (index, ms, last mark) ----")
	for i in total_frames:
		if _frames[i] > 20.0:
			var inside := PackedStringArray()
			var t_start: int = _frame_end[i] - int(_frames[i] * 1000.0)
			for m in marks:
				if int(m[1]) > t_start and int(m[1]) <= _frame_end[i]:
					inside.append(String(m[0]))
			print("ENTRY   f%-5d %8.1f ms  [%s]%s  marks in frame: %s" % [i, _frames[i], _frame_marks[i], "  (after hand-over +%d)" % (i - h) if i >= h else "", ",".join(inside)])
	var bodies := 0
	var meshes := 0
	var lights := 0
	var stack: Array = [_main]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is CollisionObject3D: bodies += 1
		if n is MeshInstance3D: meshes += 1
		if n is OmniLight3D: lights += 1
		stack.append_array(n.get_children())
	print("ENTRY final: nodes=%d collision_objects=%d meshes=%d omni_lights=%d enemies=%d" % [
		get_tree().get_node_count(), bodies, meshes, lights, get_tree().get_nodes_in_group("enemy").size()])
	get_tree().quit(0)
