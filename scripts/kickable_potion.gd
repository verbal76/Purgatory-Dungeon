# ============================================================
#  FILE: kickable_potion.gd
#  PATH: res://scripts/kickable_potion.gd
#  USED BY: destructible_prop.gd (_spawn_potion_and_kick)
#  DESCRIPTION: RigidBody3D subclass for kicked potions.
#
#  LIFECYCLE:
#    1. Spawns un-frozen with an outward impulse applied by
#       destructible_prop._spawn_potion_and_kick().
#    2. While flying: clamps speed to MAX_SPEED so it cannot
#       tunnel through trimesh walls (Jolt CCD is unreliable
#       against ConcavePolygonShape3D).
#    3. When it comes to rest, transitions to HOVER mode:
#         - freeze_mode = KINEMATIC (collider only, no forces)
#         - animates bob / sway / rotation / light pulse
#           matching scripts/health_orb_manager.gd so kicked
#           potions read visually identical to naturally-spawned
#           health orbs.
# ============================================================

extends RigidBody3D

const MAX_SPEED            : float = 8.0   # slower than prop's 13 so potions
                                             #   never punch through wall geometry
const REST_SPEED_THRESHOLD : float = 0.4
const REST_TIME_TO_FREEZE  : float = 0.8

# Hover animation constants — mirror the natural orb in
# scripts/health_orb_manager.gd:216-238.
const HOVER_BOB_AMP   : float = 0.18
const HOVER_SWAY_AMP  : float = 0.10
const HOVER_SPIN      : float = 1.2      # radians / second
const HOVER_LIGHT_LO  : float = 0.8
const HOVER_LIGHT_HI  : float = 2.2

var _rest_timer : float     = 0.0
var _hovering   : bool      = false
var _rest_pos   : Vector3   = Vector3.ZERO
var _bob_offset : float     = 0.0
var _glow_light : OmniLight3D = null


func _physics_process(delta: float) -> void:
	# ── Hover state (runs forever once settled) ──────────────
	if _hovering:
		var ht : float = Time.get_ticks_msec() * 0.001
		var bob : float = sin(ht * 1.8 + _bob_offset) * HOVER_BOB_AMP
		var sway_x : float = sin(ht * 0.42 + _bob_offset * 1.1) * HOVER_SWAY_AMP
		var sway_z : float = cos(ht * 0.37 + _bob_offset * 0.9) * HOVER_SWAY_AMP
		global_position = _rest_pos + Vector3(sway_x, bob, sway_z)
		rotation.y += delta * HOVER_SPIN
		if _glow_light != null:
			var pulse : float = (sin(ht * 3.0 + _bob_offset) + 1.0) * 0.5
			_glow_light.light_energy = lerp(HOVER_LIGHT_LO, HOVER_LIGHT_HI, pulse)
		return

	# ── Flight phase: clamp speed, watch for rest ────────────
	var v : Vector3 = linear_velocity
	if v.length() > MAX_SPEED:
		linear_velocity = v.normalized() * MAX_SPEED
		v = linear_velocity

	if v.length() < REST_SPEED_THRESHOLD:
		_rest_timer += delta
		if _rest_timer >= REST_TIME_TO_FREEZE:
			_enter_hover_mode()
	else:
		_rest_timer = 0.0


func _enter_hover_mode() -> void:
	# Kinematic freeze lets us drive position via script while still
	# reporting as an immovable collider to the physics layer.
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze      = true
	_rest_pos   = global_position
	_bob_offset = randf_range(0.0, TAU)
	_hovering   = true
	# Cache the glow light so the pulse can drive its energy each tick.
	for c in get_children():
		if c is OmniLight3D:
			_glow_light = c
			break
