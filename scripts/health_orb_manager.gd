# ============================================================
#  FILE: health_orb_manager.gd
#  PATH: res://scripts/health_orb_manager.gd
#  ATTACHED TO: Node3D in Purgatory_Dungeon_main_game_file.tscn
#  USED BY: Player
#  DESCRIPTION: Spawns and manages floating health orbs.
#  MOD NOTES:
#  - Injected AudioManager.play_buff_choice() into _on_body_entered
#    so a sound plays when the player collects the orb.
#  - Added OmniLight3D glow, GPUParticles3D mist, lateral sway
#    so orbs feel ghostlike and alive.
# ============================================================

extends Node3D

@export var orb_count     : int   = 10
@export var heal_amount   : float = 25.0
@export var respawn_time  : float = 60.0
@export var relocate_time : float = 180.0
@export var orb_height    : float = 0.9
@export var orb_radius    : float = 0.28
@export var pickup_radius : float = 1.1

# Orb colour — also used for glow light and mist particles.
const ORB_COLOR      : Color = Color(0.15, 1.0,  0.35)
const ORB_EMIT_COLOR : Color = Color(0.05, 0.6,  0.2)
const ORB_LIGHT_RANGE : float = 3.0

class OrbData:
	var root           : Node3D             = null
	var mesh_inst      : MeshInstance3D     = null
	var mat            : StandardMaterial3D = null
	var glow_light     : OmniLight3D        = null
	var mist_particles : GPUParticles3D     = null
	var area           : Area3D             = null
	var is_active      : bool               = true
	var spawn_pos      : Vector3            = Vector3.ZERO
	var idle_timer     : float              = 0.0
	var respawn_timer  : float              = 0.0
	var bob_offset     : float              = 0.0

var _orbs                   : Array      = []
var _spawn_points           : Array      = []
var _exhausted_spawn_points : Dictionary = {}


# ══════════════════════════════════════════════════════════════
#  INITIALISATION
# ══════════════════════════════════════════════════════════════

# Staged population (see Purgatory_Dungeon_main_game_file.gd). Modules are visited in random order; every
# module that has a clear point contributes a spawn point, and the first `orb_count` of them get their orb
# at once (`stage_near_done`), the rest are only collected for the respawn / relocation draws. The old pass
# computed a safe point for ALL ~330 modules before placing 10 orbs.
var stage_near_done : bool = true
var stage_done : bool = true


func stage_begin(_origin: Vector3) -> void:
	stage_near_done = false
	stage_done = false
	call("_stage_run")   # dynamic call: runs as a background coroutine


func _entry_mark(label: String) -> void:
	var main : Node = get_parent()
	if main != null and main.has_method("entry_mark"):
		main.entry_mark(label)


func _stage_run() -> void:
	var main : Node = get_parent()
	# ── Easy difficulty: more frequent orbs ───────────────────────────────────
	if has_node("/root/GlobalRunData") and GlobalRunData.difficulty == "easy":
		orb_count    = int(orb_count * 1.6)
		respawn_time = respawn_time * 0.5

	var gen : Node = main.get_node_or_null("DungeonGenerationFunction")
	var modules : Array = []
	if gen == null:
		push_warning("HealthOrbManager: DungeonGenerationFunction not found.")
	else:
		modules = (gen.get("placed_modules") as Array).duplicate() if gen.get("placed_modules") != null else []
		if modules.is_empty():
			push_warning("HealthOrbManager: placed_modules is empty.")
	modules.shuffle()
	var want : int = 0 if GlobalRunData.debug_no_health_orbs else orb_count
	_entry_mark("orbs_begin")
	if want <= 0:
		modules.clear()
		stage_near_done = true
	var created : int = 0
	for mod in modules:
		if mod is Node3D and is_instance_valid(mod):
			# Margin 2.0 (up from default 1.25) keeps the larger FBX model clear of walls.
			var safe_point : Vector3 = gen.get_random_safe_interior_point(mod as Node3D, orb_height, 2.0)
			if safe_point != Vector3.ZERO:
				_spawn_points.append(safe_point)
				if created < want:
					_create_orb(safe_point)
					created += 1
					if created >= want:
						stage_near_done = true
						_entry_mark("orbs_placed")
		if main.has_method("stage_over") and main.stage_over():
			await get_tree().process_frame
	if want > 0 and created == 0:
		push_warning("HealthOrbManager: no spawn points — orbs not placed.")
	stage_near_done = true
	stage_done = true
	_entry_mark("orbs_end")


# ══════════════════════════════════════════════════════════════
#  ORB CREATION
# ══════════════════════════════════════════════════════════════

func _create_orb(pos: Vector3) -> void:
	var data        := OrbData.new()
	data.spawn_pos   = pos
	data.is_active   = true
	data.bob_offset  = randf_range(0.0, TAU)

	# Root node — added to tree first to avoid !is_inside_tree errors.
	var root := Node3D.new()
	add_child(root)
	root.global_position = pos
	data.root = root

	# ── Mana Potion mesh (SM_ManaPotion.fbx) ─────────────────
	const MANA_FBX : String = "res://addons/props/SM_ManaPotion.fbx"
	if ResourceLoader.exists(MANA_FBX):
		var fbx_scene := load(MANA_FBX) as PackedScene
		if fbx_scene != null:
			var prop := fbx_scene.instantiate()
			prop.name  = "OrbMesh"
			prop.scale = Vector3(0.65, 0.65, 0.65)
			root.add_child(prop)
			data.mesh_inst = _find_first_mesh_in(prop)

	# Fallback: original sphere if FBX fails.
	if data.mesh_inst == null:
		var mesh_inst   := MeshInstance3D.new()
		var sphere_mesh := SphereMesh.new()
		sphere_mesh.radius = orb_radius
		sphere_mesh.height = orb_radius * 2.0
		mesh_inst.mesh     = sphere_mesh
		var mat                       := StandardMaterial3D.new()
		mat.albedo_color               = ORB_COLOR
		mat.emission_enabled           = true
		mat.emission                   = ORB_EMIT_COLOR
		mat.emission_energy_multiplier = 2.0
		mesh_inst.material_override    = mat
		root.add_child(mesh_inst)
		data.mesh_inst = mesh_inst
		data.mat       = mat

	# ── Glow light ───────────────────────────────────────────
	var glow_light              := OmniLight3D.new()
	glow_light.light_color       = ORB_COLOR
	glow_light.omni_range        = ORB_LIGHT_RANGE
	glow_light.light_energy      = 1.5
	glow_light.shadow_enabled    = false
	root.add_child(glow_light)
	data.glow_light = glow_light

	# ── Mist particles ───────────────────────────────────────
	var mist              := GPUParticles3D.new()
	mist.amount            = 6
	mist.lifetime          = 2.5
	mist.explosiveness     = 0.0
	mist.randomness        = 0.6
	mist.local_coords      = true   # move with the orb's gentle bob

	var pm := ParticleProcessMaterial.new()
	pm.direction            = Vector3(0.0, 1.0, 0.0)
	pm.spread               = 40.0
	pm.initial_velocity_min = 0.05
	pm.initial_velocity_max = 0.2
	pm.gravity              = Vector3.ZERO
	pm.scale_min            = 0.05
	pm.scale_max            = 0.12

	var grad := Gradient.new()
	grad.set_color(0,  Color(1.0, 1.0, 1.0, 0.6))
	grad.set_offset(0, 0.0)
	grad.set_color(1,  Color(1.0, 1.0, 1.0, 0.0))
	grad.set_offset(1, 1.0)
	var ramp := GradientTexture1D.new()
	ramp.gradient   = grad
	pm.color_ramp   = ramp
	mist.process_material = pm

	var quad := QuadMesh.new()
	quad.size = Vector2(0.14, 0.14)
	var qmat := StandardMaterial3D.new()
	qmat.billboard_mode             = BaseMaterial3D.BILLBOARD_ENABLED
	qmat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	qmat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	qmat.albedo_color               = Color(ORB_COLOR.r, ORB_COLOR.g, ORB_COLOR.b, 0.75)
	qmat.albedo_texture             = load("res://addons/kenney_particle_pack/magic_04.png")
	qmat.emission_enabled           = true
	qmat.emission                   = ORB_EMIT_COLOR
	qmat.emission_energy_multiplier = 0.8
	quad.material                   = qmat
	mist.draw_pass_1                = quad
	mist.emitting                   = true
	root.add_child(mist)
	data.mist_particles = mist

	# ── Area3D pickup detector ───────────────────────────────
	var area      := Area3D.new()
	var col_shape := CollisionShape3D.new()
	var sph_shape := SphereShape3D.new()
	sph_shape.radius = pickup_radius
	col_shape.shape  = sph_shape
	area.add_child(col_shape)
	root.add_child(area)
	area.body_entered.connect(_on_body_entered.bind(data))
	data.area = area

	_orbs.append(data)


# ══════════════════════════════════════════════════════════════
#  UPDATE
# ══════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	var t : float = Time.get_ticks_msec() * 0.001

	for data in _orbs:
		if not is_instance_valid(data.root):
			continue

		if data.is_active:
			# Vertical bob.
			var bob : float = sin(t * 1.8 + data.bob_offset) * 0.18

			# Slow lateral sway on two independent axes — ghostlike drift.
			var sway_x : float = sin(t * 0.42 + data.bob_offset * 1.1) * 0.10
			var sway_z : float = cos(t * 0.37 + data.bob_offset * 0.9) * 0.10

			data.root.position = data.spawn_pos + Vector3(sway_x, bob, sway_z)

			# Spin.
			data.root.rotation.y += delta * 1.2

			# Pulse glow light (and material emission only when using sphere fallback).
			var pulse : float = (sin(t * 3.0 + data.bob_offset) + 1.0) * 0.5
			if data.glow_light != null:
				data.glow_light.light_energy = lerp(0.8, 2.2, pulse)
			if data.mat != null:
				data.mat.emission_energy_multiplier = lerp(1.2, 3.0, pulse)

			# Relocate if untouched too long.
			data.idle_timer += delta
			if data.idle_timer >= relocate_time:
				_relocate_orb(data)

		else:
			data.respawn_timer -= delta
			if data.respawn_timer <= 0.0:
				_activate_orb(data)


# ══════════════════════════════════════════════════════════════
#  PICKUP
# ══════════════════════════════════════════════════════════════

func _on_body_entered(body: Node3D, data: OrbData) -> void:
	if not data.is_active:
		return
	if not body.is_in_group("player"):
		return
	if not body.has_method("receive_heal"):
		return

	body.receive_heal(heal_amount)

	if has_node("/root/AudioManager"):
		AudioManager.play_buff_choice()

	_deactivate_orb(data)


# ══════════════════════════════════════════════════════════════
#  HELPERS
# ══════════════════════════════════════════════════════════════

# Depth-first search for the first MeshInstance3D inside an instanced FBX scene.
func _find_first_mesh_in(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for child in node.get_children():
		var found := _find_first_mesh_in(child)
		if found != null:
			return found
	return null


# ══════════════════════════════════════════════════════════════
#  STATE MANAGEMENT
# ══════════════════════════════════════════════════════════════

func _deactivate_orb(data: OrbData) -> void:
	_exhausted_spawn_points[str(data.spawn_pos)] = true
	data.is_active     = false
	data.respawn_timer = respawn_time
	data.idle_timer    = 0.0
	data.root.visible  = false
	if data.mist_particles != null:
		data.mist_particles.emitting = false


func _activate_orb(data: OrbData) -> void:
	var fresh : Vector3 = _pick_fresh_spawn_point()
	if fresh == Vector3.ZERO:
		data.respawn_timer = 0.0
		return
	data.spawn_pos     = fresh
	data.is_active     = true
	data.idle_timer    = 0.0
	data.respawn_timer = 0.0
	if data.root != null:
		data.root.global_position = fresh
		data.root.visible = true
	if data.mist_particles != null:
		data.mist_particles.emitting = true


func _relocate_orb(data: OrbData) -> void:
	var fresh : Vector3 = _pick_fresh_spawn_point()
	if fresh == Vector3.ZERO:
		return
	data.spawn_pos  = fresh
	data.idle_timer = 0.0
	if data.root != null:
		data.root.global_position = fresh


func _pick_fresh_spawn_point() -> Vector3:
	var fresh_list : Array = []
	for pt in _spawn_points:
		if not _exhausted_spawn_points.has(str(pt)):
			fresh_list.append(pt)
	if fresh_list.is_empty():
		# Every point has been used once (long/Legendary runs): start a new cycle instead
		# of permanently ending orb respawns. Points currently holding a live orb stay used.
		_exhausted_spawn_points.clear()
		for o in _orbs:
			if o.is_active:
				_exhausted_spawn_points[str(o.spawn_pos)] = true
		for pt in _spawn_points:
			if not _exhausted_spawn_points.has(str(pt)):
				fresh_list.append(pt)
		if fresh_list.is_empty():
			return Vector3.ZERO
	return fresh_list[randi() % fresh_list.size()]
