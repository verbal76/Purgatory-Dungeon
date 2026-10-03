# ==============================================================================
#  FILE: dungeon_generation_function.gd
#  PATH: res://scripts/dungeon_generation_function.gd
#  DESCRIPTION: Core procedural generator. Decoupled from enemy instantiation
#               to guarantee zero FPS drops during generation.
#  MOD NOTES:
#  - Added registered_typed_spawns: replaces registered_enemy_spawns for
#    the new enemy system. Each entry carries a "type" field:
#      type 1 = Brute spawn (easy_enemy_spawnpoint)
#      type 2 = Mage spawn  (easy_enemy_spawnpoint2)
#      type 3 = Buffed random spawn (easy_enemy_spawnpoint3)
#  - Added registered_waypoints: Array[Vector3] built from Connection_A/B
#    and coursec1-6 markers. Passed to EnemyManager for the waypoint
#    navigation system that replaces the crashed NavMesh approach.
#  - _register_module() now also calls _register_waypoints_from_module().
#  - SURGICAL FIX: _get_module_cached_aabb() now uses an 'aabb_calculated' 
#    meta flag to prevent frame-by-frame tree traversal on empty modules.
# ==============================================================================
extends Node

@export var torch_scene: PackedScene

@export var target_piece_count: int = 125
@export var total_generation_attempts: int = 20000
@export var attempts_per_connection: int = 100

@export var weight_4_connection: int = 12
@export var weight_3_connection: int = 9
@export var weight_2_connection: int = 3
@export var weight_1_connection: int = 1

@export var overlap_shrink: float = 0.0
@export var connection_nudge: float = 0.04
@export var exclude_keywords: Array[String] = ["boss", "wave", "connector", "end"]

@export var exploration_padding: float = 0.5
@export var enemy_spawn_chance: float = 1.0

# ── Generation output arrays — read by main game file after generate_dungeon() ──

# All placed dungeon modules
var placed_modules: Array[Node3D] = []

# Unused connections eligible for module attachment during generation
var open_connections: Array[Node3D] = []

# Weighted scene pool built from branch_modules before layout generation
var weighted_scene_pool: Array[PackedScene] = []

# TYPED spawn data handed to EnemyManager.
# Each entry: { position: Vector3, rotation: Vector3, type: int }
# type 1 = Brute, type 2 = Mage, type 3 = Buffed random
var registered_typed_spawns: Array[Dictionary] = []

# Legacy compatibility — mirrors registered_typed_spawns as plain position/rotation.
# Kept so any code that reads registered_enemy_spawns doesn't break immediately.
var registered_enemy_spawns: Array[Dictionary] = []

# Waypoint graph built from Connection_A/B and coursec1-6 markers.
# Passed to each enemy via initialize_waypoints() so they can navigate
# the dungeon without a NavMesh.
var registered_waypoints: Array[Vector3] = []

# Torch instances spawned by _try_spawn_torches_in_module().
# Passed to TorchDimmingManager on Hardcore runs.
var registered_torches: Array[Node3D] = []

# ── Wall-plug fallback ────────────────────────────────────────────────────────
# A decorative wall section used when neither a room nor the regular end-cap
# module fits on an open connection. Guarantees the player can never see
# outside the dungeon. Does NOT count toward the room goal and does NOT
# register its spawn markers (purely geometry).
const _WALL_PLUG_PATH : String = "res://dungeon modules/new_collision_room_closer_flush.tscn"
var _wall_plug_module : PackedScene = null

# ── Torch placement constants ─────────────────────────────────────────────────
const _TORCH_CEILING_Y   : float = 3.5   # World Y of the dungeon ceiling
const _TORCH_SPHERE_R    : float = 0.18  # Sphere radius — matches torch.tscn
const _TORCH_WALL_SEARCH : float = 2.5   # Max horizontal distance to look for a wall

# Debug counters
var counted_piece_total: int = 0
var enemy_spawn_marker_total: int = 0
var waypoint_total: int = 0
# Fallback-usage counters for T1.1 diagnostics — reset each generate_dungeon().
var wall_plug_count : int = 0
var code_plug_count : int = 0
var blocked_final_count : int = 0

# ── Internal generation state ─────────────────────────────────────────────────
var _main_root: Node3D
var _starter_module: PackedScene
var _branch_modules: Array[PackedScene] = []
var _room_connector_module: PackedScene
var _end_cap_module: PackedScene


# ══════════════════════════════════════════════════════════════════════════════
#  SETUP & GENERATION ENTRY POINT
# ══════════════════════════════════════════════════════════════════════════════

func setup_generation(
	main_root: Node3D,
	starter_module: PackedScene,
	branch_modules: Array[PackedScene],
	room_connector_module: PackedScene,
	end_cap_module: PackedScene
) -> void:
	_main_root             = main_root
	_starter_module        = starter_module
	_branch_modules        = branch_modules.duplicate()
	_room_connector_module = room_connector_module
	_end_cap_module        = end_cap_module


func generate_dungeon() -> Dictionary:
	_reset_generation_state()

	if _main_root == null:            return {"success": false}
	if _starter_module == null:       return {"success": false}
	if _branch_modules.is_empty():    return {"success": false}
	if _room_connector_module == null: return {"success": false}
	if _end_cap_module == null:       return {"success": false}

	# Lazy-load the wall-plug scene once per run.
	if _wall_plug_module == null and ResourceLoader.exists(_WALL_PLUG_PATH):
		_wall_plug_module = load(_WALL_PLUG_PATH)

	_build_weighted_scene_pool()

	var starter: Node3D = _starter_module.instantiate() as Node3D
	_main_root.add_child(starter)
	starter.global_position = Vector3.ZERO
	starter.global_rotation = Vector3.ZERO

	_register_module(starter, true)
	counted_piece_total = 1

	_collect_open_connections(starter)
	_generate_layout()
	_retry_fill_pass()
	_close_open_ends_full_sweep()
	_clean_open_connections()

	print("Dungeon complete. Modules: ", placed_modules.size(),
		  "  Rooms: ", counted_piece_total, " / target ", target_piece_count,
		  "  Typed spawns: ", registered_typed_spawns.size(),
		  "  Waypoints: ", registered_waypoints.size(),
		  "  Open left: ", open_connections.size(),
		  "  Wall plugs: ", wall_plug_count,
		  "  Code plugs: ", code_plug_count,
		  "  Still blocked: ", blocked_final_count)

	return {"success": true, "starter": starter}


# Recovery pass: if the first layout sweep stopped short of target, un-block every
# connection that was flagged blocked (some were rejected only because a neighbour
# hadn't been placed yet) and run _generate_layout() once more. Cheap on runs that
# already hit target — early-exits.
func _retry_fill_pass() -> void:
	if counted_piece_total >= target_piece_count:
		return
	for mod in placed_modules:
		if not is_instance_valid(mod):
			continue
		for conn in _get_connections(mod):
			if conn.has_meta("blocked"):
				conn.set_meta("blocked", false)
	open_connections.clear()
	for mod in placed_modules:
		if is_instance_valid(mod):
			_collect_open_connections(mod)
	_generate_layout()


# ══════════════════════════════════════════════════════════════════════════════
#  MINIMAP & EXPLORATION
# ══════════════════════════════════════════════════════════════════════════════

func update_player_exploration() -> void:
	var player: Node3D = _get_player()
	if player == null: return
	var player_pos: Vector3 = player.global_position

	for module_root in placed_modules:
		if module_root == null or not is_instance_valid(module_root): continue
		if module_root.has_meta("explored") and bool(module_root.get_meta("explored")): continue

		var module_aabb: AABB = _get_module_cached_aabb(module_root)
		if module_aabb.size == Vector3.ZERO: continue
		module_aabb = _expanded_aabb(module_aabb, exploration_padding)

		if module_aabb.has_point(player_pos):
			module_root.set_meta("explored", true)


func get_map_bounds_xz() -> Rect2:
	var modules: Array[Node3D] = get_explorable_modules()
	if modules.is_empty(): return Rect2()
	var started: bool = false
	var min_x: float = 0.0; var min_z: float = 0.0
	var max_x: float = 0.0; var max_z: float = 0.0

	for module_root in modules:
		var aabb: AABB = _get_module_cached_aabb(module_root)
		if aabb.size == Vector3.ZERO: continue
		if not started:
			min_x = aabb.position.x; max_x = aabb.position.x + aabb.size.x
			min_z = aabb.position.z; max_z = aabb.position.z + aabb.size.z
			started = true
		else:
			min_x = min(min_x, aabb.position.x)
			max_x = max(max_x, aabb.position.x + aabb.size.x)
			min_z = min(min_z, aabb.position.z)
			max_z = max(max_z, aabb.position.z + aabb.size.z)

	return Rect2(Vector2(min_x, min_z), Vector2(max_x - min_x, max_z - min_z)) if started else Rect2()


func get_minimap_module_data() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for module_root in get_explorable_modules():
		var aabb: AABB = _get_module_cached_aabb(module_root)
		if aabb.size == Vector3.ZERO: continue
		result.append({
			"node": module_root,
			"name": str(module_root.name),
			"explored": bool(module_root.get_meta("explored")),
			"world_rect": Rect2(Vector2(aabb.position.x, aabb.position.z),
								Vector2(aabb.size.x, aabb.size.z)),
			"world_center": Vector2(aabb.position.x + (aabb.size.x * 0.5),
									aabb.position.z + (aabb.size.z * 0.5)),
			"lock_color": str(module_root.get_meta("lock_color")),
			"lock_overlay_visible": bool(module_root.get_meta("lock_overlay_visible"))
		})
	return result


func get_player_map_position() -> Vector2:
	var player: Node3D = _get_player()
	return Vector2(player.global_position.x, player.global_position.z) if player else Vector2.ZERO


func get_player_map_forward() -> Vector2:
	var player: Node3D = _get_player()
	if player == null: return Vector2.UP
	var forward_3d: Vector3 = -player.global_basis.z.normalized()
	return Vector2(forward_3d.x, forward_3d.z).normalized()


func reveal_all_modules() -> void:
	for module_root in placed_modules:
		if is_instance_valid(module_root):
			module_root.set_meta("explored", true)


func set_lock_overlay_for_all(color_name: String, visible_value: bool) -> void:
	for module_root in placed_modules:
		if is_instance_valid(module_root) and bool(module_root.get_meta("counts_toward_goal")):
			module_root.set_meta("lock_color", color_name)
			module_root.set_meta("lock_overlay_visible", visible_value)


# ══════════════════════════════════════════════════════════════════════════════
#  INTERNAL GENERATION STATE
# ══════════════════════════════════════════════════════════════════════════════

func _reset_generation_state() -> void:
	placed_modules.clear()
	open_connections.clear()
	weighted_scene_pool.clear()
	registered_typed_spawns.clear()
	registered_enemy_spawns.clear()
	registered_waypoints.clear()
	registered_torches.clear()
	counted_piece_total      = 0
	enemy_spawn_marker_total = 0
	waypoint_total           = 0
	wall_plug_count          = 0
	code_plug_count          = 0
	blocked_final_count      = 0


func _get_player() -> Node3D:
	return _main_root.get_node_or_null("Player") as Node3D if _main_root else null


func _build_weighted_scene_pool() -> void:
	weighted_scene_pool.clear()
	for scene in _branch_modules:
		if scene == null: continue
		var path: String = scene.resource_path.to_lower()
		if _matches_excluded_keyword(path): continue
		var weight: int = _weight_from_filename(path)
		for i in range(weight):
			weighted_scene_pool.append(scene)


func _weight_from_filename(path: String) -> int:
	if path.contains("4_opening"):  return weight_4_connection
	if path.contains("3_opening") or path.contains("tee"): return weight_3_connection
	if path.contains("2_opening") or path.contains("hall"): return weight_2_connection
	if path.contains("1_opening") or path.contains("end"): return weight_1_connection
	return weight_2_connection


# ══════════════════════════════════════════════════════════════════════════════
#  LAYOUT GENERATION
# ══════════════════════════════════════════════════════════════════════════════

func _generate_layout() -> void:
	var attempt: int = 0
	while counted_piece_total < target_piece_count and attempt < total_generation_attempts:
		attempt += 1
		_clean_open_connections()
		if open_connections.is_empty(): break

		var target_idx: int = randi() % open_connections.size()
		var target: Node3D = open_connections[target_idx]
		if not is_instance_valid(target) or _is_connection_used(target) or _is_connection_blocked(target):
			open_connections.remove_at(target_idx)
			continue

		var res: Dictionary = _try_attach_connector_then_piece(target)
		if res.get("success", false):
			_register_module(res.get("connector"), false)
			_collect_open_connections(res.get("connector"))
			_register_module(res.get("main"), true)
			_collect_open_connections(res.get("main"))
			counted_piece_total += 1
			continue

		var cap: Node3D = _try_attach_specific_module_to_connection(target, _end_cap_module)
		if cap != null:
			_register_module(cap, false)
			cap.set_meta("is_end_cap", true)
		elif _try_attach_wall_plug(target):
			wall_plug_count += 1
		elif _force_attach_code_plug(target):
			code_plug_count += 1
		else:
			target.set_meta("blocked", true)
			blocked_final_count += 1


func _close_open_ends_full_sweep() -> void:
	var found := true; var safety := 0
	while found and safety < 10:
		safety += 1; found = false
		for target in _get_all_unused_connections_from_all_modules():
			found = true
			var cap: Node3D = _try_attach_specific_module_to_connection(target, _end_cap_module)
			if cap != null:
				_register_module(cap, false)
				cap.set_meta("is_end_cap", true)
			elif _try_attach_wall_plug(target):
				wall_plug_count += 1
			elif _force_attach_code_plug(target):
				code_plug_count += 1
			else:
				target.set_meta("blocked", true)
				blocked_final_count += 1


# Last-ditch cap when neither a room nor the regular end-cap fits. If this
# plug also fails to fit (shouldn't happen in practice per asset design), the
# caller marks the connection blocked. Plug doesn't count toward the room
# goal, but its spawn markers DO register — treated like any other module.
func _try_attach_wall_plug(target: Node3D) -> bool:
	if _wall_plug_module == null:
		return false
	var plug : Node3D = _try_attach_specific_module_to_connection(target, _wall_plug_module)
	if plug == null:
		return false
	_register_module(plug, false)
	return true


# ABSOLUTE FALLBACK — if both the authored end-cap and the wall-plug scene
# refuse to fit at a connection, build a thin box wall in code directly at the
# connection's transform. Has no geometry constraints of its own, so it's
# guaranteed to land; the player can never see outside the dungeon.
# Connection markers sit 2 m above the module floor (local y = 2) and doorways
# are ~4 m wide, so the box is 4.2 m wide × 4.15 m tall × 0.15 m thick and is
# centred at the marker's height offset so it spans floor level to ceiling.
# (It used to be 1.6 × 3.5 centred 1.75 m above the marker, which left the
# lower half of the doorway open.)
func _force_attach_code_plug(target: Node3D) -> bool:
	if target == null or not is_instance_valid(target) or _main_root == null:
		return false

	var plug := StaticBody3D.new()
	plug.name = "CodePlug"
	plug.collision_layer = 1
	plug.collision_mask  = 1
	_main_root.add_child(plug)
	plug.global_transform = target.global_transform
	# Slide the wall half its thickness inward so its face sits flush with
	# the connection plane, not straddling it.
	plug.global_position += plug.global_transform.basis.z * 0.075

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.2, 4.15, 0.15)
	col.shape = box
	col.position = Vector3(0.0, 0.075, 0.0)   # local y -2.0 (floor) .. +2.15 (ceiling)
	plug.add_child(col)

	# Mark the connection used so it doesn't show up in later sweeps.
	_mark_connection_used(target)

	# Track it in placed_modules so minimap/bounds include it, but skip spawn
	# registration (no markers on a code-built plug).
	placed_modules.append(plug)
	plug.set_meta("explored", false)
	plug.set_meta("counts_toward_goal", false)
	plug.set_meta("lock_color", "")
	plug.set_meta("lock_overlay_visible", false)
	return true


func _get_all_unused_connections_from_all_modules() -> Array[Node3D]:
	var res: Array[Node3D] = []
	for mod in placed_modules:
		for conn in _get_connections(mod):
			if is_instance_valid(conn) and not _is_connection_used(conn) and not _is_connection_blocked(conn):
				res.append(conn)
	return res


func _try_attach_connector_then_piece(target: Node3D) -> Dictionary:
	var attempt: int = 0
	while attempt < attempts_per_connection:
		attempt += 1
		var conn_mod: Node3D = _room_connector_module.instantiate()
		_main_root.add_child(conn_mod)
		_reset_module_transform(conn_mod)
		var conns: Array[Node3D] = _get_connections(conn_mod)
		if conns.size() < 2:
			conn_mod.queue_free()
			return {"success": false}
		conns.shuffle()
		var exit: Node3D = null
		var entry: Node3D = null
		for c in conns:
			var other = _get_other_connection(conns, c)
			_reset_module_transform(conn_mod)
			_align_module_to_connection(conn_mod, c, target)
			if not _module_overlaps_anything(conn_mod, target):
				entry = c; exit = other; break
		if entry == null:
			conn_mod.queue_free()
			continue
		var scene: PackedScene = _pick_weighted_scene()
		var main_mod: Node3D = scene.instantiate()
		_main_root.add_child(main_mod)
		_reset_module_transform(main_mod)
		var main_conns: Array[Node3D] = _get_connections(main_mod)
		main_conns.shuffle()
		var main_entry: Node3D = null
		for mc in main_conns:
			_reset_module_transform(main_mod)
			_align_module_to_connection(main_mod, mc, exit)
			if not _module_overlaps_anything(main_mod, exit):
				main_entry = mc; break
		if main_entry:
			_mark_connection_used(target)
			_mark_connection_used(entry)
			_mark_connection_used(exit)
			_mark_connection_used(main_entry)
			return {"success": true, "connector": conn_mod, "main": main_mod}
		main_mod.queue_free()
		conn_mod.queue_free()
	return {"success": false}


func _get_other_connection(conns: Array[Node3D], used: Node3D) -> Node3D:
	for c in conns:
		if c != used: return c
	return null


# ══════════════════════════════════════════════════════════════════════════════
#  MODULE REGISTRATION
#  Called for every module (main rooms, connectors, end caps) as it's placed.
# ══════════════════════════════════════════════════════════════════════════════

func _register_module(mod: Node3D, counts: bool) -> void:
	if mod == null: return
	placed_modules.append(mod)
	mod.set_meta("explored", false)
	mod.set_meta("counts_toward_goal", counts)
	mod.set_meta("lock_color", "")
	mod.set_meta("lock_overlay_visible", false)

	# Register typed enemy spawn points from this module. Every placed module
	# contributes its spawn markers — including wall plugs — so the enemy
	# manager has the widest possible pool of anchors to pick from.
	_register_enemy_spawns_from_module(mod)

	# Register Connection and coursec nodes as navigation waypoints
	_register_waypoints_from_module(mod)

	# Place torch scene instances at Torch marker nodes
	_try_spawn_torches_in_module(mod)


# ── Typed spawn point registration ───────────────────────────────────────────

func _register_enemy_spawns_from_module(mod: Node3D) -> void:
	var points: Array[Node3D] = []
	_find_enemy_spawn_points_recursive(mod, points)
	enemy_spawn_marker_total += points.size()

	for p in points:
		if not is_instance_valid(p): continue
		if randf() > enemy_spawn_chance: continue

		# Determine spawn type from the marker name
		var spawn_type: int = _get_spawn_type_from_name(p.name)

		var data := {
			"position": p.global_position,
			"rotation": p.global_rotation,
			"type":     spawn_type
		}

		registered_typed_spawns.append(data)

		# Keep legacy array in sync for any code that still reads it
		registered_enemy_spawns.append({
			"position": p.global_position,
			"rotation": p.global_rotation
		})


# Returns the spawn type integer based on the marker node's name.
# Matches against the exact names placed in the room scenes:
#   easy_enemy_spawnpoint  → 1 (Brute)
#   easy_enemy_spawnpoint2 → 2 (Mage)
#   easy_enemy_spawnpoint3 → 3 (Buffed random)
#   anything else with enemy_spawn → 1 (default to Brute)
func _get_spawn_type_from_name(node_name: String) -> int:
	var lower := node_name.to_lower()
	if lower.ends_with("spawnpoint3"):  return 3
	if lower.ends_with("spawnpoint2"):  return 2
	if lower.contains("enemy_spawn"):   return 1
	return 1


func _find_enemy_spawn_points_recursive(node: Node, res: Array[Node3D]) -> void:
	for c in node.get_children():
		if c is Node3D:
			if c.name.to_lower().contains("enemy_spawn"):
				res.append(c)
			_find_enemy_spawn_points_recursive(c, res)


# ── Waypoint registration ─────────────────────────────────────────────────────

# Collects Connection_A/B and coursec1-6 nodes from a module and stores
# their world positions as navigation waypoints for the enemy AI.
# Called for every module as it is registered so the full graph builds
# naturally as dungeon generation places rooms.
func _register_waypoints_from_module(mod: Node3D) -> void:
	var points: Array[Node3D] = []
	_find_waypoint_nodes_recursive(mod, points)
	for p in points:
		if is_instance_valid(p):
			registered_waypoints.append(p.global_position)
			waypoint_total += 1


func _find_waypoint_nodes_recursive(node: Node, res: Array[Node3D]) -> void:
	for c in node.get_children():
		if c is Node3D:
			var lower_name := c.name.to_lower()
			# Connection points (room-to-room doorways)
			if lower_name.begins_with("connection_"):
				res.append(c)
			# Course points (intermediate movement targets, randomise paths)
			elif lower_name.begins_with("coursec"):
				res.append(c)
			_find_waypoint_nodes_recursive(c, res)


# ══════════════════════════════════════════════════════════════════════════════
#  TORCH PLACEMENT
# ══════════════════════════════════════════════════════════════════════════════

func _try_spawn_torches_in_module(mod: Node3D) -> void:
	for i in range(1, 11):
		var marker = mod.find_child("Torch" + str(i), true, false)
		if not (marker is Marker3D):
			continue
		var t : Node3D
		if torch_scene != null:
			t = torch_scene.instantiate() as Node3D
		else:
			t = _build_torch_node()
		# Parent to the module root (scale 1), not the marker (may have scale 35+).
		# Parenting to a scaled marker causes FlameMesh children to inherit that scale,
		# producing giant yellow blobs. Global position places the torch at the marker.
		mod.add_child(t)
		t.global_position = marker.global_position
		_position_torch_near_ceiling(t, marker as Marker3D)
		registered_torches.append(t)


# Raises the torch sphere/light to just below the ceiling and sinks the sphere
# halfway into the nearest wall so it looks like a wall-mounted glowing dome.
# Markers must be rotated so their blue arrow (-Z) points AWAY from the wall;
# +Z (basis.z) then aims directly at the wall for a single reliable raycast.
func _position_torch_near_ceiling(t: Node3D, marker: Marker3D) -> void:
	# Local Y that places the sphere centre just below the ceiling.
	var target_y : float = _TORCH_CEILING_Y - _TORCH_SPHERE_R - 0.02
	var local_y  : float = target_y - marker.global_position.y

	# Single raycast along the marker's +Z (toward the wall the marker faces).
	var origin   : Vector3 = marker.global_position + Vector3(0.0, local_y, 0.0)
	var wall_dir : Vector3 = marker.global_transform.basis.z
	var space    : PhysicsDirectSpaceState3D = get_viewport().find_world_3d().direct_space_state
	var q        := PhysicsRayQueryParameters3D.create(origin, origin + wall_dir * _TORCH_WALL_SEARCH)
	q.collision_mask = 1
	var hit : Dictionary = space.intersect_ray(q)

	# Place sphere centre at the wall surface; fall back to centred if no hit.
	var new_pos : Vector3
	if not hit.is_empty():
		new_pos = t.to_local(hit["position"])
	else:
		new_pos = Vector3(0.0, local_y, 0.0)

	# Apply to OmniLight3D and FlameMesh.
	for child in t.get_children():
		if child is OmniLight3D or child.name == "FlameMesh":
			(child as Node3D).position = new_pos


# Builds a minimal torch node in code when no torch_scene is assigned.
# TorchDimmingManager finds the OmniLight3D via its recursive search.
func _build_torch_node() -> Node3D:
	var root := Node3D.new()
	root.name = "Torch"

	var light := OmniLight3D.new()
	light.name        = "OmniLight3D"
	light.position    = Vector3(0.0, 1.5, 0.0)
	light.light_color = Color(1.0, 0.6, 0.2)
	light.light_energy = 3.0
	light.omni_range  = 7.7
	light.shadow_enabled = false
	# T2.6 — distance fade extended so adjacent rooms stay lit (full bright
	# out to 30 m, fades to zero by 40 m). TorchDimmingManager's flicker /
	# dimming / die rules work multiplicatively on top — unaffected.
	light.distance_fade_enabled = true
	light.distance_fade_begin   = 30.0
	light.distance_fade_length  = 10.0
	root.add_child(light)

	# Small emissive sphere as a placeholder flame visual.
	var mi  := MeshInstance3D.new()
	mi.name  = "FlameMesh"
	mi.position = Vector3(0.0, 1.5, 0.0)
	var sph := SphereMesh.new()
	sph.radius = 0.18
	sph.height = 0.36
	var mat := StandardMaterial3D.new()
	mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color               = Color(1.0, 0.7, 0.2, 1.0)
	mat.emission_enabled           = true
	mat.emission                   = Color(1.0, 0.55, 0.1)
	mat.emission_energy_multiplier = 1.5
	sph.material = mat
	mi.mesh   = sph
	mi.layers = 2   # Layer 2 — excluded from minimap camera (cull_mask = 1)
	root.add_child(mi)

	return root


# ══════════════════════════════════════════════════════════════════════════════
#  CONNECTION MANAGEMENT
# ══════════════════════════════════════════════════════════════════════════════

func _expanded_aabb(aabb: AABB, amt: float) -> AABB:
	return AABB(aabb.position - Vector3(amt, amt, amt),
				aabb.size    + Vector3(amt * 2, amt * 2, amt * 2))


func _collect_open_connections(mod: Node3D) -> void:
	for c in _get_connections(mod):
		if is_instance_valid(c) and not _is_connection_used(c) and not _is_connection_blocked(c):
			open_connections.append(c)


func _clean_open_connections() -> void:
	open_connections = open_connections.filter(func(c):
		return is_instance_valid(c) and not _is_connection_used(c) and not _is_connection_blocked(c))


func _get_connections(mod: Node3D) -> Array[Node3D]:
	var f: Array[Node3D] = []
	_find_connections_recursive(mod, f)
	return f


func _find_connections_recursive(node: Node, f: Array[Node3D]) -> void:
	for c in node.get_children():
		if c is Node3D:
			if c.name.begins_with("Connection_"):
				f.append(c)
			_find_connections_recursive(c, f)


func _try_attach_specific_module_to_connection(target: Node3D, scene: PackedScene) -> Node3D:
	if scene == null: return null
	var mod: Node3D = scene.instantiate()
	_main_root.add_child(mod)
	_reset_module_transform(mod)
	var conns: Array[Node3D] = _get_connections(mod)
	conns.shuffle()
	for c in conns:
		_reset_module_transform(mod)
		_align_module_to_connection(mod, c, target)
		if not _module_overlaps_anything(mod, target):
			_mark_connection_used(target)
			_mark_connection_used(c)
			return mod
	mod.queue_free()
	return null


func _pick_weighted_scene() -> PackedScene:
	if weighted_scene_pool.is_empty(): return null
	return weighted_scene_pool[randi() % weighted_scene_pool.size()]


func _matches_excluded_keyword(path: String) -> bool:
	for kw in exclude_keywords:
		if kw != "" and path.contains(kw.to_lower()): return true
	return false


func _reset_module_transform(mod: Node3D) -> void:
	mod.global_position = Vector3.ZERO
	mod.global_rotation = Vector3.ZERO


func _align_module_to_connection(mod: Node3D, mc: Node3D, target: Node3D) -> void:
	var yaw: float = atan2(-target.global_basis.z.normalized().x,
						   -target.global_basis.z.normalized().z) \
				   - atan2(mc.global_basis.z.normalized().x,
						   mc.global_basis.z.normalized().z)
	mod.rotate_y(yaw)
	mod.global_position += (target.global_position - mc.global_position) + \
						   (-target.global_basis.z.normalized() * connection_nudge)


func _module_overlaps_anything(cand: Node3D, target_conn: Node3D) -> bool:
	var cand_aabb: AABB = _shrink_aabb(_get_combined_world_aabb(cand), overlap_shrink)
	if cand_aabb.size == Vector3.ZERO: return false
	var target_root = _find_module_root_from_connection(target_conn)
	for existing in placed_modules:
		if not is_instance_valid(existing) or existing == target_root: continue
		if cand_aabb.intersects(_shrink_aabb(_get_module_cached_aabb(existing), overlap_shrink)):
			return true
	return false


func _find_module_root_from_connection(conn: Node3D) -> Node3D:
	var cur: Node = conn
	while cur != null and cur.get_parent() != _main_root:
		cur = cur.get_parent()
	return cur as Node3D


func _shrink_aabb(aabb: AABB, amt: float) -> AABB:
	return AABB(
		aabb.position + Vector3(amt, amt, amt),
		(aabb.size - Vector3(amt * 2, amt * 2, amt * 2)).max(Vector3(0.01, 0.01, 0.01))
	)


func _get_combined_world_aabb(mod: Node3D) -> AABB:
	var meshes: Array[MeshInstance3D] = []
	_find_meshes_recursive(mod, meshes)
	if meshes.is_empty(): return AABB()
	var res: AABB = AABB()
	var started := false
	for m in meshes:
		if m.mesh == null: continue
		var waabb = _transform_aabb(m.global_transform, m.get_aabb())
		if not started:
			res = waabb; started = true
		else:
			res = res.merge(waabb)
	return res


func _find_meshes_recursive(node: Node, res: Array[MeshInstance3D]) -> void:
	for c in node.get_children():
		if c is MeshInstance3D: res.append(c)
		_find_meshes_recursive(c, res)


# Fixed: ternary branches return float on all three paths to avoid type mismatch
func _transform_aabb(x: Transform3D, a: AABB) -> AABB:
	var mn = x * a.position
	var mx = mn
	for i in range(1, 8):
		var p = x * (a.position + Vector3(
			a.size.x if (i & 1) != 0 else 0.0,
			a.size.y if (i & 2) != 0 else 0.0,
			a.size.z if (i & 4) != 0 else 0.0
		))
		mn = mn.min(p)
		mx = mx.max(p)
	return AABB(mn, mx - mn)


func _mark_connection_used(c: Node3D) -> void:
	if c != null: c.set_meta("used", true)

func _is_connection_used(c: Node3D) -> bool:
	return c.has_meta("used") and bool(c.get_meta("used"))

func _is_connection_blocked(c: Node3D) -> bool:
	return c.has_meta("blocked") and bool(c.get_meta("blocked"))


func _get_module_cached_aabb(mod: Node3D) -> AABB:
	if mod.has_meta("aabb_calculated") and bool(mod.get_meta("aabb_calculated")):
		var c = mod.get_meta("module_world_aabb")
		if c is AABB: return c
	var res = _get_combined_world_aabb(mod)
	mod.set_meta("module_world_aabb", res)
	mod.set_meta("aabb_calculated", true)
	return res


# Public accessor used by RoomLockManager to size trigger Area3Ds.
func get_module_aabb(mod: Node3D) -> AABB:
	return _get_module_cached_aabb(mod)


func get_random_safe_interior_point(mod: Node3D, y: float = 0.9, margin: float = 1.25) -> Vector3:
	var a = _get_module_cached_aabb(mod)
	if a.size == Vector3.ZERO:
		return mod.global_position + Vector3(0, y, 0)
	var mx = minf(margin, (a.size.x * 0.5) - 0.15)
	var mz = minf(margin, (a.size.z * 0.5) - 0.15)
	# T1.3: reject candidate points that land within SPAWN_MIN_DIST_SQ of any
	# enemy spawn marker — prevents props from materialising on top of a
	# typed_spawn so enemies can never pop out of a prop on frame 1.
	const SPAWN_MIN_DIST_SQ : float = 4.0   # 2 m squared
	const MAX_RETRIES : int = 5
	for _i in MAX_RETRIES:
		var candidate := Vector3(
			randf_range(a.position.x + mx, a.position.x + a.size.x - mx),
			mod.global_position.y + y,
			randf_range(a.position.z + mz, a.position.z + a.size.z - mz)
		)
		var clear : bool = true
		for spawn in registered_typed_spawns:
			var p : Vector3 = spawn.get("position", Vector3.ZERO)
			var dx : float = p.x - candidate.x
			var dz : float = p.z - candidate.z
			if dx * dx + dz * dz < SPAWN_MIN_DIST_SQ:
				clear = false
				break
		if clear:
			return candidate
	# All retries failed — return the last candidate anyway; the filter is a
	# soft preference, not a hard guarantee, to avoid infinite retries in
	# rooms densely packed with spawn markers.
	return Vector3(
		randf_range(a.position.x + mx, a.position.x + a.size.x - mx),
		mod.global_position.y + y,
		randf_range(a.position.z + mz, a.position.z + a.size.z - mz)
	)


func get_explorable_modules() -> Array[Node3D]:
	return placed_modules.filter(func(m):
		return is_instance_valid(m) and \
			   m.has_meta("counts_toward_goal") and \
			   bool(m.get_meta("counts_toward_goal")))


# Returns true if pos XZ falls within any placed dungeon module's AABB footprint.
# Used by EnemyManager to validate spawn points — replaces the downward raycast
# which was hitting the safety floor and allowing void spawns.
# XZ-only check because module Y extents vary and spawn markers can sit at
# different heights within the same module.
func is_position_inside_dungeon(pos: Vector3) -> bool:
	for mod in placed_modules:
		if not is_instance_valid(mod):
			continue
		var aabb : AABB = _get_module_cached_aabb(mod)
		if aabb.size == Vector3.ZERO:
			continue
		# Slight inward margin so points right on the edge of a module wall
		# (where geometry is ambiguous) are rejected conservatively.
		var margin : float = 0.3
		if pos.x >= aabb.position.x + margin \
		and pos.x <= aabb.position.x + aabb.size.x - margin \
		and pos.z >= aabb.position.z + margin \
		and pos.z <= aabb.position.z + aabb.size.z - margin:
			return true
	return false


# Returns up to trap_count MeshInstance3D nodes whose names start with
# "template - floor" (case-insensitive), spread evenly across placed modules.
# Used by TrapManager to select booby trap tiles.
func get_trap_candidates(trap_count: int) -> Array[Node3D]:
	var result : Array[Node3D] = []
	if placed_modules.is_empty() or trap_count <= 0:
		return result
	var seg_size : float = float(placed_modules.size()) / float(trap_count)
	for i in range(trap_count):
		var seg_start : int = int(i * seg_size)
		var seg_end   : int = mini(int((i + 1) * seg_size), placed_modules.size())
		var seg_indices : Array = range(seg_start, seg_end)
		seg_indices.shuffle()
		for mi in seg_indices:
			var mod : Node3D = placed_modules[mi]
			if not is_instance_valid(mod):
				continue
			var candidates : Array[Node3D] = _find_floor_meshes_in_module(mod)
			if not candidates.is_empty():
				result.append(candidates[randi() % candidates.size()])
				break
	return result


func _find_floor_meshes_in_module(mod: Node3D) -> Array[Node3D]:
	var found : Array[Node3D] = []
	_collect_floor_meshes_recursive(mod, found)
	return found


func _collect_floor_meshes_recursive(node: Node, result: Array[Node3D]) -> void:
	if node is MeshInstance3D:
		if node.name.to_lower().begins_with("template-floor"):
			result.append(node as Node3D)
	for child in node.get_children():
		_collect_floor_meshes_recursive(child, result)


# Returns world-space positions of all coursec nodes inside a given module.
# Used by TrapManager's fireball mine effect.
func get_coursec_positions_in_module(mod: Node3D) -> Array[Vector3]:
	var positions : Array[Vector3] = []
	_collect_coursec_recursive(mod, positions)
	return positions


func _collect_coursec_recursive(node: Node, result: Array[Vector3]) -> void:
	if node is Node3D and node.name.to_lower().begins_with("coursec"):
		result.append((node as Node3D).global_position)
	for child in node.get_children():
		_collect_coursec_recursive(child, result)


# Returns which placed module contains a given world position (XZ check).
# Used by TrapManager to find the room a trap tile belongs to.
func get_module_containing_point(pos: Vector3) -> Node3D:
	for mod in placed_modules:
		if not is_instance_valid(mod):
			continue
		var aabb : AABB = _get_module_cached_aabb(mod)
		if aabb.size == Vector3.ZERO:
			continue
		if pos.x >= aabb.position.x and pos.x <= aabb.position.x + aabb.size.x \
		and pos.z >= aabb.position.z and pos.z <= aabb.position.z + aabb.size.z:
			return mod
	return null
