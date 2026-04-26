# ============================================================
#  FILE: room_lock_manager.gd
#  PATH: res://scripts/room_lock_manager.gd
#  DESCRIPTION: Soft-lock encounter system for the three large room types.
#
#  When the player first enters one of the large rooms:
#    1. A pulsating red orb blocker is placed at each Connection_ doorway,
#       sealing the room (StaticBody3D — blocks player and enemies alike).
#    2. Five brute enemies are spawned fanned 180° behind the player at 4m.
#    3. Each enemy receives only the room's coursec waypoints so it walks
#       into the room, then switches to LOS pursuit of the player.
#    4. When all five enemies die the orb blockers are removed.
#
#  Each large room can only lock once per run.
#  Wired up by Purgatory_Dungeon_main_game_file._boot_room_lock_manager().
# ============================================================
extends Node3D

const LARGE_ROOM_PATHS : Array[String] = [
	"res://dungeon modules/new_collision_rectangle_4_opening.tscn",
	"res://dungeon modules/collision_x_large_room_2_opening.tscn",
	"res://dungeon modules/collision_large_4_way_room_2_sides_connected.tscn",
]

const LOCK_ENEMY_COUNT   : int   = 5
const SPAWN_FAN_RADIUS   : float = 6.0   # Metres from player per spawn (toward room centre)
# Extra distance enemies walk AWAY from the player before turning to engage.
# Prevents the instant crowd-rush: they spawn, back up, then come at the player.
const RETREAT_EXTRA      : float = 4.0
# If enemies are still alive N seconds after the lock triggers, force-unlock.
# Prevents permanent lockdowns from stuck/unreachable/glitched enemies.
const LOCK_TIMEOUT_SECS  : float = 60.0

# Fan angles in degrees; 5 enemies spread evenly across 160°
const FAN_ANGLES : Array[float] = [-80.0, -40.0, 0.0, 40.0, 80.0]


# ── Per-room state ─────────────────────────────────────────────────────────────
class RoomLock:
	var module    : Node3D = null
	var blockers  : Array  = []   # StaticBody3D nodes, one per Connection_
	var remaining : int    = 0    # Counts down from LOCK_ENEMY_COUNT to 0 (used for logging)
	var room_aabb : AABB   = AABB()  # Room bounds — used to detect live enemies inside


# ── Runtime references ─────────────────────────────────────────────────────────
var _player      : Node3D    = null
var _dungeon_gen : Node      = null
var _enemy_mgr   : Node3D    = null
var _cleared     : Dictionary = {}   # module → true — prevents re-locking
# Active locks kept here so the RoomLock object is not garbage-collected while
# enemies are still alive.  Removed in _unlock_room().
var _active_locks : Array     = []


# ══════════════════════════════════════════════════════════════
#  BOOT
# ══════════════════════════════════════════════════════════════

func boot(player: Node3D, dungeon_gen: Node, enemy_mgr: Node3D) -> void:
	_player      = player
	_dungeon_gen = dungeon_gen
	_enemy_mgr   = enemy_mgr
	_setup_room_triggers()


# ══════════════════════════════════════════════════════════════
#  TRIGGER SETUP
# ══════════════════════════════════════════════════════════════

func _setup_room_triggers() -> void:
	if _dungeon_gen == null:
		return
	var modules : Array = _dungeon_gen.placed_modules
	for mod in modules:
		if not is_instance_valid(mod):
			continue
		if not (mod.scene_file_path in LARGE_ROOM_PATHS):
			continue
		_create_trigger_for_module(mod)


func _create_trigger_for_module(mod: Node3D) -> void:
	if not _dungeon_gen.has_method("get_module_aabb"):
		return
	var aabb : AABB = _dungeon_gen.get_module_aabb(mod)
	if aabb.size == Vector3.ZERO:
		return

	var trigger := Area3D.new()
	trigger.set_meta("lock_module", mod)

	var col  := CollisionShape3D.new()
	var box  := BoxShape3D.new()
	# Inset the trigger on XZ so it only fires when the player is well past
	# the doorway — prevents locking the player OUT instead of IN.
	const DOOR_INSET : float = 4.0
	box.size = Vector3(
		maxf(aabb.size.x - DOOR_INSET * 2.0, 2.0),
		aabb.size.y,
		maxf(aabb.size.z - DOOR_INSET * 2.0, 2.0)
	)
	col.shape = box
	trigger.add_child(col)

	mod.add_child(trigger)
	trigger.global_position = aabb.get_center()
	trigger.body_entered.connect(_on_trigger_body_entered.bind(trigger))


# ══════════════════════════════════════════════════════════════
#  TRIGGER CALLBACK
# ══════════════════════════════════════════════════════════════

func _on_trigger_body_entered(body: Node3D, trigger: Area3D) -> void:
	if not is_instance_valid(body) or not body.is_in_group("player"):
		return
	if not is_instance_valid(trigger) or not trigger.has_meta("lock_module"):
		return
	var mod : Node3D = trigger.get_meta("lock_module") as Node3D
	if not is_instance_valid(mod):
		return
	if _cleared.has(mod):
		return

	_cleared[mod] = true              # Prevent any second fire
	trigger.call_deferred("queue_free")  # Defer so Jolt finishes flushing events before the Area3D is freed
	_lock_room(mod)


# ══════════════════════════════════════════════════════════════
#  ROOM LOCK
# ══════════════════════════════════════════════════════════════

func _lock_room(mod: Node3D) -> void:
	# ── Wait until the player is confirmed INSIDE the room ───────────────────
	# Two-part check each poll:
	#   1. room_aabb.has_point() — definitive inside/outside test.
	#      Being 3.5 m outside the door also fails this, preventing lockouts.
	#   2. Distance from every doorway (Connection_ node) > DOOR_SAFE_DIST —
	#      guards against locking while the player straddles the threshold.
	# Polls every 0.4 s; gives up after ~5 s so a doorway-camper still gets
	# the encounter rather than being able to stall it indefinitely.
	const DOOR_SAFE_DIST : float = 3.0   # Metres clearance from each doorway
	const MAX_DOOR_WAITS : int   = 12    # 12 × 0.4 s = 4.8 s max wait

	var connections : Array = []
	_collect_connection_nodes(mod, connections)

	# Grab the room AABB once — used every poll to test inside/outside.
	var room_aabb : AABB = AABB()
	if _dungeon_gen != null and _dungeon_gen.has_method("get_module_aabb"):
		room_aabb = _dungeon_gen.get_module_aabb(mod)

	var player_confirmed_inside : bool = false
	for _w in MAX_DOOR_WAITS:
		if not is_instance_valid(_player) or not is_instance_valid(mod):
			return

		var player_pos : Vector3 = _player.global_position

		# Primary: player must be physically inside the room
		var in_room : bool = room_aabb.size == Vector3.ZERO \
			or room_aabb.has_point(player_pos)

		# Secondary: player must not be straddling any doorway threshold
		var door_clear : bool = true
		if in_room:
			for conn in connections:
				if not is_instance_valid(conn):
					continue
				if player_pos.distance_to(
						(conn as Node3D).global_position) < DOOR_SAFE_DIST:
					door_clear = false
					break

		if in_room and door_clear:
			player_confirmed_inside = true
			break   # Player is safely inside — proceed with lock

		await get_tree().create_timer(0.4).timeout

	# If we exhausted all polls without confirming the player inside,
	# abort — do NOT lock. This prevents locking the player out if they
	# backed away from the trigger or the AABB check timed out.
	if not player_confirmed_inside:
		return

	# Final validity check after any awaiting
	if not is_instance_valid(_player) or not is_instance_valid(mod):
		return

	var lock := RoomLock.new()
	lock.module    = mod
	lock.remaining = LOCK_ENEMY_COUNT
	lock.room_aabb = room_aabb   # Store for live-enemy scan on each death
	_active_locks.append(lock)   # Keep alive until _unlock_room() removes it

	# ── Seal every doorway with a pulsating red barrier ───────────────────────
	# Re-collect connections (list was built above for the door-wait check)
	connections.clear()
	_collect_connection_nodes(mod, connections)
	for conn in connections:
		if not is_instance_valid(conn):
			continue
		var blocker := _build_orb_blocker()
		mod.add_child(blocker)
		blocker.global_transform = (conn as Node3D).global_transform
		lock.blockers.append(blocker)
		_start_orb_pulse(blocker)

	# ── Clear space for the encounter — cull the 5 furthest existing enemies ──
	if _enemy_mgr != null and _enemy_mgr.has_method("cull_for_room_lock"):
		_enemy_mgr.cull_for_room_lock(LOCK_ENEMY_COUNT)

	# ── Gather this room's coursec waypoints for the spawned enemies ──────────
	var room_coursecs : Array[Vector3] = []
	if _dungeon_gen != null and _dungeon_gen.has_method("get_coursec_positions_in_module"):
		room_coursecs = _dungeon_gen.get_coursec_positions_in_module(mod)

	# ── Spawn 5 enemies fanned toward the room centre ────────────────────────
	# Previously spawned BEHIND the player (toward the doorway they just walked
	# through). Player only needs 3 m clearance from the door to confirm "inside",
	# so 4 m behind = 1 m past the entrance = outside the room AABB. Blockers
	# then sealed the door with all enemies on the corridor side → soft-lock.
	# Fix: fan toward the room centre so all spawn positions are inside the AABB.
	var to_center : Vector3 = room_aabb.get_center() - _player.global_position
	to_center.y = 0.0
	if to_center.length_squared() < 0.01:
		to_center = Vector3.FORWARD
	var back : Vector3 = to_center.normalized()

	var spawned : int = 0
	for i in LOCK_ENEMY_COUNT:
		var angle : float   = deg_to_rad(FAN_ANGLES[i])
		var dir   : Vector3 = back.rotated(Vector3.UP, angle)
		var pos   : Vector3 = _player.global_position + dir * SPAWN_FAN_RADIUS

		# Safety clamp: if the calculated position is outside the room AABB
		# (e.g. near a corner), pull it back to 60 % of the way to room centre.
		if not room_aabb.has_point(pos):
			pos = _player.global_position.lerp(room_aabb.get_center(), 0.6)
			pos.y = _player.global_position.y + 0.1

		# First waypoint: enemies fan FURTHER into the room before turning to
		# engage — prevents the instant crowd-rush at the entrance.
		var retreat_pos : Vector3 = pos + dir * RETREAT_EXTRA
		var wps : Array = [retreat_pos]
		# Second waypoint: a unique coursec point so enemies spread into the room.
		if not room_coursecs.is_empty():
			wps.append(room_coursecs[i % room_coursecs.size()])

		var enemy := _force_spawn(pos, wps)
		if enemy == null:
			continue
		if enemy.has_signal("died"):
			enemy.died.connect(_on_lock_enemy_died.bind(lock))
			spawned += 1

	# If nothing spawned (enemy manager not ready), unlock immediately
	if spawned == 0:
		_unlock_room(lock)
	else:
		# Adjust remaining count in case some spawn calls failed silently
		lock.remaining = spawned
		# Safety net: if enemies glitch/get stuck and the signal never fires,
		# force-unlock after LOCK_TIMEOUT_SECS so the player is never permanently trapped.
		_start_lock_timeout(lock)


# ══════════════════════════════════════════════════════════════
#  TIMEOUT FAILSAFE
# ══════════════════════════════════════════════════════════════

# Waits LOCK_TIMEOUT_SECS, then force-unlocks if the lock is still active.
# Protects the player from being permanently trapped by stuck enemies.
func _start_lock_timeout(lock: RoomLock) -> void:
	await get_tree().create_timer(LOCK_TIMEOUT_SECS).timeout
	# Only act if the lock is still in _active_locks (not yet naturally unlocked)
	if _active_locks.has(lock):
		push_warning("RoomLockManager: encounter timed out — force-unlocking room.")
		_unlock_room(lock)


# ══════════════════════════════════════════════════════════════
#  HELPERS
# ══════════════════════════════════════════════════════════════

func _collect_connection_nodes(node: Node, result: Array) -> void:
	for child in node.get_children():
		if child is Node3D and (child as Node3D).name.begins_with("Connection_"):
			result.append(child)
		_collect_connection_nodes(child, result)


func _build_orb_blocker() -> StaticBody3D:
	var body := StaticBody3D.new()

	# Collision box — wide enough to seal a standard doorway
	var col  := CollisionShape3D.new()
	var box  := BoxShape3D.new()
	box.size  = Vector3(3.2, 4.0, 0.5)
	col.shape = box
	body.add_child(col)

	# Visual — flat glowing barrier that fills the doorframe
	var mesh_inst  := MeshInstance3D.new()
	var door_mesh  := BoxMesh.new()
	door_mesh.size  = Vector3(3.2, 4.0, 0.12)   # Width × height match the collision box; thin depth
	mesh_inst.mesh  = door_mesh

	var mat                        := StandardMaterial3D.new()
	mat.albedo_color                = Color(1.0, 0.08, 0.08, 1.0)   # Full alpha — no transparency needed
	mat.emission_enabled            = true
	mat.emission                    = Color(1.0, 0.0, 0.0)
	mat.emission_energy_multiplier  = 3.0
	mat.shading_mode                = BaseMaterial3D.SHADING_MODE_UNSHADED
	# TRANSPARENCY_DISABLED keeps this object opaque and occlusion-culling-friendly.
	# The pulsing glow + bloom from the emission makes it look semi-transparent anyway.
	mat.transparency                = BaseMaterial3D.TRANSPARENCY_DISABLED
	mesh_inst.material_override     = mat

	body.add_child(mesh_inst)
	return body


func _start_orb_pulse(blocker: StaticBody3D) -> void:
	for child in blocker.get_children():
		if not (child is MeshInstance3D):
			continue
		var mat := (child as MeshInstance3D).material_override as StandardMaterial3D
		if mat == null:
			continue
		# Tween is owned by the mesh node — dies automatically when blocker is freed
		var t := (child as Node).create_tween().set_loops()
		t.tween_property(mat, "emission_energy_multiplier", 8.0, 0.7)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		t.tween_property(mat, "emission_energy_multiplier", 2.0, 0.7)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _force_spawn(pos: Vector3, waypoints: Array) -> Node3D:
	if _enemy_mgr == null or not is_instance_valid(_enemy_mgr):
		return null
	if not _enemy_mgr.has_method("force_spawn_at"):
		return null
	# Challenge rooms always spawn enemies at 2 "difficulty levels" above the current
	# day progression. Linear ramp at 2× the normal per-day rate (5% per day vs 2.5%),
	# floored at 1.75× so day-1 rooms are already a real threat.
	# Day 15 → ~2.25×, Day 30 → ~3.0× (normal enemies cap at ~2.39× on day 30).
	var current_day : int = 1
	if has_node("/root/GameClock"):
		current_day = GameClock.current_day
	var challenge_mult : float = clampf(1.0 + float(current_day) * 0.075, 1.75, 3.5)
	return _enemy_mgr.force_spawn_at(pos, waypoints, challenge_mult)


# ══════════════════════════════════════════════════════════════
#  DEATH TRACKING & UNLOCK
# ══════════════════════════════════════════════════════════════

func _on_lock_enemy_died(lock: RoomLock) -> void:
	lock.remaining -= 1
	# Scan the room AABB for any live enemy still inside.
	# This handles: enemies that escaped before blockers went up (outside AABB →
	# not counted), enemies recycled without firing died, and any other edge case.
	# As long as the player is alone in the room, the doors open.
	if _count_live_enemies_in_room(lock.room_aabb) == 0:
		_unlock_room(lock)


# Returns the number of living enemies whose position falls inside aabb.
# Enemies outside the room (escaped through a gap, wandered out) are ignored.
func _count_live_enemies_in_room(aabb: AABB) -> int:
	# Zero AABB means we couldn't get valid bounds — fall back to 0 so the room
	# unlocks rather than trapping the player forever.
	if aabb.size == Vector3.ZERO:
		return 0
	var count : int = 0
	for enemy in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(enemy) or not (enemy is Node3D):
			continue
		if enemy.get("_is_dead") == true:
			continue
		if aabb.has_point((enemy as Node3D).global_position):
			count += 1
	return count


func _unlock_room(lock: RoomLock) -> void:
	for blocker in lock.blockers:
		if is_instance_valid(blocker):
			blocker.queue_free()
	lock.blockers.clear()
	_active_locks.erase(lock)   # Release the strong reference — GC can now collect
