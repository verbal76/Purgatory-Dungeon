extends Node
## Structural validation of procedural generation across several seeds, using the
## same module set and settings as the main game scene.
## Metrics are printed per seed; hard invariants fail the test.

const MAIN_SCENE := "res://scenes/Purgatory_Dungeon_main_game_file.tscn"
const GEN_SCENE := "res://scenes/dungeon_generation_function.tscn"
const SEEDS: Array[int] = [1, 2, 3, 7, 42, 123, 2024, 98765]
const MATE_DISTANCE := 0.35

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


func _signature(gen: Node) -> PackedStringArray:
	var sig := PackedStringArray()
	for m in gen.placed_modules:
		var p: Vector3 = m.global_position
		sig.append("%s@%.2f,%.2f,%.2f/%.2f" % [m.scene_file_path.get_file(), p.x, p.y, p.z, m.global_rotation.y])
	return sig


func _doors(m: Node3D) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for c in m.get_children():
		if c is Node3D and String(c.name).begins_with("Connection_"):
			out.append((c as Node3D).global_position)
	return out


func _aabb_dist(a: AABB, p: Vector3) -> float:
	var c := a.get_center()
	var h := a.size * 0.5
	var d := Vector3(maxf(absf(p.x - c.x) - h.x, 0.0), maxf(absf(p.y - c.y) - h.y, 0.0), maxf(absf(p.z - c.z) - h.z, 0.0))
	return d.length()


func _validate(seed_value: int, built: Dictionary) -> void:
	var gen: Node = built["gen"]
	var res: Dictionary = built["result"]
	var tag := "seed %d: " % seed_value
	var mods: Array = gen.placed_modules
	_check(bool(res.get("success", false)), tag + "generation reports success")
	_check(gen.counted_piece_total >= gen.target_piece_count, tag + "room target met (%d/%d)" % [gen.counted_piece_total, gen.target_piece_count])
	var starter: Node3D = res.get("starter")
	_check(starter != null and starter.get_node_or_null("Player_Spawn") != null, tag + "starter module has Player_Spawn")
	_check(gen.open_connections.size() == 0, tag + "no open connections left (%d)" % gen.open_connections.size())

	# Connectivity: modules are linked when doorway markers coincide.
	var doors: Array = []
	for m in mods:
		doors.append(_doors(m))
	var adj: Array = []
	adj.resize(mods.size())
	for i in mods.size():
		adj[i] = []
	for i in mods.size():
		for j in range(i + 1, mods.size()):
			var linked := false
			for a in doors[i]:
				for b in doors[j]:
					if a.distance_to(b) <= MATE_DISTANCE:
						linked = true
						break
				if linked:
					break
			if linked:
				adj[i].append(j)
				adj[j].append(i)
	var start_idx := mods.find(starter)
	var seen := {}
	var queue: Array = [start_idx]
	seen[start_idx] = true
	while not queue.is_empty():
		var cur: int = queue.pop_back()
		for n in adj[cur]:
			if not seen.has(n):
				seen[n] = true
				queue.append(n)
	var unreachable := 0
	for i in mods.size():
		if not seen.has(i):
			if mods[i] is StaticBody3D and mods[i].scene_file_path == "":
				continue   # door plugs carry no doorway markers by design
			unreachable += 1
			print("  unreachable: %s name=%s doors=%d aabb=%s" % [mods[i].scene_file_path.get_file(), mods[i].name, doors[i].size(), gen.get_module_aabb(mods[i])])
	_check(unreachable == 0, tag + "all %d modules connected to the starter (%d unreachable)" % [mods.size(), unreachable])

	# Code plugs must seal the doorway from the floor up.
	var floor_y: float = starter.global_position.y
	for m in mods:
		if m is StaticBody3D and m.scene_file_path == "":
			for c in m.get_children():
				if c is CollisionShape3D and c.shape is BoxShape3D:
					var bottom: float = c.global_position.y - (c.shape as BoxShape3D).size.y * 0.5
					var top: float = c.global_position.y + (c.shape as BoxShape3D).size.y * 0.5
					_check(bottom <= floor_y + 0.1 and top >= floor_y + 3.5, tag + "code plug seals floor to ceiling (%.2f..%.2f)" % [bottom, top])

	# Overlap between modules that are not doorway-neighbours.
	var overlaps := 0
	var connector_overlaps := 0
	var aabbs: Array = []
	for m in mods:
		aabbs.append(gen.get_module_aabb(m))
	for i in mods.size():
		if aabbs[i].size == Vector3.ZERO:
			continue
		for j in range(i + 1, mods.size()):
			if aabbs[j].size == Vector3.ZERO or adj[i].has(j):
				continue
			var inter: AABB = aabbs[i].intersection(aabbs[j])
			if inter.size.x > 0.1 and inter.size.y > 0.1 and inter.size.z > 0.1:
				# Connector boxes are axis-aligned and often wrap L/T-shaped neighbours,
				# so connector overlaps are reported as a metric only.
				if mods[i].scene_file_path.contains("room_connector") or mods[j].scene_file_path.contains("room_connector"):
					connector_overlaps += 1
				else:
					overlaps += 1
					print("  overlap: %s <-> %s  intersection=%s" % [mods[i].scene_file_path.get_file(), mods[j].scene_file_path.get_file(), inter.size])
	_check(overlaps == 0, tag + "no overlapping non-neighbour room/hall modules (%d)" % overlaps)
	print("  metric %sconnector bounding-box overlaps: %d" % [tag, connector_overlaps])

	# Spawn / waypoint placement.
	var bad_spawns := 0
	for s in gen.registered_typed_spawns:
		if not gen.is_position_inside_dungeon(s["position"]):
			bad_spawns += 1
	_check(bad_spawns == 0, tag + "all %d enemy spawns inside dungeon bounds (%d outside)" % [gen.registered_typed_spawns.size(), bad_spawns])
	var bad_wp := 0
	for w in gen.registered_waypoints:
		if not gen.is_position_inside_dungeon(w):
			bad_wp += 1
	var far := 0.0
	for w in gen.registered_waypoints:
		if not gen.is_position_inside_dungeon(w):
			var best := 1.0e9
			for a in aabbs:
				if a.size != Vector3.ZERO:
					best = min(best, a.grow(0.3).distance_to(w) if false else _aabb_dist(a, w))
			far = max(far, best)
	print("  metric %sfarthest outside-waypoint distance to nearest module box: %.2f m" % [tag, far])
	print("  metric %swaypoints outside bounds: %d / %d" % [tag, bad_wp, gen.registered_waypoints.size()])
	print("  metric %smodules=%d rooms=%d spawns=%d plugs(wall=%d code=%d)" % [tag, mods.size(), gen.counted_piece_total, gen.registered_typed_spawns.size(), gen.wall_plug_count, gen.code_plug_count])


func _ready() -> void:
	_cfg = (load(MAIN_SCENE) as PackedScene).instantiate()   # not added to the tree: used only for its exported settings
	var first_sig := PackedStringArray()
	var seeds: Array[int] = SEEDS
	var override_seeds := OS.get_environment("GEN_TEST_SEEDS")
	if override_seeds != "":
		seeds = []
		for part in override_seeds.split(","):
			seeds.append(int(part))
	for s in seeds:
		var t0 := Time.get_ticks_msec()
		var built := _build(s)
		print("seed %d generated in %d ms" % [s, Time.get_ticks_msec() - t0])
		_validate(s, built)
		if s == seeds[0]:
			first_sig = _signature(built["gen"])
		built["root"].queue_free()
		await get_tree().process_frame
		await get_tree().process_frame
	# Determinism: regenerate the first seed.
	var again := _build(seeds[0])
	_check(_signature(again["gen"]) == first_sig, "same seed reproduces an identical layout")
	again["root"].queue_free()
	await get_tree().process_frame
	_cfg.free()
	print("test_dungeon_generation: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
