# ============================================================
#  FILE: brute_player.gd
#  PATH: res://characters/brute/scripts/brute_player.gd
#  ATTACHED TO: res://characters/brute/scenes/brute_player.tscn
#  DEPENDENCIES: BruteCharacter, Loading Screen, GameClock, AudioManager
#  DESCRIPTION: Player controller for movement, camera, combat, HUD,
#  footsteps, and pause handling.
#  MOD NOTES:
#  - SURGICAL FIX: Added recovery cancel buffer (anim_len - 0.15) to _do_attack and _do_kick to eliminate animation lag.
#  - SURGICAL FIX: Commented out velocity locks in _do_attack, _do_kick, and _handle_movement for 1st person pivot.
#  - SURGICAL FIX: Commented out jump animation triggers in _handle_jump to prevent leg clipping in 1st person pivot.
#  - SURGICAL ADD: Camera head bob system based on horizontal speed, with tunable export variables.
#  - SURGICAL FIX: Modified _do_block to hold at half animation until released, then finish fast.
#  - SURGICAL FIX: Added block knockback physics and hit grunt sound to take_damage override.
#  - SURGICAL PIVOT: Implemented "Zelda Method" attack input. Normal swings fire instantly on press. Holding the button charges the Rapid Attack in the background.
#  - SURGICAL FIX: Block hold uses speed_scale=0.0 to freeze animation in place.
#    anim_player.pause() + play() restarts from frame 0 — wrong behaviour.
#    speed_scale=0.0 then speed_scale=2.5 freezes and resumes from the same frame.
# ============================================================

extends BruteCharacter

# ── Movement ───────────────────────────────────────────────────
@export var move_speed           : float = 8.0  # Base movement speed
@export var move_acceleration    : float = 40.0 # How fast player reaches max speed
@export var move_deceleration    : float = 28.0 # How fast player stops

# ── Slide (Evade) ───────────────────────────────────────────────
@export var slide_power          : float = 20.0 # Peak launch speed (m/s) — higher = shorter re-fire gap
@export var slide_distance_clear : float = 5.0  # Distance when no enemy contact (m)
@export var slide_distance_hit   : float = 2.5  # Distance after bumping an enemy (m)
@export var slide_knock_radius   : float = 1.5  # Knockback detection radius (m)

# ── Camera ─────────────────────────────────────────────────────
@export var mouse_sensitivity    : float = 0.0025 # Camera turn speed for mouse
@export var gamepad_turn_speed   : float = 3.0 # Camera turn speed for gamepad
@export var look_deadzone        : float = 0.08 # Deadzone for right stick
@export var move_deadzone        : float = 0.08 # Deadzone for left stick
@export var idle_return_delay    : float = 0.15 # Time before returning to idle state

# ── Animation speed ────────────────────────────────────────────
@export var idle_anim_speed      : float = 1.0 # Speed multiplier for idle anim
@export var move_anim_speed      : float = 1.0 # Speed multiplier for move anim
@export var attack_speed_scale   : float = 2.5 # Speed multiplier for weapon swings
@export var kick_speed_scale     : float = 3.0 # Speed multiplier for kicks

# ── Combat ─────────────────────────────────────────────────────
@export var weapon_hitbox  : Area3D # Reference to axe damage area
@export var kick_hitbox    : Area3D # Reference to boot damage area

@export var attack_damage  : float = 25.0 # Damage applied per weapon swing
@export var kick_damage    : float = 15.0 # Damage applied per kick
@export var kick_force      : float = 9.0 # Knockback force applied by kick
@export var kick_stun_time : float = 3.0 # Duration target is stunned after kick
@export var block_knockback_force : float = 18.0 # Speed player slides back when blocking a hit

# ── Rapid Attack Attack ──────────────────────────────────────────────────────────
@export var rapid_attack_charge_time  : float = 1.5   # Seconds to fill the charge bar
@export var rapid_attack_duration     : float = 4.0   # Seconds the rapid attack lasts
@export var rapid_attack_cooldown     : float = 30.0  # Seconds before rapid attack can recharge
@export var rapid_attack_attack_rate  : float = 0.2   # Seconds between auto-hits (5 hits/sec)

# ── AOE (Potion Blast) ────────────────────────────────────────
@export var aoe_base_radius : float = 3.5 # Base size of the potion blast dome
const AOE_COOLDOWN_TIME   : float = 2.5
const AOE_DURATION         : float = 2.0

# ── Kill streak particle settings (SURGICAL ADD) ──────────────
@export var streak_tier1_kills    : int   = 3
@export var streak_tier2_kills    : int   = 6
@export var streak_tier3_kills    : int   = 9
@export var streak_fire_height    : float = 0.8
@export var swing_spark_lifetime  : float = 0.25
@export var tex_swing_slash  : String = "res://addons/kenney_particle_pack/slash_01.png"
@export var tex_swing_spark  : String = "res://addons/kenney_particle_pack/spark_04.png"
@export var tex_streak_flame1 : String = "res://addons/kenney_particle_pack/flame_03.png"
@export var tex_streak_flame2 : String = "res://addons/kenney_particle_pack/flame_05.png"
@export var tex_streak_flame3 : String = "res://addons/kenney_particle_pack/fire_02.png"

# ── Audio Streams ──────────────────────────────────────────────
var axe_hit_sounds: Array[AudioStream] = [
	preload("res://Music & background images/Sound Effects/Stab Large A.wav"),
	preload("res://Music & background images/Sound Effects/Stab Large B.wav"),
	preload("res://Music & background images/Sound Effects/Stab Large C.wav"),
	preload("res://Music & background images/Sound Effects/Stab Large D.wav"),
	preload("res://Music & background images/Sound Effects/Stab Large E.wav")
]
var swing_sound: AudioStream = preload("res://Music & background images/Sound Effects/short axe swing.mp3")
var kick_sound: AudioStream = preload("res://Music & background images/Sound Effects/player kick.mp3")
var aoe_blast_sound: AudioStream = preload("res://Music & background images/Sound Effects/Burned A.wav")
var block_sound: AudioStream = preload("res://Music & background images/Sound Effects/axe blocked.mp3")
@export var hit_grunt_sound: AudioStream

# ── Node references ────────────────────────────────────────────
@onready var spring_arm : SpringArm3D = get_node_or_null("SpringArm3D")
@onready var pause_menu : CanvasLayer = get_node_or_null("../pause_menu_function")

# ── Runtime state ──────────────────────────────────────────────
var _yaw          : float = 0.0
var _idle_timer   : float = 0.0
var _is_attacking : bool  = false
var _is_kicking   : bool  = false

# ── Slide (Evade) state ────────────────────────────────────────
var _is_sliding            : bool    = false
var _slide_timer           : float   = 0.0
var _slide_duration        : float   = 0.0
var _slide_direction       : Vector3 = Vector3.ZERO
var _slide_cam_lift        : float   = 0.0
var _slide_knocked_enemies : Array   = []
# Props already kicked by the current slide: a prop in range used to be kicked (and its 8% loot
# roll re-rolled) on every physics tick of the slide.
var _slide_kicked_props   : Array   = []

# ── Status effects (from booby traps) ──────────────────────────────────────
var _status_reversed_view     : bool  = false
var _status_heavy_gravity     : bool  = false
var _status_drunk             : bool  = false
var _status_reversed_controls : bool  = false
var _status_acid              : bool  = false
var _status_acid_timer        : float = 0.0
var _status_acid_dps          : float = 1.0   # Set by the trap (TrapManager.acid_damage_per_sec)
var _status_day_effects_days  : int   = 0

# Tracked timers for timed effects (replacing fire-and-forget create_timer
# calls so the status label can display a live countdown).
var _status_drunk_timer    : float = 0.0   # Seconds remaining on drunk effect
var _status_reversed_view_timer : float = 0.0   # Seconds remaining on Reversed View (same length as Intoxicated)
var _status_controls_timer : float = 0.0   # Seconds remaining on reversed controls

# ── Status label ───────────────────────────────────────────────────────────────
# Shows active trap effects and how long they last.
# Updates every 0.5s to show countdowns without hammering the label every tick.
var _status_label        : Label    = null
var _status_panel        : Control  = null
var _status_update_timer : float    = 0.0
const STATUS_UPDATE_INTERVAL : float = 0.5

# ── Rapid Attack state ──────────────────────────────────────────────────────────
var _attack_held              : bool  = false
var _rapid_attack_charge           : float = 0.0
var _rapid_attack_active           : bool  = false
var _rapid_attack_timer            : float = 0.0
var _rapid_attack_cooldown_remain  : float = 0.0
var _rapid_attack_attack_timer     : float = 0.0

# ── Rapid Attack HUD ────────────────────────────────────────────────────────────
var _rapid_attack_bar_label: Label     = null   # caption beside the ability bar (owned by _vitals)
var _hit_targets     : Dictionary = {}

# ── Buff System Hooks ──────────────────────────────────────────
var _aoe_cooldown          : float = 0.0
var aoe_radius_bonus       : float = 0.0
var health_on_kill         : float = 0.0
var passive_regen          : float = 0.0
var move_speed_modifier    : float = 0.0
var turn_speed_modifier    : float = 1.0
var attack_speed           : float = 1.0
# ── New buff stats ─────────────────────────────────────────────
var currency_on_kill       : float = 0.0  # Soul Harvester: potions gained per kill
var spark_damage           : float = 0.0  # Spark Fury: instant AOE damage at kill site
var spark_light_radius     : float = 0.0  # Radiant Sparks: bonus light range on kill
var spark_brightness       : float = 0.0  # Bright Carnage: light energy on kill
var attack_speed_streak    : float = 0.0  # Battle Hunger: +N% attack_speed per 5-kill tier
var poison_on_kill_chance  : float = 0.0  # Plague Spreader: chance to poison nearby enemies
# low_health_damage is inherited from CharacterBase — do not redeclare here.

# ── Kill streak state (SURGICAL ADD) ──────────────────────────
var _kill_streak          : int   = 0
var _last_kill_count      : int   = 0
var _streak_tier          : int   = 0
var _streak_attack_bonus  : float = 0.0  # running attack_speed bonus from attack_speed_streak

# ── Particle nodes ──────────────────────────────────────────────
var _swing_sparks  : GPUParticles3D = null
var _streak_fire   : GPUParticles3D = null

# ── HUD ────────────────────────────────────────────────────────
var _hud_layer       : CanvasLayer = null
var _vitals          : HudVitals   = null   # health bar + value, ability bar + caption (scripts/ui/hud_vitals.gd)
var _health_label    : Label       = null

# ── Damage vignette ────────────────────────────────────────────
# Full-screen red overlay that pulses on damage and fades out over ~0.8s.
# Gives the player a behind-hit warning without a direction indicator.
@export var vignette_peak_alpha : float = 0.32  # Max alpha on a single hit
@export var vignette_fade_speed : float = 0.9   # Alpha units per second to fade
var _damage_vignette : ColorRect = null
var _vignette_alpha  : float     = 0.0


# ══════════════════════════════════════════════════════════════
#  SETUP
# ══════════════════════════════════════════════════════════════

func _on_ready() -> void:
	_is_armed = true
	set_armed(true)
	add_to_group("player")
	process_mode = Node.PROCESS_MODE_ALWAYS
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	camera_3d       = get_node_or_null("SpringArm3D/Camera3D")
	footstep_player = get_node_or_null("FootstepPlayer")

	if camera_3d != null:
		camera_3d.current = true
		_default_cam_y = camera_3d.position.y

	_yaw = rotation.y
	_configure_footstep_player()
	_build_hud()
	connect("health_changed", _on_health_changed)
	_setup_weapon_hitbox()
	_setup_kick_hitbox()
	_setup_particles()
	_last_kill_count = CharacterBase.GLOBAL_KILL_COUNT
	_apply_hub_perks()

	var loading_script := load("res://scripts/loading_screen.gd")
	if loading_script:
		var screen := CanvasLayer.new()
		screen.set_script(loading_script)
		add_child(screen)


func _setup_weapon_hitbox() -> void:
	if weapon_hitbox == null: return
	weapon_hitbox.set_deferred("monitoring", false)
	weapon_hitbox.set_deferred("monitorable", false)
	weapon_hitbox.body_entered.connect(_on_weapon_hit)


func _setup_kick_hitbox() -> void:
	if kick_hitbox == null: return
	kick_hitbox.set_deferred("monitoring", false)
	kick_hitbox.set_deferred("monitorable", false)
	kick_hitbox.body_entered.connect(_on_kick_hit)


# ══════════════════════════════════════════════════════════════
#  DIRECTIONAL BLOCK
# ══════════════════════════════════════════════════════════════

# Rotates the brute by rotation_offset (radians) relative to his current
# facing direction, then holds the block animation at the halfway point.
# It stays paused as long as the player holds the button. Upon release,
# it resumes rapidly to complete the stance recovery.
#
# Plays the block animation facing the player's current direction.
# Holds at the halfway point while "block" is held; on release, resumes at
# 2.5x to snap out of the stance.
func _do_block() -> void:
	if _is_blocking or _is_dead or _is_sliding:
		return

	if _is_attacking:
		_is_attacking = false
		_set_weapon_hitbox_active(false)
		_hit_targets.clear()
		if anim_player != null: anim_player.speed_scale = 1.0
	if _is_kicking:
		_is_kicking = false
		_set_kick_hitbox_active(false)
		_hit_targets.clear()
		if anim_player != null: anim_player.speed_scale = 1.0

	_is_blocking = true
	velocity.x   = 0.0
	velocity.z   = 0.0

	if anim_player != null: anim_player.speed_scale = 1.0
	_play_anim("block_react")

	var anim_len  : float = _current_anim_length()
	var half_time : float = anim_len * 0.5
	var elapsed   : float = 0.0
	var released_early : bool = false

	# Advance to the halfway point, polling for premature release each frame.
	while elapsed < half_time and _is_blocking:
		if not Input.is_action_pressed("block"):
			released_early = true
			break
		elapsed += get_physics_process_delta_time()
		await get_tree().physics_frame

	# Freeze animation at the midpoint using speed_scale = 0.0 (anim_player.pause()
	# + play() restarts from frame 0 in Godot 4; speed_scale=0 holds the frame).
	if _is_blocking and not released_early:
		if anim_player != null: anim_player.speed_scale = 0.0

		# Hold until the player releases the button.
		while _is_blocking:
			if not Input.is_action_pressed("block"):
				break
			await get_tree().physics_frame

	# Player released — resume from the frozen position at 2.5x speed.
	# No play() call needed: speed_scale > 0 continues from the frozen frame.
	if _is_blocking:
		if anim_player != null:
			anim_player.speed_scale = 2.5

		# Remaining tail of the animation at 2.5x speed.
		var remain_time : float = maxf((anim_len - elapsed) / 2.5, 0.05)
		await get_tree().create_timer(remain_time).timeout

		if _is_blocking:
			_is_blocking = false
			if anim_player != null: anim_player.speed_scale = 1.0
			if not _is_dead:
				_change_state(_get_idle_state())


# ══════════════════════════════════════════════════════════════
#  RAPID ATTACK
#  Berserker frenzy: auto-swings at attack_rate for `duration` seconds,
#  player takes zero damage, first-person view and movement unchanged.
# ══════════════════════════════════════════════════════════════

func _start_rapid_attack() -> void:
	if _is_dead:
		return
	# Cancel any in-flight single-swing / kick — we own the hitbox now.
	if _is_attacking:
		_is_attacking = false
		_set_weapon_hitbox_active(false)
		_hit_targets.clear()
	if _is_kicking:
		_is_kicking = false
		_set_kick_hitbox_active(false)
		_hit_targets.clear()

	_rapid_attack_active       = true
	_rapid_attack_timer        = rapid_attack_duration
	_rapid_attack_attack_timer = 0.0
	_is_attacking              = true
	anim_player.speed_scale    = attack_speed_scale * attack_speed * 1.5
	_refresh_rapid_attack_bar()


func _end_rapid_attack() -> void:
	_rapid_attack_active  = false
	_is_attacking    = false
	_set_weapon_hitbox_active(false)
	_hit_targets.clear()
	_rapid_attack_cooldown_remain = rapid_attack_cooldown
	anim_player.speed_scale  = 1.0
	_refresh_rapid_attack_bar()

	if not _is_dead:
		_change_state(_get_idle_state())


# ══════════════════════════════════════════════════════════════
#  HUB PERK APPLICATION
# ══════════════════════════════════════════════════════════════

func _apply_hub_perks() -> void:
	if SaveManager.current_profile.is_empty():
		return

	var perk_levels : Dictionary = SaveManager.current_profile.get("perks", {})

	var magnitude_lv : int = int(perk_levels.get("magnitude", 0))
	if magnitude_lv > 0:
		aoe_base_radius *= (1.0 + 0.10 * float(magnitude_lv))

	var vitality_lv : int = int(perk_levels.get("vitality", 0))
	if vitality_lv > 0:
		var bonus : float = 10.0 * float(vitality_lv)
		max_health      += bonus
		_current_health  = max_health
		health_changed.emit(_current_health, max_health)

	var adrenaline_lv : int = int(perk_levels.get("adrenaline", 0))
	if adrenaline_lv > 0:
		attack_speed_scale *= (1.0 + 0.08 * float(adrenaline_lv))

	var ferocity_lv : int = int(perk_levels.get("ferocity", 0))
	if ferocity_lv > 0:
		attack_damage *= (1.0 + 0.10 * float(ferocity_lv))

	var swiftness_lv : int = int(perk_levels.get("swiftness", 0))
	if swiftness_lv > 0:
		move_speed_modifier += move_speed * 0.05 * float(swiftness_lv)

	var health_regen_lv : int = int(perk_levels.get("health_regen", 0))
	if health_regen_lv > 0:
		passive_regen += 0.5 * float(health_regen_lv)

	var cyclone_lv : int = int(perk_levels.get("cyclone", 0))
	if cyclone_lv > 0:
		rapid_attack_duration += 0.5 * float(cyclone_lv)
		rapid_attack_cooldown  = maxf(rapid_attack_cooldown - 3.0 * float(cyclone_lv), 10.0)


# ══════════════════════════════════════════════════════════════
#  PARTICLE SETUP
# ══════════════════════════════════════════════════════════════

func _setup_particles() -> void:
	_swing_sparks = _build_swing_sparks()
	_streak_fire  = _build_streak_fire()
	add_child(_swing_sparks)
	add_child(_streak_fire)
	_streak_fire.position = Vector3(0.0, streak_fire_height, 0.0)


func _build_swing_sparks() -> GPUParticles3D:
	var p             := GPUParticles3D.new()
	p.name             = "SwingSparks"
	p.emitting         = false
	p.one_shot         = true
	p.explosiveness    = 0.92
	p.amount           = 16
	p.lifetime         = swing_spark_lifetime
	p.visibility_aabb  = AABB(Vector3(-2, -2, -2), Vector3(4, 4, 4))

	var proc := ParticleProcessMaterial.new()
	proc.direction            = Vector3(0.0, 0.4, 1.0)
	proc.spread               = 65.0
	proc.initial_velocity_min = 3.0
	proc.initial_velocity_max = 8.0
	proc.gravity              = Vector3(0.0, -5.0, 0.0)
	proc.scale_min            = 0.07
	proc.scale_max            = 0.18
	proc.lifetime_randomness  = 0.4
	p.process_material = proc

	var quad := QuadMesh.new()
	quad.size = Vector2(0.12, 0.12)
	var mat   := StandardMaterial3D.new()
	mat.billboard_mode              = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency                = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode                = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled            = true
	mat.emission                    = Color(1.0, 0.75, 0.2)
	mat.emission_energy_multiplier   = 2.5
	if ResourceLoader.exists(tex_swing_spark):
		mat.albedo_texture = load(tex_swing_spark)
	quad.surface_set_material(0, mat)
	p.draw_pass_1 = quad
	return p


func _build_streak_fire() -> GPUParticles3D:
	var p             := GPUParticles3D.new()
	p.name             = "StreakFire"
	p.emitting         = false
	p.one_shot         = false
	p.amount           = 20
	p.lifetime         = 0.6
	p.visibility_aabb  = AABB(Vector3(-1.5, -0.5, -1.5), Vector3(3, 4, 3))

	var proc := ParticleProcessMaterial.new()
	proc.direction            = Vector3(0.0, 1.0, 0.0)
	proc.spread               = 28.0
	proc.initial_velocity_min = 1.0
	proc.initial_velocity_max = 2.5
	proc.gravity              = Vector3(0.0, 0.4, 0.0)
	proc.scale_min            = 0.09
	proc.scale_max            = 0.20
	proc.lifetime_randomness  = 0.5
	p.process_material = proc

	var quad := QuadMesh.new()
	quad.size = Vector2(0.18, 0.18)
	var mat  := StandardMaterial3D.new()
	mat.billboard_mode              = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency                = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode                = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled            = true
	mat.emission                    = Color(1.0, 0.45, 0.05)
	mat.emission_energy_multiplier   = 1.8
	if ResourceLoader.exists(tex_streak_flame1):
		mat.albedo_texture = load(tex_streak_flame1)
	quad.surface_set_material(0, mat)
	p.draw_pass_1 = quad
	return p




# ══════════════════════════════════════════════════════════════
#  KILL STREAK SYSTEM
# ══════════════════════════════════════════════════════════════

func _check_kill_streak() -> void:
	var current := CharacterBase.GLOBAL_KILL_COUNT
	if current <= _last_kill_count:
		return
	var new_kills       := current - _last_kill_count
	_last_kill_count     = current
	_kill_streak        += new_kills

	# ── Stat-based on-kill effects ─────────────────────────────────────────────
	_on_kill_haste_trigger()
	var kill_curse : float = 0.0
	if health_on_kill < 0.0:
		kill_curse += -health_on_kill
	if spark_damage < 0.0:
		kill_curse += -spark_damage
	_take_curse_damage(kill_curse * float(new_kills))
	if health_on_kill > 0.0:
		receive_heal(health_on_kill * float(new_kills))

	if currency_on_kill > 0.0 and has_node("/root/PlayerWallet"):
		PlayerWallet.add_potions(int(currency_on_kill * float(new_kills)))

	var kill_pos : Vector3 = CharacterBase.GLOBAL_LAST_KILL_POS

	if spark_damage > 0.0:
		_spawn_kill_aoe(kill_pos, spark_damage)

	if spark_light_radius > 0.0 or spark_brightness > 0.0:
		_spawn_kill_flash(kill_pos, spark_light_radius, spark_brightness)

	if poison_on_kill_chance > 0.0 and randf() < poison_on_kill_chance:
		_spawn_poison_cloud(kill_pos)

	# Battle Hunger: +attack_speed_streak per 5-kill tier (e.g. 0–4=0, 5–9=+8%, 10–14=+16%)
	if attack_speed_streak > 0.0:
		var new_bonus : float = attack_speed_streak * int(float(_kill_streak) / 5.0)
		if not is_equal_approx(new_bonus, _streak_attack_bonus):
			attack_speed            += new_bonus - _streak_attack_bonus
			_streak_attack_bonus     = new_bonus

	_update_streak_particles()


func _update_streak_particles() -> void:
	if _streak_fire == null: return

	var new_tier : int = 0
	if   _kill_streak >= streak_tier3_kills: new_tier = 3
	elif _kill_streak >= streak_tier2_kills: new_tier = 2
	elif _kill_streak >= streak_tier1_kills: new_tier = 1

	if new_tier == _streak_tier: return
	_streak_tier = new_tier

	match _streak_tier:
		0:
			_streak_fire.emitting = false
		1:
			_streak_fire.amount   = 18
			_streak_fire.lifetime = 0.55
			_apply_fire_texture(tex_streak_flame1, Color(1.0, 0.55, 0.1), 1.4)
			_streak_fire.emitting = true
		2:
			_streak_fire.amount   = 35
			_streak_fire.lifetime = 0.75
			_apply_fire_texture(tex_streak_flame2, Color(1.0, 0.35, 0.0), 2.0)
			_streak_fire.emitting = true
		3:
			_streak_fire.amount   = 60
			_streak_fire.lifetime = 1.0
			_apply_fire_texture(tex_streak_flame3, Color(1.0, 0.18, 0.0), 2.8)
			_streak_fire.emitting = true


func _apply_fire_texture(tex_path: String, emission_color: Color, energy: float) -> void:
	if _streak_fire == null or _streak_fire.draw_pass_1 == null: return
	var mat : StandardMaterial3D = _streak_fire.draw_pass_1.surface_get_material(0) as StandardMaterial3D
	if mat == null: return
	mat.emission                  = emission_color
	mat.emission_energy_multiplier = energy
	if ResourceLoader.exists(tex_path):
		mat.albedo_texture = load(tex_path)


func _break_streak() -> void:
	if _kill_streak == 0: return
	_kill_streak = 0
	_streak_tier = 0
	if _streak_fire != null:
		_streak_fire.emitting = false
	# Remove Battle Hunger attack speed bonus when streak resets.
	if _streak_attack_bonus > 0.0:
		attack_speed         -= _streak_attack_bonus
		_streak_attack_bonus  = 0.0

# ── On-kill effect helpers (declared here so the parser resolves them
#    without relying on grandparent-class lookup in GDScript 4) ──────────

func _spawn_kill_aoe(kill_pos: Vector3, damage: float) -> void:
	const RADIUS : float = 3.0
	for enemy in get_tree().get_nodes_in_group("enemies"):
		if enemy is Node3D and enemy != self:
			if (enemy as Node3D).global_position.distance_to(kill_pos) <= RADIUS:
				if enemy.has_method("take_damage"):
					enemy.take_damage(damage, self)

func _spawn_kill_flash(kill_pos: Vector3, range_bonus: float, brightness: float) -> void:
	if not is_inside_tree():
		return
	var light         := OmniLight3D.new()
	light.omni_range   = 4.0 + range_bonus * 10.0
	light.light_energy = 3.0 + brightness * 10.0
	light.light_color  = Color(1.0, 0.88, 0.45)
	get_tree().current_scene.add_child(light)
	light.global_position = kill_pos + Vector3(0.0, 0.5, 0.0)
	var tw := create_tween()
	tw.tween_property(light, "light_energy", 0.0, 0.5)
	tw.finished.connect(light.queue_free)

func _spawn_poison_cloud(kill_pos: Vector3) -> void:
	const TICK_DAMAGE    : float = 5.0
	const TICK_INTERVAL  : float = 0.5
	const TICKS_TOTAL    : int   = 10
	const CLOUD_RADIUS   : float = 2.0
	var ticks := TICKS_TOTAL
	while ticks > 0 and is_instance_valid(self) and not _is_dead:
		await get_tree().create_timer(TICK_INTERVAL).timeout
		if not is_instance_valid(self) or _is_dead:
			return
		ticks -= 1
		for enemy in get_tree().get_nodes_in_group("enemies"):
			if enemy is Node3D and enemy != self:
				if (enemy as Node3D).global_position.distance_to(kill_pos) <= CLOUD_RADIUS:
					if enemy.has_method("take_damage"):
						enemy.take_damage(TICK_DAMAGE, self)


func _fire_swing_sparks() -> void:
	if _swing_sparks == null or weapon_hitbox == null: return
	_swing_sparks.global_position = weapon_hitbox.global_position
	_swing_sparks.restart()
	_swing_sparks.emitting = true


func take_damage(amount: float, source_node: Node3D = null) -> void:
	if _is_dead: return
	if _is_sliding: return  # Invincible during the evasive slide.
	if _rapid_attack_active: return  # Invincible during rapid attack frenzy.

	if _is_blocking and source_node != null:
		var to_source : Vector3 = (source_node.global_position - global_position).normalized()
		var forward   : Vector3 = -global_transform.basis.z.normalized()

		if forward.dot(to_source) > 0.7:
			if block_sound != null and has_node("/root/AudioManager"):
				AudioManager.play_one_shot(block_sound, 2.0, randf_range(0.9, 1.1))
			if hit_grunt_sound != null and has_node("/root/AudioManager"):
				AudioManager.play_one_shot(hit_grunt_sound, 0.0, randf_range(0.9, 1.1))
			var push_dir : Vector3 = (global_position - source_node.global_position).normalized()
			push_dir.y = 0.0
			velocity = push_dir * block_knockback_force
			return

	_break_streak()
	# Flash the damage vignette — stacks slightly on rapid hits, capped at peak.
	_vignette_alpha = minf(_vignette_alpha + 0.28, vignette_peak_alpha)
	if _damage_vignette != null:
		_damage_vignette.color.a = _vignette_alpha
	# Flash the shared damage direction fan (points at the hit source).
	if source_node != null:
		_flash_damage_direction(source_node, _yaw)
	super.take_damage(amount, source_node)


func _play_hit_react() -> void:
	if _is_attacking or _is_kicking:
		_is_attacking = false
		_is_kicking = false
		_hit_targets.clear()
		_set_weapon_hitbox_active(false)
		_set_kick_hitbox_active(false)
		if anim_player != null:
			anim_player.speed_scale = 1.0
	_is_blocking = false
	if anim_player != null: anim_player.speed_scale = 1.0
	super._play_hit_react()


func _on_knockback_wall_hit() -> void:
	# React sound + minor impact damage when the player slides into a wall/enemy
	# during a knockback stun. Fires at most once per knockback event.
	if hit_grunt_sound != null and has_node("/root/AudioManager"):
		AudioManager.play_one_shot(hit_grunt_sound, 0.0, randf_range(0.85, 1.05))
	take_damage(3.0, null)


func receive_heal(amount: float) -> void:
	if _is_dead: return
	_current_health += amount
	if _current_health > max_health:
		_current_health = max_health
	emit_signal("health_changed", _current_health, max_health)
	_refresh_health_bar(_current_health, max_health)


func _on_weapon_hit(collider: Node3D) -> void:
	var target : Node = collider
	if not target.has_method("take_damage") and not target.has_method("apply_kick") and target.get_parent() != null:
		target = target.get_parent()

	if target == self or _hit_targets.has(target): return

	# Axe swing on a kickable prop counts as another kick hit.
	if target.has_method("apply_kick"):
		var forward_swing := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
		target.apply_kick(forward_swing, attack_damage * 2.0 + kick_force * 6.0)
		_hit_targets[target] = true
		return

	if target.has_method("take_damage"):
		var swing_dmg : float = attack_damage + get_low_health_attack_bonus()
		# Executioner: +bonus% damage when target is below 30% health.
		if low_health_damage > 0.0:
			var cur_hp := float(target.get("_current_health") if "_current_health" in target else max_health)
			var max_hp := float(target.get("max_health")      if "max_health"      in target else 1.0)
			if max_hp > 0.0 and cur_hp / max_hp < 0.3:
				swing_dmg *= 1.0 + low_health_damage
		target.take_damage(swing_dmg, self)
		_hit_targets[target] = true

		if axe_hit_sounds.size() > 0 and has_node("/root/AudioManager"):
			var hit_sfx : AudioStream = axe_hit_sounds.pick_random() as AudioStream
			if hit_sfx != null:
				AudioManager.play_3d_one_shot(hit_sfx, collider.global_position, 0.0, randf_range(0.9, 1.1))


func _on_kick_hit(collider: Node3D) -> void:
	var target : Node = collider
	if not target.has_method("take_damage") and not target.has_method("apply_kick") and target.get_parent() != null:
		target = target.get_parent()

	if target == self or _hit_targets.has(target): return

	# Kickable props short-circuit here — they have no HP and don't use knockback/damage.
	if target.has_method("apply_kick"):
		var forward_kick := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
		target.apply_kick(forward_kick, kick_force * 12.0)
		_hit_targets[target] = true
		return

	if target.has_method("take_damage"):
		var kick_dmg : float = kick_damage
		if low_health_damage > 0.0:
			var cur_hp := float(target.get("_current_health") if "_current_health" in target else max_health)
			var max_hp := float(target.get("max_health")      if "max_health"      in target else 1.0)
			if max_hp > 0.0 and cur_hp / max_hp < 0.3:
				kick_dmg *= 1.0 + low_health_damage
		target.take_damage(kick_dmg, self)

	if target.has_method("take_knockback"):
		var forward := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
		target.take_knockback(forward, kick_force, kick_stun_time)

	_hit_targets[target] = true


func _build_hud() -> void:
	_hud_layer      = CanvasLayer.new()
	_hud_layer.name = "HUD"
	add_child(_hud_layer)

	# Health bar + value, rapid-attack bar + caption: one shared component (the Mage uses the same).
	_vitals = HudVitals.new()
	_hud_layer.add_child(_vitals)
	_health_label            = _vitals.health_label
	_rapid_attack_bar_label  = _vitals.ability_label
	_refresh_health_bar(max_health, max_health)
	_refresh_rapid_attack_bar()

	# Damage vignette — sits above all other HUD elements so it bleeds over
	# the health bar and fills the whole screen. mouse_filter IGNORE so it
	# doesn't block any UI clicks on menus that appear while paused.
	_damage_vignette = ColorRect.new()
	_damage_vignette.color = Color(PUI.BLOOD, 0.0)
	_damage_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_damage_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(_damage_vignette)

	# ── Active trap effects list ───────────────────────────────────────────────
	# Small plate at the bottom-centre of the screen, sized to its text. Visible only when at
	# least one trap effect is active. Updates every 0.5s.
	var status := HudStatusPanel.new()
	_hud_layer.add_child(status)
	_status_panel = status
	_status_label = status.label


func _on_health_changed(new_health: float, max_val: float) -> void:
	_refresh_health_bar(new_health, max_val)


func _refresh_health_bar(current: float, max_val: float) -> void:
	if _vitals == null: return
	_vitals.set_health(current, max_val)


func _refresh_rapid_attack_bar() -> void:
	if _vitals == null:
		return

	if _rapid_attack_active:
		_vitals.set_ability(clampf(_rapid_attack_timer / rapid_attack_duration, 0.0, 1.0),
				HudVitals.Ability.ACTIVE, _rapid_attack_timer)

	elif _rapid_attack_cooldown_remain > 0.0:
		_vitals.set_ability(1.0 - clampf(_rapid_attack_cooldown_remain / rapid_attack_cooldown, 0.0, 1.0),
				HudVitals.Ability.COOLDOWN, _rapid_attack_cooldown_remain)

	elif _attack_held:
		_vitals.set_ability(_rapid_attack_charge,
				HudVitals.Ability.RELEASE if _rapid_attack_charge >= 1.0 else HudVitals.Ability.CHARGING)

	else:
		_vitals.set_ability(1.0, HudVitals.Ability.READY)


# Called by BuffManager._finalize_close after the day-change slot machine
# closes. Any in-flight action (attack/kick/slide/block) that was mid-await
# when the tree paused would leave its state flag stuck `true` forever — the
# movement input gate then refuses to respond. This clears the lot so the
# player can always act again after a buff pick, regardless of what they
# were doing when Day-N rolled over.
func _on_buff_pick_finished() -> void:
	_is_attacking = false
	_is_kicking   = false
	_is_blocking  = false
	_is_sliding   = false
	_hit_targets.clear()
	_set_weapon_hitbox_active(false)
	_set_kick_hitbox_active(false)
	if anim_player != null:
		anim_player.speed_scale = 1.0
	velocity.x = 0.0
	velocity.z = 0.0


func _on_die() -> void:
	clear_timed_statuses()
	if _streak_fire != null:
		_streak_fire.emitting = false

	if has_node("/root/GameClock"):
		GameClock.hide_hud()

	anim_player.speed_scale = death_anim_speed
	_play_anim("death")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	var you_died_script := load("res://scripts/you_died_screen.gd")
	if you_died_script:
		var screen := CanvasLayer.new()
		screen.set_script(you_died_script)
		get_tree().root.add_child(screen)


func _unhandled_input(event: InputEvent) -> void:
	if _is_pause_event(event):
		if _is_pause_menu_open(): _resume_game()
		else: _pause_game()
		get_viewport().set_input_as_handled()
		return

	if get_tree().paused: return

	# A finger on the touch screen also produces emulated mouse motion; touch look is fed by the touch
	# layer as ordinary mouse-look instead, so the emulated copy must not turn the camera a second time.
	if event is InputEventMouseMotion and (event as InputEventMouseMotion).device != InputEvent.DEVICE_ID_EMULATION:
		var look        : float = (event as InputEventMouseMotion).relative.x
		var actual_sens : float = mouse_sensitivity * turn_speed_modifier
		_yaw -= look * actual_sens
		# Show the turn on the frame it arrives, not at the next 30 Hz physics tick (at 20-40 fps the tick cadence made
		# the camera stand still for a frame, then jump). Same states as the tick: the view is locked while blocking / dead.
		if not _is_dead and not _is_blocking:
			_apply_yaw_now()

	if event.is_action_pressed("kick") and not _is_kicking and not _is_attacking and not _is_sliding and not _is_blocking:
		_do_kick()

	if event.is_action_pressed("AOE") and _aoe_cooldown <= 0.0 and not _is_dead:
		_do_aoe()

	if not _is_dead and not _is_blocking:
		if event.is_action_pressed("block"):
			_do_block()


func _physics_tick(delta: float) -> void:
	if get_tree().paused:
		# Zero horizontal velocity so character_base.move_and_slide() doesn't
		# slide the player with stale momentum while the tree is paused.
		velocity.x = 0.0
		velocity.z = 0.0
		_stop_footsteps()
		return

	if global_position.y < -15.0 and not _is_dead:
		take_damage(max_health + 1.0)

	# ── Attack Input Polling (ZELDA METHOD) ──────────────────────────────────
	if Input.is_action_just_pressed("attack") and not _is_attacking and not _is_kicking \
			and not _is_sliding and not _is_blocking and not _rapid_attack_active and not _is_dead:
		_attack_held = true
		_rapid_attack_charge = 0.0
		_do_attack()

	if Input.is_action_pressed("attack") and _attack_held and not _is_dead and _rapid_attack_cooldown_remain <= 0.0:
		_rapid_attack_charge = minf(_rapid_attack_charge + delta / rapid_attack_charge_time, 1.0)
		_refresh_rapid_attack_bar()

	if Input.is_action_just_released("attack") and _attack_held:
		_attack_held = false
		if _rapid_attack_charge >= 1.0 and _rapid_attack_cooldown_remain <= 0.0 and not _rapid_attack_active:
			_rapid_attack_charge = 0.0
			_start_rapid_attack()
		else:
			_rapid_attack_charge = 0.0
			_refresh_rapid_attack_bar()

	_check_kill_streak()
	_tick_kill_haste(delta)

	if _aoe_cooldown > 0.0:
		_aoe_cooldown -= delta

	if passive_regen > 0.0 and _current_health < max_health and not _is_dead:
		receive_heal(passive_regen * delta)

	if _status_acid and not _is_dead:
		_status_acid_timer -= delta
		take_damage(_status_acid_dps * delta)
		if _status_acid_timer <= 0.0:
			_status_acid = false

	# Tick the timed status effects that replaced fire-and-forget create_timer.
	if _status_drunk and _status_drunk_timer > 0.0:
		_status_drunk_timer -= delta
		if _status_drunk_timer <= 0.0:
			_status_drunk = false
			_refresh_status_label()

	if _status_reversed_view and _status_reversed_view_timer > 0.0:
		_status_reversed_view_timer -= delta
		if _status_reversed_view_timer <= 0.0:
			_status_reversed_view = false
			_refresh_status_label()

	if _status_reversed_controls and _status_controls_timer > 0.0:
		_status_controls_timer -= delta
		if _status_controls_timer <= 0.0:
			_status_reversed_controls = false
			_refresh_status_label()

	# Throttle status label refresh — no need to rebuild text every 60Hz tick.
	if _status_drunk or _status_reversed_view or _status_reversed_controls or _status_acid:
		_status_update_timer -= delta
		if _status_update_timer <= 0.0:
			_status_update_timer = STATUS_UPDATE_INTERVAL
			_refresh_status_label()

	if _is_blocking:
		velocity.x = move_toward(velocity.x, 0.0, move_deceleration * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_deceleration * delta)
		move_and_slide()
		_update_footsteps(delta)
		return

	if _rapid_attack_active:
		# Normal first-person movement + view + footsteps — player is in
		# full control during rapid attack. The only difference vs. normal
		# play is the auto-swing tick below and the damage immunity in
		# take_damage (see "_rapid_attack_active" gate there).
		_handle_view_input(delta)
		_apply_view_rotation()
		_handle_movement(delta)
		_update_footsteps(delta)
		_apply_head_bob(delta)

		_rapid_attack_timer -= delta
		_rapid_attack_attack_timer -= delta

		# Auto-chop. Keeps the weapon hitbox hot so anything walked into
		# during the swing connects, then re-triggers each time the attack
		# timer drains.
		if _rapid_attack_attack_timer <= 0.0:
			_rapid_attack_attack_timer = rapid_attack_attack_rate
			_hit_targets.clear()
			_set_weapon_hitbox_active(true)
			_play_anim(pick_attack())
			anim_player.speed_scale = attack_speed_scale * attack_speed * 1.5
			_fire_swing_sparks()

		_refresh_rapid_attack_bar()

		if _rapid_attack_timer <= 0.0:
			_end_rapid_attack()
		return

	if _rapid_attack_cooldown_remain > 0.0:
		_rapid_attack_cooldown_remain = maxf(_rapid_attack_cooldown_remain - delta, 0.0)
		_refresh_rapid_attack_bar()

	_handle_view_input(delta)
	_apply_view_rotation()
	_handle_movement(delta)
	_handle_slide(delta)
	_update_footsteps(delta)
	_apply_head_bob(delta)
	# Slide lunge lift — added on top of the standard head-bob result.
	if camera_3d != null and (_is_sliding or _slide_cam_lift > 0.001):
		_slide_cam_lift = lerpf(_slide_cam_lift, 0.0, delta * 8.0)
		camera_3d.position.y += _slide_cam_lift

	# Fade damage vignette — runs every tick so it disappears smoothly.
	if _vignette_alpha > 0.0 and _damage_vignette != null:
		_vignette_alpha = maxf(_vignette_alpha - vignette_fade_speed * delta, 0.0)
		_damage_vignette.color.a = _vignette_alpha
	_tick_damage_fan(delta)


func _handle_view_input(delta: float) -> void:
	var look_x : float = Input.get_axis("look_left", "look_right")
	if _status_reversed_controls:
		look_x = -look_x
	if abs(look_x) >= look_deadzone:
		var actual_speed : float = gamepad_turn_speed * turn_speed_modifier
		_yaw -= look_x * actual_speed * delta


func _apply_yaw_now() -> void:
	var yaw_out : float = _yaw
	if _status_drunk:
		yaw_out += sin(Time.get_ticks_msec() * 0.002) * 0.18
	rotation.y = yaw_out


func _apply_view_rotation() -> void:
	_apply_yaw_now()

	var arm : SpringArm3D = get_node_or_null("SpringArm3D") as SpringArm3D
	if arm != null:
		arm.rotation.x = PI if _status_reversed_view else 0.0


func _handle_movement(delta: float) -> void:
	var input_dir := Vector2(
		Input.get_axis("move_left",    "move_right"),
		Input.get_axis("move_forward", "move_back")
	)

	if input_dir.length() >= move_deadzone:
		input_dir = input_dir.normalized()

		var forward := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
		var right   := Vector3( cos(_yaw), 0.0, -sin(_yaw))
		var dir      := (forward * -input_dir.y + right * input_dir.x).normalized()

		var current_move_speed : float = maxf((move_speed + move_speed_modifier) * kill_haste_multiplier(), 1.0)
		velocity.x = move_toward(velocity.x, dir.x * current_move_speed, move_acceleration * delta)
		velocity.z = move_toward(velocity.z, dir.z * current_move_speed, move_acceleration * delta)

		if not _is_sliding:
			if not _is_reacting: anim_player.speed_scale = move_anim_speed
			var local_y := input_dir.y
			if local_y > 0.0: _change_state("standing_run_back")
			else: _change_state("standing_run_forward")

		_idle_timer = 0.0

	else:
		velocity.x = move_toward(velocity.x, 0.0, move_deceleration * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_deceleration * delta)

		if not _is_sliding and not _is_attacking and not _is_kicking:
			if not _is_reacting: anim_player.speed_scale = idle_anim_speed
			_idle_timer += delta
			if _idle_timer >= idle_return_delay: _change_state(_get_idle_state())


func _handle_slide(delta: float) -> void:
	if not InputMap.has_action("jump"):
		return

	if Input.is_action_just_pressed("jump") and not _is_sliding \
			and not _is_dead and not _is_blocking and is_on_floor():
		_start_slide()

	if _is_sliding:
		_slide_timer += delta
		var progress : float = clampf(_slide_timer / _slide_duration, 0.0, 1.0)

		# Quadratic deceleration: fast lunge at the start, smooth halt at the end.
		var spd : float = slide_power * (1.0 - progress) * (1.0 - progress)
		velocity.x = _slide_direction.x * spd
		velocity.z = _slide_direction.z * spd

		# Camera lunge lift — rises quickly at the start then fades.
		if progress < 0.2:
			_slide_cam_lift = lerpf(_slide_cam_lift, 0.08, delta * 20.0)

		_check_slide_knockback()

		if progress >= 1.0:
			_is_sliding = false
			_slide_timer = 0.0
			velocity.x   = 0.0
			velocity.z   = 0.0
			_slide_knocked_enemies.clear()
			_slide_kicked_props.clear()
			_change_state(_get_idle_state())


func _start_slide() -> void:
	if _is_attacking:
		_is_attacking = false
		_set_weapon_hitbox_active(false)
		anim_player.speed_scale = 1.0
	if _is_kicking:
		_is_kicking = false
		_set_kick_hitbox_active(false)
		anim_player.speed_scale = 1.0

	# Slide backward — opposite of the look direction (+Z in Godot's coordinate system).
	_slide_direction = Vector3(sin(_yaw), 0.0, cos(_yaw))
	_is_sliding      = true
	_slide_timer     = 0.0
	# Duration so total distance ≈ slide_distance_clear. With quadratic decel the
	# integral of (1-t)^2 over [0,1] is 1/3, so: distance = power * duration / 3.
	_slide_duration  = 3.0 * slide_distance_clear / maxf(slide_power, 0.1)
	_slide_cam_lift  = 0.0
	_slide_knocked_enemies.clear()
	_slide_kicked_props.clear()


func _check_slide_knockback() -> void:
	var my_pos : Vector3 = global_position

	# Only knock one enemy per slide so the player doesn't chain-stun an entire room.
	if _slide_knocked_enemies.size() < 1:
		for node in get_tree().get_nodes_in_group("enemies"):
			if not (node is Node3D) or not is_instance_valid(node):
				continue
			var enemy : Node3D = node as Node3D
			if enemy.get("_is_dead"):
				continue
			if my_pos.distance_to(enemy.global_position) > slide_knock_radius:
				continue
			if _slide_knocked_enemies.has(enemy):
				continue

			if enemy.has_method("take_knockback"):
				enemy.take_knockback(_slide_direction, kick_force, 1.0)
			_slide_knocked_enemies.append(enemy)

			# Shorten remaining travel to slide_distance_hit after the bump.
			_slide_duration = _slide_timer + 3.0 * slide_distance_hit / maxf(slide_power, 0.1)

	# Kickable props in the slide's radius take the same impulse treatment: every prop once per
	# slide (kicking a whole pile of barrels on a good slide is intended), so one prop's loot
	# roll is not re-rolled on every tick it stays in range.
	for prop in get_tree().get_nodes_in_group("kickable_prop"):
		if not (prop is Node3D) or not is_instance_valid(prop):
			continue
		var prop_node : Node3D = prop as Node3D
		if my_pos.distance_to(prop_node.global_position) > slide_knock_radius:
			continue
		if _slide_kicked_props.has(prop_node):
			continue
		if prop_node.has_method("apply_kick"):
			prop_node.apply_kick(_slide_direction, kick_force * 10.0)
			_slide_kicked_props.append(prop_node)


func _set_weapon_hitbox_active(active: bool) -> void:
	if weapon_hitbox == null: return
	weapon_hitbox.set_deferred("monitoring", active)
	weapon_hitbox.set_deferred("monitorable", active)


func _set_kick_hitbox_active(active: bool) -> void:
	if kick_hitbox == null: return
	kick_hitbox.set_deferred("monitoring", active)
	kick_hitbox.set_deferred("monitorable", active)


func _do_attack() -> void:
	_is_attacking = true
	_hit_targets.clear()
	anim_player.speed_scale = attack_speed_scale * attack_speed
	_play_anim(pick_attack())
	_set_weapon_hitbox_active(true)

	# Seek past wind-up to start time, stop at end time (player only — AI does not seek).
	var seek_offset : float = 0.0
	var end_time    : float = 0.0
	match anim_player.current_animation:
		"StandingMeleeAttack360High":
			seek_offset = 0.8667; end_time = 1.1333
			anim_player.seek(seek_offset, true)
		"StandingMeleeAttackBackhand":
			seek_offset = 0.9667; end_time = 1.2333
			anim_player.seek(seek_offset, true)
		"StandingMeleeAttackVer":
			seek_offset = 0.9333; end_time = 2.7667
			anim_player.seek(seek_offset, true)
		"StandingMeleeAttacksidetoSide":
			seek_offset = 0.92; end_time = 1.7333
			anim_player.seek(seek_offset, true)
		_:
			end_time = _current_anim_length()

	var duration  : float = maxf(end_time - seek_offset, 0.1)
	var wait_time : float = maxf((duration / attack_speed_scale) - 0.15, 0.05)
	await get_tree().create_timer(wait_time).timeout

	if _rapid_attack_active or _is_dead:
		return

	_set_weapon_hitbox_active(false)
	if _is_attacking:
		anim_player.speed_scale = 1.0
		_is_attacking = false
		_hit_targets.clear()
		_change_state(_get_idle_state())


func _apply_kick_to_nearby_props() -> void:
	var my_pos : Vector3 = global_position
	var forward := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
	var fwd2 : Vector2 = Vector2(forward.x, forward.z).normalized()
	const KICK_REACH : float = 2.0
	const FWD_ARC_COS : float = 0.5   # cos(60°) → ~120° total arc
	for prop in get_tree().get_nodes_in_group("kickable_prop"):
		if not (prop is Node3D) or not is_instance_valid(prop):
			continue
		var prop_node : Node3D = prop as Node3D
		if not prop_node.has_method("apply_kick"):
			continue
		var to_prop : Vector3 = prop_node.global_position - my_pos
		var horiz : Vector2 = Vector2(to_prop.x, to_prop.z)
		var dist : float = horiz.length()
		if dist > KICK_REACH or dist < 0.01:
			continue
		if (horiz / dist).dot(fwd2) < FWD_ARC_COS:
			continue
		prop_node.apply_kick(forward, kick_force * 12.0)


func _do_kick() -> void:
	_is_kicking = true
	_hit_targets.clear()
	if kick_sound != null and has_node("/root/AudioManager"):
		AudioManager.play_one_shot(kick_sound, 4.0, randf_range(0.7, 0.85))
	anim_player.speed_scale = kick_speed_scale
	_play_anim("kick")

	# Seek past kick wind-up, stop at marked end frame.
	const KICK_SEEK : float = 0.5
	const KICK_END  : float = 1.0333
	anim_player.seek(KICK_SEEK, true)

	_set_kick_hitbox_active(true)
	# Proximity scan so the kick connects with kickable props even if the hitbox
	# Area3D passes above them. Vertical distance is ignored — horizontal
	# reach + forward arc only. Enemies still go through the Area3D path.
	_apply_kick_to_nearby_props()
	var duration  : float = maxf(KICK_END - KICK_SEEK, 0.1)
	var wait_time : float = maxf((duration / kick_speed_scale) - 0.15, 0.05)
	await get_tree().create_timer(wait_time).timeout

	_set_kick_hitbox_active(false)
	if _is_kicking:
		anim_player.speed_scale = 1.0
		_is_kicking = false
		_hit_targets.clear()
		_change_state(_get_idle_state())


func _do_aoe() -> void:
	if not PlayerWallet.spend_potions(1): return
	if _is_attacking:
		_is_attacking = false
		_set_weapon_hitbox_active(false)
	if _is_kicking:
		_is_kicking = false
		_set_kick_hitbox_active(false)
	_hit_targets.clear()

	_is_attacking = true
	_aoe_cooldown = AOE_COOLDOWN_TIME
	velocity.x = 0.0
	velocity.z = 0.0

	if aoe_blast_sound != null and has_node("/root/AudioManager"):
		AudioManager.play_one_shot(aoe_blast_sound, 2.0, 1.0)

	_play_anim("block_react")
	var raw_len := _current_anim_length()
	anim_player.speed_scale = (raw_len / AOE_DURATION) if raw_len > 0.0 else 1.0

	var radius : float = aoe_base_radius * (1.0 + aoe_radius_bonus)
	var dome := _build_aoe_dome(radius)

	var end_time : int = Time.get_ticks_msec() + int(AOE_DURATION * 1000.0)
	while Time.get_ticks_msec() < end_time:
		if _is_dead: break
		_aoe_kill_in_radius(radius)
		await get_tree().create_timer(0.1).timeout

	if is_instance_valid(dome):
		dome.queue_free()
		if aoe_blast_sound != null and has_node("/root/AudioManager"):
			AudioManager.play_one_shot(aoe_blast_sound, -2.0, 0.6)

	if _is_attacking:
		anim_player.speed_scale = 1.0
		_is_attacking = false
		_change_state(_get_idle_state())


func _build_aoe_dome(radius: float) -> MeshInstance3D:
	var mesh_inst := MeshInstance3D.new()
	var mesh_sphere := SphereMesh.new()
	mesh_sphere.radius = radius; mesh_sphere.height = radius * 2.0; mesh_sphere.radial_segments = 32; mesh_sphere.rings = 16
	mesh_inst.mesh = mesh_sphere
	var shader := Shader.new()
	shader.code = "shader_type spatial;\nrender_mode blend_add, cull_disabled, unshaded;\n\nvec3 hsv2rgb(float h, float s, float v) {\n\tvec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);\n\tvec3 p = abs(fract(vec3(h) + K.xyz) * 6.0 - K.www);\n\treturn v * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), s);\n}\n\nvoid fragment() {\n\tfloat hue = fract(UV.x + UV.y * 0.5 + TIME * 0.8);\n\tvec3 rgb = hsv2rgb(hue, 0.85, 1.0);\n\tfloat pulse = 0.25 + 0.1 * sin(TIME * 4.0);\n\tALBEDO = rgb;\n\tALPHA = pulse;\n\tEMISSION = rgb * 1.5;\n}\n"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mesh_inst.material_override = mat
	get_parent().add_child(mesh_inst)
	mesh_inst.global_position = global_position
	return mesh_inst


func _aoe_kill_in_radius(radius: float) -> void:
	var sq_radius : float = radius * radius
	for enemy_node in get_tree().get_nodes_in_group("enemy"):
		if not (enemy_node is Node3D):
			continue
		var enemy : Node3D = enemy_node
		if is_instance_valid(enemy) and not enemy.get("_is_dead"):
			var target_pos : Vector3 = enemy.global_position + Vector3(0, 1.0, 0)
			var my_pos     : Vector3 = global_position + Vector3(0, 1.0, 0)
			if my_pos.distance_squared_to(target_pos) <= sq_radius:
				if enemy.has_method("take_damage"):
					enemy.take_damage(999999999.0, self)


func _process(_delta: float) -> void:
	if mesh_root != null and mesh_root.position != Vector3.ZERO: mesh_root.position = Vector3.ZERO


# ══════════════════════════════════════════════════════════════
#  STATUS EFFECTS (TRAP SYSTEM)
# ══════════════════════════════════════════════════════════════

# days_duration: for the day-based effects it is the number of in-game days; for "acid_pool" it is
# the duration in SECONDS (0 = default 15). strength: acid damage per second (0 = default 1.0).
func apply_status(effect_name: String, days_duration: int, strength: float = 0.0) -> void:
	match effect_name:
		"reversed_view":
			# Timer-based like Intoxicated (and the same length); the day count argument is ignored. Re-applying refreshes it.
			_status_reversed_view       = true
			_status_reversed_view_timer = STATUS_REVERSED_VIEW_SECONDS
		"heavy_gravity":
			if not _status_heavy_gravity:
				_status_heavy_gravity    = true
				slide_power             *= 0.5
				_status_day_effects_days = maxi(_status_day_effects_days, days_duration)
			if not GameClock.day_changed.is_connected(_on_day_changed):
				GameClock.day_changed.connect(_on_day_changed)
		"drunk":
			_status_drunk       = true
			_status_drunk_timer = STATUS_DRUNK_SECONDS   # Tracked float replaces fire-and-forget timer
		"reversed_controls":
			_status_reversed_controls = true
			_status_controls_timer    = 30.0
		"acid_pool":
			_status_acid       = true
			_status_acid_timer = float(days_duration) if days_duration > 0 else 15.0
			_status_acid_dps   = strength if strength > 0.0 else 1.0

	# Show the label immediately when an effect is applied.
	_refresh_status_label()


# Builds the active trap effects text and shows/hides the panel.
# Each active effect gets one line with its name and remaining duration.
# Called immediately on apply_status and throttled in _physics_tick for countdowns.
func _refresh_status_label() -> void:
	if _status_label == null or _status_panel == null:
		return

	var lines : Array[String] = []

	if _status_reversed_view:
		lines.append("Vision Reversed  (%.0fs)" % maxf(_status_reversed_view_timer, 0.0))

	if _status_heavy_gravity:
		lines.append("Heavy Gravity  (%d day%s)" % [
			_status_day_effects_days,
			"s" if _status_day_effects_days != 1 else ""])

	if _status_drunk:
		lines.append("Disoriented  (%.0fs)" % _status_drunk_timer)

	if _status_reversed_controls:
		lines.append("Controls Reversed  (%.0fs)" % _status_controls_timer)

	if _status_acid:
		lines.append("Acid Burn  (%.0fs)" % _status_acid_timer)

	if lines.is_empty():
		_status_panel.visible = false
	else:
		_status_label.text    = "\n".join(lines)
		_status_panel.visible = true


# Ends every timed trap status at once (death: the screen must not stay upside-down / swaying behind the death overlay,
# and nothing may carry into whatever comes next). Day-based Heavy Gravity is restored here too.
func clear_timed_statuses() -> void:
	_status_reversed_view       = false
	_status_reversed_view_timer = 0.0
	_status_drunk               = false
	_status_drunk_timer         = 0.0
	_status_reversed_controls   = false
	_status_controls_timer      = 0.0
	_status_acid                = false
	_status_acid_timer          = 0.0
	if _status_heavy_gravity:
		_status_heavy_gravity = false
		slide_power           *= 2.0
	_status_day_effects_days = 0
	if GameClock.day_changed.is_connected(_on_day_changed):
		GameClock.day_changed.disconnect(_on_day_changed)
	_refresh_status_label()


func _on_day_changed(_day: int) -> void:
	_status_day_effects_days -= 1
	if _status_day_effects_days <= 0:
		if _status_heavy_gravity:
			_status_heavy_gravity = false
			slide_power           *= 2.0
		_status_day_effects_days = 0
		if GameClock.day_changed.is_connected(_on_day_changed):
			GameClock.day_changed.disconnect(_on_day_changed)
	_refresh_status_label()


func _get_effective_move_speed() -> float:
	return maxf((move_speed + move_speed_modifier) * kill_haste_multiplier(), 1.0)


func _get_footstep_stream() -> AudioStream:
	return preload("res://Music & background images/single footstep.mp3")


func _is_pause_event(event: InputEvent) -> bool:
	if event.is_action_pressed("ui_menu") or event.is_action_pressed("ui_cancel"): return true
	return event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE


func _is_pause_menu_open() -> bool:
	return bool(pause_menu.call("is_menu_open")) if pause_menu != null and pause_menu.has_method("is_menu_open") else get_tree().paused


func _pause_game() -> void:
	_stop_footsteps()
	if pause_menu != null and pause_menu.has_method("open_menu"): pause_menu.call("open_menu")
	else: get_tree().paused = true; Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _resume_game() -> void:
	if pause_menu != null and pause_menu.has_method("close_menu"): pause_menu.call("close_menu")
	else: get_tree().paused = false; Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _smooth_turn(_delta: float) -> void:
	pass

func anim_trigger_swing_sound() -> void:
	if swing_sound != null and has_node("/root/AudioManager"):
		AudioManager.play_one_shot(swing_sound, -2.0, randf_range(0.9, 1.1))

func anim_trigger_hitbox_on() -> void:
	_hit_targets.clear(); _set_weapon_hitbox_active(true)
	_fire_swing_sparks()

func anim_trigger_hitbox_off() -> void:
	_set_weapon_hitbox_active(false)
