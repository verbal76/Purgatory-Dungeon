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
const _TORCH_CEILING_Y   : float = 3.5   # World Y used only when no ceiling is found above a marker
const _TORCH_SPHERE_R    : float = 0.18  # Sphere radius — matches torch.tscn
const _TORCH_EMBED       : float = 0.04  # How far the sphere sinks into the wall (touching, not buried)
const _TORCH_CEILING_GAP : float = 0.02  # Gap between the sphere top and the ceiling
const _TORCH_WALL_NEAR   : float = 1.5   # First wall search distance from a Torch marker
const _TORCH_WALL_FAR    : float = 3.0   # Wider search used when the near search finds nothing
const _TORCH_AUTO_SEARCH : float = 8.0   # Wall search distance for the one-torch-per-module fallback
const _TORCH_AUTO_HEIGHT : float = 2.0   # Probe height above the module origin for that fallback
const _TORCH_MAX_TILT    : float = 0.35  # Hits whose |normal.y| is above this are not walls
const _TORCH_VERIFY      : float = 0.6   # Length of the confirming ray cast from a candidate seat
const _TORCH_SEAT_SLACK  : float = 0.03  # Tolerated extra distance between seat and wall surface

# Debug counters
var counted_piece_total: int = 0
var enemy_spawn_marker_total: int = 0
var waypoint_total: int = 0
# Fallback-usage counters for T1.1 diagnostics — reset each generate_dungeon().
var wall_plug_count : int = 0
var code_plug_count : int = 0
var blocked_final_count : int = 0
# Torch diagnostics (reset each generate_dungeon()): Torch markers that found no wall and were
# skipped, and modules that got an automatically placed torch because they had none.
var torch_skipped_count : int = 0
var torch_auto_count    : int = 0
var torch_skipped_by_scene : Dictionary = {}   # module scene file name -> skipped marker count
var torch_pass_ms       : float = 0.0          # duration of _place_all_torches()
var _torch_ray : PhysicsRayQueryParameters3D = null

# ── Torch flames (batched) ────────────────────────────────────────────────────
# The glowing flame spheres are NOT one MeshInstance3D per torch any more (a default SphereMesh is
# 4224 triangles, and ~740 of them were the bulk of every frame's triangles and a fifth to a third
# of its draw calls on a phone). Each torch keeps its OmniLight3D node; the flames are drawn by a
# few MultiMeshInstance3D batches (one per 48 m grid cell, so frustum culling still works) that share
# ONE low-poly sphere mesh and ONE material. Flame and light stay at the same spot (torch root).
const _FLAME_RADIUS   : float = 0.18   # matches torch.tscn
const _FLAME_SEGMENTS : int   = 12     # 12 x 6 = ~120 triangles (default would be 64 x 32)
const _FLAME_RINGS    : int   = 6
const _FLAME_CELL     : float = 48.0   # metres per batch cell
const FLAME_BATCH_PREFIX : String = "TorchFlames"
var torch_flame_batches : Array[MultiMeshInstance3D] = []   # the batches (see _build_flame_batches)
var torch_flame_count   : int = 0                           # flame instances over all batches
var torch_flame_bounds  : Array[AABB] = []                  # world bounds of each batch (parallel to torch_flame_batches)
var torch_flame_positions : PackedVector3Array = PackedVector3Array()   # world position of every flame instance
var _flame_mesh : SphereMesh = null
var _flame_material : StandardMaterial3D = null

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


## A layout that ends far short of the room target is thrown away and generated again (the
## generator is random; a rare unlucky run closed itself in after a handful of rooms and left
## a dungeon with no enemies). The last attempt is kept whatever its size.
@export var minimum_fill_fraction : float = 0.8
## While the layout is below its target and this few doorways (or fewer) are still open, the layout
## protects its frontier: no dead-end room is placed on one, and a doorway that fails to take a
## room is retried (up to door_retry_limit times) instead of being capped. A layout that closes its
## last open doorway can never grow again.
@export var frontier_reserve  : int = 3
@export var door_retry_limit  : int = 30
@export var max_layout_attempts   : int   = 6
var layout_attempts : int = 0
## One entry per layout attempt (why it stopped, how many rooms it reached, how often attaching a
## room failed...). Diagnostics only: the stress tests read it to find and reproduce bad seeds.
var layout_history : Array[Dictionary] = []
var _diag : Dictionary = {}
## Entry-profile diagnostics for the whole generate_dungeon() call (reset on every call): phase
## durations in ms, how many scenes were instantiated / overlap-tested / measured. Read by tests/entry_profile.gd.
var gen_stats : Dictionary = {}


func generate_dungeon() -> Dictionary:
	layout_attempts = 0
	layout_history.clear()
	gen_stats = {"instantiated": 0, "overlap_checks": 0, "aabb_computed": 0, "attempt_ms": [], "torch_ms": 0.0}
	var t_gen : int = Time.get_ticks_usec()
	var result : Dictionary = {"success": false}
	for i in maxi(max_layout_attempts, 1):
		layout_attempts += 1
		var t_att : int = Time.get_ticks_usec()
		result = _generate_once()
		gen_stats["attempt_ms"].append(float(Time.get_ticks_usec() - t_att) / 1000.0)
		if not bool(result.get("success", false)):
			_free_candidate_pool()
			return result
		if counted_piece_total >= int(ceil(float(target_piece_count) * minimum_fill_fraction)):
			break
		if i < maxi(max_layout_attempts, 1) - 1:
			push_warning("DungeonGeneration: layout %d reached only %d of %d rooms - regenerating." % [
				layout_attempts, counted_piece_total, target_piece_count])
			_discard_layout()
	_free_candidate_pool()   # the reusable candidates must not stay in the physics space for the torch rays
	if bool(result.get("success", false)):
		_place_all_torches()
	gen_stats["torch_ms"] = torch_pass_ms
	gen_stats["total_ms"] = float(Time.get_ticks_usec() - t_gen) / 1000.0
	return result


## The same generation as generate_dungeon(), spread over frames: the layout loop (and the end-cap sweep)
## give the frame back whenever `budget_us` microseconds of work have been done, so a loading screen keeps
## animating and the device never stalls for the whole layout. The RNG is consumed in exactly the order
## the synchronous version consumes it, so a seed gives the same dungeon either way (tests compare them).
## The torch pass is a single synchronous step at the end.
func generate_dungeon_async(budget_us: int) -> Dictionary:
	layout_attempts = 0
	layout_history.clear()
	gen_stats = {"instantiated": 0, "overlap_checks": 0, "aabb_computed": 0, "attempt_ms": [], "torch_ms": 0.0, "slices": 0}
	var t_gen : int = Time.get_ticks_usec()
	_slice_budget_us = budget_us
	_slice_t0 = t_gen
	var result : Dictionary = {"success": false}
	for i in maxi(max_layout_attempts, 1):
		layout_attempts += 1
		var t_att : int = Time.get_ticks_usec()
		result = await _generate_once_async()
		gen_stats["attempt_ms"].append(float(Time.get_ticks_usec() - t_att) / 1000.0)
		if not bool(result.get("success", false)):
			_free_candidate_pool()
			_slice_budget_us = 0
			return result
		if counted_piece_total >= int(ceil(float(target_piece_count) * minimum_fill_fraction)):
			break
		if i < maxi(max_layout_attempts, 1) - 1:
			push_warning("DungeonGeneration: layout %d reached only %d of %d rooms - regenerating." % [
				layout_attempts, counted_piece_total, target_piece_count])
			_discard_layout()
	_free_candidate_pool()
	_slice_budget_us = 0
	await get_tree().process_frame   # let the layout's last slice present before the torch block
	if bool(result.get("success", false)):
		_place_all_torches()
	gen_stats["torch_ms"] = torch_pass_ms
	gen_stats["total_ms"] = float(Time.get_ticks_usec() - t_gen) / 1000.0
	return result


var _slice_budget_us : int = 0
var _slice_t0 : int = 0


# True when the current slice has used its budget (only ever true in the async generation).
func _slice_over() -> bool:
	return _slice_budget_us > 0 and Time.get_ticks_usec() - _slice_t0 >= _slice_budget_us


func _slice_next_frame() -> void:
	gen_stats["slices"] = int(gen_stats.get("slices", 0)) + 1
	await get_tree().process_frame
	_slice_t0 = Time.get_ticks_usec()


# Removes every module of the current layout from the tree at once (their physics bodies and
# markers must not linger while the replacement layout is built) and frees them.
func _discard_layout() -> void:
	for mod in placed_modules:
		if is_instance_valid(mod):
			var parent : Node = mod.get_parent()
			if parent != null:
				parent.remove_child(mod)
			mod.queue_free()
	placed_modules.clear()


func _generate_once() -> Dictionary:
	var starter : Node3D = _generate_begin()
	if starter == null:
		return {"success": false}
	_generate_layout()
	if _retry_fill_prepare():
		_generate_layout()
	_close_open_ends_full_sweep()
	return _generate_finish(starter)


func _generate_once_async() -> Dictionary:
	var starter : Node3D = _generate_begin()
	if starter == null:
		return {"success": false}
	await _generate_layout_async()
	if _retry_fill_prepare():
		await _generate_layout_async()
	await _close_open_ends_async()
	return _generate_finish(starter)


# Resets the state and places the starter module. Null when the generator is not set up.
func _generate_begin() -> Node3D:
	_reset_generation_state()
	_diag = {"attach_fail": 0, "end_caps": 0, "wall_plugs": 0, "code_plugs": 0, "blocked": 0,
			"dead_end_rooms": 0, "last_door_retries": 0, "stop": "", "rooms_at_stop": 0}

	if _main_root == null:            return null
	if _starter_module == null:       return null
	if _branch_modules.is_empty():    return null
	if _room_connector_module == null: return null
	if _end_cap_module == null:       return null

	# Lazy-load the wall-plug scene once per run.
	if _wall_plug_module == null and ResourceLoader.exists(_WALL_PLUG_PATH):
		_wall_plug_module = load(_WALL_PLUG_PATH)

	_build_weighted_scene_pool()

	var starter: Node3D = _instantiate_module(_starter_module)
	_main_root.add_child(starter)
	starter.global_position = Vector3.ZERO
	starter.global_rotation = Vector3.ZERO

	_register_module(starter, true)
	counted_piece_total = 1

	_collect_open_connections(starter)
	return starter


func _generate_finish(starter: Node3D) -> Dictionary:
	_clean_open_connections()
	_diag["rooms"] = counted_piece_total
	_diag["modules"] = placed_modules.size()
	layout_history.append(_diag.duplicate())

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
func _retry_fill_prepare() -> bool:
	if counted_piece_total >= target_piece_count:
		return false
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
	return true


# ══════════════════════════════════════════════════════════════════════════════
#  MINIMAP & EXPLORATION
# ══════════════════════════════════════════════════════════════════════════════

func update_player_exploration() -> void:
	var player: Node3D = _get_player()
	if player == null: return
	var player_pos: Vector3 = player.global_position

	# Only the modules whose footprint can reach the player (padding included) are tested: this runs every
	# EXPLORE_INTERVAL for the whole run and used to walk all ~330 placed modules each time.
	var pad : float = exploration_padding
	for ix in 2:
		for iz in 2:
			var probe := Vector3(player_pos.x + (pad if ix == 1 else -pad), player_pos.y,
					player_pos.z + (pad if iz == 1 else -pad))
			for module_root in _modules_near_point(probe):
				if module_root == null or not is_instance_valid(module_root): continue
				if module_root.has_meta("explored") and bool(module_root.get_meta("explored")): continue

				var module_aabb: AABB = _get_module_cached_aabb(module_root)
				if module_aabb.size == Vector3.ZERO: continue
				module_aabb = _expanded_aabb(module_aabb, pad)

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
	_grid.clear()
	_point_grid_count = -1
	_free_flame_batches()
	counted_piece_total      = 0
	enemy_spawn_marker_total = 0
	waypoint_total           = 0
	wall_plug_count          = 0
	code_plug_count          = 0
	blocked_final_count      = 0
	torch_skipped_count      = 0
	torch_auto_count         = 0
	torch_skipped_by_scene.clear()


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
	_layout_attempt = 0
	while _layout_step():
		pass
	_layout_finish()


func _generate_layout_async() -> void:
	_layout_attempt = 0
	while _layout_step():
		if _slice_over():
			await _slice_next_frame()
	_layout_finish()


var _layout_attempt : int = 0


# One iteration of the layout loop (try to fill one open doorway). False when the loop is over.
func _layout_step() -> bool:
	if counted_piece_total >= target_piece_count or _layout_attempt >= total_generation_attempts:
		return false
	_layout_attempt += 1
	_clean_open_connections()
	if open_connections.is_empty():
		return false

	var target_idx: int = randi() % open_connections.size()
	var target: Node3D = open_connections[target_idx]
	if not is_instance_valid(target) or _is_connection_used(target) or _is_connection_blocked(target):
		open_connections.remove_at(target_idx)
		return true

	var res: Dictionary = _try_attach_connector_then_piece(target)
	if res.get("success", false):
		_register_module(res.get("connector"), false)
		_collect_open_connections(res.get("connector"))
		_register_module(res.get("main"), true)
		_collect_open_connections(res.get("main"))
		counted_piece_total += 1
		if _get_connections(res.get("main")).size() < 2:
			_diag["dead_end_rooms"] += 1
		return true

	_diag["attach_fail"] += 1
	# Failing to fit a room is down to the random picks, not the doorway: while the frontier is
	# thin keep the doorway open and try again rather than closing it for good.
	if _frontier_is_thin():
		var fails: int = int(target.get_meta("door_fails", 0)) + 1
		target.set_meta("door_fails", fails)
		if fails < door_retry_limit:
			_diag["last_door_retries"] += 1
			return true
	var cap: Node3D = _try_attach_specific_module_to_connection(target, _end_cap_module)
	if cap != null:
		_register_module(cap, false)
		cap.set_meta("is_end_cap", true)
		_diag["end_caps"] += 1
	elif _try_attach_wall_plug(target):
		wall_plug_count += 1
		_diag["wall_plugs"] += 1
	elif _force_attach_code_plug(target):
		code_plug_count += 1
		_diag["code_plugs"] += 1
	else:
		target.set_meta("blocked", true)
		blocked_final_count += 1
		_diag["blocked"] += 1
	return true


func _layout_finish() -> void:
	_diag["stop"] = "target" if counted_piece_total >= target_piece_count \
			else ("open_exhausted" if open_connections.is_empty() else "attempt_cap")
	_diag["rooms_at_stop"] = counted_piece_total


func _close_open_ends_full_sweep() -> void:
	var found := true; var safety := 0
	while found and safety < 10:
		safety += 1; found = false
		for target in _get_all_unused_connections_from_all_modules():
			found = true
			_close_one_end(target)


func _close_open_ends_async() -> void:
	var found := true; var safety := 0
	while found and safety < 10:
		safety += 1; found = false
		for target in _get_all_unused_connections_from_all_modules():
			found = true
			_close_one_end(target)
			if _slice_over():
				await _slice_next_frame()


func _close_one_end(target: Node3D) -> void:
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
	_grid_add(plug)
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
	var conn_cand : Dictionary = _get_candidate(_room_connector_module)
	var attempt: int = 0
	while attempt < attempts_per_connection:
		attempt += 1
		var conn_node : Node3D = conn_cand["node"]
		_reset_module_transform(conn_node)
		var base_conns : Array[Node3D] = conn_cand["conns"]
		if base_conns.size() < 2:
			return {"success": false}
		var conns : Array[Node3D] = base_conns.duplicate()   # shuffled copy: the cached order stays the scene order
		conns.shuffle()
		var exit: Node3D = null
		var entry: Node3D = null
		var conn_aabb : AABB = AABB()
		for c in conns:
			var other = _get_other_connection(conns, c)
			_reset_module_transform(conn_node)
			_align_module_to_connection(conn_node, c, target)
			conn_aabb = _candidate_aabb(conn_cand)
			if not _aabb_overlaps_placed(conn_aabb, target):
				entry = c; exit = other; break
		if entry == null:
			continue
		var scene: PackedScene = _pick_weighted_scene(_frontier_is_thin())
		var main_cand : Dictionary = _get_candidate(scene)
		var main_node : Node3D = main_cand["node"]
		_reset_module_transform(main_node)
		var main_base : Array[Node3D] = main_cand["conns"]
		# A dead-end room placed on the LAST open doorway ends generation: a rare random run
		# produced a 5-room dungeon with no enemy spawns. Below the target, only rooms that
		# keep a doorway open may take the last one.
		if main_base.size() < 2 and _frontier_is_thin():
			continue
		var main_conns : Array[Node3D] = main_base.duplicate()
		main_conns.shuffle()
		var main_entry: Node3D = null
		var main_aabb : AABB = AABB()
		for mc in main_conns:
			_reset_module_transform(main_node)
			_align_module_to_connection(main_node, mc, exit)
			main_aabb = _candidate_aabb(main_cand)
			if not _aabb_overlaps_placed(main_aabb, exit):
				main_entry = mc; break
		if main_entry:
			# Keep the two candidates: instantiate each once, at the transform it was tested at.
			var entry_idx : int = base_conns.find(entry)
			var exit_idx : int = base_conns.find(exit)
			var main_idx : int = main_base.find(main_entry)
			var conn_mod : Node3D = _commit_candidate(_room_connector_module, conn_node, conn_aabb)
			var main_mod : Node3D = _commit_candidate(scene, main_node, main_aabb)
			var conn_real : Array[Node3D] = _get_connections(conn_mod)
			var main_real : Array[Node3D] = _get_connections(main_mod)
			_mark_connection_used(target)
			_mark_connection_used(conn_real[entry_idx])
			_mark_connection_used(conn_real[exit_idx])
			_mark_connection_used(main_real[main_idx])
			return {"success": true, "connector": conn_mod, "main": main_mod}
	return {"success": false}


# ── Candidate pool ────────────────────────────────────────────────────────────
# Fitting a room used to instantiate the scene, add it to the tree, test it and free it again for every
# try: ~2000 instantiations (50,000+ nodes freed in a single frame) for the ~330 modules a dungeon keeps.
# A candidate is now ONE reusable instance per scene that is only moved and measured (same engine
# transforms and AABB maths as before, so the same seed gives the same layout); the module that is kept
# is instantiated once, at the transform its candidate was accepted at. The pool is freed before the
# torch pass so its bodies never reach the physics queries.
var _cand_holder : Node3D = null
var _cand_pool : Dictionary = {}   # PackedScene instance id -> {"node", "conns", "meshes"}


func _get_candidate(scene: PackedScene) -> Dictionary:
	var key : int = scene.get_instance_id()
	if _cand_pool.has(key):
		return _cand_pool[key]
	if _cand_holder == null or not is_instance_valid(_cand_holder):
		_cand_holder = Node3D.new()
		_cand_holder.name = "LayoutCandidates"
		_main_root.add_child(_cand_holder)
	var node : Node3D = _instantiate_module(scene)
	_cand_holder.add_child(node)
	var meshes : Array[MeshInstance3D] = []
	_find_meshes_recursive(node, meshes)
	var conns : Array[Node3D] = []
	_find_connections_recursive(node, conns)
	var entry : Dictionary = {"node": node, "conns": conns, "meshes": meshes}
	_cand_pool[key] = entry
	return entry


func _free_candidate_pool() -> void:
	if _cand_holder != null and is_instance_valid(_cand_holder):
		if _cand_holder.get_parent() != null:
			_cand_holder.get_parent().remove_child(_cand_holder)
		_cand_holder.free()
	_cand_holder = null
	_cand_pool.clear()


# World AABB of a candidate at its current transform: the same merge of the per-mesh AABBs that
# _get_combined_world_aabb() computes, over the cached mesh list.
func _candidate_aabb(cand: Dictionary) -> AABB:
	var res: AABB = AABB()
	var started := false
	for m in cand["meshes"]:
		if m.mesh == null: continue
		var waabb = _transform_aabb(m.global_transform, m.get_aabb())
		if not started:
			res = waabb; started = true
		else:
			res = res.merge(waabb)
	return res


# Instantiates the kept module at the candidate's transform and seeds its cached AABB with the one it
# was tested at. The transform is set before add_child so the physics body is registered where it stays.
func _commit_candidate(scene: PackedScene, cand_node: Node3D, aabb: AABB) -> Node3D:
	var mod : Node3D = _instantiate_module(scene)
	var root_xf : Transform3D = _main_root.global_transform
	var g : Transform3D = cand_node.global_transform
	mod.transform = g if root_xf == Transform3D.IDENTITY else root_xf.affine_inverse() * g
	_main_root.add_child(mod)
	mod.set_meta("module_world_aabb", aabb)
	mod.set_meta("aabb_calculated", true)
	return mod


# ── Placed-module grid ────────────────────────────────────────────────────────
# Overlap tests ask "does this box touch any placed module?": a coarse XZ grid of the placed boxes
# answers it from the few modules near the candidate instead of looping over all of them. Boxes are
# registered in every cell they cover, so a strict overlap always shares a cell (same answers).
const _GRID_CELL : float = 16.0
var _grid : Dictionary = {}   # Vector2i -> Array of [module, shrunk aabb]


func _grid_add(mod: Node3D) -> void:
	var a : AABB = _shrink_aabb(_get_module_cached_aabb(mod), overlap_shrink)
	var entry : Array = [mod, a]
	var lo : Vector2i = _grid_cell(a.position)
	var hi : Vector2i = _grid_cell(a.position + a.size)
	for x in range(lo.x, hi.x + 1):
		for z in range(lo.y, hi.y + 1):
			var key := Vector2i(x, z)
			if _grid.has(key):
				(_grid[key] as Array).append(entry)
			else:
				_grid[key] = [entry]


func _grid_cell(p: Vector3) -> Vector2i:
	return Vector2i(int(floorf(p.x / _GRID_CELL)), int(floorf(p.z / _GRID_CELL)))


# True when the box (shrunk like the placed ones) overlaps a placed module other than the one
# `target_conn` belongs to.
func _aabb_overlaps_placed(world_aabb: AABB, target_conn: Node3D) -> bool:
	gen_stats["overlap_checks"] = int(gen_stats.get("overlap_checks", 0)) + 1
	var cand_aabb: AABB = _shrink_aabb(world_aabb, overlap_shrink)
	if cand_aabb.size == Vector3.ZERO: return false
	var target_root = _find_module_root_from_connection(target_conn)
	var lo : Vector2i = _grid_cell(cand_aabb.position)
	var hi : Vector2i = _grid_cell(cand_aabb.position + cand_aabb.size)
	for x in range(lo.x, hi.x + 1):
		for z in range(lo.y, hi.y + 1):
			var cell = _grid.get(Vector2i(x, z))
			if cell == null:
				continue
			for entry in cell:
				if entry[0] == target_root:
					continue
				if cand_aabb.intersects(entry[1]):
					return true
	return false


func _instantiate_module(scene: PackedScene) -> Node3D:
	gen_stats["instantiated"] = int(gen_stats.get("instantiated", 0)) + 1
	return scene.instantiate() as Node3D


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
	_grid_add(mod)
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

	# Torches are placed once for the whole layout by _place_all_torches() (end of
	# generate_dungeon()): wall raycasts only work once the colliders reach the physics space.


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

# Runs once, on the final layout. Modules are moved around while the layout is built and a body's
# transform only reaches the physics space at the next flush, so every collider is flushed first
# (without it a wall raycast made in the same frame finds almost nothing). Then every Torch
# marker gets a torch seated on its nearest wall, and every module that still has no torch (the
# end caps, anything without markers) gets one on its nearest wall, so no room is ever dark.
func _place_all_torches() -> void:
	if not is_inside_tree() or get_viewport() == null:
		return
	var world : World3D = get_viewport().find_world_3d()
	var space : PhysicsDirectSpaceState3D = world.direct_space_state if world != null else null
	if space == null:
		return
	var t0 : int = Time.get_ticks_usec()
	if _torch_ray == null:
		_torch_ray = PhysicsRayQueryParameters3D.new()
		_torch_ray.collision_mask = 1
	for mod in placed_modules:
		if is_instance_valid(mod):
			_flush_module_colliders(mod)
	for mod in placed_modules:
		if not is_instance_valid(mod):
			continue
		# The cached AABB is taken first: the torch meshes must not enlarge it.
		var has_geometry : bool = _get_module_cached_aabb(mod).size != Vector3.ZERO
		var placed : int = _try_spawn_torches_in_module(mod, space)
		if placed == 0 and has_geometry:
			if _spawn_auto_torch(mod, space):
				torch_auto_count += 1
	_build_flame_batches()
	torch_pass_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	print("Torches: ", registered_torches.size(), " placed (", torch_auto_count,
		  " automatic one-per-module, ", torch_skipped_count, " skipped: no wall in reach) in ",
		  snappedf(torch_pass_ms, 0.1), " ms")


# Pushes pending transform changes of a module's physics bodies to the physics server.
func _flush_module_colliders(mod: Node3D) -> void:
	if mod is CollisionObject3D:
		mod.force_update_transform()
	for body in mod.find_children("*", "CollisionObject3D", true, false):
		(body as Node3D).force_update_transform()


# Builds one torch node (scene if assigned, else the code-built one) under the module root.
# Parent is the module root (scale 1), not a marker (may have scale 35+): parenting to a scaled
# marker makes the FlameMesh inherit that scale and turns it into a giant yellow blob.
func _make_torch(mod: Node3D) -> Node3D:
	var t : Node3D
	if torch_scene != null:
		t = torch_scene.instantiate() as Node3D
	else:
		t = _build_torch_node()
	mod.add_child(t)
	return t


# Places a torch at every Torch1..Torch10 marker of the module. Returns how many were placed.
func _try_spawn_torches_in_module(mod: Node3D, space: PhysicsDirectSpaceState3D) -> int:
	var placed : int = 0
	for i in range(1, 11):
		var marker = mod.find_child("Torch" + str(i), true, false)
		if not (marker is Marker3D):
			continue
		var origin : Vector3 = (marker as Marker3D).global_position
		origin.y = _torch_height(space, origin)
		var dirs : Array[Vector3] = _horizontal_dirs((marker as Marker3D).global_transform.basis)
		var seat : Variant = _find_wall_seat(space, origin, dirs, _TORCH_WALL_NEAR)
		if seat == null:
			seat = _find_wall_seat(space, origin, dirs, _TORCH_WALL_FAR)
		if seat == null:
			# Never hang a light in mid-air: no wall in reach, no torch.
			torch_skipped_count += 1
			var key : String = mod.scene_file_path.get_file()
			torch_skipped_by_scene[key] = int(torch_skipped_by_scene.get(key, 0)) + 1
			continue
		_place_torch_at(mod, seat as Vector3)
		placed += 1
	return placed


# One-torch-per-module fallback: from the module's AABB centre, at torch height, look for the
# nearest wall in the four horizontal directions (module yaw) and seat a torch on it.
func _spawn_auto_torch(mod: Node3D, space: PhysicsDirectSpaceState3D) -> bool:
	var centre : Vector3 = _get_module_cached_aabb(mod).get_center()
	var dirs : Array[Vector3] = _horizontal_dirs(mod.global_transform.basis)
	var starts : Array[Vector3] = [Vector3(centre.x, mod.global_position.y + _TORCH_AUTO_HEIGHT, centre.z)]
	# The AABB centre can sit inside a wall or pillar (L / T shaped rooms): fall back to the
	# module origin and its doorways, which are in open floor space.
	starts.append(mod.global_position + Vector3(0.0, _TORCH_AUTO_HEIGHT, 0.0))
	for c in _get_connections(mod):
		starts.append(c.global_position)
	for st in starts:
		st.y = _torch_height(space, st)
		var seat : Variant = _find_wall_seat(space, st, dirs, _TORCH_AUTO_SEARCH)
		if seat != null:
			_place_torch_at(mod, seat as Vector3)
			return true
	torch_skipped_count += 1
	var scene_key : String = mod.scene_file_path.get_file()
	torch_skipped_by_scene[scene_key] = int(torch_skipped_by_scene.get(scene_key, 0)) + 1
	return false


# Creates the torch and puts the flame sphere and the light (together) at `seat`.
func _place_torch_at(mod: Node3D, seat: Vector3) -> void:
	var t : Node3D = _make_torch(mod)
	t.global_position = seat
	for child in t.get_children():
		if child is OmniLight3D or child.name == "FlameMesh":
			(child as Node3D).position = Vector3.ZERO
	registered_torches.append(t)


# World Y for a torch's sphere centre above `origin`: just under the real ceiling found with an
# upward ray (the sphere never pokes through it; the floor is always below the marker, so it
# cannot be reached either); the fixed constant only when no ceiling is hit.
func _torch_height(space: PhysicsDirectSpaceState3D, origin: Vector3) -> float:
	var ceiling_y : float = _TORCH_CEILING_Y
	var up : Dictionary = _ray_live_geometry(space, origin, origin + Vector3.UP * 12.0)
	if not up.is_empty() and (up["position"] as Vector3).y > origin.y + 0.3:
		ceiling_y = (up["position"] as Vector3).y
	return ceiling_y - _TORCH_SPHERE_R - _TORCH_CEILING_GAP


# The four horizontal directions of a basis (+X, -X, +Z, -Z flattened to the XZ plane).
func _horizontal_dirs(b: Basis) -> Array[Vector3]:
	var out : Array[Vector3] = []
	for axis in [b.x, -b.x, b.z, -b.z]:
		var flat : Vector3 = Vector3(axis.x, 0.0, axis.z)
		if flat.length_squared() > 0.0001:
			out.append(flat.normalized())
	return out


# Nearest wall within `max_dist` in any of `dirs`; returns the sphere centre that makes the sphere
# touch that wall lightly (hit + normal * (radius - embed)), or null when there is none.
# Hits that are not roughly vertical surfaces (floors, ceilings, ramps) are ignored, and a wall is
# only accepted once a second ray from the seat confirms the surface really is right behind the
# sphere (a sliver or an uneven face hit by the first ray would leave the torch floating).
func _find_wall_seat(space: PhysicsDirectSpaceState3D, origin: Vector3, dirs: Array[Vector3], max_dist: float) -> Variant:
	var found : Array = []   # entries: [distance, hit, direction]
	for d in dirs:
		var hit : Dictionary = _ray_live_geometry(space, origin, origin + d * max_dist)
		if hit.is_empty() or absf(_facing_normal(hit, d).y) > _TORCH_MAX_TILT:
			continue
		found.append([origin.distance_to(hit["position"]), hit, d])
	found.sort_custom(func(a, b): return a[0] < b[0])
	for f in found:
		var seat : Variant = _seat_on_wall(space, f[1], f[2])
		if seat != null:
			return seat
	return null


# Sphere centre touching the wall `hit` (found by a ray travelling along `d`), verified and, if the
# surface is uneven, refined by re-casting from the candidate seat. Null when it cannot be confirmed.
func _seat_on_wall(space: PhysicsDirectSpaceState3D, hit: Dictionary, d: Vector3) -> Variant:
	var reach : float = _TORCH_SPHERE_R - _TORCH_EMBED
	for _i in 3:
		var n : Vector3 = _facing_normal(hit, d)
		var seat : Vector3 = (hit["position"] as Vector3) + Vector3(n.x, 0.0, n.z).normalized() * reach
		var check : Dictionary = _ray_live_geometry(space, seat, seat + d * _TORCH_VERIFY)
		if check.is_empty() or absf(_facing_normal(check, d).y) > _TORCH_MAX_TILT:
			return null
		if seat.distance_to(check["position"]) <= reach + _TORCH_SEAT_SLACK:
			return seat
		hit = check
	return null


# Surface normal of a ray hit, flipped to face the ray origin (a back-face hit reports the other side).
func _facing_normal(hit: Dictionary, d: Vector3) -> Vector3:
	var n : Vector3 = hit["normal"]
	return -n if n.dot(d) > 0.0 else n


# Ray against level geometry only. Candidate modules that were tried and rejected during layout
# are queued for deletion but their colliders linger until the end of the frame: they are skipped.
func _ray_live_geometry(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var excluded : Array[RID] = []
	_torch_ray.from = from
	_torch_ray.to = to
	_torch_ray.exclude = excluded
	for _i in 8:
		var hit : Dictionary = space.intersect_ray(_torch_ray)
		if hit.is_empty():
			return hit
		var collider : Object = hit.get("collider")
		if PhysicsUtil.is_world_geometry(collider) and not _is_pending_delete(collider as Node):
			return hit
		excluded.append(hit["rid"])
		_torch_ray.exclude = excluded
	return {}


func _is_pending_delete(n: Node) -> bool:
	var cur : Node = n
	while cur != null and cur != _main_root:
		if cur.is_queued_for_deletion():
			return true
		cur = cur.get_parent()
	return false


# Builds a minimal torch node in code when no torch_scene is assigned: just the OmniLight3D (the
# flame sphere is drawn by the shared MultiMesh batches, see _build_flame_batches).
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

	# The flame is not a node of the torch: see _build_flame_batches().
	root.set_meta("flame_batched", true)

	return root


# Draws the flame of every code-built torch (meta "flame_batched") through MultiMesh batches: one
# shared low-poly sphere + one shared emissive material, instances grouped per grid cell. The flames
# keep layer 2 (the minimap camera only renders layer 1) and cast no shadows, like before.
func _build_flame_batches() -> void:
	_free_flame_batches()
	if _flame_mesh == null:
		_flame_material = StandardMaterial3D.new()
		_flame_material.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
		_flame_material.albedo_color               = Color(1.0, 0.7, 0.2, 1.0)
		_flame_material.emission_enabled           = true
		_flame_material.emission                   = Color(1.0, 0.55, 0.1)
		_flame_material.emission_energy_multiplier = 1.5
		_flame_mesh = SphereMesh.new()
		_flame_mesh.radius          = _FLAME_RADIUS
		_flame_mesh.height          = _FLAME_RADIUS * 2.0
		_flame_mesh.radial_segments = _FLAME_SEGMENTS
		_flame_mesh.rings           = _FLAME_RINGS
		_flame_mesh.material        = _flame_material
	var cells : Dictionary = {}   # Vector2i -> Array[Vector3]
	for t in registered_torches:
		if not is_instance_valid(t) or not t.has_meta("flame_batched"):
			continue
		var p : Vector3 = t.global_position
		var key := Vector2i(int(floor(p.x / _FLAME_CELL)), int(floor(p.z / _FLAME_CELL)))
		if not cells.has(key):
			cells[key] = []
		(cells[key] as Array).append(p)
	var keys : Array = cells.keys()
	keys.sort()   # deterministic node order
	for key in keys:
		var points : Array = cells[key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _flame_mesh
		mm.instance_count = points.size()
		for i in points.size():
			mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, points[i]))
			torch_flame_positions.append(points[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "%s_%d_%d" % [FLAME_BATCH_PREFIX, key.x, key.y]
		mmi.multimesh = mm
		mmi.layers = 2   # layer 2: excluded from the minimap camera (cull_mask = 1)
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.top_level = true   # instance transforms are world positions
		add_child(mmi)
		mmi.global_transform = Transform3D.IDENTITY
		var bounds := AABB(points[0], Vector3.ZERO)
		for pt in points:
			bounds = bounds.expand(pt)
		torch_flame_bounds.append(bounds)
		torch_flame_batches.append(mmi)
		torch_flame_count += points.size()


func _free_flame_batches() -> void:
	for b in torch_flame_batches:
		if is_instance_valid(b):
			if b.get_parent() != null:
				b.get_parent().remove_child(b)
			b.queue_free()
	torch_flame_batches.clear()
	torch_flame_bounds.clear()
	torch_flame_positions.clear()
	torch_flame_count = 0


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
	# Placed modules never change shape: the connection list is found once and kept on the module.
	if mod.has_meta("_connections"):
		return mod.get_meta("_connections")
	var f: Array[Node3D] = []
	_find_connections_recursive(mod, f)
	if mod.get_parent() == _main_root:
		mod.set_meta("_connections", f)
	return f


func _find_connections_recursive(node: Node, f: Array[Node3D]) -> void:
	for c in node.get_children():
		if c is Node3D:
			if c.name.begins_with("Connection_"):
				f.append(c)
			_find_connections_recursive(c, f)


func _try_attach_specific_module_to_connection(target: Node3D, scene: PackedScene) -> Node3D:
	if scene == null: return null
	var cand : Dictionary = _get_candidate(scene)
	var node : Node3D = cand["node"]
	var base_conns : Array[Node3D] = cand["conns"]
	var conns : Array[Node3D] = base_conns.duplicate()
	conns.shuffle()
	for c in conns:
		_reset_module_transform(node)
		_align_module_to_connection(node, c, target)
		var aabb : AABB = _candidate_aabb(cand)
		if not _aabb_overlaps_placed(aabb, target):
			var mod : Node3D = _commit_candidate(scene, node, aabb)
			_mark_connection_used(target)
			_mark_connection_used(_get_connections(mod)[base_conns.find(c)])
			return mod
	return null


# True while the layout is short of its target and nearly out of open doorways.
func _frontier_is_thin() -> bool:
	return counted_piece_total < target_piece_count and open_connections.size() <= frontier_reserve


func _pick_weighted_scene(avoid_dead_ends: bool = false) -> PackedScene:
	if weighted_scene_pool.is_empty(): return null
	if avoid_dead_ends:
		# Weighted draws that skip one-doorway rooms (classified by file name like the weights are).
		for _i in 40:
			var pick: PackedScene = weighted_scene_pool[randi() % weighted_scene_pool.size()]
			if not _is_dead_end_scene(pick):
				return pick
	return weighted_scene_pool[randi() % weighted_scene_pool.size()]


func _is_dead_end_scene(scene: PackedScene) -> bool:
	var path: String = scene.resource_path.to_lower()
	return path.contains("1_opening") or path.contains("end")


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
	gen_stats["aabb_computed"] = int(gen_stats.get("aabb_computed", 0)) + 1
	var res = _get_combined_world_aabb(mod)
	mod.set_meta("module_world_aabb", res)
	mod.set_meta("aabb_calculated", true)
	return res


# Public accessor used by RoomLockManager to size trigger Area3Ds.
func get_module_aabb(mod: Node3D) -> AABB:
	return _get_module_cached_aabb(mod)


# The module's Connection_* markers (found once, kept on the module).
func get_module_connections(mod: Node3D) -> Array[Node3D]:
	return _get_connections(mod)


# Placed modules ordered by the XZ distance from `origin` to their box centre (nearest first). Used by the
# staged population passes so the player's surroundings are finished before the far rooms.
# Modules without geometry (code plugs) sort by their own position.
func get_modules_by_distance(origin: Vector3) -> Array[Node3D]:
	var keyed : Array = []
	for mod in placed_modules:
		if not is_instance_valid(mod):
			continue
		var a : AABB = _get_module_cached_aabb(mod)
		var c : Vector3 = a.get_center() if a.size != Vector3.ZERO else mod.global_position
		var dx : float = c.x - origin.x
		var dz : float = c.z - origin.z
		keyed.append([dx * dx + dz * dz, mod])
	keyed.sort_custom(func(l, r): return l[0] < r[0])
	var out : Array[Node3D] = []
	for k in keyed:
		out.append(k[1])
	return out


# How many of `sorted_modules` (from get_modules_by_distance) have their box centre within `radius` of `origin`.
func count_modules_within(sorted_modules: Array, origin: Vector3, radius: float) -> int:
	var n : int = 0
	var r2 : float = radius * radius
	for mod in sorted_modules:
		var a : AABB = _get_module_cached_aabb(mod)
		var c : Vector3 = a.get_center() if a.size != Vector3.ZERO else mod.global_position
		var dx : float = c.x - origin.x
		var dz : float = c.z - origin.z
		if dx * dx + dz * dz > r2:
			break
		n += 1
	return n


# A candidate point is usable if a small sphere there touches no level geometry (module
# boxes are axis-aligned, so L/T-shaped rooms contain wall volume) and there is floor
# beneath it. Only possible once the colliders are in the physics space; callers run a
# couple of frames after generation. Without a physics space the point is accepted as-is.
var _clear_query : PhysicsShapeQueryParameters3D = null

func _point_is_clear(p: Vector3, probe_y: float) -> bool:
	if not is_inside_tree():
		return true
	var world : World3D = get_viewport().world_3d if get_viewport() != null else null
	var space : PhysicsDirectSpaceState3D = world.direct_space_state if world != null else null
	if space == null:
		return true
	if _clear_query == null:
		_clear_query = PhysicsShapeQueryParameters3D.new()
		var s := SphereShape3D.new()
		s.radius = 0.35
		_clear_query.shape = s
		_clear_query.collision_mask = 1
	_clear_query.transform = Transform3D(Basis(), Vector3(p.x, probe_y, p.z))
	for hit in space.intersect_shape(_clear_query, 8):
		if PhysicsUtil.is_world_geometry(hit.get("collider")):
			return false
	var rq := PhysicsRayQueryParameters3D.create(Vector3(p.x, probe_y, p.z), Vector3(p.x, probe_y - 4.0, p.z))
	rq.collision_mask = 1
	return not PhysicsUtil.ray_world(space, rq).is_empty()


# True if a sphere of `radius` at p touches no level geometry (walls, floors, door plugs).
# Used for objects that are deliberately placed near walls (flush furniture) where the
# larger clearance of _point_is_clear() would be wrong.
func is_position_clear(p: Vector3, radius: float = 0.1) -> bool:
	if not is_inside_tree():
		return true
	var world : World3D = get_viewport().world_3d if get_viewport() != null else null
	var space : PhysicsDirectSpaceState3D = world.direct_space_state if world != null else null
	if space == null:
		return true
	var q := PhysicsShapeQueryParameters3D.new()
	var s := SphereShape3D.new()
	s.radius = radius
	q.shape = s
	q.transform = Transform3D(Basis(), p)
	q.collision_mask = 1
	for hit in space.intersect_shape(q, 8):
		if PhysicsUtil.is_world_geometry(hit.get("collider")):
			return false
	return true


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
	const SPAWN_FILTER_TRIES : int = 5      # spawn-marker distance is a soft preference
	const MAX_RETRIES : int = 24            # not being inside a wall is not
	var probe_y : float = mod.global_position.y + maxf(y, 0.7)
	for _i in MAX_RETRIES:
		var candidate := Vector3(
			randf_range(a.position.x + mx, a.position.x + a.size.x - mx),
			mod.global_position.y + y,
			randf_range(a.position.z + mz, a.position.z + a.size.z - mz)
		)
		if not _point_is_clear(candidate, probe_y):
			continue
		var clear : bool = true
		if _i < SPAWN_FILTER_TRIES:
			for spawn in registered_typed_spawns:
				var p : Vector3 = spawn.get("position", Vector3.ZERO)
				var dx : float = p.x - candidate.x
				var dz : float = p.z - candidate.z
				if dx * dx + dz * dz < SPAWN_MIN_DIST_SQ:
					clear = false
					break
		if clear:
			return candidate
	# No candidate was clear of the level geometry after MAX_RETRIES: report "no safe point"
	# (Vector3.ZERO, which every caller skips) instead of returning a point known to be in a
	# wall. Without a physics space nothing could be validated, so keep the old behaviour.
	if is_inside_tree():
		return Vector3.ZERO
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
	# Slight inward margin so points right on the edge of a module wall
	# (where geometry is ambiguous) are rejected conservatively.
	var margin : float = 0.3
	for mod in _modules_near_point(pos):
		var aabb : AABB = _get_module_cached_aabb(mod)
		if aabb.size == Vector3.ZERO:
			continue
		if pos.x >= aabb.position.x + margin \
		and pos.x <= aabb.position.x + aabb.size.x - margin \
		and pos.z >= aabb.position.z + margin \
		and pos.z <= aabb.position.z + aabb.size.z - margin:
			return true
	return false


# Point queries (is_position_inside_dungeon, get_module_containing_point) used to loop over every placed
# module: the enemy manager alone asks once per spawn marker (~340 x ~330 boxes). The XZ footprints are
# bucketed once, lazily, after generation; a point only meets the modules whose footprint covers its cell.
# Rebuilt when the module list changes size. Returns the modules in placed_modules order.
var _point_grid : Dictionary = {}   # Vector2i -> Array[Node3D] (placed order)
var _point_grid_count : int = -1


func _modules_near_point(pos: Vector3) -> Array:
	if _point_grid_count != placed_modules.size():
		_rebuild_point_grid()
	var cell = _point_grid.get(_grid_cell(pos))
	return cell if cell != null else []


func _rebuild_point_grid() -> void:
	_point_grid.clear()
	for mod in placed_modules:
		if not is_instance_valid(mod):
			continue
		var a : AABB = _get_module_cached_aabb(mod)
		if a.size == Vector3.ZERO:
			continue
		var lo : Vector2i = _grid_cell(a.position)
		var hi : Vector2i = _grid_cell(a.position + a.size)
		for x in range(lo.x, hi.x + 1):
			for z in range(lo.y, hi.y + 1):
				var key := Vector2i(x, z)
				if _point_grid.has(key):
					(_point_grid[key] as Array).append(mod)
				else:
					_point_grid[key] = [mod]
	_point_grid_count = placed_modules.size()


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
	for mod in _modules_near_point(pos):
		var aabb : AABB = _get_module_cached_aabb(mod)
		if aabb.size == Vector3.ZERO:
			continue
		if pos.x >= aabb.position.x and pos.x <= aabb.position.x + aabb.size.x \
		and pos.z >= aabb.position.z and pos.z <= aabb.position.z + aabb.size.z:
			return mod
	return null
