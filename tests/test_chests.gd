extends Node
## Chests used to be impossible (the gate only accepted end-cap modules and the only end cap is a
## solid wall slab). They now live in dead-end rooms. One seed per process (CHEST_SEED, default 11).

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	var seed_value := int(OS.get_environment("CHEST_SEED")) if OS.get_environment("CHEST_SEED") != "" else 11
	GlobalRunData.character_class = "barbarian"
	GlobalRunData.seed_hash = seed_value
	var main: Node = (load("res://scenes/Purgatory_Dungeon_main_game_file.tscn") as PackedScene).instantiate()
	add_child(main)
	await _frames(300)
	var gen = main.get_node("DungeonGenerationFunction")
	var mgr = main.get_node("ChestManager")
	var space: PhysicsDirectSpaceState3D = main.get_node("Player").get_world_3d().direct_space_state

	# Deterministic: every candidate room gets a chest.
	for c in get_tree().get_nodes_in_group("chest"):
		c.free()
	var candidates: int = 0
	for m in gen.placed_modules:
		# Dead-end rooms only: the wall-slab end caps also pass the candidate test but are far too thin.
		if is_instance_valid(m) and mgr._is_chest_candidate(m) and not (m.has_meta("is_end_cap") and bool(m.get_meta("is_end_cap"))):
			candidates += 1
	mgr.chest_spawn_chance = 1.0
	mgr._spawn_all_chests()
	await _frames(2)
	var chests: Array = get_tree().get_nodes_in_group("chest")
	print("chest seed %d: %d dead-end candidates, %d chests placed" % [seed_value, candidates, chests.size()])
	_check(candidates > 0, "the dungeon has dead-end rooms that can host a chest (%d)" % candidates)
	_check(chests.size() > 0, "chests are spawned")
	_check(chests.size() <= candidates, "at most one chest per dead-end room (%d chests, %d rooms)" % [chests.size(), candidates])
	_check(chests.size() * 2 >= candidates, "most dead-end rooms host a chest (%d of %d)" % [chests.size(), candidates])

	var outside := 0
	var overlaps := 0
	var floating := 0
	for c: Node3D in chests:
		if not gen.is_position_inside_dungeon(c.global_position):
			outside += 1
		var q := PhysicsShapeQueryParameters3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(0.7, 0.5, 0.4)
		q.shape = bs
		q.transform = c.global_transform * Transform3D(Basis(), Vector3(0, 0.3, 0))
		q.collision_mask = 1
		for hit in space.intersect_shape(q, 8):
			if PhysicsUtil.is_world_geometry(hit.get("collider")):
				overlaps += 1
				break
		var rq := PhysicsRayQueryParameters3D.create(c.global_position + Vector3(0, 0.5, 0), c.global_position + Vector3(0, -2.0, 0))
		rq.collision_mask = 1
		if PhysicsUtil.ray_world(space, rq).is_empty():
			floating += 1
		_check(str(c.color) in ["bronze", "silver", "gold"], "chest colour is valid (%s)" % c.color)
	_check(outside == 0, "every chest is inside the dungeon (%d outside)" % outside)
	_check(overlaps == 0, "no chest overlaps a wall (%d)" % overlaps)
	_check(floating == 0, "every chest stands on a floor (%d floating)" % floating)

	# The end-cap slab alone must never host a chest (it is a solid 2 m wall).
	var slab_hosts := 0
	for m in gen.placed_modules:
		if is_instance_valid(m) and m.has_meta("is_end_cap") and bool(m.get_meta("is_end_cap")):
			for c: Node3D in chests:
				if gen.get_module_aabb(m).grow(0.5).has_point(c.global_position):
					slab_hosts += 1
	_check(slab_hosts == 0, "no chest sits inside the wall-slab end caps (%d)" % slab_hosts)

	# Chest meshes get the shared chest material (the FBX texture paths are broken).
	var textured := 0
	for c in chests:
		for mi in c.find_children("*", "MeshInstance3D", true, false):
			var mo = (mi as MeshInstance3D).material_override
			if mo is StandardMaterial3D and (mo as StandardMaterial3D).albedo_texture != null:
				textured += 1
				break
	_check(textured == chests.size(), "every chest mesh has the textured chest material (%d of %d)" % [textured, chests.size()])

	# Keys now have something to open: spending a key opens the chest.
	if chests.size() > 0:
		var chest = chests[0]
		PlayerWallet.add_key(chest.color)
		var keys_before: int = PlayerWallet.get_key_count(chest.color)
		chest._attempt_unlock()
		_check(chest._opened and PlayerWallet.get_key_count(chest.color) == keys_before - 1, "a matching key opens the chest and is consumed")
		var other_colors: Array = ["bronze", "silver", "gold"]
		other_colors.erase(chest.color)
		var chest2 = chests[chests.size() - 1]
		if chest2 != chest:
			var wrong: String = other_colors[0] if chest2.color == chest.color else chest2.color
			_check(not chest2._opened, "a locked chest stays closed without its key")

	print("test_chests (seed %d): %d checks, %d failures" % [seed_value, _checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
