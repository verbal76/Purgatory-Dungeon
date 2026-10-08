extends Node
## One seeded generation, checked and summarised on a single "STRESS ..." line (so hundreds of
## seeds can be run as separate processes by tests/stress_generation.sh and any failure reproduced
## from its seed). STRESS_SEED (default 1), STRESS_ATTEMPTS (max_layout_attempts; default = game's),
## STRESS_FULL=1 also places chests and checks the Day-30 portal and its guards.

const MAIN_SCENE := "res://scenes/Purgatory_Dungeon_main_game_file.tscn"
const GEN_SCENE := "res://scenes/dungeon_generation_function.tscn"
const MATE_DISTANCE := 0.35


func _doors(m: Node3D) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for c in m.get_children():
		if c is Node3D and String(c.name).begins_with("Connection_"):
			out.append((c as Node3D).global_position)
	return out


# Module indices reachable from the starter through coinciding doorway markers.
func _reachable(mods: Array) -> Dictionary:
	var doors: Array = []
	for m in mods:
		doors.append(_doors(m))
	var seen := {0: true}
	var queue := [0]
	while not queue.is_empty():
		var i: int = queue.pop_back()
		for j in mods.size():
			if seen.has(j):
				continue
			var linked := false
			for a in doors[i]:
				for b in doors[j]:
					if a.distance_to(b) <= MATE_DISTANCE:
						linked = true
						break
				if linked:
					break
			if linked:
				seen[j] = true
				queue.append(j)
	return seen


func _module_index(gen: Node, mods: Array, p: Vector3) -> int:
	var m = gen.get_module_containing_point(p)
	return mods.find(m) if m != null else -1


func _ready() -> void:
	var seed_value := int(OS.get_environment("STRESS_SEED")) if OS.get_environment("STRESS_SEED") != "" else 1
	var full := OS.get_environment("STRESS_FULL") == "1"
	var cfg: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	var root := Node3D.new()
	add_child(root)
	var gen: Node = (load(GEN_SCENE) as PackedScene).instantiate()
	gen.name = "DungeonGenerationFunction"
	root.add_child(gen)
	gen.target_piece_count = cfg.target_piece_count
	gen.total_generation_attempts = cfg.total_generation_attempts
	gen.attempts_per_connection = cfg.attempts_per_connection
	gen.weight_4_connection = cfg.weight_4_connection
	gen.weight_3_connection = cfg.weight_3_connection
	gen.weight_2_connection = cfg.weight_2_connection
	gen.weight_1_connection = cfg.weight_1_connection
	gen.overlap_shrink = cfg.overlap_shrink
	gen.connection_nudge = cfg.connection_nudge
	gen.exclude_keywords = cfg.exclude_keywords.duplicate()
	gen.exploration_padding = cfg.exploration_padding
	gen.enemy_spawn_chance = cfg.enemy_spawn_chance
	if OS.get_environment("STRESS_W1") != "":
		gen.weight_1_connection = int(OS.get_environment("STRESS_W1"))   # dead-end weight (adverse tests)
	if OS.get_environment("STRESS_ATTEMPTS") != "":
		gen.max_layout_attempts = int(OS.get_environment("STRESS_ATTEMPTS"))
	gen.setup_generation(root, cfg.starter_module, cfg.branch_modules, cfg.room_connector_module, cfg.end_cap_module)
	seed(seed_value)
	var result: Dictionary = gen.generate_dungeon()
	var mods: Array = gen.placed_modules
	var problems: Array[String] = []
	var ok: bool = bool(result.get("success", false)) and gen.counted_piece_total >= gen.target_piece_count
	if not ok:
		problems.append("short")
	if gen.registered_typed_spawns.size() == 0:
		problems.append("no_spawns")
	if gen.open_connections.size() != 0:
		problems.append("open_left")

	var reach := _reachable(mods)
	# Code-built wall plugs have no doorway markers and are not part of the walkable graph.
	var walkable := 0
	for m in mods:
		if not _doors(m).is_empty():
			walkable += 1
	var reach_walkable := 0
	for i in reach.keys():
		if not _doors(mods[i]).is_empty():
			reach_walkable += 1
	if reach_walkable != walkable:
		problems.append("disconnected:%d/%d" % [reach_walkable, walkable])
	var bad_spawn := 0
	for entry in gen.registered_typed_spawns:
		var idx: int = _module_index(gen, mods, entry.get("position", Vector3.ZERO))
		if idx < 0 or not reach.has(idx):
			bad_spawn += 1
	if bad_spawn > 0:
		problems.append("unreachable_spawns:%d" % bad_spawn)

	var dead_end_rooms := 0
	for m in mods:
		if m.has_meta("counts_toward_goal") and bool(m.get_meta("counts_toward_goal")) and not (m.has_meta("is_end_cap") and bool(m.get_meta("is_end_cap"))) \
				and m.find_children("Connection_*", "Node3D", true, false).size() == 1:
			dead_end_rooms += 1

	var chests := 0
	var chest_bad := 0
	var portal_ok := -1
	var guards_bad := 0
	if full:
		for i in 4:
			await get_tree().physics_frame
		var mgr: Node3D = (load("res://scripts/chest_manager.gd") as GDScript).new()
		mgr.set_process(false)
		mgr.chest_spawn_chance = 1.0
		root.add_child(mgr)
		mgr._spawn_all_chests()
		await get_tree().physics_frame
		var space: PhysicsDirectSpaceState3D = root.get_world_3d().direct_space_state
		for c: Node3D in get_tree().get_nodes_in_group("chest"):
			chests += 1
			var bad: bool = not gen.is_position_inside_dungeon(c.global_position)
			var idx: int = _module_index(gen, mods, c.global_position)
			if idx < 0 or not reach.has(idx):
				bad = true
			var q := PhysicsShapeQueryParameters3D.new()
			var bs := BoxShape3D.new()
			bs.size = Vector3(0.7, 0.5, 0.4)
			q.shape = bs
			q.transform = c.global_transform * Transform3D(Basis(), Vector3(0, 0.3, 0))
			q.collision_mask = 1
			for hit in space.intersect_shape(q, 8):
				if PhysicsUtil.is_world_geometry(hit.get("collider")):
					bad = true
					break
			if bad:
				chest_bad += 1
		if chest_bad > 0:
			problems.append("bad_chests:%d" % chest_bad)

		var portal := Node3D.new()
		portal.set_script(load("res://scripts/portal_manager.gd"))
		root.add_child(portal)
		portal._dungeon_gen = gen
		var pp: Vector3 = portal._pick_portal_position()
		var pidx: int = _module_index(gen, mods, pp)
		portal_ok = 1 if (pp != Vector3.ZERO and gen.is_position_inside_dungeon(pp) and pidx >= 0 and reach.has(pidx)) else 0
		if portal_ok == 0:
			problems.append("portal_unreachable")
		var origins: Array = portal._get_spawn_origins(pp, 25)
		for o in origins:
			var gpos: Vector3 = portal._valid_guard_position(o, pp)
			var gidx: int = _module_index(gen, mods, gpos)
			if not gen.is_position_inside_dungeon(gpos) or gidx < 0 or not reach.has(gidx):
				guards_bad += 1
		if guards_bad > 0:
			problems.append("bad_guards:%d" % guards_bad)

	var hist: Array = []
	for h in gen.layout_history:
		hist.append("%s/%d" % [h.get("stop", "?"), h.get("rooms", 0)])
	var diag := ""
	if not gen.layout_history.is_empty():
		var d: Dictionary = gen.layout_history[gen.layout_history.size() - 1]
		diag = "fail%d:caps%d:plugs%d:code%d:blocked%d:deadends%d:doorretries%d" % [d.get("attach_fail", 0), d.get("end_caps", 0), d.get("wall_plugs", 0), d.get("code_plugs", 0), d.get("blocked", 0), d.get("dead_end_rooms", 0), d.get("last_door_retries", 0)]
	print("STRESS seed=%d ok=%s attempts=%d rooms=%d spawns=%d dead_end_rooms=%d chests=%d portal_ok=%d history=%s diag=%s problems=%s" % [
		seed_value, str(problems.is_empty()), gen.layout_attempts, gen.counted_piece_total, gen.registered_typed_spawns.size(),
		dead_end_rooms, chests, portal_ok, ",".join(hist), diag, ",".join(problems) if not problems.is_empty() else "-"])
	cfg.free()
	get_tree().quit(0 if problems.is_empty() else 1)
