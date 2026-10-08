# ============================================================
#  FILE: chest_manager.gd
#  PATH: res://scripts/chest_manager.gd
#  DESCRIPTION: After the dungeon is generated and populated
#               with props, scan every dead-end room (an end-cap
#               module, or a room with exactly one opening) and roll
#               a chance to place one locked chest in it.
#               Chest colour is uniform-random; each chest is
#               50/50 real or mimic. See scripts/chest.gd for
#               the reveal / reward / mimic-payload logic.
#
#  BOOTED BY: Purgatory_Dungeon_main_game_file._boot_chest_manager()
#             after _boot_prop_spawner(). Waits two frames so
#             the staggered prop-spawn pass has a head start and
#             the dungeon's metadata is fully written.
# ============================================================

extends Node3D

const _ChestScript = preload("res://scripts/chest.gd")
const _COLORS      : Array[String] = ["bronze", "silver", "gold"]

@export var chest_spawn_chance : float = 0.40
@export var mimic_chance       : float = 0.50


# Staged population (see Purgatory_Dungeon_main_game_file.gd): dead-end rooms are visited nearest the player
# first; the coroutine gives the frame back whenever the shared per-frame budget is spent.
var stage_near_done : bool = true
var stage_done : bool = true


func stage_begin(origin: Vector3, near_radius: float) -> void:
	stage_near_done = false
	stage_done = false
	call("_stage_run", origin, near_radius)   # dynamic call: runs as a background coroutine


func _entry_mark(label: String) -> void:
	var main : Node = get_parent()
	if main != null and main.has_method("entry_mark"):
		main.entry_mark(label)


func _stage_run(origin: Vector3, near_radius: float) -> void:
	var main : Node = get_parent()
	var gen : Node = main.get_node_or_null("DungeonGenerationFunction")
	if gen == null:
		push_warning("ChestManager: DungeonGenerationFunction not found.")
		stage_near_done = true
		stage_done = true
		return
	var modules : Array = gen.get_modules_by_distance(origin)
	var near_count : int = gen.count_modules_within(modules, origin, near_radius)
	_entry_mark("chests_begin")
	if near_count == 0:
		stage_near_done = true
	var index : int = 0
	for mod in modules:
		index += 1
		if is_instance_valid(mod) and mod is Node3D and _is_chest_candidate(mod as Node3D) \
				and randf() < chest_spawn_chance:
			_spawn_chest_in(gen, mod as Node3D)
		if index >= near_count:
			stage_near_done = true
		if main.has_method("stage_over") and main.stage_over():
			await get_tree().process_frame
	stage_near_done = true
	stage_done = true
	_entry_mark("chests_end")


func _spawn_all_chests() -> void:
	var gen : Node = get_parent().get_node_or_null("DungeonGenerationFunction")
	if gen == null:
		push_warning("ChestManager: DungeonGenerationFunction not found.")
		return

	var modules : Array = gen.get("placed_modules") if gen.get("placed_modules") != null else []
	if modules.is_empty():
		push_warning("ChestManager: placed_modules empty.")
		return

	for mod in modules:
		if not (mod is Node3D) or not is_instance_valid(mod):
			continue
		if not _is_chest_candidate(mod as Node3D):
			continue
		if randf() >= chest_spawn_chance:
			continue
		_spawn_chest_in(gen, mod as Node3D)


# A chest lives in a dead end: a real end-cap module, or a room that has exactly one opening.
# (The only end-cap module in the module set is a solid 2 m wall slab, so on its own it can never
# host a chest; one-opening rooms are the dead ends the generator actually produces.) Connectors,
# plugs and the start room are never candidates.
func _is_chest_candidate(mod: Node3D) -> bool:
	if mod.has_meta("is_end_cap") and bool(mod.get_meta("is_end_cap")):
		return true
	if not (mod.has_meta("counts_toward_goal") and bool(mod.get_meta("counts_toward_goal"))):
		return false
	if mod.find_child("Player_Spawn", true, false) != null:
		return false
	return _connections_of(mod).size() == 1


# The room's doorway marker (a dead end has one).
func _doorway_of(mod: Node3D) -> Node3D:
	var conns : Array = _connections_of(mod)
	return conns[0] as Node3D if not conns.is_empty() else null


func _spawn_chest_in(gen: Node, end_cap: Node3D) -> void:
	# Lift Y by a small margin so the chest clears the floor-lip that most
	# end-cap scenes have running along the perimeter.
	const FLOOR_CLEARANCE : float = 0.20
	# 1/3 of the way from the room centre toward the doorway. Chest stays
	# mostly central with a subtle lean toward the entry so the player sees
	# its front face as they walk in.
	const DOORWAY_LERP : float = 1.0 / 3.0
	# Minimum distance from the nearest wall. Keeps the chest from ever
	# clipping into geometry even on tight end-caps with uneven footprints.
	const WALL_CLEARANCE : float = 1.0

	# Without a valid AABB there's no way to know the room shape — skip.
	if not gen.has_method("get_module_aabb"):
		return
	var aabb : AABB = gen.get_module_aabb(end_cap)
	if aabb.size == Vector3.ZERO:
		return
	# If the room is genuinely too small to fit a chest with wall clearance,
	# skip rather than wedge one against the wall.
	if aabb.size.x < (WALL_CLEARANCE * 2.0 + 0.8) or aabb.size.z < (WALL_CLEARANCE * 2.0 + 0.8):
		return

	var centre : Vector3 = aabb.get_center()
	var floor_y : float  = end_cap.global_position.y + FLOOR_CLEARANCE

	# Default to centre, then lerp toward the doorway if we can find one.
	var pos_xz : Vector2 = Vector2(centre.x, centre.z)
	var conn : Node3D = _doorway_of(end_cap)
	if conn != null:
		var door_xz : Vector2 = Vector2(conn.global_position.x, conn.global_position.z)
		pos_xz = pos_xz.lerp(door_xz, DOORWAY_LERP)

	# Clamp the XZ footprint so the chest is always at least WALL_CLEARANCE
	# metres from the AABB edges. Fixes "chest flush against a wall" cases
	# where a doorway happens to sit unusually close to a corner.
	pos_xz.x = clampf(pos_xz.x,
		aabb.position.x + WALL_CLEARANCE,
		aabb.position.x + aabb.size.x - WALL_CLEARANCE)
	pos_xz.y = clampf(pos_xz.y,
		aabb.position.z + WALL_CLEARANCE,
		aabb.position.z + aabb.size.z - WALL_CLEARANCE)

	var pos : Vector3 = Vector3(pos_xz.x, floor_y, pos_xz.y)

	# A room's bounding box can include wall volume (L-shaped rooms), so check the spot is open
	# and fall back to the generator's own safe interior point before giving up on this room.
	if not _spot_is_clear(gen, pos):
		pos = Vector3.ZERO
		if gen.has_method("get_random_safe_interior_point"):
			for _try in 4:
				var p : Vector3 = gen.get_random_safe_interior_point(end_cap, 0.9, 1.25)
				if p == Vector3.ZERO:
					continue
				var candidate := Vector3(p.x, floor_y, p.z)
				if _spot_is_clear(gen, candidate):
					pos = candidate
					break
		if pos == Vector3.ZERO:
			return

	var chest : StaticBody3D = _ChestScript.new()
	chest.color    = _COLORS[randi() % _COLORS.size()]
	chest.is_mimic = randf() < mimic_chance
	chest.rotation.y = _yaw_facing_doorway(end_cap, pos)

	get_parent().add_child(chest)
	chest.global_position = pos


# Rotates the chest so its local -Z points at the end-cap's Connection_A
# marker (the hallway opening). The player entering the room sees the
# chest's front straight away.
func _yaw_facing_doorway(end_cap: Node3D, chest_pos: Vector3) -> float:
	var conn : Node3D = _doorway_of(end_cap)
	if conn == null:
		return randf() * TAU
	var dir : Vector3 = conn.global_position - chest_pos
	var flat := Vector2(dir.x, dir.z)
	if flat.length_squared() < 0.001:
		return randf() * TAU
	flat = flat.normalized()
	# Rotating the local -Z axis (0,0,-1) by angle a around Y yields
	# (-sin a, 0, -cos a). Set that equal to (flat.x, 0, flat.y):
	#   sin a = -flat.x, cos a = -flat.y → a = atan2(-flat.x, -flat.y).
	return atan2(-flat.x, -flat.y)


# Open space for the chest (about 1 m wide, 1 m tall) and inside the dungeon.
func _spot_is_clear(gen: Node, pos: Vector3) -> bool:
	if gen.has_method("is_position_inside_dungeon") and not gen.is_position_inside_dungeon(pos):
		return false
	if not gen.has_method("is_position_clear"):
		return true
	return gen.is_position_clear(pos + Vector3(0.0, 0.5, 0.0), 0.5) \
			and gen.is_position_clear(pos + Vector3(0.0, 1.0, 0.0), 0.4)


# The generator keeps each module's Connection_* markers (found once); fall back to a tree search.
func _connections_of(mod: Node3D) -> Array:
	var gen : Node = get_parent().get_node_or_null("DungeonGenerationFunction") if get_parent() != null else null
	if gen != null and gen.has_method("get_module_connections"):
		return gen.get_module_connections(mod)
	return mod.find_children("Connection_*", "Node3D", true, false)
