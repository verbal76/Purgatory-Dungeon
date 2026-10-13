extends Node
## The dungeon entry is staged: the layout is generated in slices (generate_dungeon_async) and the population
## (props, chests, orbs, traps, room locks, enemies) is placed nearest-the-player first under a per-frame budget.
## This test proves staging changes WHEN things are built, never WHAT is built:
##   1. the sliced generation gives exactly the dungeon the synchronous one gives for the same seed
##      (modules, spawn points, waypoints, torches, physics bodies);
##   2. at hand-over (entry_ready) the player's neighbourhood is complete: floor and walls under and around the
##      spawn, a torch in every nearby room, props in the nearby rooms, the orbs and the first enemy wave;
##      the loading screen has not started fading before that and does start once it is;
##   3. the background stages finish (entry_complete) with the full population.
## One seed per process (ENTRY_TEST_SEED, default 7), like the other generation tests.

const MAIN_SCENE := "res://scenes/Purgatory_Dungeon_main_game_file.tscn"
const GEN_SCENE := "res://scenes/dungeon_generation_function.tscn"

var _fails: int = 0
var _checks: int = 0
var _cfg: Node


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _build(seed_value: int, budget_us: int) -> Dictionary:
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
	var result: Dictionary
	if budget_us > 0:
		result = await gen.generate_dungeon_async(budget_us)
	else:
		result = gen.generate_dungeon()
	return {"root": root, "gen": gen, "result": result}


func _state(gen: Node) -> Dictionary:
	var sig := PackedStringArray()
	for m in gen.placed_modules:
		var xf: Transform3D = m.global_transform
		sig.append("%s@%.3f,%.3f,%.3f/%.3f,%.3f" % [m.scene_file_path.get_file(), xf.origin.x, xf.origin.y, xf.origin.z, xf.basis.x.x, xf.basis.x.z])
	var spawns := PackedStringArray()
	for sp in gen.registered_typed_spawns:
		var p: Vector3 = sp["position"]
		spawns.append("%d@%.3f,%.3f,%.3f" % [int(sp["type"]), p.x, p.y, p.z])
	var wps := PackedStringArray()
	for w in gen.registered_waypoints:
		wps.append("%.3f,%.3f,%.3f" % [w.x, w.y, w.z])
	var torches := PackedStringArray()
	for t in gen.registered_torches:
		var tp: Vector3 = (t as Node3D).global_position
		torches.append("%.3f,%.3f,%.3f" % [tp.x, tp.y, tp.z])
	var bodies := 0
	var stack: Array = [gen.get_parent()]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is CollisionObject3D:
			bodies += 1
		stack.append_array(n.get_children())
	return {"sig": sig, "spawns": spawns, "wps": wps, "torches": torches, "bodies": bodies,
			"rooms": gen.counted_piece_total, "open": gen.open_connections.size()}


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	var seed_value := int(OS.get_environment("ENTRY_TEST_SEED")) if OS.get_environment("ENTRY_TEST_SEED") != "" else 7
	_cfg = (load(MAIN_SCENE) as PackedScene).instantiate()

	# ── 1. sliced generation == synchronous generation ──────────────────────────────────────────────────────
	var sync_built: Dictionary = await _build(seed_value, 0)
	var sync_state: Dictionary = _state(sync_built["gen"])
	sync_built["root"].queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	var t0 := Time.get_ticks_msec()
	var async_built: Dictionary = await _build(seed_value, 3000)
	var wall_ms := Time.get_ticks_msec() - t0
	var gen_a: Node = async_built["gen"]
	var async_state: Dictionary = _state(gen_a)
	_check(bool(async_built["result"].get("success", false)), "sliced generation succeeds")
	_check(int(gen_a.gen_stats.get("slices", 0)) > 3, "the sliced generation really gave frames back (%d slices, %d ms)" % [int(gen_a.gen_stats.get("slices", 0)), wall_ms])
	_check(async_state["sig"] == sync_state["sig"], "sliced generation places the same modules at the same transforms (%d)" % sync_state["sig"].size())
	_check(async_state["spawns"] == sync_state["spawns"], "same enemy spawn points (%d)" % sync_state["spawns"].size())
	_check(async_state["wps"] == sync_state["wps"], "same waypoint graph (%d)" % sync_state["wps"].size())
	_check(async_state["torches"] == sync_state["torches"], "same torches (%d)" % sync_state["torches"].size())
	_check(async_state["bodies"] == sync_state["bodies"], "same number of physics bodies (%d)" % sync_state["bodies"])
	_check(async_state["rooms"] == sync_state["rooms"] and async_state["open"] == sync_state["open"], "same room count and no open doorways")
	# The candidate pool must be gone (its bodies would sit in the physics space at stale transforms).
	_check(not async_built["root"].has_node("LayoutCandidates"), "the layout candidates are freed after generation")
	async_built["root"].queue_free()
	await get_tree().process_frame
	_cfg.free()

	# ── 2./3. the real entry: hand-over state and background completion ─────────────────────────────────────
	GlobalRunData.character_class = "barbarian"
	GlobalRunData.seed_hash = seed_value
	var main: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	add_child(main)
	var t_wait := Time.get_ticks_msec()
	while not bool(main.entry_is_ready) and Time.get_ticks_msec() - t_wait < 90000:
		await get_tree().process_frame
	var waited: float = float(Time.get_ticks_msec() - t_wait) / 1000.0
	_check(bool(main.entry_is_ready), "entry_ready is reached (%.1f s)" % waited)
	var loading: Node = _find_loading(main)
	_check(loading != null and not bool(loading.get("is_fading")), "the loading screen is still up at the moment the neighbourhood completes")
	var gen: Node = main.get_node("DungeonGenerationFunction")
	var player: Node3D = main.get_node("Player")
	var origin: Vector3 = player.global_position
	var radius: float = main.NEAR_RADIUS
	var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state

	var near_modules: Array = []
	for m in gen.placed_modules:
		if not is_instance_valid(m):
			continue
		var a: AABB = gen.get_module_aabb(m)
		if a.size == Vector3.ZERO:
			continue
		var c := a.get_center()
		if Vector2(c.x - origin.x, c.z - origin.z).length() <= radius:
			near_modules.append(m)
	_check(near_modules.size() >= 3, "the spawn has a neighbourhood of rooms (%d modules within %.0f m)" % [near_modules.size(), radius])

	# Collision under the player and in every near module: a ray down from each module centre finds geometry.
	var no_floor := 0
	for m in near_modules:
		var c: Vector3 = gen.get_module_aabb(m).get_center()
		var rq := PhysicsRayQueryParameters3D.create(Vector3(c.x, c.y + 3.0, c.z), Vector3(c.x, c.y - 6.0, c.z))
		rq.collision_mask = 1
		# a hit anywhere along the column or a hit from beside: modules like L-rooms may have a wall at the centre
		var hit := not space.intersect_ray(rq).is_empty()
		if not hit:
			var rq2 := PhysicsRayQueryParameters3D.create(c + Vector3(0, 1.0, 0), c + Vector3(8, 1.0, 0))
			rq2.collision_mask = 1
			hit = not space.intersect_ray(rq2).is_empty()
		if not hit:
			no_floor += 1
	_check(no_floor == 0, "collision exists in every near module at hand-over (%d without)" % no_floor)
	var down := PhysicsRayQueryParameters3D.create(origin, origin + Vector3(0, -6, 0))
	down.collision_mask = 1
	_check(not space.intersect_ray(down).is_empty(), "there is floor under the player")

	# Light: every near module that has geometry carries a registered torch.
	var torch_parents := {}
	for t in gen.registered_torches:
		if is_instance_valid(t):
			torch_parents[t.get_parent()] = true
	var dark := 0
	for m in near_modules:
		if not torch_parents.has(m):
			dark += 1
	_check(dark == 0, "every near module has a torch at hand-over (%d dark)" % dark)

	# Props: the rooms around the spawn are furnished, the prop worker reports its near field done.
	var props: Node = main.get_node("PropSpawner")
	_check(bool(props.stage_near_done), "the prop spawner finished the near field")
	var rooms_with_props := 0
	var goal_rooms := 0
	for m in near_modules:
		if not bool(m.get_meta("counts_toward_goal", false)):
			continue
		goal_rooms += 1
		var a: AABB = gen.get_module_aabb(m).grow(0.5)
		for p in props.get_children():
			if p is Node3D and a.has_point((p as Node3D).global_position):
				rooms_with_props += 1
				break
	_check(goal_rooms > 0 and rooms_with_props * 10 >= goal_rooms * 7, "most near rooms are furnished (%d of %d)" % [rooms_with_props, goal_rooms])
	_check(bool(main.get_node("ChestManager").stage_near_done), "the chest manager finished the near field")

	# Orbs and the first enemy wave exist.
	var orbs: Node = main.get_node("HealthOrbManager")
	_check(orbs._orbs.size() == orbs.orb_count, "all %d health orbs exist at hand-over (%d)" % [orbs.orb_count, orbs._orbs.size()])
	var enemy_mgr: Node = main.get_node("EnemyManager")
	_check(bool(enemy_mgr._initial_spawn_done) or enemy_mgr._all_spawns.is_empty(), "the first enemy wave exists at hand-over")
	_check(enemy_mgr._live_count <= enemy_mgr._current_pop_cap, "proximity rule: the live count stays within the population cap (%d/%d)" % [enemy_mgr._live_count, enemy_mgr._current_pop_cap])
	_check(enemy_mgr._live_count < gen.registered_typed_spawns.size() / 4, "enemies are not all spawned at load (%d live of %d spawn points)" % [enemy_mgr._live_count, gen.registered_typed_spawns.size()])

	# The loading screen fades only after the neighbourhood is complete (it needs a few settle frames).
	var fading_frames := 0
	while loading != null and is_instance_valid(loading) and not bool(loading.get("is_fading")) and fading_frames < 600:
		await get_tree().process_frame
		fading_frames += 1
	_check(loading == null or not is_instance_valid(loading) or bool(loading.get("is_fading")), "the loading screen starts its fade after hand-over")

	# Background completion.
	t_wait = Time.get_ticks_msec()
	while not bool(main.entry_is_complete) and Time.get_ticks_msec() - t_wait < 120000:
		await get_tree().process_frame
	waited = float(Time.get_ticks_msec() - t_wait) / 1000.0
	_check(bool(main.entry_is_complete), "the background stages complete (%.1f s)" % waited)
	_check(props.get_child_count() > 100, "the whole dungeon is furnished (%d props)" % props.get_child_count())
	_check(orbs._spawn_points.size() > orbs.orb_count, "orb respawn points were collected for the whole dungeon (%d)" % orbs._spawn_points.size())
	var trap_mgr: Node = main.get_node("TrapManager")
	_check(bool(trap_mgr.stage_done) and trap_mgr._trap_nodes.size() > 0, "traps are armed (%d)" % trap_mgr._trap_nodes.size())
	var locks: Node = main.get_node("RoomLockManager")
	var large := 0
	var triggers := 0
	for m in gen.placed_modules:
		if is_instance_valid(m) and m.scene_file_path in locks.LARGE_ROOM_PATHS:
			large += 1
			for c in m.get_children():
				if c is Area3D and c.has_meta("lock_module"):
					triggers += 1
	_check(triggers == large, "every large room has its lock trigger (%d of %d)" % [triggers, large])
	_check(GlobeManager._all_globes.size() == GlobeManager.globe_count, "all %d globes exist (%d)" % [GlobeManager.globe_count, GlobeManager._all_globes.size()])

	print("test_entry_staging (seed %d): %d checks, %d failures" % [seed_value, _checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _find_loading(main: Node) -> Node:
	var p := main.get_node_or_null("Player")
	if p == null:
		return null
	for c in p.get_children():
		if c is CanvasLayer and c.get_script() != null and String(c.get_script().resource_path).ends_with("loading_screen.gd"):
			return c
	return null
