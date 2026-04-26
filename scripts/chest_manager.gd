# ============================================================
#  FILE: chest_manager.gd
#  PATH: res://scripts/chest_manager.gd
#  DESCRIPTION: After the dungeon is generated and populated
#               with props, scan every end-cap module and roll
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


func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	_spawn_all_chests()


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
		# Only spawn in real end-cap rooms, not regular rooms / connectors / plugs.
		if not (mod.has_meta("is_end_cap") and bool(mod.get_meta("is_end_cap"))):
			continue
		if randf() >= chest_spawn_chance:
			continue
		_spawn_chest_in(gen, mod as Node3D)


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
	var conn : Node3D = end_cap.find_child("Connection_A", true, false) as Node3D
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
	var conn : Node3D = end_cap.find_child("Connection_A", true, false) as Node3D
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
