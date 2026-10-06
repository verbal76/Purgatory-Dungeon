extends Node
## Render-cost probe (not a pass/fail test, not part of run_tests.sh). Boots the REAL main game
## scene with a fixed seed, parks the player/camera at representative viewpoints and records what
## the renderer is asked to do: draw calls / objects / primitives (RenderingServer), node and
## light counts, lights overlapping every visible mesh (Mobile renderer: at most 8 omni lights
## per mesh, every one costs per-pixel work), script cost, and the frame time of whatever
## renderer runs it.
##
## It works with the code of BOTH v7 and v7.1+ (it only reads generic scene-tree data), so the same
## file is copied into an older worktree for side-by-side numbers.
##
## Usage (with a renderer; software Vulkan is SLOW, so keep frames small):
##   xvfb-run -a -s "-screen 0 1600x720x24" godot --rendering-driver vulkan \
##       --rendering-method mobile --resolution 1600x720 --path . res://tests/perf_render_probe.tscn
## Headless (no renderer: countable metrics and script cost only, rendering info reads 0):
##   godot --headless --path . res://tests/perf_render_probe.tscn
##
## Environment (all optional):
##   PERF_SEED=12345        generation seed (GlobalRunData.seed_hash)
##   PERF_DIFFICULTY=medium "hardcore" also boots TorchDimmingManager
##   PERF_FRAMES=4          rendered frames averaged per viewpoint (frame time, rendering info)
##   PERF_SETTLE=3          frames to let render after moving (shader / light-list warm up)
##   PERF_VIEWS=spawn,mid_room,corridor,big_room,busiest   viewpoints to visit
##   PERF_ENEMIES=0         0 (default) hides enemies so layouts are comparable, 1 keeps them
##   PERF_ABLATE=0          1 also measures frame time with lights / flames / props hidden (first view,
##                          plus the views named in PERF_ABLATE_VIEWS=a,b)
##   PERF_SWEEP=0           1 also sweeps "nearest K torch lights on" (K=0..all) on the same views as PERF_ABLATE
##   PERF_ROUNDS=2          ablation / sweep states are measured this many times, interleaved; best frame kept
##   PERF_DIST_FRAMES=0     N > 0: sample N extra frames per viewpoint and report the frame-time distribution
##                          (median / p95 / p99 / max, frames over 33 and 100 ms) and the first frames after the move
##   PERF_SOAK=0            N > 0: after the viewpoints, walk the player through the level for N seconds with
##                          the game running (use with PERF_ENEMIES=1, best headless) and report the frame-time
##                          distribution plus what the slowest frames contained (node creation, allocation, script / physics time)
##   PERF_OUT=path          also write the JSON summary to this file
## The last output line starts with PERFJSON and holds everything as JSON.

const MAIN_SCENE := "res://scenes/Purgatory_Dungeon_main_game_file.tscn"
const MAX_OMNI_PER_MESH := 8   # Godot Mobile renderer: lights beyond this are dropped for a mesh

var _results: Dictionary = {}
var _main: Node = null
var _gen: Node = null
var _cam: Camera3D = null
var _player: Node3D = null
var _headless: bool = false
var _reseed: int = -1   # >= 0 while the probe re-seeds the global RNG every frame (see _process)


## The main script seeds the RNG in _ready() and generates two frames later; other nodes consume
## random numbers in between (a different amount with and without a renderer), so the same seed
## gave different layouts. Re-seeding every frame until generation has started removes that.
func _process(_delta: float) -> void:
	if _reseed < 0:
		return
	if _gen != null and _gen.placed_modules.size() > 0:
		_reseed = -1   # generation has run: from here on the game draws its own random numbers
		return
	seed(_reseed)


func _env_i(key: String, default_value: int) -> int:
	var v := OS.get_environment(key)
	return int(v) if v != "" else default_value


func _env_s(key: String, default_value: String) -> String:
	var v := OS.get_environment(key)
	return v if v != "" else default_value


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	Engine.max_fps = 0   # headless frames otherwise idle up to a ~145 fps cap: wall time would hide the CPU cost
	var seed_value := _env_i("PERF_SEED", 12345)
	GlobalRunData.character_class = "barbarian"
	GlobalRunData.seed_hash = seed_value
	GlobalRunData.difficulty = _env_s("PERF_DIFFICULTY", "medium")
	var t0 := Time.get_ticks_msec()
	_main = (load(MAIN_SCENE) as PackedScene).instantiate()
	add_child(_main)
	_gen = _main.get_node("DungeonGenerationFunction")
	_reseed = seed_value
	# The main script boots managers after generation; the trap manager is the last one.
	var guard := 0
	while _main.get_node_or_null("TrapManager") == null and guard < 3000:
		await get_tree().process_frame
		guard += 1
	_results["boot_ms"] = Time.get_ticks_msec() - t0
	_results["seed"] = seed_value
	_results["difficulty"] = GlobalRunData.difficulty
	_results["renderer"] = "headless" if _headless else str(RenderingServer.get_video_adapter_name())
	_results["rendering_method"] = RenderingServer.get_current_rendering_method()
	if _env_i("PERF_ENEMIES", 0) == 0:
		var em := _main.get_node_or_null("EnemyManager")
		if em != null and em.has_method("stop_spawning"):
			em.stop_spawning()
	await _wait_for_spawning()
	_player = _main.get_node_or_null("Player") as Node3D
	_cam = get_viewport().get_camera_3d()
	if _player != null:
		_player.set_process(false)
		_player.set_physics_process(false)
		_player.set_process_input(false)
		_player.set_process_unhandled_input(false)
	_hide_enemies_if_needed()
	_results["generation"] = _generation_facts()
	_results["census"] = _census()

	var views := _pick_viewpoints()
	var wanted := _env_s("PERF_VIEWS", "spawn,mid_room,corridor,big_room,busiest").split(",", false)
	var out_views: Dictionary = {}
	var first := true
	var ablate_views := _env_s("PERF_ABLATE_VIEWS", "").split(",", false)
	for name in wanted:
		if not views.has(name):
			continue
		await _move_to(views[name])
		out_views[name] = await _measure_view(name, views[name])
		if _env_i("PERF_ABLATE", 0) == 1 and not _headless and (first or name in ablate_views):
			_results["ablation_" + name] = await _ablate()
		if _env_i("PERF_SWEEP", 0) == 1 and not _headless and (first or name in ablate_views):
			_results["sweep_" + name] = await _sweep_lights()
		first = false
	_results["views"] = out_views
	var soak_s := _env_i("PERF_SOAK", 0)
	if soak_s > 0:
		_results["soak"] = await _soak(float(soak_s))
	_results["script_cost"] = await _script_cost()
	_print_summary()
	var json := JSON.stringify(_results)
	var out_path := _env_s("PERF_OUT", "")
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f != null:
			f.store_string(json)
	print("PERFJSON " + json)
	get_tree().quit(0)


## Props, chests and orbs are placed in per-frame batches: wait until their node counts stop
## growing (15 stable frames, at most 600 frames) so every run is measured in the same state.
func _wait_for_spawning() -> void:
	var last := -1
	var stable := 0
	var waited := 0
	while stable < 15 and waited < 600:
		await get_tree().process_frame
		waited += 1
		var n := 0
		for k in ["PropSpawner", "ChestManager", "HealthOrbManager", "TrapManager"]:
			var node := _main.get_node_or_null(k)
			if node != null:
				n += node.get_child_count()
		n += get_tree().get_node_count()
		if n == last:
			stable += 1
		else:
			stable = 0
			last = n
	_results["spawn_wait_frames"] = waited


# ── census ───────────────────────────────────────────────────────────────────

func _walk(node: Node, out: Array) -> void:
	out.append(node)
	for c in node.get_children():
		_walk(c, out)


func _light_category(l: Node) -> String:
	var p := l.get_parent()
	if p == null:
		return "orphan"
	if p.has_meta("flame_batched") or p.get_node_or_null("FlameMesh") != null or str(p.name).begins_with("Torch"):
		return "torch"
	var cur: Node = p
	while cur != null and cur != _main and cur != get_tree().root:
		var s: Script = cur.get_script() as Script
		if s != null:
			return s.resource_path.get_file().get_basename()
		if cur is CharacterBody3D:
			return "character:" + str(cur.name)
		cur = cur.get_parent()
	return "other:" + str(p.name)


func _census() -> Dictionary:
	var all: Array = []
	_walk(get_tree().root, all)
	var by_class: Dictionary = {}
	var meshes: Array = []
	var omni: Array = []
	var other_lights := 0
	var shadow_lights := 0
	var flames_total := 0
	var flames_visible := 0
	var uniq_meshes: Dictionary = {}
	var uniq_mats: Dictionary = {}
	var surfaces := 0
	var cats: Dictionary = {}
	var flame_mats: Dictionary = {}
	var skinned := 0
	for n in all:
		var cls: String = n.get_class()
		by_class[cls] = int(by_class.get(cls, 0)) + 1
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			meshes.append(mi)
			if mi.mesh != null:
				uniq_meshes[mi.mesh.get_rid()] = true
				var sc := mi.mesh.get_surface_count()
				surfaces += sc
				for s in sc:
					var m: Material = mi.get_active_material(s)
					if m != null:
						uniq_mats[m.get_rid()] = true
			if mi.skeleton != NodePath("") and mi.skin != null:
				skinned += 1
			if _is_flame(mi):
				flames_total += 1
				if mi.is_visible_in_tree():
					flames_visible += 1
				if mi.mesh != null:
					flame_mats[mi.mesh.surface_get_material(0).get_rid() if mi.mesh.surface_get_material(0) != null else mi.mesh.get_rid()] = true
		elif n is MultiMeshInstance3D and _is_flame(n):
			var mm := (n as MultiMeshInstance3D).multimesh
			if mm != null:
				flames_total += mm.instance_count
				if (n as Node3D).is_visible_in_tree():
					flames_visible += mm.instance_count
				flame_mats[(n as MultiMeshInstance3D).material_override.get_rid() if (n as MultiMeshInstance3D).material_override != null else mm.get_rid()] = true
		elif n is OmniLight3D:
			omni.append(n)
			var cat := _light_category(n)
			var e: Array = cats.get(cat, [0, 0])
			e[0] += 1
			if (n as Node3D).is_visible_in_tree() and (n as Light3D).light_energy > 0.0:
				e[1] += 1
			cats[cat] = e
			if (n as Light3D).shadow_enabled:
				shadow_lights += 1
		elif n is Light3D:
			other_lights += 1
	var tops: Array = []
	for k in by_class:
		tops.append([int(by_class[k]), k])
	tops.sort_custom(func(a, b): return a[0] > b[0])
	var top_dict: Dictionary = {}
	for i in mini(14, tops.size()):
		top_dict[tops[i][1]] = tops[i][0]
	# meshes per module
	var mods: Array = _gen.placed_modules
	var per_mod: Array = []
	var counted := 0
	for m in mods:
		if not is_instance_valid(m):
			continue
		var c := 0
		for n in m.find_children("*", "MeshInstance3D", true, false):
			c += 1
		per_mod.append(c)
		counted += c
	per_mod.sort()
	var vis_meshes := 0
	for mi in meshes:
		if (mi as Node3D).is_visible_in_tree():
			vis_meshes += 1
	return {
		"nodes": get_tree().get_node_count(),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"top_classes": top_dict,
		"mesh_instances": meshes.size(),
		"mesh_instances_visible_in_tree": vis_meshes,
		"mesh_surfaces": surfaces,
		"unique_meshes": uniq_meshes.size(),
		"unique_materials": uniq_mats.size(),
		"skinned_meshes": skinned,
		"omni_lights": omni.size(),
		"omni_lights_visible": _count_active_lights(omni),
		"other_lights": other_lights,
		"shadow_casting_lights": shadow_lights,
		"omni_by_source": cats,
		"flame_meshes": flames_total,
		"flame_meshes_visible": flames_visible,
		"flame_unique_materials": flame_mats.size(),
		"occluder_instances": int(by_class.get("OccluderInstance3D", 0)),
		"modules": per_mod.size(),
		"meshes_per_module_median": per_mod[per_mod.size() / 2] if per_mod.size() > 0 else 0,
		"meshes_per_module_max": per_mod[per_mod.size() - 1] if per_mod.size() > 0 else 0,
		"meshes_in_modules_total": counted,
		"enemies_in_group": get_tree().get_nodes_in_group("enemy").size(),
		"orphan_nodes": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
	}


func _count_active_lights(lights: Array) -> int:
	var c := 0
	for l in lights:
		if is_instance_valid(l) and (l as Node3D).is_visible_in_tree() and (l as Light3D).light_energy > 0.0:
			c += 1
	return c


func _generation_facts() -> Dictionary:
	return {
		"modules": _gen.placed_modules.size(),
		"rooms": _gen.counted_piece_total,
		"torches_registered": _gen.registered_torches.size() if "registered_torches" in _gen else 0,
		"torch_pass_ms": _gen.torch_pass_ms if "torch_pass_ms" in _gen else -1.0,
		"typed_spawns": _gen.registered_typed_spawns.size(),
		"waypoints": _gen.registered_waypoints.size(),
	}


func _hide_enemies_if_needed() -> void:
	if _env_i("PERF_ENEMIES", 0) == 1:
		return
	for e in get_tree().get_nodes_in_group("enemy"):
		if e is Node3D:
			(e as Node3D).visible = false


# ── viewpoints ───────────────────────────────────────────────────────────────

func _module_name(m: Node3D) -> String:
	return m.scene_file_path.get_file().get_basename() if m.scene_file_path != "" else str(m.name)


func _pick_viewpoints() -> Dictionary:
	var mods: Array = []
	for m in _gen.placed_modules:
		if is_instance_valid(m):
			var a: AABB = _gen.get_module_aabb(m)
			if a.size != Vector3.ZERO:
				mods.append({"mod": m, "aabb": a, "name": _module_name(m)})
	var out: Dictionary = {}
	if mods.is_empty():
		return out
	out["spawn"] = mods[0]   # the starter is registered first
	var rooms: Array = mods.filter(func(d): return not (d.name.contains("hall") or d.name.contains("connector") or d.name.contains("closer") or d.name.contains("end")))
	rooms.sort_custom(func(a, b): return a.aabb.get_volume() < b.aabb.get_volume())
	if not rooms.is_empty():
		out["mid_room"] = rooms[rooms.size() / 2]
		out["big_room"] = rooms[rooms.size() - 1]
	var halls: Array = mods.filter(func(d): return d.name.contains("hall") or d.name.contains("long"))
	halls.sort_custom(func(a, b): return maxf(a.aabb.size.x, a.aabb.size.z) > maxf(b.aabb.size.x, b.aabb.size.z))
	if not halls.is_empty():
		out["corridor"] = halls[0]
	# "busiest": the module centre with the most torches within light fade distance
	var torches: Array = _gen.registered_torches if "registered_torches" in _gen else []
	var best: Dictionary = {}
	var best_n := -1
	for d in mods:
		var c: Vector3 = d.aabb.get_center()
		var n := 0
		for t in torches:
			if is_instance_valid(t) and c.distance_squared_to((t as Node3D).global_position) < 1600.0:
				n += 1
		if n > best_n:
			best_n = n
			best = d
	if best_n >= 0:
		out["busiest"] = best
	return out


func _eye_position(d: Dictionary) -> Vector3:
	var a: AABB = d.aabb
	var c: Vector3 = a.get_center()
	var floor_y: float = (d.mod as Node3D).global_position.y
	var space: PhysicsDirectSpaceState3D = (d.mod as Node3D).get_world_3d().direct_space_state
	# first clear spot on a small spiral around the AABB centre
	for ring in [0.0, 1.5, 3.0, 5.0, 8.0]:
		for k in (1 if ring == 0.0 else 8):
			var ang := float(k) * TAU / 8.0
			var p := Vector3(c.x + cos(ang) * ring, floor_y + 0.9, c.z + sin(ang) * ring)
			if _gen.is_position_clear(p, 0.4):
				return Vector3(p.x, floor_y + 1.6, p.z)
	return Vector3(c.x, floor_y + 1.6, c.z)


func _longest_dir(eye: Vector3) -> Vector3:
	var space: PhysicsDirectSpaceState3D = get_viewport().find_world_3d().direct_space_state
	var best_len := -1.0
	var best_dir := Vector3.FORWARD
	for k in 16:
		var ang := float(k) * TAU / 16.0
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var q := PhysicsRayQueryParameters3D.create(eye, eye + dir * 60.0)
		q.collision_mask = 1
		var hit := PhysicsUtil.ray_world(space, q)   # level geometry only: props / chests must not steer the view
		var l := 60.0 if hit.is_empty() else eye.distance_to(hit["position"])
		if l > best_len + 0.01:
			best_len = l
			best_dir = dir
	return best_dir


func _move_to(d: Dictionary) -> void:
	var eye := _eye_position(d)
	var dir := _longest_dir(eye)
	if _player != null:
		_player.global_position = eye - Vector3(0, 1.6, 0) + Vector3(0, 0.05, 0)
		if "velocity" in _player:
			_player.velocity = Vector3.ZERO
	if _cam != null:
		_cam.global_transform = Transform3D(Basis.looking_at(dir, Vector3.UP), eye)
	d["eye"] = eye
	d["dir"] = dir
	var t_move := Time.get_ticks_msec()
	var first_frames: Array = []
	for i in _env_i("PERF_SETTLE", 3):
		var tf := Time.get_ticks_usec()
		await _render_frame()
		first_frames.append(snappedf(float(Time.get_ticks_usec() - tf) / 1000.0, 0.1))
	d["first_frames_ms"] = first_frames
	# Systems that follow the camera in real time (light budget fades) need about 0.8 s to settle.
	while Time.get_ticks_msec() - t_move < 800:
		await _render_frame()


func _render_frame() -> void:
	if _headless:
		await get_tree().process_frame
	else:
		await RenderingServer.frame_post_draw


# ── measurement ──────────────────────────────────────────────────────────────

func _frustum_outside(planes: Array, a: AABB) -> bool:
	# Camera3D.get_frustum() planes face outward: a point is inside when its distance is <= 0.
	# The AABB is outside a plane when even its most-inside corner is on the positive side.
	for p in planes:
		var pl := p as Plane
		var n := pl.normal
		var v := Vector3(
			a.position.x + (a.size.x if n.x < 0.0 else 0.0),
			a.position.y + (a.size.y if n.y < 0.0 else 0.0),
			a.position.z + (a.size.z if n.z < 0.0 else 0.0))
		if pl.distance_to(v) > 0.0:
			return true
	return false


func _dist(ft: Array) -> Dictionary:
	var a: Array = ft.duplicate()
	a.sort()
	var n := a.size()
	if n == 0:
		return {}
	var o33 := 0
	var o100 := 0
	for v in a:
		if v > 33.4:
			o33 += 1
		if v > 100.0:
			o100 += 1
	return {"n": n, "median": snappedf(a[n / 2], 0.01), "p95": snappedf(a[mini(int(n * 0.95), n - 1)], 0.01),
		"p99": snappedf(a[mini(int(n * 0.99), n - 1)], 0.01), "max": snappedf(a[n - 1], 0.01), "over_33ms": o33, "over_100ms": o100}


func _measure_view(name: String, d: Dictionary) -> Dictionary:
	var frames := _env_i("PERF_FRAMES", 4)
	var ft: Array[float] = []
	var proc_ms := 0.0
	var phys_ms := 0.0
	var draws := 0
	var objs := 0
	var prims := 0
	for i in frames:
		var t := Time.get_ticks_usec()
		await _render_frame()
		ft.append(float(Time.get_ticks_usec() - t) / 1000.0)
		proc_ms += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		phys_ms += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		draws += int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		objs += int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME))
		prims += int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
	ft.sort()
	var res := {
		"module": d.name,
		"eye": [snappedf(d.eye.x, 0.1), snappedf(d.eye.y, 0.1), snappedf(d.eye.z, 0.1)],
		"draw_calls": draws / frames,
		"objects": objs / frames,
		"primitives": prims / frames,
		"frame_ms_median": ft[ft.size() / 2],
		"frame_ms_min": ft[0],
		"process_ms_avg": proc_ms / frames,
		"physics_ms_avg": phys_ms / frames,
	}
	res.merge(_light_overlap())
	res["nodes"] = get_tree().get_node_count()
	var dist_n := _env_i("PERF_DIST_FRAMES", 0)
	if dist_n > 0:
		var samples: Array = []
		for i in dist_n:
			var t := Time.get_ticks_usec()
			await _render_frame()
			samples.append(float(Time.get_ticks_usec() - t) / 1000.0)
		res["frame_dist_ms"] = _dist(samples)
	if d.has("first_frames_ms"):
		res["first_frames_ms_after_move"] = d["first_frames_ms"]
	return res


## Lights that can reach a camera-visible mesh. A light counts when it is visible, has energy,
## is inside its distance-fade range of the camera, and its range sphere touches the mesh AABB.
func _light_overlap() -> Dictionary:
	var cam := _cam
	if cam == null:
		return {}
	var cpos := cam.global_position
	var lights: Array = []
	var all: Array = []
	_walk(get_tree().root, all)
	var active_lights := 0
	var in_fade := 0
	for n in all:
		if n is OmniLight3D:
			var l := n as OmniLight3D
			if not l.is_visible_in_tree() or l.light_energy <= 0.0:
				continue
			active_lights += 1
			var dist := cpos.distance_to(l.global_position)
			var reach := 1e9
			if l.distance_fade_enabled:
				reach = l.distance_fade_begin + l.distance_fade_length
			if dist > reach:
				continue
			in_fade += 1
			lights.append([l.global_position, l.omni_range])
	var planes := cam.get_frustum()
	if _module_set.is_empty():
		for m in _gen.placed_modules:
			if is_instance_valid(m):
				_module_set[m.get_instance_id()] = true
	var cats: Dictionary = {}
	var counts: Array[int] = []
	var pairs := 0
	var over := 0
	var meshes_in_view := 0
	for n in all:
		if not (n is GeometryInstance3D):
			continue
		var gi := n as GeometryInstance3D
		if not gi.is_visible_in_tree():
			continue
		if gi is MeshInstance3D and (gi as MeshInstance3D).mesh == null:
			continue
		var a: AABB = gi.global_transform * gi.get_aabb()
		if _frustum_outside(planes, a):
			continue
		if gi.visibility_range_end > 0.0 and cpos.distance_to(a.get_center()) > gi.visibility_range_end + 0.0:
			continue
		var cat := _mesh_category(gi)
		var ce: Array = cats.get(cat, [0, 0, 0, {}])
		ce[0] += 1
		if gi is MeshInstance3D:
			ce[1] += _mesh_tris((gi as MeshInstance3D).mesh)
			ce[2] += (gi as MeshInstance3D).mesh.get_surface_count()
			for si in (gi as MeshInstance3D).mesh.get_surface_count():
				var mat: Material = (gi as MeshInstance3D).get_active_material(si)
				var mk := "none"
				if mat is BaseMaterial3D:
					mk = "T" + str((mat as BaseMaterial3D).transparency)   # 0 opaque, 1 alpha, 2 scissor, 3 hash, 4 alpha+depth prepass
				elif mat != null:
					mk = "shader"
				ce[3][mk] = int(ce[3].get(mk, 0)) + 1
		elif gi is MultiMeshInstance3D and (gi as MultiMeshInstance3D).multimesh != null:
			var mm := (gi as MultiMeshInstance3D).multimesh
			ce[1] += _mesh_tris(mm.mesh) * mm.visible_instance_count if mm.visible_instance_count >= 0 else _mesh_tris(mm.mesh) * mm.instance_count
			ce[2] += 1
		cats[cat] = ce
		if cat == "flames":
			continue   # unshaded: not part of the light statistics
		meshes_in_view += 1
		var c := 0
		for l in lights:
			var lp: Vector3 = l[0]
			var q := lp.clamp(a.position, a.end)
			if lp.distance_squared_to(q) <= l[1] * l[1]:
				c += 1
		counts.append(c)
		pairs += mini(c, MAX_OMNI_PER_MESH)
		if c > MAX_OMNI_PER_MESH:
			over += 1
	counts.sort()
	var n_c := counts.size()
	var total := 0
	for c in counts:
		total += c
	return {
		"in_view_by_category": cats,
		"lights_active_total": active_lights,
		"lights_within_fade_of_camera": in_fade,
		"meshes_in_view": meshes_in_view,
		"lights_per_mesh_mean": snappedf(float(total) / maxf(n_c, 1), 0.01),
		"lights_per_mesh_p95": counts[int(n_c * 0.95)] if n_c > 0 else 0,
		"lights_per_mesh_max": counts[n_c - 1] if n_c > 0 else 0,
		"meshes_over_8_lights": over,
		"mesh_light_pairs_capped8": pairs,
	}


var _tri_cache: Dictionary = {}   # Mesh -> triangle count (probe-only, uses surface arrays)
var _module_set: Dictionary = {}  # module root instance id -> true


func _mesh_tris(m: Mesh) -> int:
	if m == null:
		return 0
	if _tri_cache.has(m):
		return _tri_cache[m]
	var tris := 0
	for i in m.get_surface_count():
		var arrays := m.surface_get_arrays(i)
		if arrays.is_empty():
			continue
		var idx = arrays[Mesh.ARRAY_INDEX]
		if idx != null and (idx as PackedInt32Array).size() > 0:
			tris += (idx as PackedInt32Array).size() / 3
		else:
			var v = arrays[Mesh.ARRAY_VERTEX]
			tris += (v as PackedVector3Array).size() / 3 if v != null else 0
	_tri_cache[m] = tris
	return tris


func _is_flame(n: Node) -> bool:
	var nm := str(n.name)
	return nm.begins_with("FlameMesh") or nm.begins_with("TorchFlames")


func _mesh_category(n: Node) -> String:
	if _is_flame(n):
		return "flames"
	var cur: Node = n
	while cur != null and cur != get_tree().root:
		if _module_set.has(cur.get_instance_id()):
			return "architecture"
		var nm := str(cur.name)
		if nm == "PropSpawner":
			return "props"
		if nm == "ChestManager" or cur.is_in_group("chest"):
			return "chests"
		if cur is CharacterBody3D or cur.is_in_group("enemy") or cur.is_in_group("player"):
			return "characters"
		cur = cur.get_parent()
	return "other"


## Fastest of `frames` frames: the minimum is the most robust software-render number when other
## processes share the CPU.
func _best_frame(frames: int) -> float:
	var best := INF
	for i in frames:
		var t := Time.get_ticks_usec()
		await _render_frame()
		best = minf(best, float(Time.get_ticks_usec() - t) / 1000.0)
	return best


func _info() -> Array:
	return [
		int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)),
		int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)),
	]


## Frame time and draw/object/primitive counts with parts of the scene changed, same viewpoint.
## Lights and flames are only hidden (visible=false) or have their mesh swapped, then restored.
func _ablate() -> Dictionary:
	var frames := maxi(_env_i("PERF_FRAMES", 4), 3)
	var all: Array = []
	_walk(get_tree().root, all)
	var omni: Array = []
	var torch_omni: Array = []
	var flames: Array = []
	var props: Array = []
	for n in all:
		if n is OmniLight3D:
			omni.append(n)
			if _light_category(n) == "torch":
				torch_omni.append(n)
		elif n is GeometryInstance3D and _is_flame(n):
			flames.append(n)
	var ps := _main.get_node_or_null("PropSpawner")
	if ps != null:
		for n in ps.get_children():
			if n is Node3D:
				props.append(n)
	var cpos := _cam.global_position
	torch_omni.sort_custom(func(a, b): return cpos.distance_squared_to((a as Node3D).global_position) < cpos.distance_squared_to((b as Node3D).global_position))
	var far_torch_lights: Array = torch_omni.slice(12)
	# architecture materials (unique): flipped between the alpha pass (4) and opaque (0)
	var arch_mats: Dictionary = {}
	if _module_set.is_empty():
		for m in _gen.placed_modules:
			if is_instance_valid(m):
				_module_set[m.get_instance_id()] = true
	for n in all:
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null and _mesh_category(n) == "architecture":
			for si in (n as MeshInstance3D).mesh.get_surface_count():
				var am := (n as MeshInstance3D).get_active_material(si)
				if am is BaseMaterial3D:
					arch_mats[am] = (am as BaseMaterial3D).transparency
	var low := SphereMesh.new()
	low.radius = 0.18
	low.height = 0.36
	low.radial_segments = 8
	low.rings = 4
	var res: Dictionary = {}
	# [label, nodes hidden, flame meshes whose mesh is swapped to a low-poly sphere]
	var states: Array = [
		["baseline", [], false],
		["no_omni_lights", omni, false],
		["no_flame_meshes", flames, false],
		["no_lights_no_flames", omni + flames, false],
		["no_props", props, false],
		["torch_lights_nearest12_only", far_torch_lights, false],
		["arch_materials_flipped_0_4", [], false],
		["flames_lowpoly_8x4", [], true],
		["lights12_and_lowpoly_flames", far_torch_lights, true],
	]
	var rounds := maxi(_env_i("PERF_ROUNDS", 2), 1)
	var best_ms: Dictionary = {}
	for r in rounds:
		for st in states:
			var nodes: Array = st[1]
			var prev: Array = []
			for n in nodes:
				prev.append((n as Node3D).visible)
				(n as Node3D).visible = false
			if str(st[0]).begins_with("arch_materials_flipped"):
				for am in arch_mats:
					(am as BaseMaterial3D).transparency = BaseMaterial3D.TRANSPARENCY_DISABLED if int(arch_mats[am]) != 0 else BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
			var old_meshes: Dictionary = {}
			if st[2]:
				for f in flames:
					if f is MeshInstance3D:
						old_meshes[f] = (f as MeshInstance3D).mesh
						(f as MeshInstance3D).mesh = low
			for i in 2:
				await _render_frame()
			var ms := await _best_frame(frames)
			var info := _info()
			best_ms[st[0]] = minf(float(best_ms.get(st[0], INF)), ms)
			res[st[0]] = {"frame_ms": snappedf(best_ms[st[0]], 0.1), "draw_calls": info[0], "objects": info[1], "primitives": info[2], "changed_nodes": nodes.size()}
			for i in nodes.size():
				if is_instance_valid(nodes[i]):
					(nodes[i] as Node3D).visible = prev[i]
			for f in old_meshes:
				(f as MeshInstance3D).mesh = old_meshes[f]
			if str(st[0]).begins_with("arch_materials_flipped"):
				for am in arch_mats:
					(am as BaseMaterial3D).transparency = int(arch_mats[am]) as BaseMaterial3D.Transparency
	return res


## Frame time as a function of how many torch lights (nearest to the camera) stay on. Lights are
## only hidden and restored. Also reports the mesh/light overlap numbers for each K.
func _sweep_lights() -> Dictionary:
	var frames := maxi(_env_i("PERF_FRAMES", 4), 3)
	var all: Array = []
	_walk(get_tree().root, all)
	var torch_omni: Array = []
	for n in all:
		if n is OmniLight3D and _light_category(n) == "torch" and (n as Node3D).visible:
			torch_omni.append(n)
	var cpos := _cam.global_position
	torch_omni.sort_custom(func(a, b): return cpos.distance_squared_to((a as Node3D).global_position) < cpos.distance_squared_to((b as Node3D).global_position))
	var res: Dictionary = {}
	var rounds := maxi(_env_i("PERF_ROUNDS", 2), 1)
	var ks: Array = [0, 1, 4, 8, 12, 16, 24, 32, 64, torch_omni.size()]
	for r in rounds:
		for k in ks:
			var off: Array = torch_omni.slice(k)
			for l in off:
				(l as Node3D).visible = false
			for i in 2:
				await _render_frame()
			var ms := await _best_frame(frames)
			var ov := _light_overlap()
			var key := "K=%d" % k
			var prev_ms: float = res[key]["frame_ms"] if res.has(key) else INF
			res[key] = {"frame_ms": snappedf(minf(prev_ms, ms), 0.1), "pairs8": ov.get("mesh_light_pairs_capped8", 0),
				"lights_within_fade": ov.get("lights_within_fade_of_camera", 0), "over8": ov.get("meshes_over_8_lights", 0)}
			for l in off:
				(l as Node3D).visible = true
	return res


## Walks the player through the level (modules visited nearest-neighbour first, 5 m/s) with the
## whole game running and records every frame: wall time, script and physics time, nodes created
## (node count delta), objects and static memory delta (allocation bursts), draw calls, live enemies.
## The slowest frames are listed with what happened in them, to attribute spikes.
func _soak(seconds: float) -> Dictionary:
	if _player == null or _cam == null:
		return {}
	if "_current_health" in _player:
		_player._current_health = 1.0e9
		_player.max_health = 1.0e9
	var centres: Array = []
	for m in _gen.placed_modules:
		if is_instance_valid(m):
			var a: AABB = _gen.get_module_aabb(m)
			if a.size != Vector3.ZERO:
				centres.append(Vector3(a.get_center().x, (m as Node3D).global_position.y, a.get_center().z))
	var path: Array[Vector3] = []
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
	var max_frames := int(seconds * 1000.0)
	var ft := PackedFloat32Array()
	ft.resize(max_frames)
	var proc := PackedFloat32Array()
	proc.resize(max_frames)
	var phys := PackedFloat32Array()
	phys.resize(max_frames)
	var dnodes := PackedInt32Array()
	dnodes.resize(max_frames)
	var dobjs := PackedInt32Array()
	dobjs.resize(max_frames)
	var dmem := PackedFloat32Array()
	dmem.resize(max_frames)
	var draws := PackedInt32Array()
	draws.resize(max_frames)
	var enemies := PackedInt32Array()
	enemies.resize(max_frames)
	var n := 0
	var pos: Vector3 = _player.global_position
	var seg := 0
	var t_start := Time.get_ticks_msec()
	var last_us := Time.get_ticks_usec()
	var last_nodes := get_tree().get_node_count()
	var last_objs := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var last_mem: float = Performance.get_monitor(Performance.MEMORY_STATIC)
	while float(Time.get_ticks_msec() - t_start) < seconds * 1000.0 and n < max_frames and seg < path.size():
		await _render_frame()
		var now := Time.get_ticks_usec()
		var delta_s := float(now - last_us) / 1.0e6
		ft[n] = float(now - last_us) / 1000.0
		last_us = now
		# move 5 m/s towards the next module centre, face the direction of travel
		var to: Vector3 = path[seg] - pos
		to.y = 0.0
		var step := 5.0 * minf(delta_s, 0.1)
		if to.length() <= step:
			seg += 1
		else:
			pos += to.normalized() * step
		_player.global_position = pos + Vector3(0, 0.05, 0)
		if "velocity" in _player:
			_player.velocity = Vector3.ZERO
		if to.length() > 0.5:
			_cam.global_transform = Transform3D(Basis.looking_at(to.normalized(), Vector3.UP), pos + Vector3(0, 1.6, 0))
		proc[n] = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		phys[n] = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		var nn := get_tree().get_node_count()
		var oo := int(Performance.get_monitor(Performance.OBJECT_COUNT))
		var mm: float = Performance.get_monitor(Performance.MEMORY_STATIC)
		dnodes[n] = nn - last_nodes
		dobjs[n] = oo - last_objs
		dmem[n] = (mm - last_mem) / 1024.0
		last_nodes = nn
		last_objs = oo
		last_mem = mm
		draws[n] = int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		enemies[n] = get_tree().get_nodes_in_group("enemy").size() if n % 30 == 0 else (enemies[n - 1] if n > 0 else 0)
		n += 1
	var samples: Array = []
	var skip := mini(60, n / 4)   # the first frames still contain the teleport / spawn burst of the setup
	for i in range(skip, n):
		samples.append(ft[i])
	var res: Dictionary = {"frames": n, "seconds": snappedf(float(Time.get_ticks_msec() - t_start) / 1000.0, 0.1),
		"distance_walked_m": snappedf(float(seg) * 20.0, 1.0), "dist_ms": _dist(samples)}
	# slowest frames and what they contained
	var order: Array = range(skip, n)
	order.sort_custom(func(a, b): return ft[a] > ft[b])
	var worst: Array = []
	for k in mini(12, order.size()):
		var i: int = order[k]
		worst.append({"frame": i, "ms": snappedf(ft[i], 0.1),
			"nodes_created": dnodes[i], "objects_delta": dobjs[i], "static_mem_delta_kb": snappedf(dmem[i], 1.0), "draws": draws[i]})
	res["slowest_frames"] = worst
	# correlation summary: how many frames over 2x median contain node creation / allocation
	var slow := 0
	var slow_nodes := 0
	var slow_alloc := 0
	var cpu_med: float = res["dist_ms"].get("median", 1.0)
	for i in range(skip, n):
		if ft[i] > cpu_med * 3.0:
			slow += 1
			if dnodes[i] > 0:
				slow_nodes += 1
			if dmem[i] > 256.0:
				slow_alloc += 1
	res["frames_over_3x_median"] = {"count": slow, "with_node_creation": slow_nodes, "with_alloc_gt_256kb": slow_alloc,
		}
	var enemy_max := 0
	for i in n:
		enemy_max = maxi(enemy_max, enemies[i])
	res["max_enemies_seen"] = enemy_max
	return res


## Script cost of known per-frame suspects, measured with the real data of this run.
func _script_cost() -> Dictionary:
	var res: Dictionary = {}
	# exploration update (throttled to 2 Hz in the main scene)
	var t := Time.get_ticks_usec()
	for i in 20:
		_gen.update_player_exploration()
	res["update_player_exploration_ms_per_call"] = float(Time.get_ticks_usec() - t) / 1000.0 / 20.0
	# TorchDimmingManager._process (hardcore only): drive it with the registered torches
	var script: GDScript = load("res://scripts/torch_dimming_manager.gd")
	var existing := _main.get_node_or_null("TorchDimmingManager")
	var mgr: Node = existing
	var made := false
	if mgr == null and script != null:
		mgr = Node.new()
		mgr.set_script(script)
		add_child(mgr)
		mgr.boot(_gen.registered_torches, null)
		made = true
	if mgr != null:
		mgr.set_process(false)
		var t2 := Time.get_ticks_usec()
		for i in 60:
			mgr._process(0.016)
		res["torch_dimming_process_ms_per_frame"] = float(Time.get_ticks_usec() - t2) / 1000.0 / 60.0
		if made:
			mgr.queue_free()
	res["torch_dimming_booted_in_run"] = existing != null
	# Frame-level script time over a short window
	var proc := 0.0
	var phys := 0.0
	var n := 30
	for i in n:
		await get_tree().physics_frame
		proc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	res["window_process_ms_avg"] = proc / n
	res["window_physics_ms_avg"] = phys / n
	return res


func _print_summary() -> void:
	var c: Dictionary = _results["census"]
	print("PERF renderer=%s method=%s seed=%d difficulty=%s boot=%d ms" % [_results["renderer"], _results["rendering_method"], _results["seed"], _results["difficulty"], _results["boot_ms"]])
	print("PERF generation: ", _results["generation"])
	print("PERF census: nodes=%d objects=%d meshes=%d (surfaces %d, unique meshes %d, unique materials %d) omni=%d (active %d) shadow_lights=%d flames=%d occluders=%d" % [
		c["nodes"], c["objects"], c["mesh_instances"], c["mesh_surfaces"], c["unique_meshes"], c["unique_materials"],
		c["omni_lights"], c["omni_lights_visible"], c["shadow_casting_lights"], c["flame_meshes"], c["occluder_instances"]])
	print("PERF omni by source: ", c["omni_by_source"])
	print("PERF top classes: ", c["top_classes"])
	var views: Dictionary = _results["views"]
	for k in views:
		var v: Dictionary = views[k]
		print("PERF   in view [meshes, tris, surfaces, material transparency modes (T0 opaque, T1 alpha blend, T2 scissor, T3 hash, T4 alpha+depth prepass)]: ", v.get("in_view_by_category", {}))
		print("PERF view %-9s %-34s draws=%d objs=%d prims=%d | lights active=%d in_fade=%d | meshes=%d lights/mesh mean=%.2f p95=%d max=%d over8=%d pairs8=%d | frame=%.0f ms proc=%.2f phys=%.2f" % [
			k, v.get("module", ""), v["draw_calls"], v["objects"], v["primitives"], v.get("lights_active_total", 0),
			v.get("lights_within_fade_of_camera", 0), v.get("meshes_in_view", 0), v.get("lights_per_mesh_mean", 0.0),
			v.get("lights_per_mesh_p95", 0), v.get("lights_per_mesh_max", 0), v.get("meshes_over_8_lights", 0),
			v.get("mesh_light_pairs_capped8", 0), v["frame_ms_median"], v["process_ms_avg"], v["physics_ms_avg"]])
	for rk in _results:
		if str(rk).begins_with("sweep_"):
			var sw: Dictionary = _results[rk]
			for k in sw:
				print("PERF %s %-8s best-frame=%.1f ms pairs8=%d lights_within_fade=%d over8=%d" % [rk, k, sw[k]["frame_ms"], sw[k]["pairs8"], sw[k]["lights_within_fade"], sw[k]["over8"]])
		if str(rk).begins_with("ablation_"):
			var ab: Dictionary = _results[rk]
			for k in ab:
				print("PERF %s %-30s best-frame=%.1f ms draws=%d objs=%d prims=%d (changed %d)" % [
					rk, k, ab[k]["frame_ms"], ab[k]["draw_calls"], ab[k]["objects"], ab[k]["primitives"], ab[k]["changed_nodes"]])
	for k in views:
		if views[k].has("frame_dist_ms"):
			print("PERF dist view %-9s frame ms %s  first frames after move %s" % [k, views[k]["frame_dist_ms"], views[k].get("first_frames_ms_after_move", [])])
	if _results.has("soak"):
		var sk: Dictionary = _results["soak"]
		print("PERF soak: ", sk.get("frames", 0), " frames in ", sk.get("seconds", 0), " s, dist ", sk.get("dist_ms", {}), "\nPERF soak frames over 3x median: ", sk.get("frames_over_3x_median", {}), " max enemies ", sk.get("max_enemies_seen", 0))
		for w in sk.get("slowest_frames", []):
			print("PERF soak slow frame ", w)
	print("PERF script cost: ", _results["script_cost"])
