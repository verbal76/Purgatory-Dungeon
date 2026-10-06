# ==============================================================================
#  FILE: brute_ai.gd
#  PATH: res://characters/brute/scripts/brute_ai.gd
#  ATTACHED TO: res://characters/brute/scenes/brute_enemy.tscn
#  DESCRIPTION: Brute enemy AI controller.
#               Waypoint-guided navigation with LOS switch to direct pursuit 
#               when the player is visible. Fan-steering wall avoidance keeps 
#               the enemy from walking through geometry. 4-way death rays orient 
#               the corpse so the fall-backward animation clears the nearest wall.
#  MOD NOTES:
#  - SURGICAL FIX: Waypoint optimization. Added 30-meter radius cull 
#    (distance_squared < 900.0) to _find_best_waypoint_toward_player to prevent CPU spikes.
#  - SURGICAL FIX: Ally-blocking LoS reroute. _los_query now hits all 
#    layers and drops _has_los if an idle/blocking ally is between brute and player.
#  - Replaced NavigationServer3D.query_path() (crash-prone after procedural
#    generation) with a waypoint graph received via initialize_waypoints().
#  - LOS check (throttled): when a raycast to the player is clear, the enemy
#    switches from waypoint-hopping to direct pursuit.
#  - Fan steering: 6-step rotational fan search finds the wall-clear direction
#    closest to the desired heading. PhysicsRayQueryParameters3D cached.
#  - apply_buff() and apply_red_glow() are handled by character_base.
#  - SURGICAL FIX: Cached [get_rid()] in _on_ready to prevent massive array allocations.
#  - SURGICAL FIX: _on_die instantly calls queue_free() after animation to prevent the
#    corpse from resetting to T-pose and immediately clears the live enemy count slot.
#  - SURGICAL FIX: Throttled the heavy wall-avoidance raycast logic to ~6Hz. 
#  - SURGICAL FIX: Added Waypoint LOS verification and Tabu memory array to 
#    prevent enemies from getting stuck against walls or trapped in local minima corners.
#  - SURGICAL FIX: "Score First, Raycast Later" algorithm implemented in waypoint
#    selection to prevent severe CPU bottlenecking from mass raycast loops.
#  - SURGICAL FIX: Replaced `:=` with explicit `: float = ...` typing for 
#    dynamic SettingsManager variables to prevent static analyzer crashes.
#  - SURGICAL FIX: Removed Mage-specific DEATH_ANIMS dictionary call.
# ==============================================================================
extends BruteCharacter

var PotionPickupScript = load("res://objects/pickups/PotionPickup.gd")

# Enemies move 25 % faster while they haven't yet sighted the player.
# Dropped permanently the moment first LOS is acquired.
const APPROACH_SPEED_MULT : float = 1.25

# ── Movement / Engagement settings ────────────────────────────────────────────
@export var far_speed          : float = 5.0   # Speed when player is far away
@export var mid_speed          : float = 6.5   # Speed at mid range
@export var close_speed        : float = 8.0   # Speed when closing in
@export var far_range          : float = 16.0  # Distance threshold: far to mid
@export var mid_range          : float = 8.0   # Distance threshold: mid to close
@export var close_range        : float = 3.5   # Distance threshold: close
@export var base_stop_distance : float = 1.6   # Ideal standoff distance
@export var dynamic_stop_scaling : float = 0.5 # How much player velocity shifts the stop distance
@export var range_buffer       : float = 0.20  # Hysteresis band to prevent jitter
@export var run_anim_speed_threshold : float = 0.1  # Min speed before run anim plays

# ── Combat settings ────────────────────────────────────────────────────────────
@export var attack_range     : float = 2.0   # Melee attack trigger distance
@export var attack_cooldown  : float = 2.0   # Seconds between attacks
@export var attack_speed_scale : float = 1.0 # Multiplier on attack animation speed
@export var attack_damage    : float = 7.5   # Base damage per hit

# ── Kick (close-range interrupt) ───────────────────────────────────────────────
# Brute enemy sprints at the player and kicks when in range.
# Knocks the player back and stuns for 3 seconds.
# Chance gate prevents kick from triggering every available tick.
@export var enemy_kick_range    : float = 2.5   # Metres — trigger distance
@export var enemy_kick_cooldown : float = 12.0  # Seconds between kicks
@export var enemy_kick_damage   : float = 10.0  # Impact damage
@export var enemy_kick_force    : float = 10.0  # Knockback impulse
@export var enemy_kick_stun     : float = 3.0   # Player stun duration (seconds)
@export var enemy_kick_chance   : float = 0.25  # Random gate [0,1] per eligible tick

# ── Navigation settings ────────────────────────────────────────────────────────
@export var use_activation_range     : bool  = false # If true, sleep outside activation_range
@export var activation_range         : float = 40.0  # Range before enemy wakes up
@export var idle_outside_activation  : bool  = true  # Play idle when sleeping
@export var move_acceleration        : float = 18.0  # How fast velocity builds
@export var stop_acceleration        : float = 22.0  # How fast velocity brakes
@export var nav_refresh_interval     : float = 0.30  # Seconds between waypoint target updates
@export var los_check_interval       : float = 0.50  # Seconds between LOS raycasts to player (was 0.35 — 30% fewer raycasts)
@export var waypoint_reach_distance  : float = 1.8   # Metres before we pick the next waypoint
@export var fan_step_degrees         : float = 15.0  # Fan steering rotation step in degrees
@export var fan_max_steps            : int   = 6     # Maximum fan steps each direction
@export var fan_ray_length           : float = 1.8   # Wall clearance raycast distance

# ── Audio assets ──────────────────────────────────────────────────────────────
var hurt_sound  : AudioStream = preload("res://Music & background images/Sound Effects/male-hurt-sound-95206.mp3")
var death_sound : AudioStream = preload("res://Music & background images/Sound Effects/dramatic-death-collapse-352720 (1).mp3")

const FLASH_DURATION : float = 0.12

# ── Potion drop tuning ─────────────────────────────────────────────────────────
# All three values are plain constants so they're easy to find and tweak.
const POTION_DROP_BASE_PCT     : int = 6  # Base % chance per kill          (was 10)
const POTION_DROP_SCAVENGE_PCT : int = 3  # Bonus % per scavenge perk level (was 5)
const POTION_DROP_GREED_PCT    : int = 5  # % chance of 2nd drop per greed level (was 10)
# Chest key drop (persistent across runs; any enemy, any colour, rare).
const KEY_DROP_PCT             : int = 5
const _KeyPickupScript = preload("res://scripts/key_pickup.gd")
const _KEY_COLORS              : Array[String] = ["bronze", "silver", "gold"]

# ── Runtime state — all cached in _on_ready(), never fetched mid-frame ─────────
var _is_attacking          : bool   = false
var _attack_cooldown_timer : float  = 0.0
var _is_kicking_ai         : bool   = false
var _kick_cooldown_timer   : float  = 0.0
var _cached_player         : Node3D = null
var _last_global_pos       : Vector3 = Vector3.ZERO
var _smoothed_player_vel   : Vector3 = Vector3.ZERO
var _smoothed_actual_speed : float  = 0.0
var _current_dynamic_stop  : float  = 1.6
var _hit_flash_timer       : float  = 0.0
var _hit_flash_material    : StandardMaterial3D = null
var _flash_meshes          : Array[MeshInstance3D] = []
var _stun_indicator_root   : Node3D = null
# FIX 4: Cached star node refs — avoids get_child() inside loop every frame.
var _stun_stars            : Array[Node3D] = []
var _stun_was_active       : bool = false   # dirty flag — block only runs on state change
var _frustration_timer     : float  = 0.0

# ── Throttle State for Physics CPU Relief ─────────────────────────────────────
var _wall_check_timer      : float   = 0.0
var _last_safe_dir         : Vector3 = Vector3.ZERO

# ── Waypoint navigation state ─────────────────────────────────────────────────
var _waypoints             : Array   = []       # Array[Vector3] from dungeon generator
var _current_target        : Vector3 = Vector3.ZERO # Position enemy is currently walking toward
var _nav_timer             : float   = 0.0      # Throttle for waypoint target updates
var _los_timer             : float   = 0.0      # Throttle for LOS raycast to player
var _has_los               : bool    = false    # Cached LOS state
var _approach_boost        : bool    = false    # True until first LOS; +25% speed
var _visited_waypoints     : Array[Vector3] = [] # Memory for Tabu search (ordered, for eviction)
var _visited_wp_set        : Dictionary     = {} # O(1) lookup mirror of _visited_waypoints

# ── Object pool support ───────────────────────────────────────────────────────
# Set by EnemyManager when acquiring this enemy from the pool.
# If valid on death, calls back into EnemyManager to recycle instead of queue_free().
var _pool_return : Callable = Callable()

# ── Cached PhysicsRayQueryParameters3D (no allocations in _physics_process) ───
var _wall_query : PhysicsRayQueryParameters3D = null
var _los_query  : PhysicsRayQueryParameters3D = null

# ── Cached SettingsManager values — refreshed every 5s, NOT every tick ────────
# SettingsManager.get_setting() is a string dictionary lookup. At 15 enemies ×
# 60Hz = 900 lookups/sec. Caching drops this to 3 lookups/sec.
var _cached_speed_mult  : float = 1.0
var _cached_damage_mod  : float = 1.0
var _settings_cache_timer : float = 0.0
const SETTINGS_CACHE_INTERVAL : float = 5.0



# ══════════════════════════════════════════════════════════════════════════════
#  SETUP
# ══════════════════════════════════════════════════════════════════════════════

func _on_ready() -> void:
	var health_mult : float = float(SettingsManager.get_setting("HealthSlider", 100.0)) / 100.0
	max_health      = 50.0 * health_mult
	_current_health = max_health

	set_armed(true)
	add_to_group("enemy")
	add_to_group("enemies") 

	var speed_variance = randf_range(0.85, 1.15)
	far_speed   *= speed_variance
	mid_speed   *= speed_variance
	close_speed *= speed_variance

	_attack_cooldown_timer = randf() * 1.5
	_nav_timer             = randf() * nav_refresh_interval
	_los_timer             = randf() * los_check_interval
	_frustration_timer     = randf() * 4.0
	_wall_check_timer      = randf_range(0.0, 0.15)

	_setup_hit_flash()
	_build_stun_indicator()
	_last_global_pos = global_position
	connect("health_changed", _on_enemy_health_changed)

	# ── Disable shadow casting — skeletal mesh shadows are the most expensive
	# GPU operation in crowd scenes. Disabling across all mesh instances gives
	# a 30-50% GPU improvement with 10+ enemies with no visible quality loss.
	_disable_shadows_recursive(self)

	# ── Prime the settings cache so tick 0 has valid values ───────────────────
	_cached_speed_mult  = float(SettingsManager.get_setting("SpeedSlider",  100.0)) / 100.0
	_cached_damage_mod  = float(SettingsManager.get_setting("DamageSlider", 100.0)) / 100.0

	_wall_query = PhysicsRayQueryParameters3D.new()
	_wall_query.collide_with_bodies = true
	_wall_query.collision_mask      = 1  # Static geometry only
	_wall_query.exclude             = [get_rid()]

	_los_query = PhysicsRayQueryParameters3D.new()
	_los_query.collide_with_bodies = true
	_los_query.collide_with_areas  = false
	_los_query.collision_mask      = 0xFFFFFFFF # Hits all layers
	_los_query.exclude             = [get_rid()]


func initialize_waypoints(points: Array) -> void:
	_waypoints = points
	if not _waypoints.is_empty():
		_current_target = _waypoints[randi() % _waypoints.size()]
	_approach_boost = true   # Boost active until first LOS


func _on_buff_applied(multiplier: float) -> void:
	far_speed     *= multiplier
	mid_speed     *= multiplier
	close_speed   *= multiplier
	attack_damage *= multiplier


# ══════════════════════════════════════════════════════════════════════════════
#  WAYPOINT NAVIGATION
# ══════════════════════════════════════════════════════════════════════════════

func _find_best_waypoint_toward_player(player_pos: Vector3) -> Vector3:
	if _waypoints.is_empty():
		return player_pos

	var my_pos : Vector3 = global_position
	var space  := get_world_3d().direct_space_state

	# SURGICAL FIX: Use Vector4 (xyz=position, w=distance score) instead of
	# a Dictionary per candidate. Dictionary allocates a heap object per entry —
	# with 20+ waypoints in range this caused significant GC churn every nav tick.
	# Vector4 is a value type: no heap allocation per element.
	var scored_wps : Array[Vector4] = []

	for i in range(_waypoints.size()):
		var wp : Vector3 = _waypoints[i]
		if my_pos.distance_squared_to(wp) < 900.0:
			var d : float = player_pos.distance_squared_to(wp)
			if _visited_wp_set.has(wp):
				d += 9999.0
			scored_wps.append(Vector4(wp.x, wp.y, wp.z, d))

	scored_wps.sort_custom(func(a: Vector4, b: Vector4): return a.w < b.w)

	for entry in scored_wps:
		var wp_pos := Vector3(entry.x, entry.y, entry.z)
		_wall_query.from = my_pos + Vector3(0.0, 1.0, 0.0)
		_wall_query.to   = wp_pos + Vector3(0.0, 1.0, 0.0)
		if space.intersect_ray(_wall_query).is_empty():
			return wp_pos

	var best_pos  : Vector3 = player_pos
	var best_dist : float   = INF
	for i in range(_waypoints.size()):
		var wp : Vector3 = _waypoints[i]
		var d : float = my_pos.distance_squared_to(wp)
		if d < best_dist:
			best_dist = d
			best_pos  = wp

	return best_pos


func _update_los(player: Node3D, delta: float) -> void:
	_los_timer += delta
	if _los_timer < los_check_interval:
		return
	_los_timer = 0.0

	var space := get_world_3d().direct_space_state
	var start := global_position + Vector3(0.0, 1.0, 0.0)
	var end   := player.global_position + Vector3(0.0, 1.0, 0.0)

	_los_query.from    = start
	_los_query.to      = end

	# Line of sight is blocked by level geometry only. Allies, props and chests between
	# the brute and the player used to cut sight (the old ally branch set false in both
	# arms), dropping crowds of brutes to waypoint pathing with a clear view.
	var player_rid : Array[RID] = []
	if player is CollisionObject3D:
		player_rid.append(player.get_rid())
	var result := PhysicsUtil.ray_world(space, _los_query, player_rid)

	if result.is_empty():
		if not _has_los:
			_approach_boost = false   # First sighting — drop the approach speed bonus
		_has_los = true
	else:
		_has_los = false


func _update_nav_target(player_pos: Vector3, _delta: float) -> void:
	# FIX 1: Only run the expensive waypoint search when the current target
	# is actually reached — not on a 0.3s timer. Previously every 0.3s fired
	# up to 40 raycasts per enemy. Now runs once per waypoint reached (~3-6s).
	if _has_los:
		_current_target = player_pos
		_visited_waypoints.clear()
		_visited_wp_set.clear()
		return

	# Without LOS: only search when we have arrived at the current target.
	var reached : bool = _current_target == Vector3.ZERO or \
		global_position.distance_squared_to(_current_target) < \
		(waypoint_reach_distance * waypoint_reach_distance)

	if reached:
		if _current_target != Vector3.ZERO and not _visited_wp_set.has(_current_target):
			_visited_waypoints.append(_current_target)
			_visited_wp_set[_current_target] = true
			if _visited_waypoints.size() > 12:
				var evicted : Vector3 = _visited_waypoints.pop_front()
				_visited_wp_set.erase(evicted)
		_current_target = _find_best_waypoint_toward_player(player_pos)


func _find_wall_safe_direction(desired: Vector3) -> Vector3:
	var flat := Vector3(desired.x, 0.0, desired.z).normalized()
	if flat == Vector3.ZERO: return Vector3.ZERO

	# SURGICAL FIX: Cache space state and ray origin once for the entire fan.
	# Previously _direction_clear() fetched direct_space_state on every single
	# raycast — up to 13 separate fetches per call. One fetch is all needed.
	var space := get_world_3d().direct_space_state
	_wall_query.from = global_position + Vector3(0.0, 0.5, 0.0)

	_wall_query.to = _wall_query.from + flat * fan_ray_length
	if space.intersect_ray(_wall_query).is_empty(): return flat

	for step in range(1, fan_max_steps + 1):
		var angle : float = deg_to_rad(fan_step_degrees * float(step))
		var left  := flat.rotated(Vector3.UP,  angle).normalized()
		var right := flat.rotated(Vector3.UP, -angle).normalized()
		_wall_query.to = _wall_query.from + left * fan_ray_length
		if space.intersect_ray(_wall_query).is_empty(): return left
		_wall_query.to = _wall_query.from + right * fan_ray_length
		if space.intersect_ray(_wall_query).is_empty(): return right

	return flat


# ══════════════════════════════════════════════════════════════════════════════
#  DAMAGE & HIT REACTIONS
# ══════════════════════════════════════════════════════════════════════════════

func take_damage(amount: float, _source: Node = null) -> void:
	if _is_dead: return
	_last_damage_source = _source   # Required for kill-credit in _trigger_death()
	_current_health -= amount
	health_changed.emit(_current_health, max_health)
	if _current_health <= 0:
		_trigger_death()
	else:
		_play_hit_react()


func _play_hit_react() -> void:
	var _life : int = _life_id   # abort if this enemy is pooled/reborn while we wait
	if anim_player == null: return
	_is_reacting  = true
	_is_attacking = false
	velocity.x    = 0.0
	velocity.z    = 0.0

	if hurt_sound != null and has_node("/root/AudioManager"):
		AudioManager.play_3d_one_shot(hurt_sound, global_position, 6.0, randf_range(0.75, 0.95))

	var anim_to_play := "react_gut"
	var player := _find_player()
	if player != null:
		var to_hit  := (player.global_position - global_position).normalized()
		var forward := -global_transform.basis.z.normalized()
		var right   :=  global_transform.basis.x.normalized()
		if abs(forward.dot(to_hit)) > abs(right.dot(to_hit)):
			anim_to_play = "react_gut" if forward.dot(to_hit) > 0.0 else "react_back"
		else:
			anim_to_play = "react_right" if right.dot(to_hit) > 0.0 else "react_left"

	anim_player.speed_scale = react_anim_speed
	_play_anim(anim_to_play)
	await anim_player.animation_finished
	if _life != _life_id: return
	anim_player.speed_scale = 1.0
	_is_reacting = false
	if not _is_dead:
		_change_state(_get_idle_state())


func _setup_hit_flash() -> void:
	_hit_flash_material = StandardMaterial3D.new()
	_hit_flash_material.transparency              = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hit_flash_material.albedo_color              = Color(1.0, 1.0, 1.0, 0.35)
	_hit_flash_material.emission_enabled          = true
	_hit_flash_material.emission                  = Color(1.0, 1.0, 1.0)
	_hit_flash_material.emission_energy_multiplier = 1.6
	_flash_meshes.clear()
	_collect_flash_meshes(mesh_root if mesh_root != null else self)


func _collect_flash_meshes(node: Node) -> void:
	if node is MeshInstance3D:
		_flash_meshes.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_flash_meshes(child)


func _start_hit_flash() -> void:
	_hit_flash_timer = FLASH_DURATION
	for mesh in _flash_meshes:
		if is_instance_valid(mesh):
			mesh.material_overlay = _hit_flash_material


func _clear_hit_flash() -> void:
	for mesh in _flash_meshes:
		if is_instance_valid(mesh):
			mesh.material_overlay = null


func _on_enemy_health_changed(_hp: float, _max: float) -> void:
	_start_hit_flash()


func _build_stun_indicator() -> void:
	_stun_indicator_root          = Node3D.new()
	_stun_indicator_root.position = Vector3(0.0, 1.95, 0.0)
	_stun_indicator_root.visible  = false
	add_child(_stun_indicator_root)

	var star_mat := StandardMaterial3D.new()
	star_mat.albedo_color              = Color(1.0, 0.9, 0.1)
	star_mat.emission_enabled          = true
	star_mat.emission                  = Color(1.0, 0.9, 0.1)
	star_mat.emission_energy_multiplier = 2.0

	var star_mesh := SphereMesh.new()
	star_mesh.radius = 0.06
	star_mesh.height = 0.12

	for i in range(3):
		var star := MeshInstance3D.new()
		star.mesh              = star_mesh
		star.material_override = star_mat
		var angle := (i / 3.0) * TAU
		star.position = Vector3(cos(angle) * 0.4, 0.0, sin(angle) * 0.4)
		_stun_indicator_root.add_child(star)
		# FIX 4: Cache star ref so _process never calls get_child() per frame.
		_stun_stars.append(star)


func _on_die() -> void:
	var _life : int = _life_id   # abort if this enemy is pooled/reborn while we wait
	var main = get_tree().current_scene
	if main and main.has_method("register_enemy_kill"):
		main.register_enemy_kill()

	if death_sound != null and has_node("/root/AudioManager"):
		AudioManager.play_3d_one_shot(death_sound, global_position, 8.0, randf_range(0.65, 0.8))

	if PotionPickupScript != null and SaveManager.current_profile_is_valid():
		var perks       = SaveManager.current_profile.get("perks", {})
		var drop_chance : int = POTION_DROP_BASE_PCT + (perks.get("scavenge", 0) * POTION_DROP_SCAVENGE_PCT)
		if randi() % 100 < drop_chance:
			_spawn_potion_pickup()
			if randi() % 100 < (perks.get("greed", 0) * POTION_DROP_GREED_PCT):
				_spawn_potion_pickup()

	# Chest key drop — independent roll, any colour uniformly random.
	if randi() % 100 < KEY_DROP_PCT:
		_spawn_key_pickup(_KEY_COLORS[randi() % _KEY_COLORS.size()])

	if mesh_root != null:
		var space         := get_world_3d().direct_space_state
		var start         := global_position + Vector3(0.0, 1.0, 0.0)
		var base_backward := -mesh_root.global_transform.basis.z.normalized()
		var best_dist     := -1.0
		var best_angle    := 0.0

		for angle in [0.0, PI, PI / 2.0, -PI / 2.0]:
			var fall_dir := base_backward.rotated(Vector3.UP, angle)
			var end      := start + (fall_dir * 2.5)
			var query    := PhysicsRayQueryParameters3D.create(start, end)
			query.collide_with_bodies = true
			query.exclude             = [self]
			var result := space.intersect_ray(query)
			var dist : float = start.distance_to(result.position) if not result.is_empty() else 2.5
			if dist > best_dist:
				best_dist  = dist
				best_angle = angle

		mesh_root.rotation.y += best_angle

	_play_anim("death")
	collision_layer = 0
	velocity        = Vector3.ZERO
	
	if _stun_indicator_root != null:
		_stun_indicator_root.visible = false

	await get_tree().create_timer(_current_anim_length()).timeout
	if not is_instance_valid(self): return
	if _life != _life_id: return

	# Pool path: return to EnemyManager's pool instead of freeing.
	# Falls back to queue_free() if this enemy was not spawned from a pool
	# (e.g. pressure-spawn fallback) or if EnemyManager was already freed.
	if _pool_return.is_valid():
		_pool_return.call()
	else:
		queue_free()


# ── Pool API ──────────────────────────────────────────────────────────────────

func set_pool_return(cb: Callable) -> void:
	_pool_return = cb


# Called by EnemyManager when re-activating this enemy from the pool.
# Resets all AI and CharacterBase state so the enemy behaves as freshly spawned.
func reset_for_pool(new_pos: Vector3, _new_rot: Vector3, new_waypoints: Array) -> void:
	_life_id += 1                      # invalidate any delayed work from the previous life
	_state = ""                        # force the idle transition below to actually play
	if anim_player != null:
		anim_player.speed_scale = 1.0  # death/react/attack speed must not leak into the new life
	# ── CharacterBase state ──────────────────────────────────────────────────
	_buff_multiplier = 1.0
	max_health       = _base_max_health
	_current_health  = max_health
	_is_dead         = false
	_is_stunned      = false
	_is_reacting     = false
	_stun_timer      = 0.0
	velocity         = Vector3.ZERO
	collision_layer  = 1   # Restored — _on_die() zeroes this for the corpse
	# T1.4 — prime the LOD timer so pooled respawns also get an immediate
	# distance check on their first physics tick back alive.
	_lod_dist_timer  = 1.0
	_lod_frame_counter = 0

	# ── AI state ─────────────────────────────────────────────────────────────
	_is_attacking          = false
	_is_kicking_ai         = false
	_attack_cooldown_timer = randf() * 1.5   # Stagger so not all respawns fire at once
	_kick_cooldown_timer   = randf_range(0.0, 5.0)   # Stagger kicks on respawn
	_wall_check_timer      = randf_range(0.0, 0.15)
	_has_los               = false
	_approach_boost        = true    # Re-arm boost for this new life
	_current_target        = Vector3.ZERO
	_visited_waypoints.clear()
	_visited_wp_set.clear()
	_nav_timer             = randf() * nav_refresh_interval
	_los_timer             = randf() * los_check_interval
	_frustration_timer     = randf() * 4.0   # a reborn brute must not inherit the old life's stuck timer
	_last_global_pos       = new_pos
	_smoothed_actual_speed = 0.0
	# Reset movement state so stale directions from the previous life don't carry over.
	_last_safe_dir         = Vector3.ZERO
	_current_dynamic_stop  = base_stop_distance

	# ── Navigation ───────────────────────────────────────────────────────────
	initialize_waypoints(new_waypoints)

	# ── Position & visibility ─────────────────────────────────────────────────
	# NOTE: Do NOT set global_rotation — mesh facing is fully managed by
	# _physics_tick's atan2 formula which assumes CharacterBody3D.rotation.y = 0.
	global_position = new_pos
	if mesh_root != null:
		mesh_root.rotation.y = MESH_FACING

	# ── UI ───────────────────────────────────────────────────────────────────
	if _stun_indicator_root != null:
		_stun_indicator_root.visible = false

	# ── Re-enable ─────────────────────────────────────────────────────────────
	add_to_group("enemy")    # a parked enemy sits outside the groups (see EnemyManager._park)
	add_to_group("enemies")
	visible = true
	set_physics_process(true)
	set_process(true)

	_change_state(_get_idle_state())
	health_changed.emit(_current_health, max_health)


# A brute that has chased for 12 s without ever seeing the player is retired. It used to be freed and the next
# top-up instantiated a replacement: a free + instantiate pair is a multi-millisecond hitch (many times that on a
# phone). It now goes back to EnemyManager's pool exactly like a corpse does and is reborn by reset_for_pool().
func _retire_stuck() -> void:
	if not _pool_return.is_valid():
		queue_free()
		return
	_is_dead        = true    # EnemyManager's sweep drops dead enemies from its live list; reset_for_pool() revives
	collision_layer = 0
	velocity        = Vector3.ZERO
	_pool_return.call()


func _spawn_potion_pickup() -> void:
	var pickup = PotionPickupScript.new()
	get_parent().add_child(pickup)
	pickup.global_position = global_position


func _spawn_key_pickup(color: String) -> void:
	var pickup := _KeyPickupScript.new()
	pickup._color = color
	get_parent().add_child(pickup)
	pickup.global_position = global_position + Vector3(0.0, 0.4, 0.0)


func _process(delta: float) -> void:
	# ── Refresh cached SettingsManager values periodically ────────────────────
	_settings_cache_timer += delta
	if _settings_cache_timer >= SETTINGS_CACHE_INTERVAL:
		_settings_cache_timer = 0.0
		_cached_speed_mult  = float(SettingsManager.get_setting("SpeedSlider",  100.0)) / 100.0
		_cached_damage_mod  = float(SettingsManager.get_setting("DamageSlider", 100.0)) / 100.0

	if mesh_root != null and mesh_root.position != Vector3.ZERO:
		mesh_root.position = Vector3.ZERO

	if _hit_flash_timer > 0.0:
		_hit_flash_timer -= delta
		if _hit_flash_timer <= 0.0:
			_clear_hit_flash()

	if _is_dead:
		_clear_hit_flash()
		if _stun_indicator_root != null:
			_stun_indicator_root.visible = false
		return

	# FIX 4: Dirty flag so this block only runs when stun state changes or
	# while actively stunned. Eliminates per-frame get_child() calls for all
	# non-stunned enemies (which is almost all of them at any given moment).
	if _is_stunned != _stun_was_active:
		_stun_was_active = _is_stunned
		if _stun_indicator_root != null:
			_stun_indicator_root.visible = _is_stunned

	if _is_stunned and _stun_indicator_root != null:
		_stun_indicator_root.rotation.y += 6.0 * delta
		var msec := Time.get_ticks_msec() / 150.0
		for i in range(_stun_stars.size()):
			_stun_stars[i].position.y = sin(msec + ((i / 3.0) * TAU)) * 0.1


# Recursively disables shadow casting on every GeometryInstance3D in the tree.
# Called once in _on_ready(). Skeletal mesh shadows at 10+ enemies cost as much
# GPU as the rest of the scene combined — disabling is the highest-ROI perf fix.
func _disable_shadows_recursive(node: Node) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_disable_shadows_recursive(child)


func _physics_tick(delta: float) -> void:
	if _attack_cooldown_timer > 0.0:
		_attack_cooldown_timer -= delta
	if _kick_cooldown_timer > 0.0:
		_kick_cooldown_timer -= delta

	var actual_motion          : Vector3 = global_position - _last_global_pos
	_last_global_pos            = global_position
	var raw_speed              : float = (Vector2(actual_motion.x, actual_motion.z).length() / delta) if delta > 0.0 else 0.0
	_smoothed_actual_speed      = lerp(_smoothed_actual_speed, raw_speed, 12.0 * delta)
	var actually_moving        : bool = _smoothed_actual_speed > run_anim_speed_threshold

	if _is_reacting or _is_stunned:
		_set_horizontal_velocity(Vector3.ZERO, stop_acceleration, delta)
		if _is_stunned: _change_state(_get_idle_state())
		return

	if _is_attacking:
		_set_horizontal_velocity(Vector3.ZERO, stop_acceleration, delta)
		return

	var player : Node3D = _find_player()
	if player == null:
		_set_horizontal_velocity(Vector3.ZERO, stop_acceleration, delta)
		_change_state(_get_idle_state())
		return

	var flat_to_player : Vector3 = Vector3(
		player.global_position.x - global_position.x,
		0.0,
		player.global_position.z - global_position.z)
	var distance : float = flat_to_player.length()

	var raw_player_vel : Vector3 = player.velocity if "velocity" in player else Vector3.ZERO
	_smoothed_player_vel = _smoothed_player_vel.lerp(raw_player_vel, 8.0 * delta)

	if distance > attack_range + 1.0:
		_frustration_timer += delta
		if _frustration_timer >= 12.0:
			_frustration_timer = 0.0
			if not _has_los:
				_retire_stuck()
				return
	else:
		_frustration_timer = 0.0

	if distance > 0.001:
		# FIX 3: Replace look_at() with direct atan2 — same result, ~5x cheaper.
		# look_at() builds a full 3x3 rotation basis then decomposes it back to
		# euler angles. We only need the Y angle, so atan2 is all we need.
		mesh_root.rotation.y = atan2(
			player.global_position.x - mesh_root.global_position.x,
			player.global_position.z - mesh_root.global_position.z)

	if use_activation_range and distance > activation_range and idle_outside_activation:
		_set_horizontal_velocity(Vector3.ZERO, stop_acceleration, delta)
		_change_state(_get_idle_state())
		return

	# SURGICAL ADD: Rapid Attack awareness. When the player is spinning, the brute
	# cannot safely attack — it would just walk into the hitbox repeatedly.
	# Instead it charges straight at the player at full speed, which feels
	# aggressive and keeps pressure on without the suicidal melee loop.
	var player_is_rapid_attack : bool = false
	if is_instance_valid(player) and player.get("_rapid_attack_active") != null:
		player_is_rapid_attack = player.get("_rapid_attack_active") == true

	if player_is_rapid_attack:
		# Charge directly at the player — skip waypoints and wall avoidance.
		# The rapid_attack's AOE will hit them anyway; at least they look threatening.
		var charge_dir := flat_to_player.normalized()
		var chase_speed : float = close_speed * _cached_speed_mult * 1.5
		_set_horizontal_velocity(charge_dir * chase_speed, move_acceleration, delta)
		if actually_moving:
			anim_player.speed_scale = _cached_speed_mult * 1.5
			_change_state("standing_run_forward" if _is_armed else "unarmed_run_forward")
		return

	# Kick: higher priority than normal melee — interrupts when cooldown is clear.
	# Random chance gate prevents kick from triggering every available tick.
	if not _is_attacking and not _is_kicking_ai and _kick_cooldown_timer <= 0.0 \
			and distance <= enemy_kick_range and not player_is_rapid_attack \
			and randf() < enemy_kick_chance:
		_do_ai_kick(player)
		return

	if distance <= attack_range and _attack_cooldown_timer <= 0.0:
		_do_attack(player)
		return

	_update_los(player, delta)
	_update_nav_target(player.global_position, delta)

	_current_dynamic_stop = lerp(
		_current_dynamic_stop,
		_calculate_dynamic_stop(flat_to_player, _smoothed_player_vel),
		4.0 * delta)

	var wants_motion : bool = (
		distance > _current_dynamic_stop + range_buffer or
		distance < _current_dynamic_stop - 0.10)

	if wants_motion:
		var raw_dir   := global_position.direction_to(_current_target)
		raw_dir.y      = 0.0

		_wall_check_timer -= delta
		# SURGICAL FIX: Skip the wall avoidance fan entirely when we have direct
		# LOS to the player. In a room fight every enemy sees the player — no walls
		# to route around. Eliminates ~500 raycasts/sec at 6 enemies in close range.
		var should_check_walls : bool = _wall_check_timer <= 0.0 and not _has_los
		if _wall_check_timer <= 0.0:
			_wall_check_timer = randf_range(0.12, 0.18)

		var player_mod : float = 1.0
		if "enemy_speed_modifier" in player:
			player_mod = float(player.enemy_speed_modifier)

		# Speed boost when the player has outrun the enemy — prevents kiting.
		# Beyond 22m the enemy gets 50% faster to close the gap.
		var chase_mult : float = 1.5 if distance > 22.0 else 1.0

		var speed_multiplier  : float = player_mod * _cached_speed_mult * chase_mult

		var current_speed  : float = _get_target_speed_for_distance(distance, _current_dynamic_stop) * speed_multiplier
		
		if should_check_walls:
			_last_safe_dir = _find_wall_safe_direction(raw_dir)
		elif _has_los:
			# SURGICAL FIX: When we have direct LOS, skip stale wall-avoidance direction.
			# Wall avoidance could have left _last_safe_dir pointing sideways or backward.
			# Gaining LOS while that direction is cached made enemies run away from the
			# player even with a clear sightline. Force the direction straight at the target.
			var los_dir := raw_dir
			los_dir.y = 0.0
			if los_dir.length_squared() < 0.001:
				los_dir = flat_to_player.normalized()
			_last_safe_dir = los_dir.normalized()

		_set_horizontal_velocity(_last_safe_dir * current_speed, move_acceleration, delta)

		if actually_moving:
			anim_player.speed_scale = _cached_speed_mult
			_change_state("standing_run_forward" if _is_armed else "unarmed_run_forward")
		else:
			anim_player.speed_scale = 1.0
			_change_state(_get_idle_state())
	else:
		_set_horizontal_velocity(Vector3.ZERO, stop_acceleration, delta)
		anim_player.speed_scale = 1.0
		_change_state(_get_idle_state())


func _calculate_dynamic_stop(flat_to_player: Vector3, player_velocity: Vector3) -> float:
	var toward_brute  := -flat_to_player.normalized()
	var approach_speed := player_velocity.dot(toward_brute)
	var dynamic_stop   := base_stop_distance
	if approach_speed > 1.0:   dynamic_stop += dynamic_stop_scaling
	elif approach_speed < -1.0: dynamic_stop -= dynamic_stop_scaling
	return clampf(dynamic_stop, 1.0, attack_range - 0.1)


func _get_target_speed_for_distance(distance: float, dynamic_stop: float) -> float:
	var base := close_speed
	if distance >= far_range:
		base = far_speed
	elif distance >= mid_range:
		base = lerp(far_speed, mid_speed, inverse_lerp(far_range, mid_range, distance))
	elif distance >= close_range:
		base = lerp(mid_speed, close_speed, inverse_lerp(mid_range, close_range, distance))
	elif distance < dynamic_stop - 0.10:
		base = close_speed * 0.65

	return base * (APPROACH_SPEED_MULT if _approach_boost else 1.0)


func _set_horizontal_velocity(target: Vector3, accel: float, delta: float) -> void:
	velocity.x = move_toward(velocity.x, target.x, accel * delta)
	velocity.z = move_toward(velocity.z, target.z, accel * delta)


func _do_attack(player: Node3D) -> void:
	var _life : int = _life_id   # abort if this enemy is pooled/reborn while we wait
	_is_attacking = true
	var player_mod : float = 1.0
	if player and "enemy_speed_modifier" in player:
		player_mod = float(player.enemy_speed_modifier)
		
	anim_player.speed_scale = attack_speed_scale * player_mod
	_play_anim(pick_attack())
	var anim_len : float = _current_anim_length() / (attack_speed_scale * player_mod)

	await get_tree().create_timer(anim_len * 0.5).timeout
	if _life != _life_id: return

	# SURGICAL FIX: Re-check range at the moment of impact.
	# The attack started when the player was in range, but the timer delay
	# means the player may have moved away by the time damage fires.
	# A 1.5× tolerance handles the brief overlap at the edge of attack_range
	# while still blocking phantom hits on players who clearly dodged.
	if not _is_dead and not _is_stunned and player and is_instance_valid(player) and player.has_method("take_damage"):
		var current_dist : float = global_position.distance_to(player.global_position)
		if current_dist <= attack_range * 1.5:
			var player_damage_mod : float = 1.0
			if "enemy_damage_modifier" in player:
				player_damage_mod = float(player.enemy_damage_modifier)
			player.take_damage(attack_damage * player_damage_mod * _cached_damage_mod, self)

	await get_tree().create_timer(anim_len * 0.5).timeout
	if _life != _life_id: return
	anim_player.speed_scale = 1.0
	_is_attacking           = false
	_attack_cooldown_timer  = attack_cooldown
	_change_state(_get_idle_state())


func _do_ai_kick(player: Node3D) -> void:
	var _life : int = _life_id   # abort if this enemy is pooled/reborn while we wait
	_is_kicking_ai = true
	_is_attacking  = true

	# Sprint impulse toward the player — decays via stop_acceleration once
	# _is_attacking blocks further movement control.
	var flat_dir : Vector3 = Vector3(
		player.global_position.x - global_position.x,
		0.0,
		player.global_position.z - global_position.z)
	if flat_dir.length_squared() > 0.001:
		flat_dir = flat_dir.normalized()
		velocity.x = flat_dir.x * close_speed * 1.8
		velocity.z = flat_dir.z * close_speed * 1.8

	_play_anim("kick")
	anim_player.speed_scale = 1.0
	var anim_len : float = _current_anim_length()

	await get_tree().create_timer(anim_len * 0.50).timeout
	if _life != _life_id: return

	if not _is_dead and is_instance_valid(player):
		var dist : float = global_position.distance_to(player.global_position)
		if dist <= enemy_kick_range * 1.6:
			var push_dir : Vector3 = player.global_position - global_position
			push_dir.y = 0.0
			if push_dir.length_squared() > 0.001:
				push_dir = push_dir.normalized()
			var player_damage_mod : float = float(player.enemy_damage_modifier) \
				if "enemy_damage_modifier" in player else 1.0
			if player.has_method("take_damage"):
				player.take_damage(enemy_kick_damage * player_damage_mod * _cached_damage_mod, self)
			if player.has_method("take_knockback"):
				player.take_knockback(push_dir, enemy_kick_force, enemy_kick_stun)

	await get_tree().create_timer(anim_len * 0.50).timeout
	if _life != _life_id: return
	_is_kicking_ai       = false
	_is_attacking        = false
	_kick_cooldown_timer  = enemy_kick_cooldown


func _find_player() -> Node3D:
	if _cached_player and is_instance_valid(_cached_player):
		return _cached_player
	_cached_player = get_tree().get_first_node_in_group("player")
	return _cached_player


func _smooth_turn(_delta: float) -> void: pass

func apply_stun() -> void: _is_stunned = true
func end_stun()   -> void: if _stun_timer <= 0.0: _is_stunned = false
