# ============================================================
#  FILE: destructible_prop.gd
#  PATH: res://scripts/destructible_prop.gd
#  USED BY: prop_spawner.gd
#  DESCRIPTION: Kickable dungeon prop (RigidBody3D). Not breakable.
#               Kick it and it tumbles with physics and bounces off
#               walls. On kick there is a chance the prop transforms
#               into a health potion at that instant — the potion
#               is the physics body that then flies off, not the prop.
#
#  PUBLIC API:
#    apply_kick(direction: Vector3, force: float)
#      Called by brute_player._on_kick_hit and
#      brute_player._check_slide_knockback. Rolls potion drop and
#      applies the impulse to whichever body is the outcome.
# ============================================================

extends RigidBody3D

const POTION_FBX : String = "res://addons/props/SM_ManaPotion.fbx"
const _PotionScript = preload("res://scripts/kickable_potion.gd")

# Potion drop probability per kick. 8% feels rewarding without flooding rooms.
const POTION_DROP_CHANCE : float = 0.08
# Curse drop probability per kick (rolled after the potion check fails).
# Same 8% so props are equally likely to help or hurt you.
const CURSE_DROP_CHANCE  : float = 0.08

# Set these on the instance BEFORE add_child() so _ready() can use them.
var _model_path : String              = ""
var _shared_mat : StandardMaterial3D  = null
# Set by prop_spawner._maybe_spawn_toppers so that model types which are only
# walk-through decor when on the floor (candle / single book / coin pile) stay
# solid when they're placed on top of a carrier.
var _is_topper : bool = false

# Model keywords that, when on the FLOOR (i.e. not a topper), are walk-through
# ambient decor — no collision, not in the kickable group, no contact damage.
# These are the same names the spawner's TOPPER_MODELS list uses minus Bottle
# (Bottle still tumbles if kicked).
const _FLOOR_DECOR_KEYWORDS : Array[String] = ["Candle", "BrownBook", "SmallPileOfCoins"]

# Speed threshold below which contact does no damage.
const CONTACT_DAMAGE_MIN_SPEED : float = 2.0
# Per-target cooldown in seconds so a prop grinding against one enemy
# doesn't spam damage every physics tick.
const CONTACT_COOLDOWN : float = 0.5
# 30% of contact hits on enemies also trigger a knockback (the "stun chance").
const CONTACT_STUN_CHANCE : float = 0.30
# Extra impulse applied to the prop when a moving enemy walks into a moving prop.
# This is the "re-kick" — the contact redirects the prop along the enemy's motion.
const ENEMY_REKICK_IMPULSE : float = 3.0

# Velocity caps (m/s). 30 Hz physics × these speeds keeps per-tick motion below
# half the prop's 0.60 m collision box width so it cannot tunnel through a wall.
const MAX_SPEED_NORMAL : float = 13.0
const MAX_SPEED_ANVIL  : float =  2.6   # 1/5 of normal — solid steel hardly budges.
# Damage dealt to the player when they kick a solid-steel anvil (ouch, your foot).
const ANVIL_KICK_SELF_DAMAGE : float = 8.0

# Anvil flag — set in _ready() from the FBX path. Changes mass, damping, bounce,
# max speed, and contact-damage multiplier.
var _is_anvil : bool = false

# Only crates, boxes (containers), anvils, and barrels drop potions / curses on
# kick. Everything else (books, shelves, stools, tables) is inert loot-wise.
# Matched by substring against _model_path in _ready().
const _DROP_MODEL_KEYWORDS : Array[String] = ["Anvil", "Crate", "Container", "Barrle"]
# ...except anything whose name also contains one of these — broken/pieces
# variants are ambient debris, not loot-bearing.
const _DROP_MODEL_EXCLUDES : Array[String] = ["Pieces"]
var _can_drop : bool = false

# Carriers accept small topper props on top (book, bottle, candle, coin pile).
# When the carrier is kicked, the toppers overhead get an upward shrapnel kick.
const _TOPPER_CARRIER_KEYWORDS : Array[String] = ["Crate", "Table", "Barrle"]
# Same broken-pieces exclusion — kicked barrel debris isn't a shelf.
const _TOPPER_CARRIER_EXCLUDES : Array[String] = ["Pieces"]

# Tracks last-hit timestamp per target so we can rate-limit damage.
var _contact_last_hit : Dictionary = {}

# Sleep-like freeze-on-rest optimization. A frozen RigidBody3D acts as a static
# collider — other bodies still bump off it, but it contributes nothing to
# Jolt's solver / contact constraint buffers. With ~300 props per dungeon,
# leaving them all fully dynamic blows through Jolt's 20 480 contact-constraint
# limit and drops the game to <1 FPS. We unfreeze only on kick and re-freeze
# after the prop settles.
const REST_SPEED_THRESHOLD : float = 0.4    # m/s — below this counts as "still"
const REST_TIME_TO_FREEZE  : float = 0.8    # s stationary before we re-freeze
# T2.7 — hard ceiling. If a prop slowly tumbles or wedges without ever meeting
# the strict rest criteria, this force-freeze fires so CPU doesn't bleed forever.
const REST_MAX_TIME        : float = 5.0
var _rest_timer : float = 0.0
var _active_timer : float = 0.0   # seconds spent un-frozen; paired with REST_MAX_TIME

# T2.8 — freeze-race guard. Each unfreeze (spawn or kick) bumps this counter.
# `_freeze_self` captures its gen at call_deferred time and bails if stale —
# prevents a late deferred freeze from locking a prop a kick already started.
var _freeze_gen : int = 0


func _ready() -> void:
	_is_anvil = _model_path.findn("SM_Anvil") >= 0
	for kw in _DROP_MODEL_KEYWORDS:
		if _model_path.findn(kw) >= 0:
			_can_drop = true
			break
	# Explicit exclusions override the include list.
	for kw in _DROP_MODEL_EXCLUDES:
		if _model_path.findn(kw) >= 0:
			_can_drop = false
			break

	# ── Physics body ─────────────────────────────────────────────────────────
	# Anvils are solid steel: 5× mass (so same kick impulse → 1/5 the velocity),
	# heavier damping so they stop quickly, almost no bounce, high friction.
	if _is_anvil:
		mass          = 25.0
		linear_damp   = 1.6
		angular_damp  = 2.4
	else:
		mass          = 5.0
		linear_damp   = 0.8
		angular_damp  = 1.5
	gravity_scale      = 1.0
	can_sleep          = true
	# Let gravity settle the body on spawn — sleeping=true + contact_monitor=true
	# caused wake/sleep thrashing against the trimesh floor, which showed up as
	# props slowly sinking and rising again.
	sleeping           = false
	# No Jolt CCD — the per-tick velocity clamp already prevents tunneling and
	# continuous_cd on hundreds of props was causing massive load/run-time lag.
	continuous_cd      = false
	# Contact monitoring so we can damage enemies/player when the prop is moving.
	# One contact is enough to trigger the damage handler.
	contact_monitor        = true
	max_contacts_reported  = 1

	collision_layer    = 1
	collision_mask     = 1      # Collide with dungeon walls/floor/columns and other props.

	# Anvil is solid steel (tiny 0.05 bounce). Normal props get 0.15 — enough
	# ricochet to read as impact, low enough that trimesh-floor oscillation
	# doesn't build up.
	var pm := PhysicsMaterial.new()
	if _is_anvil:
		pm.friction = 0.9
		pm.bounce   = 0.05
	else:
		pm.friction = 0.6
		pm.bounce   = 0.15
	pm.rough = true
	physics_material_override = pm

	# ── Size multiplier ──────────────────────────────────────────────────────
	# Base visual scale is 0.85. All props go +10% on top of that; big book
	# props (piles and shelves) get +25% for readability. A single book
	# (SM_BrownBook) stays at +10% — a lone book at +25% looks comically huge.
	# The SAME multiplier is applied to the collision box below so the physics
	# shape stays in lockstep with the visual mesh.
	var is_big_book : bool = _model_path.findn("BookPile") >= 0 \
							  or _model_path.findn("BookShelf") >= 0
	var mult : float = 1.25 if is_big_book else 1.10

	# ── FBX mesh ─────────────────────────────────────────────────────────────
	if _model_path != "" and ResourceLoader.exists(_model_path):
		var fbx_scene := load(_model_path) as PackedScene
		if fbx_scene != null:
			var mesh_child := fbx_scene.instantiate()
			var s : float = 0.85 * mult
			mesh_child.scale = Vector3(s, s, s)
			add_child(mesh_child)
			if _shared_mat != null:
				_apply_mat_recursive(mesh_child, _shared_mat)

	# ── Collision box ─────────────────────────────────────────────────────────
	# Stock 0.60 × 1.5 × 0.60 centred 0.75 m above the floor origin, scaled by
	# `mult` so it matches the visual mesh exactly. The y offset scales too so
	# the box's bottom stays at y=0 (floor contact) instead of dipping below.
	var col  := CollisionShape3D.new()
	var box  := BoxShape3D.new()
	box.size  = Vector3(0.60 * mult, 1.5 * mult, 0.60 * mult)
	col.shape = box
	col.position = Vector3(0.0, 0.75 * mult, 0.0)
	add_child(col)

	# Broken-pieces variants are purely decorative — no collision, no kick,
	# no contact damage. The player walks right through them.
	var is_pieces : bool = _model_path.findn("Pieces") >= 0

	# Small floor-decor items (candles, single books, coin piles) are also
	# pass-through when spawned on the floor. When placed as TOPPERS on a
	# carrier prop they remain solid so they can scatter via shrapnel on kick.
	var is_floor_decor : bool = false
	if not _is_topper:
		for kw in _FLOOR_DECOR_KEYWORDS:
			if _model_path.findn(kw) >= 0:
				is_floor_decor = true
				break

	if is_pieces or is_floor_decor:
		collision_layer = 0
		collision_mask  = 0
		contact_monitor = false
	else:
		add_to_group("kickable_prop")
		# Damage enemies/player on high-speed contact; receive extra impulse
		# from enemies that walk into us while we're already moving.
		body_entered.connect(_on_contact_body)

	# Freeze at spawn — acts as a static collider until something kicks it.
	# Drastically reduces Jolt's per-tick contact work for inert props.
	# DEFERRED so the spawner has a chance to set global_position AFTER add_child()
	# returns. Freezing before the teleport leaves Jolt with the body at (0,0,0)
	# in its broadphase — visually invisible and stacked on top of each other.
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	call_deferred("_freeze_self", _freeze_gen)


# T2.5 — `contact_monitor = false` while frozen, true while un-frozen. Frozen
# bodies still collide with other bodies, they just don't report contacts back
# to the solver. At 300 props this saves substantial per-tick Jolt work.
# T2.8 — `gen` arg captured at call_deferred time. If apply_kick ran in between
# and bumped _freeze_gen, this call is stale → bail.
func _freeze_self(gen: int = -1) -> void:
	if gen != -1 and gen != _freeze_gen:
		return
	freeze = true
	contact_monitor = false
	set_physics_process(false)


# Runs only while the prop is un-frozen (post-kick). Clamps velocity to prevent
# wall tunneling, and re-freezes once the prop has come to rest so it stops
# consuming physics ticks.
func _physics_process(delta: float) -> void:
	var max_speed : float = MAX_SPEED_ANVIL if _is_anvil else MAX_SPEED_NORMAL
	var v : Vector3 = linear_velocity
	if v.length() > max_speed:
		linear_velocity = v.normalized() * max_speed
		v = linear_velocity

	# Freeze only when the prop is genuinely settled:
	#   * low linear and angular velocity (not tumbling)
	#   * not currently falling into a surface (|v.y| small → last bounce ended)
	#   * orientation roughly upright — basis.y within ~70° of world UP so we
	#     don't lock props in an upside-down or lying-flat pose
	var up_align : float = global_transform.basis.y.dot(Vector3.UP)
	if v.length() < REST_SPEED_THRESHOLD \
			and angular_velocity.length() < 0.5 \
			and absf(v.y) < 0.5 \
			and up_align > 0.3:
		_rest_timer += delta
		if _rest_timer >= REST_TIME_TO_FREEZE:
			_commit_freeze()
			return
	else:
		_rest_timer = 0.0

	# T2.7 — absolute ceiling on time spent un-frozen. Catches edge cases
	# where a prop ends up wedged/tumbling but never satisfies the strict
	# rest gate. After REST_MAX_TIME we force-freeze regardless of pose.
	_active_timer += delta
	if _active_timer >= REST_MAX_TIME:
		_commit_freeze()


func _commit_freeze() -> void:
	freeze = true
	contact_monitor = false
	set_physics_process(false)
	_rest_timer = 0.0
	_active_timer = 0.0


# ══════════════════════════════════════════════════════════════
#  PUBLIC API
# ══════════════════════════════════════════════════════════════

# Called by brute_player._on_kick_hit and _check_slide_knockback.
# direction is a unit Vector3; force is the impulse magnitude to apply.
func apply_kick(direction: Vector3, force: float) -> void:
	# A prop that already turned into a potion/curse this frame is gone; a second kick in the
	# same physics tick (slide + shove) must not roll or spawn again.
	if is_queued_for_deletion():
		return
	# Kicking a solid-steel anvil hurts your foot. Damage the player regardless
	# of whether the potion roll replaces the anvil below.
	if _is_anvil:
		var player : Node = get_tree().get_first_node_in_group("player")
		if player != null and player.has_method("take_damage"):
			player.take_damage(ANVIL_KICK_SELF_DAMAGE, self)

	# Any small toppers sitting on top of this prop scatter upward as shrapnel.
	_shrapnel_kick_toppers(force)

	# Drop rolls only apply to the loot-bearing prop types (crates, boxes,
	# anvils, barrels). Books, shelves, stools, tables never drop anything.
	if _can_drop:
		var roll : float = randf()
		if roll < POTION_DROP_CHANCE:
			_spawn_potion_and_kick(direction, force)
			queue_free()
			return
		# Curse roll sits in the next band after the potion band.
		# GlobeManager.spawn_at handles the purple-globe chase + debuff + on-screen alert.
		if roll < POTION_DROP_CHANCE + CURSE_DROP_CHANCE:
			if has_node("/root/GlobeManager"):
				var parent_nd : Node = get_parent()
				if parent_nd != null:
					GlobeManager.spawn_at(global_position + Vector3(0.0, 0.5, 0.0), parent_nd)
			queue_free()
			return

	# Prop itself takes the kick — unfreeze so physics can move it, resume
	# the clamp/rest ticker, then apply the impulse.
	# T2.5: re-enable contact monitoring for damage-on-impact.
	# T2.8: bump the freeze-gen so any in-flight deferred _freeze_self bails.
	_freeze_gen += 1
	freeze = false
	contact_monitor = true
	set_physics_process(true)
	_rest_timer = 0.0
	_active_timer = 0.0
	sleeping = false
	apply_central_impulse(direction * force)
	# Small random torque so it tumbles believably.
	var torque := Vector3(
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0)
	) * force * 0.25
	apply_torque_impulse(torque)


# ══════════════════════════════════════════════════════════════
#  INTERNAL
# ══════════════════════════════════════════════════════════════

func _spawn_potion_and_kick(direction: Vector3, force: float) -> void:
	var parent_nd : Node = get_parent()
	if parent_nd == null:
		return

	# Rigid potion body — lighter than the prop so it launches farther.
	# kickable_potion.gd adds the same per-tick velocity clamp the prop uses,
	# so the potion can't tunnel through walls either.
	var potion := RigidBody3D.new()
	potion.set_script(_PotionScript)
	potion.name          = "KickablePotion"
	potion.mass          = 2.0
	potion.gravity_scale = 1.0
	potion.linear_damp   = 0.8
	potion.angular_damp  = 1.5
	potion.can_sleep     = true
	# CCD off — the clamp in kickable_potion.gd enforces speed ≤ safe max.
	potion.continuous_cd = false
	potion.collision_layer = 1
	potion.collision_mask  = 1

	var pm := PhysicsMaterial.new()
	pm.friction = 0.5
	# Potions get a tiny bounce (0.1) — still slidy, less risk of floor oscillation.
	pm.bounce   = 0.1
	pm.rough    = true
	potion.physics_material_override = pm

	# Physics collider — sphere so it rolls believably.
	var col_shape := CollisionShape3D.new()
	var sphere    := SphereShape3D.new()
	sphere.radius  = 0.25
	col_shape.shape = sphere
	potion.add_child(col_shape)

	# Bottle mesh.
	if ResourceLoader.exists(POTION_FBX):
		var fbx_scene := load(POTION_FBX) as PackedScene
		if fbx_scene != null:
			var mesh_node := fbx_scene.instantiate()
			mesh_node.scale = Vector3(0.7, 0.7, 0.7)
			potion.add_child(mesh_node)

	# Green glow matching the natural health-orb palette (ORB_COLOR in
	# health_orb_manager.gd:25). kickable_potion.gd pulses its light_energy
	# 0.8→2.2 once the potion is hovering.
	var glow := OmniLight3D.new()
	glow.name            = "GlowLight"
	glow.light_color     = Color(0.15, 1.0, 0.35)
	glow.omni_range      = 3.0
	glow.light_energy    = 1.5
	glow.shadow_enabled  = false
	potion.add_child(glow)

	# Pickup trigger — pickup_radius matches the natural orb (1.1 m).
	var pickup_area := Area3D.new()
	pickup_area.name            = "PickupArea"
	pickup_area.collision_layer = 0
	pickup_area.collision_mask  = 0xFFFFFFFF   # Detect any body; filter by receive_heal below.

	var pickup_shape := CollisionShape3D.new()
	var pickup_sphere := SphereShape3D.new()
	pickup_sphere.radius   = 1.1
	pickup_shape.shape = pickup_sphere
	pickup_area.add_child(pickup_shape)
	potion.add_child(pickup_area)

	parent_nd.add_child(potion)
	potion.global_position = global_position + Vector3(0.0, 0.5, 0.0)

	# Heal whichever body enters the Area3D. Ignore the potion's own rigid body
	# (same layer) and anything without receive_heal.
	pickup_area.body_entered.connect(func(body: Node3D) -> void:
		if not is_instance_valid(potion):
			return
		if body == potion:
			return
		var target : Node = body
		if not target.has_method("receive_heal") and target.get_parent() != null:
			target = target.get_parent()
		if target.has_method("receive_heal"):
			target.receive_heal(25.0)
			potion.queue_free()
	)

	# Auto-despawn so a potion kicked into an unreachable spot doesn't litter.
	get_tree().create_timer(30.0).timeout.connect(func() -> void:
		if is_instance_valid(potion):
			potion.queue_free()
	)

	# Apply the kick impulse so the potion tumbles out of the prop's position.
	# Clamp the resulting velocity before the first physics tick so the potion
	# can never punch through a nearby wall on frame 0 (the per-tick clamp in
	# kickable_potion.gd is fine for subsequent ticks).
	const _POTION_MAX_SPEED : float = 8.0
	potion.apply_central_impulse(direction * force)
	if potion.linear_velocity.length() > _POTION_MAX_SPEED:
		potion.linear_velocity = potion.linear_velocity.normalized() * _POTION_MAX_SPEED
	var torque := Vector3(
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0)
	) * force * 0.25
	potion.apply_torque_impulse(torque)


# Finds any kickable_prop nodes sitting directly above this prop within a
# small horizontal radius and kicks them upward + outward. Only "carrier"
# props (crates, tables, intact barrels) trigger this — a stool or candle
# wouldn't have anything resting on it.
func _shrapnel_kick_toppers(parent_force: float) -> void:
	var is_carrier : bool = false
	for kw in _TOPPER_CARRIER_KEYWORDS:
		if _model_path.findn(kw) >= 0:
			is_carrier = true
			break
	if not is_carrier:
		return
	for kw in _TOPPER_CARRIER_EXCLUDES:
		if _model_path.findn(kw) >= 0:
			return

	const UP_MIN : float = 0.8     # toppers sit ~1.5 m above parent origin
	const UP_MAX : float = 2.5
	const XZ_MAX : float = 1.0
	for other in get_tree().get_nodes_in_group("kickable_prop"):
		if other == self or not is_instance_valid(other):
			continue
		if not (other is Node3D):
			continue
		var d : Vector3 = (other as Node3D).global_position - global_position
		if d.y < UP_MIN or d.y > UP_MAX:
			continue
		if Vector2(d.x, d.z).length() > XZ_MAX:
			continue
		if not other.has_method("apply_kick"):
			continue
		var shrapnel_dir : Vector3 = Vector3(
			randf_range(-0.6, 0.6),
			randf_range(0.8, 1.5),
			randf_range(-0.6, 0.6)
		).normalized()
		other.apply_kick(shrapnel_dir, parent_force * 0.5)


func _apply_mat_recursive(node: Node, mat: StandardMaterial3D) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).material_override = mat
	for child in node.get_children():
		_apply_mat_recursive(child, mat)


# Fires when a body enters the prop's collision shape (enabled by contact_monitor).
# Handles moving-prop damage to enemies/player and enemy contact re-kicking the prop.
func _on_contact_body(body: Node) -> void:
	if body == self:
		return
	var speed : float = linear_velocity.length()
	if speed < CONTACT_DAMAGE_MIN_SPEED:
		return

	var target : Node = body
	if not target.has_method("take_damage") and target.get_parent() != null:
		target = target.get_parent()
	if target == self:
		return

	# Per-target cooldown — key by instance ID.
	var tid : int = target.get_instance_id()
	var now : float = Time.get_ticks_msec() / 1000.0
	var last : float = _contact_last_hit.get(tid, -10.0)
	if now - last < CONTACT_COOLDOWN:
		return
	_contact_last_hit[tid] = now

	if target.has_method("take_damage"):
		# Anvils hit MUCH harder than wooden crates at the same speed.
		var dmg : float = (
			clampf(speed * 4.0, 10.0, 30.0) if _is_anvil
			else clampf(speed * 1.5, 4.0, 15.0)
		)
		target.take_damage(dmg, self)
		# Stun chance — only on enemies that support knockback.
		if target.is_in_group("enemies") \
				and target.has_method("take_knockback") \
				and randf() < CONTACT_STUN_CHANCE:
			var dir : Vector3 = linear_velocity.normalized()
			target.take_knockback(dir, 6.0, 0.8)

	# Moving enemy contact re-kicks the prop along the enemy's own motion.
	if body is CharacterBody3D and target.is_in_group("enemies"):
		var enemy_vel : Vector3 = body.velocity
		if enemy_vel.length() > 0.1:
			apply_central_impulse(enemy_vel.normalized() * ENEMY_REKICK_IMPULSE)
