extends Node
## Torch placement: every module has at least one torch and every torch is seated on a wall (or
## the ceiling), not floating in the air. Same generation setup as test_dungeon_generation.gd
## (the main scene is loaded only for its exported generator settings). Measurements are made
## after a few physics frames so the colliders are in the physics space, with 5 world-axis rays
## (right/left/forward/back/up, 3 m, mask 1). Metrics are printed per seed.
## TORCH_TEST_SEEDS=1,2 overrides the seed list (run_tests.sh runs one seed per process).

const MAIN_SCENE := "res://scenes/Purgatory_Dungeon_main_game_file.tscn"
const GEN_SCENE := "res://scenes/dungeon_generation_function.tscn"
const SEEDS: Array[int] = [1, 7, 42]
const SPHERE_R := 0.18
const SEAT_TOLERANCE := 0.25       # sphere centre must be within this of a wall/ceiling
const MAX_EXCEPTION_FRACTION := 0.01
const RAY_LEN := 3.0
const PHYSICS_FRAMES := 4

var _fails: int = 0
var _checks: int = 0
var _cfg: Node


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _build(seed_value: int) -> Dictionary:
	var root := Node3D.new()
	add_child(root)
	var gen: Node = (load(GEN_SCENE) as PackedScene).instantiate()
	root.add_child(gen)
	gen.target_piece_count = _cfg.target_piece_count
	gen.total_generation_attempts = _cfg.total_generation_attempts
	gen.attempts_per_connection = _cfg.attempts_per_connection
	gen.weight_4_connection = _cfg.weight_4_connection
	gen.weight_3_connection = _cfg.weight_3_connection
	gen.weight_2_connection = _cfg.weight_2_connection
	gen.weight_1_connection = _cfg.weight_1_connection
	gen.overlap_shrink = _cfg.overlap_shrink
	gen.connection_nudge = _cfg.connection_nudge
	gen.exclude_keywords = _cfg.exclude_keywords.duplicate()
	gen.exploration_padding = _cfg.exploration_padding
	gen.enemy_spawn_chance = _cfg.enemy_spawn_chance
	gen.setup_generation(root, _cfg.starter_module, _cfg.branch_modules, _cfg.room_connector_module, _cfg.end_cap_module)
	seed(seed_value)
	var result: Dictionary = gen.generate_dungeon()
	return {"root": root, "gen": gen, "result": result}


## A torch node is a direct child of a module that owns both an OmniLight3D and a FlameMesh.
func _torch_nodes_of(mod: Node3D) -> Array[Node3D]:
	var out: Array[Node3D] = []
	for c in mod.get_children():
		if c is Node3D and c.get_node_or_null("OmniLight3D") is OmniLight3D and c.get_node_or_null("FlameMesh") is MeshInstance3D:
			out.append(c)
	return out


## Distance from p to the nearest surface along the five world axes (up included). Returns
## {"gap": float (INF when nothing within RAY_LEN), "back": bool (nearest hit is a back face)}.
func _surface_gap(space: PhysicsDirectSpaceState3D, p: Vector3) -> Dictionary:
	var gap := INF
	var back := false
	var per_dir: Array[String] = []
	var up_gap := INF
	for d in [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK, Vector3.UP]:
		var q := PhysicsRayQueryParameters3D.create(p, p + d * RAY_LEN)
		q.collision_mask = 1
		var hit: Dictionary = space.intersect_ray(q)
		if hit.is_empty():
			per_dir.append("-")
			continue
		var dist: float = p.distance_to(hit["position"])
		per_dir.append("%.2f" % dist)
		if d == Vector3.UP:
			up_gap = dist
		if dist < gap:
			gap = dist
			back = (hit["normal"] as Vector3).dot(d) > 0.05
	return {"gap": gap, "back": back, "dirs": "/".join(per_dir), "up": up_gap}


func _median(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var s := values.duplicate()
	s.sort()
	return s[s.size() / 2]


func _validate(seed_value: int, built: Dictionary) -> void:
	var gen: Node = built["gen"]
	var tag := "seed %d: " % seed_value
	_check(bool(built["result"].get("success", false)), tag + "generation reports success")
	var space: PhysicsDirectSpaceState3D = (built["root"] as Node3D).get_viewport().world_3d.direct_space_state

	var total_torches := 0
	var dark: Array[String] = []
	var gaps: Array[float] = []
	var floating: Array[String] = []
	var buried: Array[String] = []
	var heights: Array[float] = []
	var unregistered := 0
	var registered_ids := {}
	for t in gen.registered_torches:
		registered_ids[t.get_instance_id()] = true
	var scene_modules := 0
	for mod in gen.placed_modules:
		var torches := _torch_nodes_of(mod)
		if mod.scene_file_path != "":
			scene_modules += 1
			if torches.is_empty():
				dark.append("%s@%s" % [mod.scene_file_path.get_file(), str(mod.global_position)])
		for t in torches:
			total_torches += 1
			if not registered_ids.has(t.get_instance_id()):
				unregistered += 1
			var flame := t.get_node("FlameMesh") as Node3D
			var light := t.get_node("OmniLight3D") as Node3D
			if flame.global_position.distance_to(light.global_position) > 0.001:
				unregistered += 1000   # light and flame must stay together
			var m := _surface_gap(space, flame.global_position)
			var g: float = m["gap"]
			gaps.append(g if g != INF else RAY_LEN)
			var desc := "%s torch@%s gap=%s (+x/-x/-z/+z/up: %s) rot_y=%.1f" % [mod.scene_file_path.get_file(), str(flame.global_position), "none" if g == INF else "%.2f" % g, m["dirs"], rad_to_deg(mod.global_rotation.y)]
			if g > SEAT_TOLERANCE:
				floating.append(desc)
			heights.append(flame.global_position.y)
			if m["up"] < SPHERE_R:
				buried.append(desc + " (sphere pokes through the ceiling)")
			elif m["back"]:
				buried.append(desc + " (nearest surface is a back face: centre is inside solid geometry)")

	var skipped: int = int(gen.torch_skipped_count) if "torch_skipped_count" in gen else -1
	var auto: int = int(gen.torch_auto_count) if "torch_auto_count" in gen else -1
	print("  metric %smodules(with scene)=%d torches=%d (generator-skipped=%d auto=%d) median_gap=%.2f m floating(>%.2f m)=%d dark_modules=%d" % [
		tag, scene_modules, total_torches, skipped, auto, _median(gaps), SEAT_TOLERANCE, floating.size(), dark.size()])

	heights.sort()
	if not heights.is_empty():
		print("  metric %storch height y: min=%.2f median=%.2f max=%.2f" % [tag, heights[0], heights[heights.size() / 2], heights[heights.size() - 1]])
	if "torch_skipped_by_scene" in gen:
		print("  skipped markers by module: %s ; torch pass %.1f ms" % [str(gen.torch_skipped_by_scene), gen.torch_pass_ms])
	var limit := int(ceil(float(total_torches) * MAX_EXCEPTION_FRACTION))
	_check(total_torches > 0, tag + "dungeon has torches")
	_check(dark.is_empty(), tag + "every module has >= 1 torch (%d dark: %s)" % [dark.size(), ", ".join(dark.slice(0, 5))])
	for s in floating.slice(0, 8):
		print("  floating: " + s)
	_check(floating.size() <= limit, tag + "torches seated on a wall/ceiling (%d floating of %d, allowed %d)" % [floating.size(), total_torches, limit])
	for s in buried.slice(0, 8):
		print("  buried: " + s)
	_check(buried.size() <= limit, tag + "no torch buried in solid geometry (%d of %d, allowed %d)" % [buried.size(), total_torches, limit])
	_check(gen.registered_torches.size() == total_torches, tag + "registered_torches (%d) == torch nodes in modules (%d)" % [gen.registered_torches.size(), total_torches])
	_check(unregistered == 0, tag + "every torch node is registered and its light sits on its flame (%d)" % unregistered)


func _ready() -> void:
	_cfg = (load(MAIN_SCENE) as PackedScene).instantiate()   # not added to the tree: exported settings only
	var seeds: Array[int] = SEEDS
	var override_seeds := OS.get_environment("TORCH_TEST_SEEDS")
	if override_seeds != "":
		seeds = []
		for part in override_seeds.split(","):
			seeds.append(int(part))
	for s in seeds:
		var t0 := Time.get_ticks_msec()
		var built := _build(s)
		print("seed %d generated in %d ms" % [s, Time.get_ticks_msec() - t0])
		for i in PHYSICS_FRAMES:
			await get_tree().physics_frame
		_validate(s, built)
		built["root"].queue_free()
		await get_tree().process_frame
		await get_tree().process_frame
	_cfg.free()
	print("test_torch_placement: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
