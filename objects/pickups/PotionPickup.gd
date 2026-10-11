# ============================================================
#  FILE:         PotionPickup.gd
#  PATH:         res://objects/pickups/PotionPickup.gd
#
#  DEPENDENCIES:
#    - PlayerWallet (autoload) — receives the potion on collection
#
#  DESCRIPTION:
#    A floating green pyramid that the player walks over to collect.
#    Built entirely in code — no .tscn needed. Instantiate with
#    PotionPickup.new(), add to scene tree, set global_position.
#    Uses Area3D so it never blocks the player or enemies.
#    On player contact: adds 1 potion to PlayerWallet, frees itself.
#
#  SPAWNED BY:
#    brute_ai.gd _on_die() — 1:10 chance per enemy kill.
#
#  WHAT YOU CAN ADJUST:
#    POTION_VALUE       — how many potions this pickup is worth
#    FLOAT_HEIGHT       — resting height above spawn point
#    BOB_AMPLITUDE      — how much it bobs up and down
#    BOB_FREQUENCY      — how fast the bobbing cycle is
#    SPIN_SPEED         — how fast the pyramid rotates (radians/sec)
#    PICKUP_RADIUS      — collision detection radius
#    PYRAMID_COLOR      — the pyramid's glow color
#    PYRAMID_EMISSION   — emission energy intensity
#    LIFETIME           — seconds before the pickup despawns (0 = never)
# ============================================================

extends Area3D

const Juice := preload("res://scripts/juice.gd")


# ── Tuning constants ───────────────────────────────────────

# How many potions this pickup adds to the wallet.
const POTION_VALUE     : int   = 1

# Resting height above the spawn floor position.
const FLOAT_HEIGHT     : float = 0.6

# How much the pyramid bobs up and down in units.
const BOB_AMPLITUDE    : float = 0.15

# How many full bob cycles per second.
const BOB_FREQUENCY    : float = 1.2

# Rotation speed in radians per second.
const SPIN_SPEED       : float = 2.5

# Collision detection radius — how close the player must be.
const PICKUP_RADIUS    : float = 0.8

# The pyramid's green glow color.
const PYRAMID_COLOR    : Color = Color(0.2, 0.9, 0.3)

# Emission energy multiplier for the glow effect.
const PYRAMID_EMISSION : float = 1.8

# Seconds before the pickup despawns. 0 means it stays forever.
const LIFETIME         : float = 0.0


# ── Runtime state ──────────────────────────────────────────

# The base XZ world position (for lateral sway).
var _base_pos     : Vector3    = Vector3.ZERO

# The base Y position this pickup floats around.
var _base_y       : float      = 0.0

# Shared timer for bob and spin animation.
var _anim_timer   : float      = 0.0

# The mesh node holding the bottle visual.
var _mesh_inst    : MeshInstance3D = null

# Lifetime countdown. Only used if LIFETIME > 0.
var _life_timer   : float      = 0.0

# True once collected — prevents double-collection.
var _collected    : bool       = false


# ── Setup ──────────────────────────────────────────────────

func _ready() -> void:
	# Record hover baselines — XZ for sway, Y for bob.
	_base_pos = global_position
	_base_y   = global_position.y + FLOAT_HEIGHT

	# This Area3D should not block anything physically.
	collision_layer = 0
	collision_mask  = 0

	_build_visual()
	_build_detection()

	# Connect the body_entered signal to detect the player.
	body_entered.connect(_on_body_entered)

	# Start lifetime countdown if enabled.
	if LIFETIME > 0.0:
		_life_timer = LIFETIME

	# Loot pop: it springs out of the kill (small to full size with an overshoot) with a glint, instead of appearing whole.
	Juice.burst("gold", global_position + Vector3(0.0, 0.5, 0.0), Vector3.UP, 0.5)
	scale = Vector3.ONE * 0.2
	create_tween().tween_property(self, "scale", Vector3.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _build_visual() -> void:
	const BOTTLE_FBX : String = "res://addons/props/SM_Bottle.fbx"

	if ResourceLoader.exists(BOTTLE_FBX):
		var fbx_scene := load(BOTTLE_FBX) as PackedScene
		if fbx_scene != null:
			var prop := fbx_scene.instantiate()
			prop.name  = "PotionMesh"
			# Scale the bottle to a reasonable pickup size.
			prop.scale = Vector3(0.6, 0.6, 0.6)
			add_child(prop)
			_mesh_inst = _find_first_mesh_in(prop)

	# Fallback: original pyramid if FBX fails to load.
	if _mesh_inst == null:
		_mesh_inst = MeshInstance3D.new()
		var pyramid := CylinderMesh.new()
		pyramid.top_radius      = 0.0
		pyramid.bottom_radius   = 0.2
		pyramid.height          = 0.35
		pyramid.radial_segments = 4
		pyramid.rings           = 0
		_mesh_inst.mesh         = pyramid
		var mat := StandardMaterial3D.new()
		mat.albedo_color               = PYRAMID_COLOR
		mat.emission_enabled           = true
		mat.emission                   = PYRAMID_COLOR
		mat.emission_energy_multiplier = PYRAMID_EMISSION
		_mesh_inst.material_override   = mat
		add_child(_mesh_inst)

	# Subtle glow light — works regardless of which visual path was taken.
	var glow              := OmniLight3D.new()
	glow.light_color       = PYRAMID_COLOR
	glow.omni_range        = 2.0
	glow.light_energy      = 0.8
	glow.shadow_enabled    = false
	add_child(glow)


# Depth-first search for the first MeshInstance3D in an instanced scene.
func _find_first_mesh_in(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for child in node.get_children():
		var found := _find_first_mesh_in(child)
		if found != null:
			return found
	return null


func _build_detection() -> void:
	# Add a CollisionShape3D with a sphere for overlap detection.
	var shape_node := CollisionShape3D.new()
	var sphere     := SphereShape3D.new()
	sphere.radius  = PICKUP_RADIUS
	shape_node.shape = sphere
	add_child(shape_node)

	# Enable monitoring so body_entered fires when the player overlaps.
	set_deferred("monitoring", true)
	set_deferred("monitorable", false)

	# Set the collision mask to detect the player's collision layer.
	# Player is typically on layer 1. Adjust if your player uses a different layer.
	collision_mask = 1


# ── Process — bob and spin ─────────────────────────────────

func _process(delta: float) -> void:
	if _collected:
		return

	_anim_timer += delta

	# Bob, lateral sway, and spin — mirrors health orb behaviour.
	var sway_x : float = sin(_anim_timer * 0.42) * 0.08
	var sway_z : float = cos(_anim_timer * 0.37) * 0.08
	global_position = Vector3(
		_base_pos.x + sway_x,
		_base_y + sin(_anim_timer * BOB_FREQUENCY * TAU) * BOB_AMPLITUDE,
		_base_pos.z + sway_z
	)

	# Spin the mesh around the Y axis.
	if _mesh_inst != null:
		_mesh_inst.rotation.y += SPIN_SPEED * delta

	# Lifetime despawn if enabled.
	if LIFETIME > 0.0:
		_life_timer -= delta
		if _life_timer <= 0.0:
			queue_free()


# ── Collection ─────────────────────────────────────────────

func _on_body_entered(body: Node3D) -> void:
	if _collected:
		return

	# Only collect if the player walks into it.
	if not body.is_in_group("player"):
		return

	_collected = true
	PlayerWallet.add_potions(POTION_VALUE)
	# Collected: a glitter burst, a floating "+1", a coin sound (it was silent).
	Juice.burst("gold", global_position, Vector3.UP, 0.8)
	Juice.number(global_position + Vector3(0.0, 0.5, 0.0), "+%d" % POTION_VALUE, Color(0.55, 1.0, 0.6), 1.0)
	if has_node("/root/AudioManager"):
		AudioManager.play_sfx("coin", -3.0, 0.96, 1.08, 1)
	Juice.haptic(14)
	queue_free()
