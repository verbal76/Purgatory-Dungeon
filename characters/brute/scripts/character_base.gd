# ============================================================
#  FILE: character_base.gd
#  PATH: res://characters/brute/scripts/character_base.gd
#  DESCRIPTION: Base class for all characters.
#  MOD NOTES:
#  - Adjusted seek() to 0.5 to restore arm swing during jump.
#  - SURGICAL ADD: apply_buff() for enemy_manager to boost type-3 spawns.
#    Scales max_health and calls _on_buff_applied() virtual so AI
#    subclasses can scale their own speed/damage variables.
#  - SURGICAL FIX: apply_red_glow() disabled per user request to 
#    remove the "cherry red" overlay on buffed enemies.
#  - SURGICAL FIX: Raycast check added to take_knockback() to prevent 
#    velocity spikes from kicking enemies directly through wall colliders.
#  - SURGICAL FIX: _anim_map cached once in _ready() after _on_ready().
#    Previously _get_animation_map() allocated a new Dictionary on every
#    _play_anim() call. Falls back to _get_animation_map() directly if the
#    cache is empty, preventing infinite push_warning() spam that freezes
#    the editor at 18+ enemies.
#  - SURGICAL FIX: combat_anim_blend_time = 0.0 added. Locomotion states
#    blend smoothly via anim_blend_time; combat states (attack, react, kick,
#    block, death) snap in instantly. Blend time was the primary cause of
#    perceived input lag on attack and kick. anim_blend_time reduced
#    from 0.25 to 0.15 for snappier locomotion transitions.
#  - SURGICAL FIX: AI tick LOD retained (throttles _physics_tick at range).
#    Skeleton LOD (callback_mode_process switching + advance()) was REMOVED —
#    switching AnimationPlayer process mode on a live node caused a hard
#    freeze requiring a system reset. LOD is physics-only, not skeleton.
# ============================================================

extends CharacterBody3D
class_name CharacterBase

const GRAVITY    := 20.0
const TURN_SPEED := 10.0
const MESH_SCALE := 0.01
const MESH_FACING := PI

@export var max_health             : float = 100.0
@export var react_anim_speed       : float = 5.0
@export var death_anim_speed       : float = 1.0
# Locomotion blend (run↔idle). Was 0.25 — reduced for snappier feel.
@export var anim_blend_time        : float = 0.15
# Combat animations snap in with zero blend so attacks fire visually
# on the same frame the input is received. Set > 0 to soften if desired.
@export var combat_anim_blend_time : float = 0.0

# ── Footstep / head-bob (shared by all player characters) ─────────────────────
@export var head_bob_intensity             : float = 0.05
@export var head_bob_speed                 : float = 2.0
@export var footstep_interval_seconds      : float = 0.38
@export var footstep_volume_db             : float = 5.0
@export var footstep_pitch_min             : float = 0.96
@export var footstep_pitch_max             : float = 1.04
@export var minimum_movement_for_footsteps : float = 0.1

var _current_health  : float = 100.0
# Stored after _on_ready() so mage/brute health scaling is captured before any
# external buff is applied. reset_for_pool() restores max_health to this value.
var _base_max_health : float = 0.0

# ── Buff system ───────────────────────────────────────────────────────────────
var _buff_multiplier   : float = 1.0
# Incoming damage is multiplied by (1 - damage_reduction).  Capped at 0.9 to
# prevent complete immunity.  Set by the Iron Will buff.
var damage_reduction   : float = 0.0
# Multiplies outgoing damage when the target is below 30% health.
# Set by the Executioner buff.
var low_health_damage  : float = 0.0
# Adrenaline Spike: flat bonus damage added to the player's attacks while at or below
# LOW_HEALTH_FRACTION of max health (see get_low_health_attack_bonus()).
var low_hp_attack_bonus : float = 0.0
const LOW_HEALTH_FRACTION := 0.3
# Shadow Dancer: +kill_haste (a fraction, 0.18 = +18%) movement speed for KILL_HASTE_SECONDS after
# each kill. The timer is ticked in the player's _physics_tick, so it freezes while paused.
var kill_haste          : float = 0.0
var _kill_haste_timer   : float = 0.0
const KILL_HASTE_SECONDS := 5.0
# Globe curses / buffs that scale how hard the dungeon hits back. enemy_*_modifier are multipliers
# (1.0 = unchanged) read by the enemy AI; they live here so BOTH player classes can carry them.
var enemy_speed_modifier  : float = 1.0
var enemy_damage_modifier : float = 1.0

signal health_changed(new_health: float, max_val: float)
signal died

static var GLOBAL_KILL_COUNT : int = 0

# Incremented every time a pooled enemy is reborn (reset_for_pool). Delayed behaviour
# (attacks, hit reactions, death-return timers) captures it before awaiting and aborts
# if it changed, so nothing from a previous life can touch the new one.
var _life_id : int = 0
# World position of the most recent enemy kill — used by on-kill effects
# (spark_damage AOE, poison cloud, light flash) to know where to spawn.
static var GLOBAL_LAST_KILL_POS : Vector3 = Vector3.ZERO
# Timestamp (seconds) of the last time a player node took damage.
# enemy_manager.gd reads this to decide when to spawn pressure enemies.
static var GLOBAL_PLAYER_LAST_DAMAGE_TIME : float = 0.0

# FIX 2: Cached player reference shared across ALL enemy instances.
# get_nodes_in_group() walks the full scene tree every call — at 18 enemies
# that was 18 tree scans per second just for LOD distance. One static ref
# shared by all instances drops this to a single scan on first use ever.
static var _cached_player_lod : Node3D = null

@onready var mesh_root : Node3D = $Mesh

var anim_player  : AnimationPlayer = null
var _state       : String = ""
var _is_armed    : bool   = false
var _is_dead     : bool   = false
var _is_stunned  : bool   = false
var _is_reacting : bool   = false
var _stun_timer  : float  = 0.0

# Cached animation map — built once in _ready() after _on_ready() so
# subclass overrides of _get_animation_map() are captured.
# Falls back to calling _get_animation_map() directly if cache is empty,
# which prevents a push_warning() spam loop if caching fails for any reason.
var _anim_map : Dictionary = {}

# ── Footstep / head-bob runtime state ─────────────────────────────────────────
var camera_3d       : Camera3D          = null
var footstep_player : AudioStreamPlayer = null
var _footstep_timer : float = 0.0
var _head_bob_time  : float = 0.0
var _default_cam_y  : float = 0.0
var _is_blocking         : bool    = false
# Tracks the node that dealt the killing blow — used to credit kills only to
# the player, not to cull sweeps, traps, or other enemies.
var _last_damage_source  : Node3D  = null
# Knockback wall-hit response: armed when take_knockback() fires, consumed the
# first time a high-speed slide collision is detected during stun.
var _knockback_hit_fired : bool    = false

# ── AI tick throttling (LOD) ────────────────────────────────────────────────
# Enemies far from the player don't need 60Hz AI decisions. The interval is
# updated every second based on distance. move_and_slide() always runs so
# physics stays correct; only the expensive _physics_tick is throttled.
#   < 12m  → every frame  (60Hz)
#   12-25m → every 2nd    (30Hz)
#   25m+   → every 6th    (10Hz)
var _lod_skip_interval : int   = 1
var _lod_frame_counter : int   = 0
# Start at 1.0 so the LOD distance check fires on the FIRST physics tick after
# spawn instead of after a 1-second warmup — distant enemies drop to 10 Hz
# immediately, killing the spawn-wave CPU spike.
var _lod_dist_timer    : float = 1.0

# ── Off-screen freeze ────────────────────────────────────────────────────────
# Enemies that are both off-camera AND beyond 20m skip all physics processing.
# They freeze silently in place — the player never sees this happen.
# Resumes the instant the enemy re-enters the camera frustum or gets close.
# A VisibleOnScreenNotifier3D is attached at runtime in _ready() for all
# non-player characters. Saves ~900 move_and_slide() calls/second at 30 enemies.
const OFF_SCREEN_FREEZE_DIST_SQ : float = 400.0   # 20m × 20m
var _is_on_screen               : bool  = true


func _ready() -> void:
	_current_health = max_health
	mesh_root.scale = Vector3(MESH_SCALE, MESH_SCALE, MESH_SCALE)
	mesh_root.rotation.y = MESH_FACING

	anim_player = _find_anim_player(self)
	if anim_player == null:
		push_error("CharacterBase: no AnimationPlayer found in scene tree.")
		return

	_on_ready()

	# Store base health AFTER _on_ready() — mage scales max_health there.
	# reset_for_pool() restores to this pre-buff value on each reuse.
	_base_max_health = max_health

	# Cache after _on_ready() so subclass setup is complete.
	_anim_map = _get_animation_map()

	_change_state(_get_idle_state())

	# Attach a screen-visibility notifier to every non-player character.
	# Done after _on_ready() so the "player" group is already registered.
	if not is_in_group("player"):
		_setup_visibility_notifier()
	else:
		_build_damage_direction_fan()


# ══════════════════════════════════════════════════════════════
#  DAMAGE DIRECTION FAN  (player-only HUD indicator)
#  Narrow red wedge drawn on its own CanvasLayer, rotated around
#  screen centre to point at the damage source. Stacks on top of
#  each player's existing red vignette.
# ══════════════════════════════════════════════════════════════

const DAMAGE_FAN_PEAK_ALPHA  : float = 0.55
const DAMAGE_FAN_FADE_SPEED  : float = 0.9         # alpha units / second
const DAMAGE_FAN_ARC_DEG     : float = 30.0
const DAMAGE_FAN_INNER_RADIUS: float = 200.0
const DAMAGE_FAN_OUTER_RADIUS: float = 260.0

var _fan_layer   : CanvasLayer = null
var _fan_root    : Node2D      = null
var _fan_wedge   : Polygon2D   = null
var _fan_alpha   : float       = 0.0


func _build_damage_direction_fan() -> void:
	_fan_layer = CanvasLayer.new()
	_fan_layer.name  = "DamageDirectionLayer"
	_fan_layer.layer = 25   # Above default HUD (0), below minimap (30)
	add_child(_fan_layer)

	_fan_root = Node2D.new()
	_fan_root.name = "DamageFanRoot"
	_fan_layer.add_child(_fan_root)

	# Wedge drawn in LOCAL space pointing up (-Y). Rotating _fan_root rotates
	# the wedge around the screen-centre pivot.
	_fan_wedge = Polygon2D.new()
	_fan_wedge.name  = "DamageFanWedge"
	_fan_wedge.color = Color(0.9, 0.1, 0.1, 0.0)
	_fan_wedge.polygon = _build_wedge_polygon(
		DAMAGE_FAN_INNER_RADIUS,
		DAMAGE_FAN_OUTER_RADIUS,
		deg_to_rad(DAMAGE_FAN_ARC_DEG))
	_fan_root.add_child(_fan_wedge)

	_update_fan_position()
	var vp : Viewport = get_viewport()
	if vp != null and not vp.size_changed.is_connected(_update_fan_position):
		vp.size_changed.connect(_update_fan_position)


# Builds a 2D wedge polygon pointing up (-Y), spanning `arc_rad` centred on up.
# Outer radius at top, inner radius as the flat base — a ring segment.
func _build_wedge_polygon(r_inner: float, r_outer: float, arc_rad: float) -> PackedVector2Array:
	var pts : PackedVector2Array = []
	var steps : int = 8
	var start : float = -arc_rad * 0.5 - PI * 0.5   # centre at -Y
	# Outer arc, left → right.
	for i in steps + 1:
		var t : float = float(i) / float(steps)
		var a : float = start + arc_rad * t
		pts.append(Vector2(cos(a), sin(a)) * r_outer)
	# Inner arc, right → left.
	for i in steps + 1:
		var t : float = float(i) / float(steps)
		var a : float = start + arc_rad * (1.0 - t)
		pts.append(Vector2(cos(a), sin(a)) * r_inner)
	return pts


func _update_fan_position() -> void:
	if _fan_root == null:
		return
	var vp : Viewport = get_viewport()
	if vp == null:
		return
	var size : Vector2 = vp.get_visible_rect().size
	_fan_root.position = size * 0.5


# Flashes the wedge at the angle from player forward toward `source_node`.
# `player_yaw` is the player's yaw so we can compute a screen-relative angle
# without each subclass handling trig differently.
func _flash_damage_direction(source_node: Node3D, player_yaw: float) -> void:
	if _fan_root == null or _fan_wedge == null or source_node == null:
		return
	var to_src : Vector3 = source_node.global_position - global_position
	if to_src.length_squared() < 0.01:
		return

	# World-space XZ direction of the damage source.
	var src_xz : Vector2 = Vector2(to_src.x, to_src.z)
	if src_xz.length_squared() < 0.0001:
		return
	src_xz = src_xz.normalized()

	# Player forward in XZ (yaw=0 faces -Z, matching the kick code convention).
	var fwd_xz : Vector2 = Vector2(-sin(player_yaw), -cos(player_yaw))

	# Angle from forward to source (positive = source is to the player's right).
	var cross : float = fwd_xz.x * src_xz.y - fwd_xz.y * src_xz.x
	var dot   : float = fwd_xz.dot(src_xz)
	var relative : float = atan2(cross, dot)

	_fan_root.rotation = relative
	_fan_alpha = DAMAGE_FAN_PEAK_ALPHA
	_fan_wedge.color.a = _fan_alpha


func _tick_damage_fan(delta: float) -> void:
	if _fan_wedge == null or _fan_alpha <= 0.0:
		return
	_fan_alpha = maxf(_fan_alpha - DAMAGE_FAN_FADE_SPEED * delta, 0.0)
	_fan_wedge.color.a = _fan_alpha


func _setup_visibility_notifier() -> void:
	var notifier := VisibleOnScreenNotifier3D.new()
	# AABB sized to roughly cover an enemy capsule (2m wide, 2.5m tall).
	# Slightly generous so the freeze doesn't trigger while still partially visible.
	notifier.aabb = AABB(Vector3(-1.0, 0.0, -1.0), Vector3(2.0, 2.5, 2.0))
	add_child(notifier)
	notifier.screen_entered.connect(func(): _is_on_screen = true)
	notifier.screen_exited.connect(func(): _is_on_screen = false)


func _on_ready() -> void:
	pass


func _physics_process(delta: float) -> void:
	if _is_dead:
		if not is_on_floor():
			velocity.y -= GRAVITY * delta
		else:
			velocity.y = -0.01

		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()

		if mesh_root != null:
			mesh_root.position = Vector3.ZERO
		return

	if _is_stunned:
		_stun_timer -= delta
		if _stun_timer <= 0.0:
			_is_stunned = false

	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	# ── AI tick LOD (enemies only) ─────────────────────────────────────────
	# Players always get full ticks. Enemies throttle _physics_tick by
	# distance. move_and_slide() always runs to keep physics correct.
	# NOTE: Skeleton LOD (AnimationPlayer process mode switching) was removed
	# because switching callback_mode_process on a live AnimationMixer caused
	# a hard engine freeze. Physics-only LOD is stable.
	if not is_in_group("player"):
		# ── Off-screen freeze ─────────────────────────────────────────────────
		# Enemy is off-camera AND far enough that the player won't notice a freeze.
		# Zero velocity and skip all further physics this tick.
		if not _is_on_screen and is_on_floor() \
				and _cached_player_lod != null \
				and is_instance_valid(_cached_player_lod) \
				and global_position.distance_squared_to(
					_cached_player_lod.global_position) > OFF_SCREEN_FREEZE_DIST_SQ:
			velocity = Vector3.ZERO
			return

		_lod_dist_timer += delta
		if _lod_dist_timer >= 1.0:
			_lod_dist_timer = 0.0
			# FIX 2: Use static cached ref — no scene tree scan per enemy per second.
			if _cached_player_lod == null or not is_instance_valid(_cached_player_lod):
				_cached_player_lod = get_tree().get_first_node_in_group("player")
			if _cached_player_lod != null:
				var d : float = global_position.distance_to(_cached_player_lod.global_position)
				if   d < 12.0: _lod_skip_interval = 1
				elif d < 25.0: _lod_skip_interval = 2
				else:          _lod_skip_interval = 6

		_lod_frame_counter += 1
		if _lod_frame_counter < _lod_skip_interval:
			move_and_slide()
			if mesh_root != null:
				mesh_root.position = Vector3.ZERO
			return

		_lod_frame_counter = 0
		var effective_delta := delta * float(_lod_skip_interval)
		_physics_tick(effective_delta)
		move_and_slide()
		if mesh_root != null:
			mesh_root.position = Vector3.ZERO
		_smooth_turn(effective_delta)
		return

	_physics_tick(delta)
	move_and_slide()

	# Knockback wall-hit response — fires once per knockback event when the
	# player is stunned, moving fast, and has a slide collision (wall or body).
	if _is_stunned and not _knockback_hit_fired:
		var flat_spd : float = Vector2(velocity.x, velocity.z).length()
		if flat_spd > 3.0 and get_slide_collision_count() > 0:
			_knockback_hit_fired = true
			_on_knockback_wall_hit()

	if mesh_root != null:
		mesh_root.position = Vector3.ZERO

	_smooth_turn(delta)


func _process(_delta: float) -> void:
	if mesh_root != null:
		mesh_root.position = Vector3.ZERO


func _physics_tick(_delta: float) -> void:
	pass


# Called at most once per knockback event when the player slides into a wall
# or body at speed. Override in player scripts for sound + minor damage.
func _on_knockback_wall_hit() -> void:
	pass


func take_damage(amount: float, _source_node: Node3D = null) -> void:
	if _is_dead:
		return

	_last_damage_source = _source_node

	if is_in_group("player"):
		CharacterBase.GLOBAL_PLAYER_LAST_DAMAGE_TIME = Time.get_ticks_msec() * 0.001
		# Apply damage reduction (Iron Will buff).  Cap at 90% so the player
		# always takes at least 10% of any hit — prevents full immunity stacking.
		# A negative value (Pain Mirror, Void Embrace curses) makes the player take MORE damage.
		if damage_reduction != 0.0:
			amount *= maxf(0.1, 1.0 - clampf(damage_reduction, -1.0, 0.9))

	_current_health = maxf(_current_health - amount, 0.0)
	health_changed.emit(_current_health, max_health)

	if _current_health <= 0.0:
		_trigger_death()
	elif not _is_reacting:
		_play_hit_react()


func receive_heal(amount: float) -> void:
	if _is_dead:
		return

	_current_health = minf(_current_health + amount, max_health)
	health_changed.emit(_current_health, max_health)


# Bonus attack damage that depends on the player's current health (Adrenaline Spike).
func get_low_health_attack_bonus() -> float:
	if low_hp_attack_bonus > 0.0 and max_health > 0.0 \
			and _current_health / max_health < LOW_HEALTH_FRACTION:
		return low_hp_attack_bonus
	return 0.0


# Called by the player after kills are registered (Shadow Dancer).
func _on_kill_haste_trigger() -> void:
	if kill_haste > 0.0:
		_kill_haste_timer = KILL_HASTE_SECONDS


func _tick_kill_haste(delta: float) -> void:
	if _kill_haste_timer > 0.0:
		_kill_haste_timer = maxf(_kill_haste_timer - delta, 0.0)


func kill_haste_multiplier() -> float:
	return 1.0 + kill_haste if _kill_haste_timer > 0.0 and kill_haste > 0.0 else 1.0


func take_knockback(direction: Vector3, force: float, stun_duration: float = 1.0) -> void:
	if _is_dead:
		return

	_knockback_hit_fired = false   # Arm the wall-hit response for this new knockback
	var flat := Vector3(direction.x, 0.0, direction.z).normalized()

	var space     := get_world_3d().direct_space_state
	var start_pos := global_position + Vector3(0, 1.0, 0)
	var end_pos   := start_pos + (flat * 3.0)

	var query := PhysicsRayQueryParameters3D.create(start_pos, end_pos)
	query.collision_mask = 1
	query.exclude        = [get_rid()]

	var hit         := space.intersect_ray(query)
	var final_force := force

	if not hit.is_empty():
		var wall_dist : float = start_pos.distance_to(hit.position)
		final_force = minf(force, maxf(wall_dist - 0.5, 0.0) * 4.0)

	velocity.x  = flat.x * final_force
	velocity.z  = flat.z * final_force
	_is_stunned = true
	_stun_timer = stun_duration


func apply_buff(multiplier: float) -> void:
	_buff_multiplier = multiplier
	max_health      *= multiplier
	_current_health  = max_health
	health_changed.emit(_current_health, max_health)
	_on_buff_applied(multiplier)


func _on_buff_applied(_multiplier: float) -> void:
	pass


func apply_red_glow() -> void:
	pass


func _play_hit_react() -> void:
	if anim_player == null:
		return

	_is_reacting = true
	anim_player.speed_scale = react_anim_speed
	_play_anim("react_gut")
	await anim_player.animation_finished

	anim_player.speed_scale = 1.0
	_is_reacting = false

	if not _is_dead:
		_change_state(_get_idle_state())


func _trigger_death() -> void:
	if _is_dead:
		return

	_is_dead     = true
	_is_stunned  = false
	_is_reacting = false
	velocity     = Vector3.ZERO

	if anim_player != null:
		anim_player.speed_scale = death_anim_speed

	if not is_in_group("player"):
		# Only credit the kill if the player dealt the finishing blow.
		# Day-cull, room-lock cull, and trap deaths pass no source (null),
		# so those do NOT increment the counter.
		if _last_damage_source != null \
				and is_instance_valid(_last_damage_source) \
				and _last_damage_source.is_in_group("player"):
			GLOBAL_KILL_COUNT     += 1
			GLOBAL_LAST_KILL_POS   = global_position

	died.emit()
	_on_die()


func _on_die() -> void:
	pass


# ══════════════════════════════════════════════════════════════
#  ON-KILL EFFECT HELPERS
#  Called by both player scripts after GLOBAL_LAST_KILL_POS is set.
#  All effects use get_tree().get_nodes_in_group("enemies") so they
#  never need to create physics bodies mid-frame.
# ══════════════════════════════════════════════════════════════

# Spark Fury — instant AOE damage burst at the kill location.
func _spawn_kill_aoe(kill_pos: Vector3, damage: float) -> void:
	const RADIUS : float = 3.0
	for enemy in get_tree().get_nodes_in_group("enemies"):
		if enemy is Node3D and enemy != self:
			if (enemy as Node3D).global_position.distance_to(kill_pos) <= RADIUS:
				if enemy.has_method("take_damage"):
					enemy.take_damage(damage, self)


# Radiant Sparks / Bright Carnage — brief OmniLight3D flash at kill location.
func _spawn_kill_flash(kill_pos: Vector3, range_bonus: float, brightness: float) -> void:
	if not is_inside_tree():
		return
	var light        := OmniLight3D.new()
	light.omni_range  = 4.0 + range_bonus * 10.0
	light.light_energy = 3.0 + brightness * 10.0
	light.light_color  = Color(1.0, 0.88, 0.45)
	get_tree().current_scene.add_child(light)
	light.global_position = kill_pos + Vector3(0.0, 0.5, 0.0)
	# Fade and remove over 0.5 s.
	var tw := create_tween()
	tw.tween_property(light, "light_energy", 0.0, 0.5)
	tw.finished.connect(light.queue_free)


# Plague Spreader — poison cloud that deals 5 damage every 0.5 s for 5 s.
func _spawn_poison_cloud(kill_pos: Vector3) -> void:
	const TICK_DAMAGE : float = 5.0
	const TICK_INTERVAL : float = 0.5
	const TICKS_TOTAL : int = 10   # 10 × 0.5 s = 5 s
	const RADIUS : float = 2.0
	var ticks := TICKS_TOTAL
	while ticks > 0 and is_instance_valid(self) and not _is_dead:
		await get_tree().create_timer(TICK_INTERVAL).timeout
		if not is_instance_valid(self) or _is_dead:
			return
		ticks -= 1
		for enemy in get_tree().get_nodes_in_group("enemies"):
			if enemy is Node3D and enemy != self:
				if (enemy as Node3D).global_position.distance_to(kill_pos) <= RADIUS:
					if enemy.has_method("take_damage"):
						enemy.take_damage(TICK_DAMAGE, self)


func get_health() -> float:
	return _current_health


func _change_state(new_state: String) -> void:
	if _is_dead:
		return
	if _is_reacting:
		return
	if new_state == _state or new_state == "":
		return

	_state = new_state
	_play_anim(_state)


func _play_anim(anim_name: String) -> void:
	# Use cached map. Fall back to live call if cache is empty — this prevents
	# a push_warning() spam loop if the cache failed to populate for any reason.
	var map : Dictionary = _anim_map if not _anim_map.is_empty() \
			else _get_animation_map()
	var real_name : String = str(map.get(anim_name, ""))

	if real_name == "":
		# Suppress warning in base class — base always has an empty map.
		# Only warn from subclasses that should have a populated map.
		if not _anim_map.is_empty():
			push_warning("CharacterBase: no mapping for state -> " + anim_name)
		return

	if not anim_player.has_animation(real_name):
		push_warning("CharacterBase: animation not found -> " + real_name)
		return

	var anim_resource : Animation = anim_player.get_animation(real_name)
	if anim_resource != null:
		if _is_locomotion_state(anim_name):
			anim_resource.loop_mode = Animation.LOOP_LINEAR
		else:
			anim_resource.loop_mode = Animation.LOOP_NONE

	# Locomotion blends smoothly. Combat snaps immediately.
	var blend : float = anim_blend_time if _is_locomotion_state(anim_name) \
			else combat_anim_blend_time
	anim_player.play(real_name, blend)

	# SURGICAL SKIP: Trim the crouch wind-up off the Mage's jump animation.
	if self is MageCharacter and real_name == "StandingJump":
		anim_player.seek(0.5, true)


func _is_locomotion_state(state_name: String) -> bool:
	return state_name in [
		"standing_idle", "unarmed_idle",
		"standing_run_forward", "standing_run_back",
		"unarmed_run_forward", "unarmed_run_back",
		"unarmed_jump_running",
	]


func _get_animation_map() -> Dictionary:
	return {}


func set_armed(armed: bool) -> void:
	_is_armed = armed
	if not _is_dead:
		_change_state(_get_idle_state())


func _get_idle_state() -> String:
	return "standing_idle" if _is_armed else "unarmed_idle"


func _smooth_turn(delta: float) -> void:
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	if flat.length() < 0.1:
		return

	var angle := atan2(flat.x, flat.z) + MESH_FACING
	mesh_root.rotation.y = lerp_angle(
		mesh_root.rotation.y, angle, TURN_SPEED * delta
	)


func _find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		var ap := node as AnimationPlayer
		# Skip empty AnimationPlayers — prop FBX imports (e.g. a staff) can create
		# an AP with zero animations.  Returning one of those causes every
		# has_animation() call to fail even though the real AP is nearby.
		if ap.get_animation_list().size() > 0:
			return ap

	for child in node.get_children():
		var found := _find_anim_player(child)
		if found:
			return found

	return null


# ══════════════════════════════════════════════════════════════
#  FOOTSTEP / HEAD BOB  (shared by brute and mage player scripts)
# ══════════════════════════════════════════════════════════════

# Override in player scripts to provide the correct effective speed for
# footstep interval scaling.
func _get_effective_move_speed() -> float:
	return 1.0


# Override in player scripts that carry a footstep audio stream.
func _get_footstep_stream() -> AudioStream:
	return null


func _configure_footstep_player() -> void:
	if footstep_player == null:
		return
	var stream := _get_footstep_stream()
	if stream != null:
		footstep_player.stream = stream
	footstep_player.autoplay  = false
	footstep_player.bus       = AudioManager.get_sfx_bus_name() if has_node("/root/AudioManager") else "Master"
	footstep_player.volume_db = _get_footstep_db()


func _update_footsteps(delta: float) -> void:
	if footstep_player == null or not is_on_floor():
		_footstep_timer = 0.0
		return
	var h_speed := Vector2(velocity.x, velocity.z).length()
	if h_speed < minimum_movement_for_footsteps:
		_footstep_timer = 0.0
		return
	_footstep_timer -= delta
	if _footstep_timer <= 0.0:
		footstep_player.stop()
		footstep_player.volume_db   = _get_footstep_db()
		footstep_player.pitch_scale = randf_range(footstep_pitch_min, footstep_pitch_max)
		footstep_player.play()
		# Buffs add to footstep_interval_seconds as an absolute (Footstep Stalker is -0.5 on a 0.38
		# default), which could go to or below 0 and retrigger the sound every frame. Floor it.
		_footstep_timer = maxf(footstep_interval_seconds, 0.12) / clampf(h_speed / _get_effective_move_speed(), 0.65, 1.35)


func _apply_head_bob(delta: float) -> void:
	if camera_3d == null:
		return
	var h_speed := Vector2(velocity.x, velocity.z).length()
	if is_on_floor() and h_speed > minimum_movement_for_footsteps and not _is_blocking:
		_head_bob_time += delta * h_speed * head_bob_speed
		var bob_offset := sin(_head_bob_time) * maxf(head_bob_intensity, 0.0)   # a buff must not invert the bob
		camera_3d.position.y = lerp(camera_3d.position.y, _default_cam_y + bob_offset, delta * 10.0)
	else:
		_head_bob_time = 0.0
		camera_3d.position.y = lerp(camera_3d.position.y, _default_cam_y, delta * 10.0)


func _stop_footsteps() -> void:
	_footstep_timer = 0.0
	if footstep_player != null and footstep_player.playing:
		footstep_player.stop()


func _get_footstep_db() -> float:
	if has_node("/root/AudioManager"):
		return AudioManager.get_effective_sfx_playback_db(footstep_volume_db)
	return footstep_volume_db


func _current_anim_length() -> float:
	if anim_player == null:
		return 0.5

	var anim_name := anim_player.current_animation
	if anim_name == "":
		return 0.5

	if not anim_player.has_animation(anim_name):
		return 0.5

	return anim_player.get_animation(anim_name).length
