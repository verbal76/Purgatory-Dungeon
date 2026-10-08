# ============================================================
#  FILE:         Globe.gd
#  PATH:         res://objects/globe/Globe.gd
#  OPTIMIZATION: Throttled steering probes.
#  BUGFIX: Force-disabled collision mask against player to
#  ensure collection triggers without pushing.
#  BUGFIX 2: Added collision exception with player in activate()
#  so the globe passes through them. Excluded player from wall
#  probes so the globe doesn't steer away from its target.
#  VISUAL: OmniLight3D glow, GPUParticles3D mist trail, lateral sway.
# ============================================================

extends CharacterBody3D

const RARITY_COLORS : Dictionary = {
	"common"    : Color(0.45, 0.65, 1.0),
	"rare"      : Color(0.65, 0.25, 1.0),
	"legendary" : Color(1.0,  0.75, 0.1),
	"cursed"    : Color(0.70, 0.15, 0.95)  # witching-hour purple
}

enum GlobeState { DORMANT, CHASING, COLLECTED }

@export var chase_speed         : float = 5.5
@export var collect_radius      : float = 0.8
@export var float_height        : float = 0.8
@export var float_amplitude     : float = 0.18
@export var float_frequency     : float = 1.4
@export var forward_probe_dist  : float = 1.2
@export var wall_clearance_dist : float = 0.4
@export var side_probe_offset   : float = 0.35
@export var wall_check_height   : float = 0.5
@export var turn_step_degrees   : float = 15.0
@export var max_turn_steps      : int   = 6
@export var steering_interval   : float = 0.16

var _state           : GlobeState        = GlobeState.DORMANT
var _effect          : Dictionary        = {}
var _rarity          : String            = "common"
var _float_timer     : float             = 0.0
var _base_y          : float             = 0.0
var _mesh_inst       : MeshInstance3D    = null
var _glow_mat        : StandardMaterial3D = null
var _glow_light      : OmniLight3D       = null
var _mist_particles  : GPUParticles3D    = null
var _steering_timer  : float             = 0.0
var _cached_dir      : Vector3           = Vector3.ZERO
var _cached_player   : Node3D            = null

func _ready() -> void:
	collision_mask = 1
	collision_layer = 0

func setup(effect: Dictionary, rarity: String) -> void:
	_effect  = effect
	_rarity  = rarity
	_base_y  = global_position.y + float_height
	_build_visual()
	visible = false

func _build_visual() -> void:
	var rarity_col : Color = RARITY_COLORS.get(_rarity, Color.WHITE)

	# ── Bottle mesh (SM_PosionBottle.fbx) ────────────────────
	const GLOBE_FBX : String = "res://addons/props/SM_PosionBottle.fbx"
	if ResourceLoader.exists(GLOBE_FBX):
		var fbx_scene := load(GLOBE_FBX) as PackedScene
		if fbx_scene != null:
			var prop := fbx_scene.instantiate()
			prop.name  = "GlobeMesh"
			prop.scale = Vector3(0.55, 0.55, 0.55)
			add_child(prop)
			_mesh_inst = _find_first_mesh_in(prop)

	# Fallback: original sphere if FBX fails.
	if _mesh_inst == null:
		var fallback_mi := MeshInstance3D.new()
		var sphere      := SphereMesh.new()
		sphere.radius   = 0.25
		sphere.height   = 0.5
		fallback_mi.mesh = sphere
		_glow_mat = StandardMaterial3D.new()
		_glow_mat.albedo_color               = rarity_col
		_glow_mat.albedo_color.a             = 0.85
		_glow_mat.emission_enabled           = true
		_glow_mat.emission                   = rarity_col
		_glow_mat.emission_energy_multiplier = 1.2
		_glow_mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
		fallback_mi.material_override        = _glow_mat
		add_child(fallback_mi)
		_mesh_inst = fallback_mi

	# ── Glow light ───────────────────────────────────────────
	_glow_light              = OmniLight3D.new()
	_glow_light.light_color  = rarity_col
	_glow_light.omni_range   = 3.5
	_glow_light.light_energy = 1.8
	_glow_light.shadow_enabled = false
	add_child(_glow_light)

	# ── Mist trail particles ─────────────────────────────────
	_mist_particles          = GPUParticles3D.new()
	_mist_particles.amount   = 8
	_mist_particles.lifetime = 2.0
	_mist_particles.explosiveness = 0.0
	_mist_particles.randomness    = 0.5
	_mist_particles.local_coords  = false   # world space — creates a trail as the orb moves

	var pm := ParticleProcessMaterial.new()
	pm.direction               = Vector3(0.0, 1.0, 0.0)
	pm.spread                  = 45.0
	pm.initial_velocity_min    = 0.05
	pm.initial_velocity_max    = 0.25
	pm.gravity                 = Vector3.ZERO
	pm.scale_min               = 0.06
	pm.scale_max               = 0.14

	# Alpha fade over particle lifetime.
	var grad := Gradient.new()
	grad.set_color(0,  Color(1.0, 1.0, 1.0, 0.7))
	grad.set_offset(0, 0.0)
	grad.set_color(1,  Color(1.0, 1.0, 1.0, 0.0))
	grad.set_offset(1, 1.0)
	var ramp := GradientTexture1D.new()
	ramp.gradient = grad
	pm.color_ramp = ramp

	_mist_particles.process_material = pm

	# Billboard quad mesh for particles — twirl texture gives a swirling curse trail.
	var quad := QuadMesh.new()
	quad.size = Vector2(0.16, 0.16)
	var qmat := StandardMaterial3D.new()
	qmat.billboard_mode             = BaseMaterial3D.BILLBOARD_ENABLED
	qmat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	qmat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	qmat.albedo_color               = Color(rarity_col.r, rarity_col.g, rarity_col.b, 0.75)
	qmat.albedo_texture             = load("res://addons/kenney_particle_pack/twirl_01.png")
	qmat.emission_enabled           = true
	qmat.emission                   = rarity_col
	qmat.emission_energy_multiplier = 0.7
	quad.material                   = qmat
	_mist_particles.draw_pass_1     = quad
	_mist_particles.emitting        = false
	add_child(_mist_particles)


# Depth-first search for the first MeshInstance3D in an instanced FBX scene.
func _find_first_mesh_in(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for child in node.get_children():
		var found := _find_first_mesh_in(child)
		if found != null:
			return found
	return null

func activate() -> void:
	if _state != GlobeState.DORMANT:
		return
	var player = get_tree().get_first_node_in_group("player")
	if player != null:
		add_collision_exception_with(player)
		_cached_player = player
	_state = GlobeState.CHASING
	visible = true
	if _mist_particles != null:
		_mist_particles.emitting = true

func is_dormant() -> bool:
	return _state == GlobeState.DORMANT

func _physics_process(delta: float) -> void:
	if _state == GlobeState.CHASING:
		_tick_chasing(delta)

func _tick_chasing(delta: float) -> void:
	_float_timer += delta
	if _steering_timer > 0.0:
		_steering_timer -= delta

	var player : Node3D = _cached_player if _cached_player != null and is_instance_valid(_cached_player) \
						  else get_tree().get_first_node_in_group("player")
	if player == null:
		return
	_cached_player = player
	# A dead player cannot collect globes: the death screen has just converted kills into
	# potions, and a late "Grave Whispers" globe wiped them.
	if player.get("_is_dead") == true:
		return

	var to_player : Vector3 = player.global_position - global_position
	var dist      : float   = Vector3(to_player.x, 0.0, to_player.z).length()

	# Pulse glow light (and material emission only when using sphere fallback).
	var pulse : float = (sin(_float_timer * 3.0) + 1.0) * 0.5
	if _glow_light != null:
		_glow_light.light_energy = lerp(1.0, 2.8, pulse)
	if _glow_mat != null:
		_glow_mat.emission_energy_multiplier = lerp(0.8, 2.2, pulse)

	if dist <= collect_radius:
		_collect()
		return

	# Recalculate steering direction on interval.
	if _steering_timer <= 0.0 or _cached_dir == Vector3.ZERO:
		var desired : Vector3 = to_player.normalized()
		_cached_dir = _find_safe_direction(desired)
		if _cached_dir == Vector3.ZERO:
			_cached_dir = desired
		_steering_timer = steering_interval

	# Lateral sway perpendicular to the chase direction — ghostlike wavering.
	var perp : Vector3 = Vector3(_cached_dir.z, 0.0, -_cached_dir.x)
	var sway : float   = sin(_float_timer * 0.65) * 0.75

	velocity.x = _cached_dir.x * chase_speed + perp.x * sway
	velocity.z = _cached_dir.z * chase_speed + perp.z * sway
	velocity.y = ((_base_y + sin(_float_timer * float_frequency) * float_amplitude) - global_position.y) * 6.0
	move_and_slide()

func _find_safe_direction(base: Vector3) -> Vector3:
	var flat : Vector3 = Vector3(base.x, 0.0, base.z).normalized()
	if _direction_has_clearance(flat):
		return flat
	for step in range(1, max_turn_steps + 1):
		var ang : float = deg_to_rad(turn_step_degrees * float(step))
		for d in [1, -1]:
			var test : Vector3 = flat.rotated(Vector3.UP, ang * d).normalized()
			if _direction_has_clearance(test):
				return test
	return Vector3.ZERO

func _direction_has_clearance(dir: Vector3) -> bool:
	var flat  : Vector3 = dir.normalized()
	var right : Vector3 = Vector3(flat.z, 0.0, -flat.x).normalized()
	return _probe_clear(Vector3.ZERO, flat) \
	   and _probe_clear(-right * side_probe_offset, flat) \
	   and _probe_clear( right * side_probe_offset, flat)

func _probe_clear(offset: Vector3, dir: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	var start := global_position + Vector3(0.0, wall_check_height, 0.0) + offset
	var query := PhysicsRayQueryParameters3D.create(
		start, start + dir * (forward_probe_dist + wall_clearance_dist))
	query.collide_with_areas = false
	var exclude : Array[RID] = [get_rid()]
	if _cached_player != null and is_instance_valid(_cached_player):
		exclude.append(_cached_player.get_rid())
	query.exclude = exclude
	return space.intersect_ray(query).is_empty()

func _collect() -> void:
	_state = GlobeState.COLLECTED
	if _mist_particles != null:
		_mist_particles.emitting = false
	_effect = GlobeManager.resolve_effect_for_pickup(_effect)   # never hand out a curse that cannot bite
	GlobeManager.announce_collection(_effect)
	_apply_effect()
	call_deferred("queue_free")

func _apply_effect() -> void:
	var effect_type : String = _effect.get("effect_type", "")
	if effect_type == "currency":
		PlayerWallet.add_potions(int(_effect.get("value", 0)))
	elif effect_type == "drain_potions":
		# Grave Whispers — drain the entire potion wallet instantly.
		var current : int = SaveManager.current_profile.get("meta_currency", 0)
		if current > 0:
			PlayerWallet.spend_potions(current)
	else:
		BuffManager._apply_buff(_effect)
	GlobeManager.emit_signal("globe_collected", _effect)
