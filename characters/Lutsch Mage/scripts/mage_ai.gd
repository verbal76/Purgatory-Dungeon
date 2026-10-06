# ==============================================================================
#  FILE: mage_ai.gd
#  PATH: res://characters/Lutsch Mage/scripts/mage_ai.gd
#  ATTACHED TO: res://characters/Lutsch Mage/scenes/mage_player.tscn
#  USED BY: None
#  DESCRIPTION: Ranged AI mage enemy. Maintains preferred range, strafes,
#               and fires spells. Waypoint-guided navigation with LOS switch
#               to direct pursuit when the player is visible.
#  MOD NOTES:
#  - SURGICAL FIX: Waypoint optimization. Added 30-meter radius cull 
#    (distance_squared < 900.0) to _find_best_waypoint_toward_player to prevent CPU spikes.
#  - SURGICAL FIX: Ally-blocking LoS reroute. _los_query now hits all 
#    layers and drops _has_los if an idle/blocking ally is between mage and player.
#  - Replaced NavigationServer3D.query_path() with waypoint graph navigation.
#    Receives the waypoint graph via initialize_waypoints() after spawn.
#  - LOS check throttled at los_check_interval seconds.
#  - Fan steering wall avoidance added (same pattern as brute_ai).
#  - _on_buff_applied() scales run_speed, walk_speed, back_speed, spell_damage.
#  - Switched _do_spell_attack to spawn a projectile scene instead of hitscan.
#  - SURGICAL FIX: Cached [get_rid()] in _on_ready to prevent massive array allocations.
#  - SURGICAL FIX: _on_die instantly calls queue_free() after animation to clear the corpse.
#  - SURGICAL FIX: Fireball now fires straight ahead relative to the player's actual
#    live position instead of the delayed mesh bone rotation, fixing aiming whiffs.
#    The Mage also snaps its rotation right before firing so it faces the target perfectly.
#  - SURGICAL FIX: Added 4-second destruct timer to fireballs to plug memory leaks.
#  - SURGICAL FIX: Throttled the heavy wall-avoidance raycast logic to ~6Hz.
#  - SURGICAL FIX: Added Waypoint LOS verification and Tabu memory array to 
#    prevent enemies from getting stuck against walls or trapped in local minima corners.
#  - SURGICAL FIX: Restored pure MoveMode state machine, purged accidental Brute melee 
#    tracking logic, fixed strict typing crashes on speed_multiplier, and restored 
#    the missing _set_horizontal_velocity helper function.
#  - SURGICAL FIX: Removed _is_armed check from animation state change to prevent 
#    massive console spam and resulting lag.
#  - SURGICAL FIX: Increased strafe_switch_interval to 4.0 and added missing _update_strafe_timer() call to _physics_tick.
#  - SURGICAL FIX: Enforced mesh_root.look_at() unconditionally at the end of _physics_tick so mage always faces player while moving/strafing.
#  - SURGICAL ADD: Added Rapid Attack check to _physics_tick. Mages will now stop casting and walk blindly toward the player if _rapid_attack_active is true.
#  - SURGICAL FIX: Added _smooth_turn() override (no-op pass). CharacterBase runs
#    _smooth_turn AFTER _physics_tick, which was rotating mesh_root toward the
#    strafe/velocity direction and overwriting the look_at. Disabling it here so
#    the unconditional look_at inside _physics_tick owns facing permanently.
#    (brute_ai already had this override — mage_ai was missing it.)
#  - SURGICAL FIX: Unused parameter warnings in _on_enemy_health_changed resolved
#    by prefixing with underscore.
#  - SURGICAL ADD: MAINTAIN mode now plays standing_walk_left / standing_walk_right
#    based on strafe direction instead of always playing standing_walk_forward.
#    REQUIREMENT: Add "standing_walk_left" and "standing_walk_right" keys to the
#    mage animation map (mage_base.gd or mage_animations.gd) pointing at your
#    Mixamo side-step animations. If those keys are absent the mage will hold
#    its last valid animation while strafing — it will not crash.
# ==============================================================================
extends MageCharacter

var PotionPickupScript = load("res://objects/pickups/PotionPickup.gd")

# Enemies move 25 % faster while they haven't yet sighted the player.
# Dropped permanently the moment first LOS is acquired.
const APPROACH_SPEED_MULT : float = 1.25

# ── Speeds ─────────────────────────────────────────────────────────────────────
@export var run_speed  : float = 3.5   # Approach speed
@export var walk_speed : float = 1.8   # Maintain-range walk speed
@export var back_speed : float = 1.4   # Retreat speed
@export var run_anim_speed_threshold : float = 0.1

# ── Distance bands ─────────────────────────────────────────────────────────────
@export var preferred_range    : float = 5.0   # Ideal distance from player
@export var run_range          : float = 10.0  # Beyond this: run to close in
@export var min_range          : float = 3.5   # Inside this: retreat
@export var range_tolerance    : float = 0.8
@export var anti_clip_distance : float = 0.85

# ── Attack ─────────────────────────────────────────────────────────────────────
@export var attack_range       : float = 12.0
@export var min_attack_range   : float = 3.0
@export var attack_cooldown    : float = 3.0
@export var attack_speed_scale : float = 1.5
@export var spell_damage       : float = 10.0
@export var fireball_scene     : PackedScene
@export var fireball_spawn_y   : float = 1.5
@export var fireball_pool_size : int   = 6    # Pre-instantiated fireballs reused across casts

# ── Shove (close-range interrupt) ──────────────────────────────────────────────
# Mage enemy sprints at the player and plays the 2H shove animation when within
# shove range. Knocks the player back and stuns for 3 seconds.
# Chance gate prevents constant shove spam every time cooldown expires.
@export var enemy_shove_range    : float = 3.2   # Metres — trigger distance
@export var enemy_shove_cooldown : float = 14.0  # Seconds between shoves
@export var enemy_shove_damage   : float = 8.0   # Impact damage
@export var enemy_shove_force    : float = 10.0  # Knockback impulse
@export var enemy_shove_stun     : float = 3.0   # Player stun duration (seconds)
@export var enemy_shove_chance   : float = 0.30  # Random gate [0,1] per eligible tick

# ── Activation ─────────────────────────────────────────────────────────────────
@export var use_activation_range    : bool  = false
@export var activation_range        : float = 40.0
@export var idle_outside_activation : bool  = true

# ── Movement smoothing ─────────────────────────────────────────────────────────
@export var move_acceleration : float = 18.0
@export var stop_acceleration : float = 22.0

# ── Strafe ─────────────────────────────────────────────────────────────────────
@export var enable_strafe          : bool  = true
@export var strafe_strength        : float = 0.3
@export var strafe_switch_interval : float = 4.0

# ── Navigation ─────────────────────────────────────────────────────────────────
@export var nav_refresh_interval  : float = 0.30
@export var los_check_interval    : float = 0.50  # was 0.35 — 30% fewer LOS raycasts
@export var waypoint_reach_distance : float = 2.0
@export var fan_step_degrees      : float = 15.0
@export var fan_max_steps         : int   = 6
@export var fan_ray_length        : float = 1.8

# ── Audio assets ──────────────────────────────────────────────────────────────
var hurt_sound  : AudioStream = preload("res://Music & background images/Sound Effects/male-hurt-sound-95206.mp3")
var death_sound : AudioStream = preload("res://Music & background images/Sound Effects/dramatic-death-collapse-352720 (1).mp3")

# ── Health bar ────────────────────────────────────────────────────────────────
const BAR_WIDTH  : float = 0.8
const BAR_HEIGHT : float = 0.09
const BAR_Y      : float = 2.3

enum MoveMode { APPROACH, MAINTAIN, RETREAT }

# ── Runtime state ──────────────────────────────────────────────────────────────
var _strafe_timer          : float  = 0.0
var _strafe_sign           : float  = 1.0
var _is_attacking          : bool   = false
var _attack_cooldown_timer : float  = 0.0
var _is_shoving            : bool   = false
var _shove_cooldown_timer  : float  = 0.0
var _cached_player         : Node3D = null
var _move_mode             : int    = MoveMode.APPROACH
var _last_global_pos       : Vector3 = Vector3.ZERO
var _smoothed_actual_speed : float   = 0.0
var _hp_bar_root           : Node3D             = null
var _stun_indicator_root   : Node3D             = null
# FIX 4: Cached star refs and dirty flag (same pattern as brute_ai).
var _stun_stars      : Array[Node3D] = []
var _stun_was_active : bool = false

# ── Right-hand bone for fireball spawn ────────────────────────────────────────
var _skeleton              : Skeleton3D = null
var _right_hand_bone_idx   : int        = -1
var _frustration_timer     : float  = 0.0

# ── Hit flash state ─────────────────────────────────────────────────────────────
var _hit_flash_timer       : float  = 0.0
var _hit_flash_material    : StandardMaterial3D = null
var _flash_meshes          : Array[MeshInstance3D] = []
const FLASH_DURATION       : float = 0.12

# ── Potion drop tuning ─────────────────────────────────────────────────────────
const POTION_DROP_BASE_PCT     : int = 6  # Base % chance per kill          (was 10)
const POTION_DROP_SCAVENGE_PCT : int = 3  # Bonus % per scavenge perk level (was 5)
const POTION_DROP_GREED_PCT    : int = 5  # % chance of 2nd drop per greed level (was 10)
# Chest key drop — same as brute_ai.gd (persistent across runs).
const KEY_DROP_PCT             : int = 5
const _KeyPickupScript = preload("res://scripts/key_pickup.gd")
const _KEY_COLORS              : Array[String] = ["bronze", "silver", "gold"]

# ── Throttle State for Physics CPU Relief ──────────────────────────────────────
var _wall_check_timer      : float   = 0.0
var _last_safe_dir         : Vector3 = Vector3.ZERO

# ── Waypoint navigation state ─────────────────────────────────────────────────
var _waypoints             : Array   = []
var _current_target        : Vector3 = Vector3.ZERO
var _nav_timer             : float   = 0.0
var _los_timer             : float   = 0.0
var _has_los               : bool    = false
var _approach_boost        : bool    = false    # True until first LOS; +25% approach speed
var _visited_waypoints     : Array[Vector3] = [] # Ordered list for eviction
var _visited_wp_set        : Dictionary     = {} # O(1) lookup mirror of _visited_waypoints

# ── Object pool support ───────────────────────────────────────────────────────
var _pool_return : Callable = Callable()

# ── Fireball pool ─────────────────────────────────────────────────────────────
# Pre-instantiated fireballs parented to the main scene. Each cast acquires the
# first inactive one instead of calling instantiate(). On fade-out the fireball
# hides itself (fireball._on_particle_faded) and becomes available again.
var _fireball_pool : Array = []

# ── Cached ray query objects ──────────────────────────────────────────────────
var _wall_query : PhysicsRayQueryParameters3D = null
var _los_query  : PhysicsRayQueryParameters3D = null

# ── Cached SettingsManager values ────────────────────────────────────────────
var _cached_speed_mult    : float = 1.0
var _cached_damage_mod    : float = 1.0
var _settings_cache_timer : float = 0.0
const SETTINGS_CACHE_INTERVAL : float = 5.0


# ══════════════════════════════════════════════════════════════════════════════
#  SETUP
# ══════════════════════════════════════════════════════════════════════════════

# ── AI animation map ───────────────────────────────────────────────────────────
# The mage ENEMY uses vampire-mage.gltf, which has proper magic attack
# animations. mage_base.gd's map targets the brute stand-in (used only by the
# mage player). Overriding here gives the enemy its correct animation names
# without touching mage_player.gd or mage_base.gd at all.
const _AI_ANIM_MAP := {
	"standing_idle"                 : "StandingIdle",
	"standing_run_forward"          : "StandingRunForward",
	"standing_run_back"             : "StandingRunBack",
	"standing_run_left"             : "StandingRunLeft",
	"standing_run_right"            : "StandingRunRight",
	"standing_sprint_forward"       : "StandingSprintForward",
	"standing_walk_forward"         : "StandingWalkForward",
	"standing_walk_back"            : "StandingWalkBack",
	"standing_walk_left"            : "StandingWalkLeft",
	"standing_walk_right"           : "StandingWalkRight",
	"standing_turn_left_90"         : "StandingTurnLeft90",
	"standing_turn_right_90"        : "StandingTurnRight90",
	"standing_jump"                 : "StandingJump",
	"standing_jump_running"         : "StandingJumpRunning",
	"standing_jump_running_landing" : "StandingJumpRunningLanding",
	"standing_land_to_idle"         : "StandingLandToStandingIdle",
	"attack_1h_cast_01"             : "Standing1HCastSpell01",
	"attack_1h_01"                  : "Standing1HMagicAttack01",
	"attack_1h_03"                  : "Standing1HMagicAttack03",
	"attack_2h_cast_01"             : "Standing2HCastSpell01",
	"attack_2h_01"                  : "Standing2HMagicAttack01",
	"attack_2h_02"                  : "Standing2HMagicAttack02",
	"attack_2h_03"                  : "Standing2HMagicAttack03",
	"attack_2h_05"                  : "Standing2HMagicAttack05",
	"attack_2h_area_01"             : "Standing2HMagicAreaAttack01",
	"attack_2h_area_02"             : "Standing2HMagicAreaAttack02",
	"block_start"                   : "StandingBlockStart",
	"block_idle"                    : "StandingBlockIdle",
	"block_end"                     : "StandingBlockEnd",
	"block_react"                   : "StandingBlockReactLarge",
	"react_large_front"             : "StandingReactLargeFromFront",
	"react_large_back"              : "StandingReactLargeFromBack",
	"react_large_left"              : "StandingReactLargeFromLeft",
	"react_large_right"             : "StandingReactLargeFromRight",
	"react_small_front"             : "StandingReactSmallFromFront",
	"react_small_back"              : "StandingReactSmallFromBack",
	"react_small_left"              : "StandingReactSmallFromLeft",
	"react_small_right"             : "StandingReactSmallFromRight",
	"death_backward"                : "StandingReactDeathBackward",
	"death_forward"                 : "StandingReactDeathForward",
	"death_left"                    : "StandingReactDeathLeft",
	"death_right"                   : "StandingReactDeathRight",
	"react_gut"                     : "StandingReactLargeFromFront",
	"react_left"                    : "StandingReactLargeFromLeft",
	"react_right"                   : "StandingReactLargeFromRight",
	"react_back"                    : "StandingReactLargeFromBack",
	"death"                         : "StandingReactDeathBackward",
}

func _get_animation_map() -> Dictionary:
	return _AI_ANIM_MAP


func _on_ready() -> void:
	var health_mult     : float = float(SettingsManager.get_setting("HealthSlider", 100.0)) / 100.0
	max_health           = 35.0 * health_mult
	_current_health      = max_health

	var speed_variance := randf_range(0.85, 1.15)
	run_speed   *= speed_variance
	walk_speed  *= speed_variance
	back_speed  *= speed_variance

	_attack_cooldown_timer = randf() * 1.5
	_strafe_timer          = randf() * strafe_switch_interval
	_nav_timer             = randf() * nav_refresh_interval
	_los_timer             = randf() * los_check_interval
	_frustration_timer     = randf() * 4.0
	_wall_check_timer      = randf_range(0.0, 0.15)

	_pick_new_strafe_sign()
	_setup_hit_flash()
	_build_stun_indicator()
	add_to_group("enemy")
	add_to_group("enemies")

	_disable_shadows_recursive(self)

	_cached_speed_mult = float(SettingsManager.get_setting("SpeedSlider",  100.0)) / 100.0
	_cached_damage_mod = float(SettingsManager.get_setting("DamageSlider", 100.0)) / 100.0

	_skeleton = find_child("Skeleton3D", true, false) as Skeleton3D
	if _skeleton != null:
		_right_hand_bone_idx = _skeleton.find_bone("mixamorigRightHand")

	_last_global_pos = global_position
	connect("health_changed", _on_enemy_health_changed)

	_wall_query = PhysicsRayQueryParameters3D.new()
	_wall_query.collide_with_bodies = true
	_wall_query.collision_mask      = 1
	_wall_query.exclude             = [get_rid()]

	_los_query = PhysicsRayQueryParameters3D.new()
	_los_query.collide_with_bodies = true
	_los_query.collide_with_areas  = false
	_los_query.collision_mask      = 0xFFFFFFFF
	_los_query.exclude             = [get_rid()]

	# Populate the fireball pool after all other setup is complete.
	_init_fireball_pool()


# ── Fireball pool management ──────────────────────────────────────────────────

# The pool is parented to the scene root, not to this enemy, so it must be freed with
# the enemy or every freed mage (pool full, frustration timeout, run end) leaks 6 nodes.
func _exit_tree() -> void:
	for fb in _fireball_pool:
		if is_instance_valid(fb) and not fb.is_queued_for_deletion():
			fb.queue_free()
	_fireball_pool.clear()


func _init_fireball_pool() -> void:
	if fireball_scene == null:
		return
	var root : Node = get_tree().current_scene
	if root == null:
		return
	for i in range(fireball_pool_size):
		var fb : Node = fireball_scene.instantiate()
		root.add_child(fb)
		fb.visible = false
		fb.set_physics_process(false)
		# Mark inactive so _acquire_fireball() can find this slot.
		# _is_active defaults true in fireball.gd — must be cleared here.
		fb._is_active = false
		if "monitoring" in fb:
			fb.set_deferred("monitoring", false)
		_fireball_pool.append(fb)


# Returns the first inactive pooled fireball. Falls back to a fresh instantiation
# if the pool is exhausted (handles burst-fire edge cases without crashing).
func _acquire_fireball() -> Node:
	for fb in _fireball_pool:
		if is_instance_valid(fb) and not fb._is_active:
			return fb
	# Pool exhausted — instantiate a temporary non-pooled one.
	if fireball_scene != null:
		var fb : Node = fireball_scene.instantiate()
		get_tree().current_scene.add_child(fb)
		return fb
	return null


func initialize_waypoints(points: Array) -> void:
	_waypoints = points
	if not _waypoints.is_empty():
		_current_target = _waypoints[randi() % _waypoints.size()]
	_approach_boost = true   # Boost active until first LOS


func _on_buff_applied(multiplier: float) -> void:
	run_speed    *= multiplier
	walk_speed   *= multiplier
	back_speed   *= multiplier
	spell_damage *= multiplier


# ══════════════════════════════════════════════════════════════════════════════
#  SMOOTH TURN OVERRIDE
# ══════════════════════════════════════════════════════════════════════════════

# SURGICAL FIX: CharacterBase._physics_process() calls _smooth_turn() AFTER
# _physics_tick() completes. The base implementation rotates mesh_root to face
# the velocity direction — which for a strafing mage is sideways, not toward
# the player. This completely overrides the look_at done inside _physics_tick.
# Disabling it here so the unconditional look_at at the bottom of _physics_tick
# permanently owns the mage's facing. brute_ai already had this override.
func _smooth_turn(_delta: float) -> void:
	pass


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

	_los_query.from = start
	_los_query.to   = end

	var result := space.intersect_ray(_los_query)
	
	if result.is_empty() or result.get("collider") == player:
		if not _has_los:
			_approach_boost = false   # First sighting — drop the approach speed bonus
		_has_los = true
	else:
		var col = result.get("collider")
		if col != null and col.is_in_group("enemy"):
			var ally_speed : float = col.velocity.length() if "velocity" in col else 0.0
			if ally_speed < 1.5:
				_has_los = false
			else:
				_has_los = false
		else:
			_has_los = false 


func _update_nav_target(player_pos: Vector3, _delta: float) -> void:
	# FIX 1: Same as brute_ai — only search when target is reached, not on timer.
	if _has_los:
		_current_target = player_pos
		_visited_waypoints.clear()
		_visited_wp_set.clear()
		return

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

	var anim_to_play := "react_large_front"
	var player := _find_player()
	if player != null:
		var to_hit  := (player.global_position - global_position).normalized()
		var forward := -global_transform.basis.z.normalized()
		var right   :=  global_transform.basis.x.normalized()
		if abs(forward.dot(to_hit)) > abs(right.dot(to_hit)):
			anim_to_play = "react_large_front" if forward.dot(to_hit) > 0.0 else "react_large_back"
		else:
			anim_to_play = "react_large_right" if right.dot(to_hit) > 0.0 else "react_large_left"

	anim_player.speed_scale = react_anim_speed
	_play_anim(anim_to_play)
	await anim_player.animation_finished
	if _life != _life_id: return
	anim_player.speed_scale = 1.0
	_is_reacting            = false
	if not _is_dead: _change_state(_get_idle_state())


func pick_death_direction() -> String:
	var directions := {
		"backward" : -mesh_root.global_transform.basis.z.normalized(),
		"forward"  :  mesh_root.global_transform.basis.z.normalized(),
		"left"     : -mesh_root.global_transform.basis.x.normalized(),
		"right"    :  mesh_root.global_transform.basis.x.normalized(),
	}
	var space     := get_world_3d().direct_space_state
	var best_dir  := "backward"
	var best_dist := 0.0

	for dir_name in directions:
		var dir_vec : Vector3 = directions[dir_name]
		var start := global_position + Vector3(0.0, 1.0, 0.0)
		var end   := start + dir_vec * 3.0
		var query := PhysicsRayQueryParameters3D.create(start, end)
		query.exclude             = [self]
		query.collide_with_bodies = true
		var result := space.intersect_ray(query)
		var dist : float = start.distance_to(result.position) if not result.is_empty() else 3.0
		if dist > best_dist:
			best_dist = dist
			best_dir  = dir_name

	return DEATH_ANIMS[best_dir]


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
	if _hp_bar_root != null: _hp_bar_root.visible = false
	await get_tree().create_timer(_current_anim_length()).timeout
	if not is_instance_valid(self): return
	if _life != _life_id: return

	if _pool_return.is_valid():
		_pool_return.call()
	else:
		queue_free()


# ── Pool API ──────────────────────────────────────────────────────────────────

func set_pool_return(cb: Callable) -> void:
	_pool_return = cb


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
	collision_layer  = 1
	# T1.4 — prime the LOD timer so pooled respawns also get an immediate
	# distance check on their first physics tick back alive.
	_lod_dist_timer  = 1.0
	_lod_frame_counter = 0

	# ── AI state ─────────────────────────────────────────────────────────────
	_is_attacking          = false
	_is_shoving            = false
	_attack_cooldown_timer = randf() * 1.5
	_shove_cooldown_timer  = randf_range(0.0, 6.0)   # Stagger shoves on respawn
	_wall_check_timer      = randf_range(0.0, 0.15)
	_has_los               = false
	_approach_boost        = true    # Re-arm boost for this new life
	_current_target        = Vector3.ZERO
	_visited_waypoints.clear()
	_visited_wp_set.clear()
	_nav_timer             = randf() * nav_refresh_interval
	_los_timer             = randf() * los_check_interval
	_frustration_timer     = randf() * 4.0
	_last_global_pos       = new_pos
	_smoothed_actual_speed = 0.0
	_strafe_timer          = randf() * strafe_switch_interval
	_pick_new_strafe_sign()
	# Reset movement state so stale directions from the previous life don't carry over.
	_last_safe_dir         = Vector3.ZERO

	# ── Navigation ───────────────────────────────────────────────────────────
	initialize_waypoints(new_waypoints)

	# ── Position & visibility ─────────────────────────────────────────────────
	# NOTE: Do NOT set global_rotation — mesh facing is fully managed by
	# _physics_tick's look_at which assumes CharacterBody3D.rotation.y = 0.
	global_position = new_pos
	if mesh_root != null:
		mesh_root.rotation.y = MESH_FACING

	# ── UI ───────────────────────────────────────────────────────────────────
	if _stun_indicator_root != null:
		_stun_indicator_root.visible = false
	if _hp_bar_root != null:
		_hp_bar_root.visible = true

	# ── Re-enable ─────────────────────────────────────────────────────────────
	if anim_player != null:
		anim_player.active = true   # EnemyManager._park() deactivates the mixer of a parked enemy
	add_to_group("enemy")    # a parked enemy sits outside the groups (see EnemyManager._park)
	add_to_group("enemies")
	visible = true
	set_physics_process(true)
	set_process(true)

	_change_state(_get_idle_state())
	health_changed.emit(_current_health, max_health)


# A mage that has chased for 12 s without ever seeing the player is retired. It used to be freed (with its six
# pooled fireballs) and the next top-up instantiated a replacement, a multi-millisecond hitch (many times that on a
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


# ══════════════════════════════════════════════════════════════════════════════
#  HIT FLASH & UI
# ══════════════════════════════════════════════════════════════════════════════

func _disable_shadows_recursive(node: Node) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_disable_shadows_recursive(child)


func _setup_hit_flash() -> void:
	_hit_flash_material = StandardMaterial3D.new()
	_hit_flash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hit_flash_material.albedo_color = Color(1.0, 1.0, 1.0, 0.35)
	_hit_flash_material.emission_enabled = true
	_hit_flash_material.emission = Color(1.0, 1.0, 1.0)
	_hit_flash_material.emission_energy_multiplier = 1.6
	_flash_meshes.clear()
	_collect_flash_meshes(mesh_root if mesh_root != null else self)


func _collect_flash_meshes(node: Node) -> void:
	if node is MeshInstance3D: _flash_meshes.append(node)
	for child in node.get_children(): _collect_flash_meshes(child)


func _start_hit_flash() -> void:
	_hit_flash_timer = FLASH_DURATION
	for mesh in _flash_meshes:
		if is_instance_valid(mesh): mesh.material_overlay = _hit_flash_material


func _clear_hit_flash() -> void:
	for mesh in _flash_meshes:
		if is_instance_valid(mesh): mesh.material_overlay = null


# SURGICAL FIX: Prefixed unused parameters with underscore to clear warnings.
func _on_enemy_health_changed(_hp: float, _max_v: float) -> void:
	_start_hit_flash()


func _build_stun_indicator() -> void:
	_stun_indicator_root = Node3D.new()
	_stun_indicator_root.position.y = 1.95
	_stun_indicator_root.visible = false
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
		_stun_stars.append(star)  # FIX 4: cache ref


# ══════════════════════════════════════════════════════════════════════════════
#  PROCESS & PHYSICS
# ══════════════════════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	_settings_cache_timer += delta
	if _settings_cache_timer >= SETTINGS_CACHE_INTERVAL:
		_settings_cache_timer = 0.0
		_cached_speed_mult = float(SettingsManager.get_setting("SpeedSlider",  100.0)) / 100.0
		_cached_damage_mod = float(SettingsManager.get_setting("DamageSlider", 100.0)) / 100.0

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

	# FIX 4: Dirty flag + cached stars — same pattern as brute_ai.
	if _is_stunned != _stun_was_active:
		_stun_was_active = _is_stunned
		if _stun_indicator_root != null:
			_stun_indicator_root.visible = _is_stunned

	if _is_stunned and _stun_indicator_root != null:
		_stun_indicator_root.rotation.y += 6.0 * delta
		var msec := Time.get_ticks_msec() / 150.0
		for i in range(_stun_stars.size()):
			_stun_stars[i].position.y = sin(msec + ((i / 3.0) * TAU)) * 0.1


func _physics_tick(delta: float) -> void:
	if _attack_cooldown_timer > 0.0:
		_attack_cooldown_timer -= delta
	if _shove_cooldown_timer > 0.0:
		_shove_cooldown_timer -= delta

	_update_strafe_timer(delta)

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

	if distance > attack_range + 1.0:
		_frustration_timer += delta
		if _frustration_timer >= 12.0:
			_frustration_timer = 0.0
			if not _has_los:
				_retire_stuck()
				return
	else:
		_frustration_timer = 0.0

	if use_activation_range and distance > activation_range and idle_outside_activation:
		_set_horizontal_velocity(Vector3.ZERO, stop_acceleration, delta)
		_change_state(_get_idle_state())
		return

	var player_is_rapid_attack : bool = false
	if is_instance_valid(player) and player.get("_rapid_attack_active") != null:
		player_is_rapid_attack = player.get("_rapid_attack_active") == true

	# Shove: higher priority than ranged attack — interrupts when player is very close.
	# Random chance gate prevents shove from triggering every available tick.
	if not _is_attacking and not _is_shoving and _shove_cooldown_timer <= 0.0 \
			and distance <= enemy_shove_range and not player_is_rapid_attack \
			and randf() < enemy_shove_chance:
		_do_ai_shove(player)
		return

	if distance <= attack_range and _attack_cooldown_timer <= 0.0 and not player_is_rapid_attack:
		_do_spell_attack(player)
		return

	_update_los(player, delta)
	_update_nav_target(player.global_position, delta)

	_wall_check_timer -= delta
	# SURGICAL FIX: Skip the wall avoidance fan entirely when we have direct
	# LOS to the player. In a room fight every enemy sees the player — no walls
	# to route around. Eliminates ~500 raycasts/sec at 6 enemies in close range.
	var should_check_walls : bool = _wall_check_timer <= 0.0 and not _has_los
	if _wall_check_timer <= 0.0:
		_wall_check_timer = randf_range(0.12, 0.18)

	var player_mod        : float = float(player.enemy_speed_modifier) if "enemy_speed_modifier" in player else 1.0
	var chase_mult        : float = 1.5 if distance > 22.0 else 1.0
	var speed_multiplier  : float = player_mod * _cached_speed_mult * chase_mult

	if player_is_rapid_attack:
		_move_mode = MoveMode.APPROACH
	elif distance < min_range: 
		_move_mode = MoveMode.RETREAT
	elif distance > run_range: 
		_move_mode = MoveMode.APPROACH
	else: 
		_move_mode = MoveMode.MAINTAIN

	match _move_mode:
		MoveMode.APPROACH:
			var desired_dir := global_position.direction_to(_current_target)
			if enable_strafe and distance < run_range and desired_dir != Vector3.ZERO:
				var right   := Vector3(desired_dir.z, 0.0, -desired_dir.x)
				desired_dir  = (desired_dir + right * _strafe_sign * strafe_strength).normalized()

			if should_check_walls:
				_last_safe_dir = _find_wall_safe_direction(desired_dir)
			elif _has_los:
				# SURGICAL FIX: Same as brute_ai — when mage has direct LOS,
				# don't use a stale wall-avoidance direction. Go straight at target.
				var los_dir := desired_dir
				los_dir.y = 0.0
				if los_dir.length_squared() < 0.001:
					los_dir = flat_to_player.normalized()
				_last_safe_dir = los_dir.normalized()

			var current_speed : float = (run_speed if distance > run_range else walk_speed) \
				* speed_multiplier \
				* (APPROACH_SPEED_MULT if _approach_boost else 1.0)
			_set_horizontal_velocity(_last_safe_dir * current_speed, move_acceleration, delta)

			if actually_moving:
				anim_player.speed_scale = _cached_speed_mult
				_change_state("standing_run_forward")
			else:
				anim_player.speed_scale = 1.0
				_change_state(_get_idle_state())

		MoveMode.RETREAT:
			var away_dir := -flat_to_player.normalized()

			if should_check_walls:
				_last_safe_dir = _find_wall_safe_direction(away_dir)

			var current_speed : float = back_speed * speed_multiplier
			_set_horizontal_velocity(_last_safe_dir * current_speed, move_acceleration, delta)
			anim_player.speed_scale = _cached_speed_mult
			_change_state("standing_walk_back")

		MoveMode.MAINTAIN:
			var to_player   := flat_to_player.normalized()
			var right_dir   := Vector3(to_player.z, 0.0, -to_player.x)
			var desired_dir := right_dir * _strafe_sign

			if should_check_walls:
				_last_safe_dir = _find_wall_safe_direction(desired_dir)

			var current_speed : float = walk_speed * 0.6 * speed_multiplier
			_set_horizontal_velocity(_last_safe_dir * current_speed, move_acceleration, delta)

			if actually_moving:
				anim_player.speed_scale = _cached_speed_mult
				# SURGICAL ADD: Play direction-aware strafe animation so the mage
				# walks sideways while staying locked onto the player.
				# _strafe_sign > 0 = moving to mage's right relative to player facing.
				# Requires "standing_walk_left" and "standing_walk_right" keys in the
				# mage animation map. Falls back to last valid anim silently if absent.
				if _strafe_sign > 0.0:
					_change_state("standing_walk_right")
				else:
					_change_state("standing_walk_left")
			else:
				anim_player.speed_scale = 1.0
				_change_state(_get_idle_state())

	# FIX 3: Replace look_at() with direct atan2 — same facing result, ~5x cheaper.
	if distance > 0.001 and is_instance_valid(player):
		mesh_root.rotation.y = atan2(
			player.global_position.x - mesh_root.global_position.x,
			player.global_position.z - mesh_root.global_position.z)


func _do_spell_attack(player: Node3D) -> void:
	var _life : int = _life_id   # abort if this enemy is pooled/reborn while we wait
	_is_attacking = true
	var player_mod : float = float(player.enemy_speed_modifier) if "enemy_speed_modifier" in player else 1.0
	_play_anim(pick_attack())
	anim_player.speed_scale = attack_speed_scale * player_mod
	var anim_len : float = _current_anim_length() / (attack_speed_scale * player_mod)

	await get_tree().create_timer(anim_len * 0.85).timeout
	if _life != _life_id: return

	if not _is_stunned and not _is_dead and is_instance_valid(player):
		var flat_to_player := Vector3(player.global_position.x - global_position.x, 0.0, player.global_position.z - global_position.z)
		if flat_to_player.length_squared() > 0.001:
			mesh_root.look_at(Vector3(player.global_position.x, mesh_root.global_position.y, player.global_position.z), Vector3.UP)
			mesh_root.rotation.y += PI

		if fireball_scene != null:
			var fireball : Node = _acquire_fireball()
			if fireball != null:
				var spawn_pos : Vector3
				if _skeleton != null and _right_hand_bone_idx >= 0:
					var bone_local : Transform3D = _skeleton.get_bone_global_pose(_right_hand_bone_idx)
					spawn_pos = (_skeleton.global_transform * bone_local).origin
				else:
					spawn_pos = global_position + Vector3(0, fireball_spawn_y, 0)
				var target_pos : Vector3 = player.global_position + Vector3(0, 1.0, 0)
				var to_target  : Vector3 = (target_pos - spawn_pos).normalized()
				spawn_pos += to_target * 0.7
				var true_aim_dir : Vector3 = (target_pos - spawn_pos).normalized()
				fireball.global_position = spawn_pos
				fireball.look_at(target_pos, Vector3.UP)

				var player_damage_mod : float = float(player.enemy_damage_modifier) if "enemy_damage_modifier" in player else 1.0
				var final_damage : float = spell_damage * player_damage_mod * _cached_damage_mod

				# Pool-aware fireball uses activate(); fallback (non-pooled) uses setup().
				if fireball.has_method("activate"):
					fireball.activate(final_damage, true_aim_dir)
				elif fireball.has_method("setup"):
					fireball.setup(final_damage, true_aim_dir)

	await get_tree().create_timer(anim_len * 0.15).timeout
	if _life != _life_id: return
	_is_attacking = false; _attack_cooldown_timer = attack_cooldown


func _do_ai_shove(player: Node3D) -> void:
	var _life : int = _life_id   # abort if this enemy is pooled/reborn while we wait
	_is_shoving   = true
	_is_attacking = true

	# Sprint impulse toward the player — decays naturally via stop_acceleration
	# each tick once _is_attacking blocks further movement control.
	var flat_dir : Vector3 = Vector3(
		player.global_position.x - global_position.x,
		0.0,
		player.global_position.z - global_position.z)
	if flat_dir.length_squared() > 0.001:
		flat_dir = flat_dir.normalized()
		velocity.x = flat_dir.x * run_speed * 2.2
		velocity.z = flat_dir.z * run_speed * 2.2

	_play_anim("attack_2h_02")
	anim_player.speed_scale = 1.0
	var anim_len : float = _current_anim_length()

	await get_tree().create_timer(anim_len * 0.55).timeout
	if _life != _life_id: return

	if not _is_dead and is_instance_valid(player):
		var dist : float = global_position.distance_to(player.global_position)
		if dist <= enemy_shove_range * 1.6:
			var push_dir : Vector3 = player.global_position - global_position
			push_dir.y = 0.0
			if push_dir.length_squared() > 0.001:
				push_dir = push_dir.normalized()
			var player_damage_mod : float = float(player.enemy_damage_modifier) \
				if "enemy_damage_modifier" in player else 1.0
			if player.has_method("take_damage"):
				player.take_damage(enemy_shove_damage * player_damage_mod * _cached_damage_mod, self)
			if player.has_method("take_knockback"):
				player.take_knockback(push_dir, enemy_shove_force, enemy_shove_stun)

	await get_tree().create_timer(anim_len * 0.45).timeout
	if _life != _life_id: return
	_is_shoving          = false
	_is_attacking        = false
	_shove_cooldown_timer = enemy_shove_cooldown


func _set_horizontal_velocity(target: Vector3, accel: float, delta: float) -> void:
	velocity.x = move_toward(velocity.x, target.x, accel * delta)
	velocity.z = move_toward(velocity.z, target.z, accel * delta)


func _find_player() -> Node3D:
	if _cached_player and is_instance_valid(_cached_player): return _cached_player
	_cached_player = get_tree().get_first_node_in_group("player"); return _cached_player


func _update_strafe_timer(delta: float) -> void:
	if not enable_strafe: return
	_strafe_timer -= delta
	if _strafe_timer <= 0.0: _pick_new_strafe_sign()


func _pick_new_strafe_sign() -> void:
	_strafe_sign = -1.0 if randf() < 0.5 else 1.0
	_strafe_timer = strafe_switch_interval
