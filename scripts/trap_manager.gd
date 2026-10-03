# ==============================================================================
# FILE: trap_manager.gd
# PATH: res://scripts/trap_manager.gd
# DESCRIPTION: Booby trap system for Purgetory Dungeon.
#   - Scans placed modules for "template - floor" mesh tiles
#   - Selects trap_count tiles spread evenly across the dungeon
#   - Attaches an Area3D trigger to each chosen tile
#   - On player contact: fires a random effect and deactivates the trap
#   - trap_sense perk level 1–4 gives 25–100% per-trap chance to glow red
#
# ADJUSTABLE SETTINGS:
#   trap_count          — how many traps spawn per run (default 5)
#   trap_trigger_height — how tall the trigger box is above the tile (default 0.4)
#   acid_damage_per_sec — damage per second from the acid pool effect (default 1.0)
#   acid_duration       — seconds the acid lasts (default 15.0)
#   effect_day_duration — in-game days the "1 day" effects last (default 1)
#   homing_fireball_speed — speed of the mine fireballs (default 10.0)
#   homing_fireball_damage — damage each homing fireball deals (default 15.0)
#
# MOD NOTES:
#   Add new effect IDs to EFFECTS and handle them in _apply_effect().
#   Effects that need per-tick processing live in the player scripts
#   behind _status_* flags set here.
# ==============================================================================

extends Node3D

# ── Settings ──────────────────────────────────────────────────────────────────
@export var trap_count            : int   = 50    # Traps per run (was 5 — spread across 125 rooms means almost none)
@export var fireball_trap_count   : int   = 10    # Extra guaranteed fireball-mine traps added on top of trap_count
@export var trap_trigger_height   : float = 0.4   # Trigger box height above tile
@export var acid_damage_per_sec   : float = 1.0   # Acid pool DPS
@export var acid_duration         : float = 15.0  # Acid effect duration in seconds
@export var effect_day_duration   : int   = 1     # How many days "1-day" effects last
@export var homing_fireball_speed  : float = 10.0  # Mine fireball travel speed
@export var homing_fireball_damage : float = 15.0  # Mine fireball damage on hit
@export var schizophrenia_duration : float = 60.0  # Seconds the auditory hallucinations last

# ── Effect IDs ────────────────────────────────────────────────────────────────
const EFFECT_REVERSED_VIEW      := "reversed_view"
const EFFECT_HEAVY_GRAVITY       := "heavy_gravity"
const EFFECT_DRUNK              := "drunk"
const EFFECT_REVERSED_CONTROLS  := "reversed_controls"
const EFFECT_ACID_POOL          := "acid_pool"
const EFFECT_FIREBALL_MINE      := "fireball_mine"
const EFFECT_SCHIZOPHRENIA      := "schizophrenia"  # Auditory hallucinations via schizophrenia_audio.gd
const EFFECT_JUMPSCARE          := "jumpscare"       # Full-screen scary face + scream

const ALL_EFFECTS : Array[String] = [
	EFFECT_REVERSED_VIEW,
	EFFECT_HEAVY_GRAVITY,
	EFFECT_DRUNK,
	EFFECT_REVERSED_CONTROLS,
	EFFECT_ACID_POOL,
	EFFECT_FIREBALL_MINE,
	EFFECT_SCHIZOPHRENIA,
	EFFECT_JUMPSCARE,
]

# Trap sense material — red glow, probability-based per perk level
const TRAP_SENSE_COLOR := Color(1.0, 0.05, 0.05, 1.0)

# ── Runtime state ─────────────────────────────────────────────────────────────
var _dungeon_gen        : Node      = null
var _player             : Node3D    = null
var _trap_sense_level   : int       = 0    # 0 = no perk; each level adds 25% glow chance
var _trap_nodes         : Array     = []
var _homing_fireballs   : Array     = []
var _banner_hud         : CanvasLayer = null
# Jumpscare resources — assigned by boot_traps(), sourced from the main
# game scene's Inspector exports (see Purgatory_Dungeon_main_game_file.gd).
var _jumpscare_texture  : Texture2D    = null
var _jumpscare_sound    : AudioStream  = null
var _jumpscare_fired    : bool         = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Spawn the trap banner HUD and attach it to the scene root so it
	# renders over gameplay regardless of where TrapManager sits in the tree.
	var hud_script := load("res://scripts/trap_banner_hud.gd")
	if hud_script != null:
		_banner_hud = CanvasLayer.new()
		_banner_hud.set_script(hud_script)
		get_tree().root.add_child(_banner_hud)


# The banner HUD is parented to the scene root (so it renders over gameplay), which means it
# would otherwise outlive this manager: one leaked CanvasLayer per run.
func _exit_tree() -> void:
	if is_instance_valid(_banner_hud):
		_banner_hud.queue_free()


# ── Boot ──────────────────────────────────────────────────────────────────────

# Called from Purgatory_Dungeon_main_game_file.gd after dungeon generation.
func boot_traps(dungeon_gen: Node, player: Node3D,
		jumpscare_texture: Texture2D = null,
		jumpscare_sound: AudioStream = null) -> void:
	_dungeon_gen       = dungeon_gen
	_player            = player
	_jumpscare_texture = jumpscare_texture
	_jumpscare_sound   = jumpscare_sound

	if GlobalRunData.debug_no_traps:
		return

	# Read trap_sense perk level — each level gives +25% chance a trap glows red.
	var perks : Dictionary = SaveManager.current_profile.get("perks", {})
	_trap_sense_level = int(perks.get("trap_sense", 0))

	if _dungeon_gen == null or not _dungeon_gen.has_method("get_trap_candidates"):
		push_warning("TrapManager: dungeon_gen not valid — no traps spawned.")
		return

	var candidates : Array[Node3D] = _dungeon_gen.get_trap_candidates(trap_count)
	for tile in candidates:
		if is_instance_valid(tile):
			_arm_trap(tile)

	# ── Forced fireball-mine traps ─────────────────────────────────────────────
	# A separate request for fireball_trap_count additional tiles; these always
	# trigger EFFECT_FIREBALL_MINE regardless of the normal random pick.
	if fireball_trap_count > 0:
		var fb_candidates : Array[Node3D] = _dungeon_gen.get_trap_candidates(fireball_trap_count)
		for tile in fb_candidates:
			if is_instance_valid(tile):
				_arm_trap(tile, EFFECT_FIREBALL_MINE)


# ── Trap arming ───────────────────────────────────────────────────────────────

func _arm_trap(tile: MeshInstance3D, forced_effect: String = "") -> void:
	# Glow red with a probability that scales with perk level.
	# Level 1 = 25%, level 2 = 50%, level 3 = 75%, level 4+ = 100%.
	if _trap_sense_level > 0:
		var glow_chance : float = minf(float(_trap_sense_level) * 0.25, 1.0)
		if randf() < glow_chance:
			_tint_tile(tile, TRAP_SENSE_COLOR)

	# Build an Area3D trigger just above the tile surface.
	var area      := Area3D.new()
	area.name      = "TrapTrigger"
	area.collision_layer = 0
	# BUG FIX: Was collision_mask = 2 (layer 2) but the player CharacterBody3D
	# is on layer 1 by default. This is why traps never activated across 27 runs.
	# Using 0xFFFFFFFF hits all layers — the group check in _on_trap_body_entered
	# already filters for the player correctly so this is safe.
	area.collision_mask  = 0xFFFFFFFF

	var shape_node := CollisionShape3D.new()
	var box        := BoxShape3D.new()

	# Match the tile's AABB footprint so the trigger covers the whole tile.
	var mi_aabb := tile.get_aabb()
	var xform   := tile.global_transform
	# World-space size from the local AABB scaled by the tile's transform.
	var world_size := Vector3(
		mi_aabb.size.x * xform.basis.get_scale().x,
		trap_trigger_height,
		mi_aabb.size.z * xform.basis.get_scale().z
	)
	box.size         = world_size.abs()
	shape_node.shape = box
	area.add_child(shape_node)

	# Store tile reference on the area for cleanup/tinting.
	area.set_meta("tile_node", tile)
	area.set_meta("armed", true)
	area.set_meta("forced_effect", forced_effect)   # "" = random, non-empty = always that effect

	# Position trigger above the tile centre.
	get_parent().add_child(area)
	area.global_position = tile.global_position + Vector3(0.0, trap_trigger_height * 0.5, 0.0)

	area.body_entered.connect(_on_trap_body_entered.bind(area))
	_trap_nodes.append(area)


func _tint_tile(tile: MeshInstance3D, color: Color) -> void:
	# Create a unique material override so only this tile is tinted.
	var mat := StandardMaterial3D.new()
	mat.albedo_color    = color
	mat.emission_enabled = true
	mat.emission        = color
	mat.emission_energy_multiplier = 1.5
	tile.material_override = mat


# ── Trigger ───────────────────────────────────────────────────────────────────

func _on_trap_body_entered(body: Node3D, area: Area3D) -> void:
	if not is_instance_valid(area):
		return
	if not area.get_meta("armed", false):
		return
	if not body.is_in_group("player"):
		return

	# Disarm immediately — one trigger per trap.
	area.set_meta("armed", false)
	area.set_deferred("monitoring", false)

	# Remove the orange tint now that it has fired.
	var tile = area.get_meta("tile_node", null)
	if tile != null and is_instance_valid(tile) and tile.material_override != null:
		tile.material_override = null

	# Pick effect — use forced_effect if set, otherwise random.
	var forced : String = area.get_meta("forced_effect", "")
	var effect : String = forced if forced != "" else ALL_EFFECTS[randi() % ALL_EFFECTS.size()]
	_apply_effect(body, effect, area.global_position)

	# Clean up the Area3D after a short delay.
	get_tree().create_timer(0.5).timeout.connect(area.queue_free)


# ── Effect dispatch ───────────────────────────────────────────────────────────

func _apply_effect(player: Node3D, effect: String, trap_pos: Vector3) -> void:
	# All effects route through flags on the player. The player scripts read
	# these flags each physics tick and apply the appropriate behaviour.

	# ── Banner notification ────────────────────────────────────────────────────
	if _banner_hud != null and _banner_hud.has_method("show_trap"):
		match effect:
			"reversed_view", "heavy_gravity":
				_banner_hud.show_trap(effect, -1.0, effect_day_duration)
			"drunk", "reversed_controls":
				_banner_hud.show_trap(effect, 30.0)
			"acid_pool":
				_banner_hud.show_trap(effect, acid_duration)
			"schizophrenia":
				_banner_hud.show_trap(effect, schizophrenia_duration)
			_:   # fireball_mine, jumpscare — instant / no duration
				_banner_hud.show_trap(effect, 0.0)

	match effect:

		EFFECT_REVERSED_VIEW:
			# Flip the camera X by PI so the player sees upside-down.
			# Lasts effect_day_duration in-game days — reset on day_changed.
			if player.has_method("apply_status"):
				player.apply_status("reversed_view", effect_day_duration)

		EFFECT_HEAVY_GRAVITY:
			# Halves jump velocity for effect_day_duration days.
			if player.has_method("apply_status"):
				player.apply_status("heavy_gravity", effect_day_duration)

		EFFECT_DRUNK:
			# Wavy view oscillation. Clears after 30 seconds.
			if player.has_method("apply_status"):
				player.apply_status("drunk", 0)   # 0 = timer-based, 30s

		EFFECT_REVERSED_CONTROLS:
			# All movement and look inputs flipped. Clears after 30 seconds.
			if player.has_method("apply_status"):
				player.apply_status("reversed_controls", 0)

		EFFECT_ACID_POOL:
			# Ticking damage for acid_duration seconds. Handled by player.
			if player.has_method("apply_status"):
				player.apply_status("acid_pool", 0)

		EFFECT_FIREBALL_MINE:
			# Half health immediately, then homing fireballs from coursec nodes.
			if player.has_method("receive_heal"):
				var half : float = player.get("max_health") * -0.5
				player.take_damage(abs(half))
			_spawn_homing_fireballs(player, trap_pos)

		EFFECT_SCHIZOPHRENIA:
			# Attach the auditory hallucination script to the player for
			# schizophrenia_duration seconds, then detach it cleanly.
			# Routes through BuffManager._handle_schizophrenia() so the same
			# node management logic is reused — no duplicate code.
			if has_node("/root/BuffManager"):
				BuffManager._handle_schizophrenia(true)
				get_tree().create_timer(schizophrenia_duration).timeout.connect(
					func() -> void:
						if has_node("/root/BuffManager"):
							BuffManager._handle_schizophrenia(false)
				)

		EFFECT_JUMPSCARE:
			# Only fire once per run — subsequent traps do nothing.
			if _jumpscare_fired:
				return
			_jumpscare_fired = true
			# Load jumpscare.gd, pass the resources assigned in the main game
			# scene's Inspector, add to scene root so it covers the full screen.
			# setup() is called before add_child so resources are ready when
			# _ready() fires and builds the overlay.
			var scare_script := load("res://scripts/Jumpscare.gd")
			if scare_script != null:
				var scare : CanvasLayer = CanvasLayer.new()
				scare.set_script(scare_script)
				scare.call("setup", _jumpscare_texture, _jumpscare_sound)
				get_tree().root.add_child(scare)


# ── Homing fireballs ──────────────────────────────────────────────────────────

func _spawn_homing_fireballs(player: Node3D, trap_pos: Vector3) -> void:
	if _dungeon_gen == null or not _dungeon_gen.has_method("get_module_containing_point"):
		return
	if _dungeon_gen == null or not _dungeon_gen.has_method("get_coursec_positions_in_module"):
		return

	# Find the room the trap is in.
	var mod : Node3D = _dungeon_gen.get_module_containing_point(trap_pos)
	if mod == null:
		return

	var origins : Array[Vector3] = _dungeon_gen.get_coursec_positions_in_module(mod)
	if origins.is_empty():
		return

	for origin in origins:
		_launch_homing_fireball(origin, player)


func _launch_homing_fireball(origin: Vector3, player: Node3D) -> void:
	var fb             := Area3D.new()
	fb.name             = "HomingFireball"
	fb.collision_layer  = 0
	fb.collision_mask   = 0xFFFFFFFF
	fb.monitorable      = false
	fb.monitoring       = false

	var shape_node := CollisionShape3D.new()
	var sphere     := SphereShape3D.new()
	sphere.radius   = 0.3
	shape_node.shape = sphere
	fb.add_child(shape_node)

	# Visual — bright red glowing sphere
	var glow_inst   := MeshInstance3D.new()
	var glow_sphere := SphereMesh.new()
	glow_sphere.radius = 0.2
	glow_sphere.height = 0.4
	glow_inst.mesh     = glow_sphere
	var mat            := StandardMaterial3D.new()
	mat.albedo_color                = Color(1.0, 0.15, 0.0, 0.9)
	mat.emission_enabled            = true
	mat.emission                    = Color(1.0, 0.1, 0.0)
	mat.emission_energy_multiplier  = 4.0
	mat.transparency                = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode                = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow_inst.material_override     = mat
	fb.add_child(glow_inst)

	get_parent().add_child(fb)
	fb.global_position = origin + Vector3(0.0, 1.0, 0.0)

	var damage_val : float = homing_fireball_damage
	fb.body_entered.connect(_on_homing_hit.bind(fb, damage_val))

	_homing_fireballs.append(fb)

	# Coroutine that steers toward the player every frame.
	_fly_homing(fb, player)


func _fly_homing(fb: Area3D, player: Node3D) -> void:
	# Safety limit — fireballs self-destruct after 15 seconds so they
	# can't circle forever if the player dies.
	var lifetime : float = 15.0

	while is_instance_valid(fb) and is_instance_valid(player) and lifetime > 0.0:
		if not is_inside_tree():
			break
		var tree := get_tree()
		if tree == null:
			break
		# This manager is PROCESS_MODE_ALWAYS, so without this the fireball keeps flying
		# (and aging) behind the pause menu, then hits the moment the game resumes.
		if tree.paused:
			await tree.process_frame
			continue
		var dt := get_process_delta_time()
		lifetime -= dt

		if not fb.monitoring:
			fb.monitoring = true   # Enable after first step (escape origin overlap)

		# Aim for chest height each frame — true homing, cannot be dodged.
		var target_pos  := player.global_position + Vector3(0.0, 1.0, 0.0)
		var direction   := (target_pos - fb.global_position).normalized()
		fb.global_position += direction * homing_fireball_speed * dt

		await tree.process_frame

	if is_instance_valid(fb):
		fb.queue_free()


func _on_homing_hit(body: Node3D, fb: Area3D, damage_val: float) -> void:
	if not is_instance_valid(fb):
		return
	if fb.has_meta("hit"):
		return
	fb.set_meta("hit", true)

	var target := body
	if not target.has_method("take_damage") and target.get_parent() != null:
		target = target.get_parent()
	if target != null and target.has_method("take_damage"):
		target.take_damage(damage_val, null)

	if is_instance_valid(fb):
		fb.queue_free()


# ── Process — homing fireball cleanup ─────────────────────────────────────────

func _process(_delta: float) -> void:
	# Prune freed fireballs from the tracking array.
	for i in range(_homing_fireballs.size() - 1, -1, -1):
		if not is_instance_valid(_homing_fireballs[i]):
			_homing_fireballs.remove_at(i)
