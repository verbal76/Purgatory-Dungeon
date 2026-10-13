extends Node
## Frame-time ATTRIBUTION probe (not a pass/fail test, not part of run_tests.sh).
##
## Boots the REAL main game scene (enemies on, real player scripts running, touch layer when
## PURGATORY_FORCE_TOUCH=1), walks the player along a scripted path through the level for N seconds and
## attributes the frame time to systems: every `_process` / `_physics_process` of every game script (plus a
## list of named periodic functions) is wrapped at load time by a timing shim, so the table shows
## mean / p95 / max milliseconds PER FRAME for each script. Nothing about the game changes: the wrapper
## only reads the clock before and after the original function (a few hundred nanoseconds per call).
##
## What is NOT in the script table (printed as "engine / unattributed"): the engine's own per-frame work
## (animation mixers, skeleton updates, physics step, timers, signals, deferred calls, canvas updates, and
## on a renderer: culling + draw submission). The `proc` / `phys` columns are Godot's own monitors.
##
## Usage (CPU-side numbers are meaningful headless, A/B them under the same load, several repetitions):
##   PURGATORY_SAVE_ROOT=$(mktemp -d)/PurgetoryDungeon PURGATORY_FORCE_TOUCH=1 \
##     godot --headless --path . res://tests/perf_attribution.tscn
## With a software renderer (relative numbers only; countable metrics draws/objects/prims are exact):
##   xvfb-run -a -s "-screen 0 1600x720x24" godot --rendering-driver vulkan --rendering-method mobile \
##     --resolution 1600x720 --path . res://tests/perf_attribution.tscn
##
## Environment (all optional):
##   PERF_SEED=12345          generation seed
##   PERF_ATTR_SECONDS=25     measured walk length (wall seconds)
##   PERF_ATTR_WARM=3         seconds of the walk discarded as warm-up
##   PERF_ATTR_FPS=60         engine frame cap while measuring (0 = uncapped; a phone runs 30-60)
##   PERF_ATTR_MAGE=0         1 = Mage instead of Barbarian
##   PERF_ATTR_RUNS=20        profile run count (the enemy population cap grows with it; full cap from run 15)
##   PERF_ATTR_WRAP=1         0 = no timing shim (frame-time distribution only, for the shim-overhead check)
##   PERF_OUT=path            also write the JSON summary to this file
## The last output line starts with ATTRJSON and holds everything as JSON.

const MAIN_SCENE := "res://scenes/Purgatory_Dungeon_main_game_file.tscn"
const SCRIPT_ROOTS: Array[String] = ["res://scripts", "res://autoloads", "res://characters", "res://objects"]
const SKIP_PREFIXES: Array[String] = ["res://scripts/boot"]
## Named non-coroutine functions that run periodically or on events (timed inclusively, nested inside the
## process callbacks above; they are NOT added to the per-frame total).
const EXTRA_FUNCS := {
	"res://scripts/enemy_manager.gd": ["_top_up_population", "_run_cull_sweep", "_check_pressure_spawn", "_check_difficulty_escalation",
		"_spawn_enemy_from_data", "force_spawn_at", "_refresh_active_zone", "_snap_to_floor", "_player_can_see_spawn", "_count_enemies_near"],
	"res://scripts/module_visibility.gd": ["refresh"],
	"res://scripts/torch_light_budget.gd": ["refresh", "_step_fades"],
	"res://scripts/dungeon_generation_function.gd": ["update_player_exploration"],
	"res://characters/brute/scripts/brute_ai.gd": ["_physics_tick", "_update_los", "_update_nav_target", "_find_wall_safe_direction", "reset_for_pool", "_on_ready"],
	"res://characters/Lutsch Mage/scripts/mage_ai.gd": ["_physics_tick", "reset_for_pool", "_on_ready"],
	"res://characters/brute/scripts/character_base.gd": ["_change_state", "_play_anim"],
}

var _main: Node = null
var _gen: Node = null
var _player: Node3D = null
var _cam: Camera3D = null
var _headless: bool = false

# timing sink ------------------------------------------------------------------------------------------
var _acc: Dictionary = {}          # key -> microseconds accumulated since the last flush
var _calls: Dictionary = {}        # key -> call count (whole run)
const MAX_KEYS: int = 128
var _key_index: Dictionary = {}    # key -> column
var _flat := PackedFloat32Array()  # MAX_KEYS columns of _max_frames (ms per frame); one flat array: packed arrays are value types
var _frame: int = 0
var _max_frames: int = 0
var _recording: bool = false
var _wrapped: Array[String] = []
var _skipped: Array[String] = []

# per-frame series ---------------------------------------------------------------------------------------
var _ft := PackedFloat32Array()
var _proc := PackedFloat32Array()
var _phys := PackedFloat32Array()
var _dnodes := PackedInt32Array()
var _dmem := PackedFloat32Array()
var _enemies := PackedInt32Array()
var _ticks := PackedInt32Array()
var _draws := PackedInt32Array()
var _pipes := PackedInt32Array()   # pipeline compilations (all kinds) since the previous frame, from the rendering monitors
var _last_pipes: int = 0
var _tstamp := PackedFloat32Array()
var _last_us: int = 0
var _last_nodes: int = 0
var _last_mem: float = 0.0
var _last_pf: int = 0


func _env_i(key: String, d: int) -> int:
	var v := OS.get_environment(key)
	return int(v) if v != "" else d


## Called by the shim of every wrapped function.
func rec(key: StringName, us: int) -> void:
	_acc[key] = int(_acc.get(key, 0)) + us
	_calls[key] = int(_calls.get(key, 0)) + 1


# ── shim installation ───────────────────────────────────────────────────────────────────────────────────

func _collect_scripts(dir: String, out: Array[String]) -> void:
	for skip in SKIP_PREFIXES:
		if dir.begins_with(skip):
			return
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		_collect_scripts(dir.path_join(sub), out)


static func _split_params(s: String) -> PackedStringArray:
	var out := PackedStringArray()
	var depth := 0
	var cur := ""
	for ch in s:
		if ch == "(" or ch == "[" or ch == "{":
			depth += 1
		elif ch == ")" or ch == "]" or ch == "}":
			depth -= 1
		if ch == "," and depth == 0:
			out.append(cur)
			cur = ""
		else:
			cur += ch
	if cur.strip_edges() != "":
		out.append(cur)
	return out


## Wraps `func NAME(params) -> ret:` (top level, non-coroutine) of `src`; returns the new source or "" when
## the function is absent / not wrappable.
func _wrap_function(src: String, fname: String, key: String) -> String:
	var re := RegEx.new()
	re.compile("(?m)^func\\s+" + fname + "\\s*\\(([^()]*)\\)\\s*(?:->\\s*([A-Za-z_][\\w\\.\\[\\]]*))?\\s*:[ \\t]*(?:#.*)?$")
	var m := re.search(src)
	if m == null:
		return ""
	# body = up to the next top-level line; coroutines (await) would time the waiting too: skip them
	var rest := src.substr(m.get_end())
	var nl := RegEx.new()
	nl.compile("\\n[^\\s#]")
	var nxt := nl.search(rest)
	var body := rest if nxt == null else rest.substr(0, nxt.get_start())
	if body.contains("await ") or body.contains("await("):
		_skipped.append(key + " (coroutine)")
		return ""
	var params := m.get_string(1)
	var ret := m.get_string(2)
	var names := PackedStringArray()
	for p in _split_params(params):
		var nm := p.strip_edges()
		var cut := nm.length()
		for stop in [":", "="]:
			var i := nm.find(stop)
			if i >= 0:
				cut = mini(cut, i)
		names.append(nm.substr(0, cut).strip_edges())
	var orig := "_pa_o_" + fname
	var head := m.get_string(0)
	var renamed := head.replace("func " + fname, "func " + orig)
	# `func  name(` with extra spaces: replace by regex-safe fallback
	if renamed == head:
		return ""
	var call := orig + "(" + ", ".join(names) + ")"
	var wrapper := "\n\nfunc " + fname + "(" + params + ")" + ((" -> " + ret) if ret != "" else "") + ":\n"
	wrapper += "\tvar __t := Time.get_ticks_usec()\n"
	if ret == "void":
		wrapper += "\t" + call + "\n"
		wrapper += "\tEngine.get_meta(&\"perf_sink\").rec(&\"" + key + "\", Time.get_ticks_usec() - __t)\n"
	else:
		wrapper += "\tvar __r = " + call + "\n"
		wrapper += "\tEngine.get_meta(&\"perf_sink\").rec(&\"" + key + "\", Time.get_ticks_usec() - __t)\n"
		wrapper += "\treturn __r\n"
	return src.substr(0, m.get_start()) + renamed + src.substr(m.get_end()) + wrapper


func _install_shims() -> void:
	Engine.set_meta("perf_sink", self)
	var paths: Array[String] = []
	for r in SCRIPT_ROOTS:
		_collect_scripts(r, paths)
	paths.sort()
	for path in paths:
		var scr := load(path) as GDScript
		if scr == null:
			continue
		var orig_src: String = scr.source_code
		if orig_src == "":
			continue
		var names: Array = ["_process", "_physics_process"]
		names.append_array(EXTRA_FUNCS.get(path, []))
		var src := orig_src
		var did: Array[String] = []
		for fname_v in names:
			var fname: String = fname_v
			var key: String = path.get_file() + ":" + fname
			var out: String = _wrap_function(src, fname, key)
			if out != "":
				src = out
				did.append(key)
		if did.is_empty():
			continue
		scr.source_code = src
		var err := scr.reload(true)
		if err != OK:
			scr.source_code = orig_src
			scr.reload(true)
			_skipped.append(path.get_file() + " (reload failed)")
			continue
		_wrapped.append_array(did)


# ── frame loop ──────────────────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	process_priority = -100000   # first thing in every frame: flushes the previous frame's accumulators
	_headless = DisplayServer.get_name() == "headless"
	var seed_value := _env_i("PERF_SEED", 12345)
	GlobalRunData.character_class = "mage" if _env_i("PERF_ATTR_MAGE", 0) == 1 else "barbarian"
	GlobalRunData.seed_hash = seed_value
	GlobalRunData.difficulty = "medium"
	# a veteran save: the enemy population cap grows with the run count (full cap from run 15)
	if SaveManager.current_profile is Dictionary:
		SaveManager.current_profile["run_count"] = _env_i("PERF_ATTR_RUNS", 20)
	if _env_i("PERF_ATTR_WRAP", 1) == 1:
		_install_shims()
	var t0 := Time.get_ticks_msec()
	_main = (load(MAIN_SCENE) as PackedScene).instantiate()
	add_child(_main)
	_gen = _main.get_node("DungeonGenerationFunction")
	# same layout every run: the main script seeds in _ready and generates two frames later
	var reseed := true
	var guard := 0
	while guard < 4000:
		await get_tree().process_frame
		guard += 1
		if reseed and _gen.placed_modules.size() == 0:
			seed(seed_value)
		elif _gen.placed_modules.size() > 0:
			reseed = false
		if _main.get_node_or_null("TrapManager") != null and bool(_main.get("entry_is_complete")):
			break
	var boot_ms := Time.get_ticks_msec() - t0
	# let staged population / loading screen settle
	for i in 90:
		await get_tree().process_frame
	_player = _main.get_node_or_null("Player") as Node3D
	_cam = get_viewport().get_camera_3d()
	var report := await _walk(float(_env_i("PERF_ATTR_SECONDS", 25)))
	report["boot_ms"] = boot_ms
	report["renderer"] = "headless" if _headless else str(RenderingServer.get_video_adapter_name())
	report["shims"] = _wrapped.size()
	report["shims_skipped"] = _skipped
	_print(report)
	var json := JSON.stringify(report)
	var out_path := OS.get_environment("PERF_OUT")
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f != null:
			f.store_string(json)
	print("ATTRJSON " + json)
	get_tree().quit(0)


func _process(_delta: float) -> void:
	if not _recording or _frame >= _max_frames:
		return
	var now := Time.get_ticks_usec()
	if _last_us != 0:
		_ft[_frame] = float(now - _last_us) / 1000.0
		_tstamp[_frame] = float(now) / 1.0e6
		for k in _acc:
			if not _key_index.has(k) and _key_index.size() < MAX_KEYS:
				_key_index[k] = _key_index.size()
			if _key_index.has(k):
				_flat[int(_key_index[k]) * _max_frames + _frame] = float(_acc[k]) / 1000.0
		_proc[_frame] = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		_phys[_frame] = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		var nn := get_tree().get_node_count()
		_dnodes[_frame] = nn - _last_nodes
		_last_nodes = nn
		var mm: float = Performance.get_monitor(Performance.MEMORY_STATIC)
		_dmem[_frame] = (mm - _last_mem) / 1024.0
		_last_mem = mm
		_enemies[_frame] = get_tree().get_nodes_in_group("enemy").size() if _frame % 15 == 0 else (_enemies[_frame - 1] if _frame > 0 else 0)
		_ticks[_frame] = Engine.get_physics_frames() - _last_pf
		_last_pf = Engine.get_physics_frames()
		_draws[_frame] = int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		var pt := _pipeline_total()
		_pipes[_frame] = pt - _last_pipes
		_last_pipes = pt
		_frame += 1
	_acc.clear()
	_last_us = now


## Pipeline compilations so far (canvas + mesh + surface + draw + specialization monitors; 0 headless).
func _pipeline_total() -> int:
	var t := 0
	for m in [Performance.PIPELINE_COMPILATIONS_CANVAS, Performance.PIPELINE_COMPILATIONS_MESH, Performance.PIPELINE_COMPILATIONS_SURFACE,
			Performance.PIPELINE_COMPILATIONS_DRAW, Performance.PIPELINE_COMPILATIONS_SPECIALIZATION]:
		t += int(Performance.get_monitor(m))
	return t


func _centres() -> Array:
	var centres: Array = []
	for m in _gen.placed_modules:
		if is_instance_valid(m):
			var a: AABB = _gen.get_module_aabb(m)
			if a.size != Vector3.ZERO:
				centres.append(Vector3(a.get_center().x, (m as Node3D).global_position.y, a.get_center().z))
	var path: Array = []
	var cur: Vector3 = _player.global_position
	while not centres.is_empty() and path.size() < 400:
		var bi := 0
		var bd := INF
		for i in centres.size():
			var dd: float = cur.distance_squared_to(centres[i])
			if dd < bd:
				bd = dd
				bi = i
		cur = centres[bi]
		path.append(cur)
		centres.remove_at(bi)
	return path


func _walk(seconds: float) -> Dictionary:
	if _player == null or _cam == null:
		return {"error": "no player / camera"}
	if "_current_health" in _player:
		_player._current_health = 1.0e9
		_player.max_health = 1.0e9
	var path := _centres()
	Engine.max_fps = _env_i("PERF_ATTR_FPS", 60)
	_max_frames = int(seconds * 400.0) + 64
	_flat.resize(MAX_KEYS * _max_frames)
	_ft.resize(_max_frames)
	_proc.resize(_max_frames)
	_phys.resize(_max_frames)
	_dmem.resize(_max_frames)
	_tstamp.resize(_max_frames)
	_dnodes.resize(_max_frames)
	_enemies.resize(_max_frames)
	_ticks.resize(_max_frames)
	_draws.resize(_max_frames)
	_pipes.resize(_max_frames)
	_last_pipes = _pipeline_total()
	_calls.clear()
	_last_nodes = get_tree().get_node_count()
	_last_mem = Performance.get_monitor(Performance.MEMORY_STATIC)
	_last_pf = Engine.get_physics_frames()
	_last_us = 0
	_recording = true
	var pos: Vector3 = _player.global_position
	var seg := 0
	var t_start := Time.get_ticks_msec()
	var last := Time.get_ticks_usec()
	while float(Time.get_ticks_msec() - t_start) < seconds * 1000.0 and _frame < _max_frames - 1 and seg < path.size():
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var dt := minf(float(now - last) / 1.0e6, 0.1)
		last = now
		var to: Vector3 = path[seg] - pos
		to.y = 0.0
		var step := 5.0 * dt   # 5 m/s: a brisk walk
		if to.length() <= step:
			seg += 1
		else:
			pos += to.normalized() * step
		_player.global_position = pos + Vector3(0, 0.05, 0)
		if "velocity" in _player:
			_player.velocity = Vector3.ZERO
		if to.length() > 0.5:
			var basis_look := Basis.looking_at(to.normalized(), Vector3.UP)
			_cam.global_transform = Transform3D(basis_look, pos + Vector3(0, 1.6, 0))
	_recording = false
	return _summarise(float(Time.get_ticks_msec() - t_start) / 1000.0)


# ── report ──────────────────────────────────────────────────────────────────────────────────────────────

static func _stats(a: PackedFloat32Array, from: int, to: int) -> Dictionary:
	var n := to - from
	if n <= 0:
		return {"mean": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0, "n": 0}
	var s := a.slice(from, to)
	var sum := 0.0
	for v in s:
		sum += v
	s.sort()
	return {"mean": snappedf(sum / n, 0.001), "p50": snappedf(s[n / 2], 0.001), "p95": snappedf(s[mini(int(n * 0.95), n - 1)], 0.001),
		"p99": snappedf(s[mini(int(n * 0.99), n - 1)], 0.001), "max": snappedf(s[n - 1], 0.001), "n": n}


func _col(k: Variant) -> PackedFloat32Array:
	var c: int = _key_index[k]
	return _flat.slice(c * _max_frames, (c + 1) * _max_frames)


func _summarise(seconds: float) -> Dictionary:
	var n := _frame
	var skip := mini(int(float(_env_i("PERF_ATTR_WARM", 3)) * float(n) / maxf(seconds, 1.0)), n / 3)
	var res: Dictionary = {"frames": n, "seconds": snappedf(seconds, 0.1), "warmup_frames_skipped": skip}
	res["frame_ms"] = _stats(_ft, skip, n)
	res["process_monitor_ms"] = _stats(_proc, skip, n)
	res["physics_monitor_ms"] = _stats(_phys, skip, n)
	var rows: Array = []
	var top_sum := PackedFloat32Array()
	top_sum.resize(n)
	for k in _key_index:
		var st := _stats(_col(k), skip, n)
		var top := String(k).ends_with(":_process") or String(k).ends_with(":_physics_process")
		st["key"] = String(k)
		st["top_level"] = top
		st["calls_per_frame"] = snappedf(float(_calls.get(k, 0)) / maxf(float(n), 1.0), 0.01)
		rows.append(st)
		if top:
			for i in n:
				top_sum[i] += _flat[int(_key_index[k]) * _max_frames + i]
	rows.sort_custom(func(a, b): return float(a["mean"]) > float(b["mean"]))
	res["scripts"] = rows
	res["scripts_top_level_sum_ms"] = _stats(top_sum, skip, n)
	# spikes: the slowest frames, with the three most expensive wrapped functions of that frame
	var order: Array = range(skip, n)
	order.sort_custom(func(a, b): return _ft[a] > _ft[b])
	var med: float = res["frame_ms"].get("p50", 1.0)
	var spikes: Array = []
	for k in mini(14, order.size()):
		var i: int = order[k]
		var parts: Array = []
		for key in _key_index:
			var v: float = _flat[int(_key_index[key]) * _max_frames + i]
			if v > 0.3:
				parts.append([snappedf(v, 0.1), String(key)])
		parts.sort_custom(func(a, b): return a[0] > b[0])
		spikes.append({"frame": i, "t_s": snappedf(_tstamp[i] - _tstamp[skip], 0.01), "ms": snappedf(_ft[i], 0.1), "physics_ticks": _ticks[i],
			"process_monitor_ms": snappedf(_proc[i], 0.1), "physics_monitor_ms": snappedf(_phys[i], 0.1), "nodes_delta": _dnodes[i],
			"static_mem_kb": snappedf(_dmem[i], 1.0), "enemies": _enemies[i], "top": parts.slice(0, 3)})
	res["spikes"] = spikes
	var thr := maxf(med * 2.0, med + 8.0)
	var over := 0
	var with_tick2 := 0
	var times: Array = []
	for i in range(skip, n):
		if _ft[i] > thr:
			over += 1
			times.append(snappedf(_tstamp[i] - _tstamp[skip], 0.1))
			if _ticks[i] >= 2:
				with_tick2 += 1
	res["frames_over_threshold"] = {"threshold_ms": snappedf(thr, 0.1), "count": over, "with_2plus_physics_ticks": with_tick2, "times_s": times.slice(0, 60)}
	var emax := 0
	var esum := 0
	for i in range(skip, n):
		emax = maxi(emax, _enemies[i])
		esum += _enemies[i]
	res["enemies"] = {"max": emax, "mean": snappedf(float(esum) / maxf(float(n - skip), 1.0), 0.1)}
	var comp_frames := 0
	var comp_total := 0
	var comp_times: Array = []
	for i in range(skip, n):
		if _pipes[i] > 0:
			comp_frames += 1
			comp_total += _pipes[i]
			comp_times.append([snappedf(_tstamp[i] - _tstamp[skip], 0.1), _pipes[i], snappedf(_ft[i], 1.0)])
	res["pipeline_compilations"] = {"frames_with_compile": comp_frames, "total": comp_total, "events_t_count_frame_ms": comp_times.slice(0, 40)}
	var dsum := 0
	var dmax := 0
	for i in range(skip, n):
		dsum += _draws[i]
		dmax = maxi(dmax, _draws[i])
	res["draw_calls"] = {"mean": snappedf(float(dsum) / maxf(float(n - skip), 1.0), 0.1), "max": dmax}
	res["nodes"] = get_tree().get_node_count()
	res["objects"] = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	return res


func _print(r: Dictionary) -> void:
	var f: Dictionary = r["frame_ms"]
	print("ATTR frames=%d in %.1f s | frame ms mean %.2f p50 %.2f p95 %.2f p99 %.2f max %.2f | enemies %s | boot %d ms | renderer %s" % [
		r["frames"], r["seconds"], f["mean"], f["p50"], f["p95"], f["p99"], f["max"], r["enemies"], r["boot_ms"], r["renderer"]])
	var p: Dictionary = r["process_monitor_ms"]
	var q: Dictionary = r["physics_monitor_ms"]
	print("ATTR monitors: process mean %.2f p95 %.2f max %.2f | physics mean %.2f p95 %.2f max %.2f | scripts top-level sum mean %.2f p95 %.2f max %.2f" % [
		p["mean"], p["p95"], p["max"], q["mean"], q["p95"], q["max"], r["scripts_top_level_sum_ms"]["mean"], r["scripts_top_level_sum_ms"]["p95"], r["scripts_top_level_sum_ms"]["max"]])
	print("ATTR   mean   p95    max  calls/f  script  (top = per-frame callback, else inclusive named function)")
	var shown := 0
	for row in r["scripts"]:
		if shown >= 30:
			break
		print("ATTR %6.3f %6.3f %6.2f %7.2f  %s%s" % [row["mean"], row["p95"], row["max"], row["calls_per_frame"], row["key"], "" if row["top_level"] else "  (incl.)"])
		shown += 1
	for s in r["spikes"]:
		print("ATTR spike ", s)
	print("ATTR over threshold: ", r["frames_over_threshold"])
	print("ATTR pipeline compilations during the walk: ", r["pipeline_compilations"], " draw calls ", r["draw_calls"])
	print("ATTR shims skipped: ", r["shims_skipped"])
