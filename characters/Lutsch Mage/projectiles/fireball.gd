# ==============================================================================
# File Name: fireball.gd
# Path: res://characters/Lutsch Mage/projectiles/fireball.gd
# Description: Area3D-based projectile for the Mage enemy.
#              Moves forward each frame and uses a per-frame raycast to detect
#              walls. The raycast runs BEFORE the position update so even thin
#              geometry is detected reliably — direct global_position manipulation
#              bypasses physics broadphase and can miss walls between frames.
#              Damages the player on Area3D body_entered, shuts down particles
#              cleanly, and respects the max_lifetime failsafe.
#
#  MOD NOTES:
#  - SURGICAL FIX: Added per-frame ShapeCast / raycast sweep for wall detection.
#    Previous version moved via global_position += which could tunnel through
#    thin walls between physics steps, hitting the player after they dodged.
#  - SURGICAL FIX: collision_mask set explicitly in _ready() to 0xFFFFFFFF so
#    wall detection works regardless of how the scene editor has it configured.
#  - POOL SUPPORT: activate() replaces setup() for pool-managed fireballs.
#    Pool fireballs hide themselves after fading instead of queue_free().
#    Non-pooled fireballs (setup() path) behave identically to before.
# ==============================================================================
extends Area3D

@export var speed              : float = 15.0   # Metres per second travel speed
@export var max_lifetime       : float = 5.0    # Failsafe: destroy after this many seconds
@export var particle_fade_time : float = 1.5    # Match your Kenney particle lifetime

@onready var _particles       : GPUParticles3D  = $GPUParticles3D
@onready var _collision_shape : CollisionShape3D = $CollisionShape3D

var _damage    : float   = 10.0
var _direction : Vector3 = Vector3.FORWARD
var _is_active : bool    = true

# True when this fireball is managed by mage_ai's pool.
# Pool fireballs hide on fade instead of queue_free().
var _is_pooled : bool = false

# Reusable lifetime timer — reset on each activate() to avoid stacking
# SceneTreeTimers that could fire on a reused fireball mid-flight.
var _lifetime_timer : Timer = null

# Cached ray query — allocated once in _ready() to avoid per-frame allocations.
var _wall_query : PhysicsRayQueryParameters3D = null


func _ready() -> void:
	# Force collision mask to detect everything — walls (layer 1) and player.
	# If this is left to the scene editor it may be wrong and fireballs
	# will tunnel through walls silently.
	collision_mask = 0xFFFFFFFF

	connect("body_entered", _on_body_entered)

	_wall_query = PhysicsRayQueryParameters3D.new()
	_wall_query.collide_with_bodies = true
	_wall_query.collide_with_areas  = false
	_wall_query.collision_mask      = 1      # Static geometry (walls) only
	_wall_query.exclude             = [get_rid()]

	# Reusable lifetime timer — started by setup() or activate(), not here.
	_lifetime_timer = Timer.new()
	_lifetime_timer.one_shot   = true
	_lifetime_timer.autostart  = false
	_lifetime_timer.wait_time  = max_lifetime
	_lifetime_timer.timeout.connect(_on_timeout)
	add_child(_lifetime_timer)

	# Dynamic light so the fireball illuminates dungeon walls on any
	# difficulty. Cluster cap at 4096 handles transient projectile lights.
	var l              := OmniLight3D.new()
	l.name              = "FireLight"
	l.light_color       = Color(1.0, 0.55, 0.1)
	l.light_energy      = 2.5
	l.omni_range        = 5.0
	l.shadow_enabled    = false
	add_child(l)


# ── Non-pooled path (original API, unchanged behaviour) ───────────────────────
# Called by mage_ai for one-shot fireballs that are not pool-managed.
func setup(damage: float, dir: Vector3) -> void:
	_is_pooled = false
	_damage    = damage
	_direction = dir.normalized()

	if _direction.length_squared() > 0.001:
		var look_target := global_position + _direction
		look_at(look_target, Vector3.UP)

	_lifetime_timer.start(max_lifetime)


# ── Pooled path ───────────────────────────────────────────────────────────────
# Called by mage_ai._acquire_fireball() to reuse a hidden fireball from the pool.
# Resets all flight state so the fireball behaves as if freshly instantiated.
func activate(damage: float, dir: Vector3) -> void:
	_is_pooled = true
	_damage    = damage
	_direction = dir.normalized()
	_is_active = true

	visible = true
	set_physics_process(true)

	if _collision_shape != null:
		_collision_shape.set_deferred("disabled", false)
	if _particles != null:
		_particles.restart()

	if _direction.length_squared() > 0.001:
		look_at(global_position + _direction, Vector3.UP)

	# Reset the timer so previous-use timeouts cannot fire mid new-flight.
	_lifetime_timer.stop()
	_lifetime_timer.start(max_lifetime)


func _physics_process(delta: float) -> void:
	if not _is_active:
		return

	var move_dist : float   = speed * delta
	var move_vec  : Vector3 = _direction * move_dist

	# ── Per-frame wall raycast ─────────────────────────────────────────────
	# Sweep a ray one full frame's movement ahead (plus a small margin so we
	# catch geometry right at the surface). If it hits before we'd arrive,
	# stop at the hit point and detonate. This prevents tunneling through walls.
	if _wall_query != null and is_inside_tree():
		var space := get_world_3d().direct_space_state
		_wall_query.from = global_position
		_wall_query.to   = global_position + move_vec + _direction * 0.15

		var hit := space.intersect_ray(_wall_query)
		if not hit.is_empty():
			_deactivate()
			return

	global_position += move_vec


func _on_body_entered(body: Node3D) -> void:
	if not _is_active:
		return

	if body.is_in_group("player") and body.has_method("take_damage"):
		body.take_damage(_damage, self)

	# Enemy fireball ends on a kickable prop too, and kicks it — can't pass through.
	if body.has_method("apply_kick"):
		body.apply_kick(_direction, _damage * 3.0)

	_deactivate()


func _on_timeout() -> void:
	if _is_active:
		_deactivate()


# Shared shutdown path — disables movement and hitbox, then fades particles.
# After the fade: pool fireballs hide themselves; non-pooled call queue_free().
func _deactivate() -> void:
	_is_active = false
	_lifetime_timer.stop()
	if _collision_shape != null:
		_collision_shape.set_deferred("disabled", true)
	if _particles != null:
		_particles.emitting = false
	get_tree().create_timer(particle_fade_time).timeout.connect(
		_on_particle_faded, CONNECT_ONE_SHOT)


func _on_particle_faded() -> void:
	if _is_pooled:
		# Return to pool: hide and suspend until activate() is called again.
		visible = false
		set_physics_process(false)
		# _is_active is already false — _acquire_fireball() uses this as
		# the availability flag so no further bookkeeping is needed.
	else:
		queue_free()
