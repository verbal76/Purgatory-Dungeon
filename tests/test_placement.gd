extends Node
## Functional placement invariants for generated objects (not aesthetics): everything the
## game places must be inside the dungeon, not embedded in wall geometry, and stand on
## walkable floor. One seed per process (PLACE_SEED, default 11).

const SETTLE_FRAMES := 600

var _fails: int = 0
var _checks: int = 0
var _space: PhysicsDirectSpaceState3D
var _gen: Node


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _embedded(p: Vector3, radius: float = 0.1) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	var s := SphereShape3D.new()
	s.radius = radius
	q.shape = s
	q.transform = Transform3D(Basis(), p)
	q.collision_mask = 1
	for hit in _space.intersect_shape(q, 8):
		if PhysicsUtil.is_world_geometry(hit.get("collider")):
			return true
	return false


func _floor_below(p: Vector3, reach: float) -> bool:
	var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 0.5, 0), p + Vector3(0, -reach, 0))
	q.collision_mask = 1
	var r := PhysicsUtil.ray_world(_space, q)
	return not r.is_empty()


# test_point = where to probe for being inside a wall; reach = how far below we accept floor.
func _audit(kind: String, points: Array, probe_lift: float, reach: float) -> void:
	var outside := 0
	var embedded := 0
	var no_floor := 0
	var tight := 0   # informational: within 0.35 m of a wall (wall furniture is flush by design)
	var details: Array[String] = []
	for p: Vector3 in points:
		var bad := false
		if not _gen.is_position_inside_dungeon(p):
			outside += 1
			bad = true
		if _embedded(p + Vector3(0, probe_lift, 0)):
			embedded += 1
			bad = true
		if _embedded(p + Vector3(0, probe_lift, 0), 0.35):
			tight += 1
		if not _floor_below(p, reach):
			no_floor += 1
			bad = true
		if bad and details.size() < 4:
			details.append("(%.1f, %.1f, %.1f)" % [p.x, p.y, p.z])
	print("  placement %s: %d checked, outside=%d embedded=%d no_floor=%d (within 0.35 m of a wall: %d) %s" % [kind, points.size(), outside, embedded, no_floor, tight, ", ".join(details)])
	_check(outside == 0, "%s: all inside the dungeon (%d outside)" % [kind, outside])
	_check(embedded == 0, "%s: none embedded in wall geometry (%d embedded)" % [kind, embedded])
	_check(no_floor == 0, "%s: all have floor beneath them (%d floating)" % [kind, no_floor])


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	var seed_value := int(OS.get_environment("PLACE_SEED")) if OS.get_environment("PLACE_SEED") != "" else 11
	GlobalRunData.character_class = "barbarian"
	GlobalRunData.seed_hash = seed_value
	var main: Node = (load("res://scenes/Purgatory_Dungeon_main_game_file.tscn") as PackedScene).instantiate()
	add_child(main)
	await _frames(SETTLE_FRAMES)
	_gen = main.get_node("DungeonGenerationFunction")
	var player: Node3D = main.get_node("Player")
	_space = player.get_world_3d().direct_space_state
	print("placement seed %d: %d modules" % [seed_value, _gen.placed_modules.size()])

	var orbs: Array = []
	for o in main.get_node("HealthOrbManager")._orbs:
		if o.root != null:
			orbs.append(o.root.global_position)
	_check(orbs.size() > 0, "orbs were placed")
	_audit("orbs", orbs, 0.0, 6.0)

	var chests: Array = []
	var chest_nodes := get_tree().get_nodes_in_group("chest")
	for c in chest_nodes:
		chests.append(c.global_position)
	# NOTE: currently 0 chests spawn, by design of the module set: the only end-cap module is a
	# solid 2 m wall slab, so ChestManager's size gate rejects every end cap. Enabling chests
	# needs a design decision about where they live; this audit guards against any future
	# placement putting one inside a wall.
	print("  metric: %d chests placed" % chest_nodes.size())
	_audit("chests", chests, 0.6, 2.0)
	# A chest's real collision box (0.8 x 0.6 x 0.5) must not overlap any wall.
	var box_overlaps := 0
	for c: Node3D in chest_nodes:
		var q := PhysicsShapeQueryParameters3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(0.7, 0.5, 0.4)   # slightly inside the chest's 0.8 x 0.6 x 0.5 box
		q.shape = bs
		q.transform = c.global_transform * Transform3D(Basis(), Vector3(0, 0.3, 0))
		q.collision_mask = 1
		for hit in _space.intersect_shape(q, 8):
			if PhysicsUtil.is_world_geometry(hit.get("collider")):
				box_overlaps += 1
				break
	_check(box_overlaps == 0, "no chest collision box overlaps a wall (%d)" % box_overlaps)

	var props: Array = []
	for c in main.get_node("PropSpawner").get_children():
		if c is RigidBody3D:
			props.append(c.global_position)
	_check(props.size() > 0, "props were placed")
	_audit("props", props, 0.6, 2.0)

	var globes: Array = []
	for g in GlobeManager._all_globes:
		if is_instance_valid(g):
			globes.append(g.global_position)
	if globes.size() > 0:
		_audit("globes", globes, 0.0, 6.0)

	# Orb spawn points recycle instead of running out for good.
	var orb_mgr = main.get_node("HealthOrbManager")
	for pt in orb_mgr._spawn_points:
		orb_mgr._exhausted_spawn_points[str(pt)] = true
	_check(orb_mgr._pick_fresh_spawn_point() != Vector3.ZERO, "orb spawn points recycle once all have been used")

	# Every position the portal could choose (random draw from the last placed modules).
	var portal := Node3D.new()
	portal.set_script(load("res://scripts/portal_manager.gd"))
	portal._dungeon_gen = _gen
	var candidates := {}
	for i in 80:
		var p: Vector3 = portal._pick_portal_position()
		candidates[p] = true
	portal.free()
	_audit("portal candidates", candidates.keys(), 0.0, 6.0)

	print("test_placement: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
