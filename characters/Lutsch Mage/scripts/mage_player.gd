# ============================================================
#  FILE: mage_player.gd
#  PATH: res://characters/Lutsch Mage/scripts/mage_player.gd
#  ATTACHED TO: res://characters/Lutsch Mage/scenes/mage_player.tscn
#  USED BY: character_base.gd, mage_base.gd
#  NOTES:
#  Player controller for the mage. Ranged magic attacks spawn
#  from hand Marker3D nodes. No melee weapons or kicks.
#  MOD NOTES:
#  - SURGICAL FIX (Item #3): Fireballs now collide with World (Layer 1) 
#    and Enemies (Layer 2). Added _spawn_impact_particles() to generate 
#    a secondary explosion effect when hitting walls or enemies.
#  - SURGICAL REPLACE: _spawn_projectile() placeholder (cone-damage system)
#    replaced with a real runtime fireball. Fireball is an Area3D built
#    entirely in code — no separate scene file needed.
#  - Spawns from get_spawn_position_right() for 1H attacks, both hands for 2H.
#  - Travels via coroutine at fireball_speed m/s. Despawns at spell_range
#    metres or on first body_entered hit.
#  - Particles: fire_01 core (omnidirectional) + trace_03 trail (streaming).
#    All texture paths exported for Inspector tuning.
#  - spell_cone_degrees kept for Inspector compatibility (unused by fireball).
#  - SURGICAL FIX: Removed lambda physics connections entirely to eliminate 
#    Godot 4's "Lambda capture freed" engine spam. Connections now bind a 
#    unique string ID and call _on_fireball_hit() safely.
#  - SURGICAL FIX: Replaced SceneTree timers for particle cleanup with 
#    child Timer nodes to avoid detached callable errors.
#  - SURGICAL ADD: Dynamically loads and attaches loading_screen.gd instantly on ready.
#  - SURGICAL PIVOT: Applied 1st person movement logic (removed velocity locks, jump anims).
#  - SURGICAL PIVOT: Added recovery cancel buffers to attacks to eliminate lag.
#  - SURGICAL PIVOT: Added camera head bob logic driven by horizontal speed.
#  - SURGICAL PIVOT: Upgraded directional block to hold at 50% while button is pressed.
#  - SURGICAL PIVOT: Added block knockback physics and hit grunt audio to take_damage().
# ============================================================

extends BruteCharacter

# ── Movement ───────────────────────────────────────────────────
@export var move_speed         : float = 7.0
@export var move_acceleration  : float = 40.0
@export var move_deceleration  : float = 28.0

# ── Slide (Evade) ───────────────────────────────────────────────
@export var slide_power          : float = 20.0 # Peak launch speed (m/s) — higher = shorter re-fire gap
@export var slide_distance_clear : float = 5.0  # Distance when no enemy contact (m)
@export var slide_distance_hit   : float = 2.5  # Distance after bumping an enemy (m)
@export var slide_knock_radius   : float = 1.5  # Knockback detection radius (m)

# ── Camera ─────────────────────────────────────────────────────
@export var mouse_sensitivity  : float = 0.0025
@export var gamepad_turn_speed : float = 3.0
@export var look_deadzone      : float = 0.08
@export var move_deadzone      : float = 0.08
@export var idle_return_delay  : float = 0.15

# ── Animation speed ────────────────────────────────────────────
@export var idle_anim_speed    : float = 1.0
@export var move_anim_speed    : float = 1.0
@export var attack_speed_scale : float = 3.5
@export var block_anim_speed   : float = 1.5

# ── Combat ─────────────────────────────────────────────────────
@export var spell_damage       : float = 37.5  # 1.5× brute axe swing (25×1.5)
@export var spell_range        : float = 15.0
@export var spell_cone_degrees : float = 30.0  # Kept for Inspector compatibility
@export var block_knockback_force : float = 18.0 # Speed player slides back when blocking a hit

# ── Shove (right bumper — 2H animation as melee push) ─────────
@export var shove_damage    : float = 15.0   # = brute kick_damage
@export var shove_force     : float = 9.0    # knockback impulse
@export var shove_stun_time : float = 3.0    # seconds target is stunned
@export var shove_range     : float = 2.5    # metres — same as melee reach

# ── Fireball projectile settings (SURGICAL ADD) ───────────────
# Tune these in the Inspector without touching code.
@export var fireball_speed            : float = 14.0  # Travel speed in m/s
@export var fireball_collision_radius : float = 0.35  # Hit detection sphere radius
@export var tex_fireball_core  : String = "res://addons/kenney_particle_pack/fire_01.png"
@export var tex_fireball_trail : String = "res://addons/kenney_particle_pack/trace_03.png"
@export var fireball_cast_sound : AudioStream  # Drag a crackle/zap SFX here in the Inspector

# ── Lightning Dome (AOE — spends 1 potion) ──────────────────────
const DOME_COOLDOWN_TIME    : float = 2.5
@export var dome_bolt_count : int   = 12   # Bolts fired radially; +2 per Magnitude perk level

# ── Lightning Rapid Attack ────────────────────────────────────────────
@export var rapid_attack_charge_time     : float = 1.5   # Seconds to fill the charge bar
@export var rapid_attack_duration        : float = 4.0   # Seconds the rapid attack lasts
@export var rapid_attack_cooldown        : float = 30.0  # Seconds before rapid attack can recharge
@export var rapid_attack_attack_rate     : float = 0.12  # Seconds between bolts — ~8 Hz single-bolt machine gun

# ── Hand spawn points (formerly from MageCharacter / mage_base.gd) ────────────
# Assign Marker3D nodes in the Inspector — projectiles spawn from these.
@export var right_hand_marker : Marker3D
@export var left_hand_marker  : Marker3D

# ── Node references ────────────────────────────────────────────
@onready var spring_arm : SpringArm3D = get_node_or_null("SpringArm3D")
@onready var pause_menu : CanvasLayer = get_node_or_null("../pause_menu_function")

# ── Runtime state ──────────────────────────────────────────────
var _yaw          : float = 0.0
var _idle_timer   : float = 0.0
var _is_attacking : bool  = false

# ── Slide (Evade) state ────────────────────────────────────────
var _is_sliding            : bool    = false
var _slide_timer           : float   = 0.0
var _slide_duration        : float   = 0.0
var _slide_direction       : Vector3 = Vector3.ZERO
var _slide_cam_lift        : float   = 0.0
var _slide_knocked_enemies : Array   = []

# ── Rapid Attack / storm state ──────────────────────────────────────
var _attack_held             : bool    = false
var _rapid_attack_charge          : float   = 0.0
var _rapid_attack_active          : bool    = false
var _rapid_attack_timer           : float   = 0.0
var _rapid_attack_cooldown_remain : float   = 0.0
var _rapid_attack_attack_timer    : float   = 0.0
var _rapid_attack_bar_bg          : ColorRect = null
var _rapid_attack_bar_fill        : ColorRect = null
var _rapid_attack_bar_label       : Label     = null

# ── Dome state ─────────────────────────────────────────────────
var _dome_cooldown : float = 0.0

# ── Buff stats (modified by BuffManager via player.set()) ───────────────────
# attack_speed: multiplier stacked on attack_speed_scale (Swift Strikes, etc.)
# attack_damage: flat additive bonus/penalty to spell_damage (Berserker, Blunted, etc.)
var attack_speed  : float = 1.0
var attack_damage : float = 0.0

# ── Status effects (from booby traps) ──────────────────────────────────────
var _status_reversed_view     : bool  = false
var _status_heavy_gravity     : bool  = false
var _status_drunk             : bool  = false
var _status_reversed_controls : bool  = false
var _status_acid              : bool  = false
var _status_acid_timer        : float = 0.0
var _status_acid_dps          : float = 1.0   # Set by the trap (TrapManager.acid_damage_per_sec)
# Tracked timers (the brute's pattern) instead of fire-and-forget SceneTree timers: re-applying an
# effect refreshes it, and the countdown pauses with the game.
var _status_drunk_timer       : float = 0.0
# On-screen list of active trap effects (same panel the Barbarian has): the trap banner only
# flashes at trigger time, and day-long effects (reversed view, heavy gravity) would otherwise be
# invisible afterwards.
var _status_label             : Label   = null
var _status_panel             : Control = null
var _status_update_timer      : float   = 0.0
const STATUS_UPDATE_INTERVAL  : float   = 0.5
var _status_controls_timer    : float = 0.0
var _status_day_effects_days  : int   = 0
var passive_regen             : float = 0.0   # HP/sec from Regeneration perk

# ── On-kill buff stats (mirror brute_player's set) ──────────────────────────
# BuffManager sets these by name, same as brute.  Mage doesn't inherit
# brute_player.gd so they must be declared here explicitly.
var health_on_kill        : float = 0.0  # Vampiric / Vampire Lord
var currency_on_kill      : float = 0.0  # Soul Harvester
var spark_damage          : float = 0.0  # Spark Fury: AOE at kill site
var spark_light_radius    : float = 0.0  # Radiant Sparks: kill flash range bonus
var spark_brightness      : float = 0.0  # Bright Carnage: kill flash intensity
var attack_speed_streak   : float = 0.0  # Battle Hunger: +N% per 5-kill tier
var poison_on_kill_chance : float = 0.0  # Plague Spreader
# low_health_damage is inherited from CharacterBase — do not redeclare here.

# ── Kill tracking (mage has no streak-fire system; tracks for stat effects only) ─
var _kill_streak          : int   = 0
var _last_kill_count      : int   = 0
var _streak_attack_bonus  : float = 0.0

# ── Fireball spawn point ────────────────────────────────────────
# Cached at _on_ready(). Fires from StaffTip Marker3D when present,
# falls back to mixamorigRightHand bone, then to a chest-height fallback.
var _skeleton              : Skeleton3D = null
var _right_hand_bone_idx   : int        = -1
var _staff_tip             : Node3D     = null   # Marker3D on the staff end

# ── Crosshair ──────────────────────────────────────────────────
# Persistent yellow dot at screen centre showing where fireballs will hit.
var _crosshair_layer       : CanvasLayer = null

# ── Health bar HUD ─────────────────────────────────────────────
var _health_bar_bg   : ColorRect = null
var _health_bar_fill : ColorRect = null
var _health_label    : Label     = null

# ── Damage vignette ────────────────────────────────────────────
# Full-screen red overlay that pulses on damage and fades out over ~0.8 s.
# Mirrors the Brute's vignette so both players get the same feedback.
@export var vignette_peak_alpha : float = 0.32
@export var vignette_fade_speed : float = 0.9
var _damage_vignette : ColorRect = null
var _vignette_alpha  : float     = 0.0

# ── HUD ────────────────────────────────────────────────────────
# Health bar removed — mage uses a separate world-space health indicator.
# Legacy brute-style HUD variables stripped here.

# ── Audio Streams ──────────────────────────────────────────────
@export var hit_grunt_sound: AudioStream # Drag your hit react sound here in the inspector
var block_sound: AudioStream = preload("res://Music & background images/Sound Effects/axe blocked.mp3")

# ══════════════════════════════════════════════════════════════
#  SETUP
# ══════════════════════════════════════════════════════════════

func _on_ready() -> void:
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

	# ── Near-clip arms visibility ──────────────────────────────────────────────
	# Camera sits inside the chest. With back-face culling the body mesh surfaces
	# are invisible from inside (normals face outward = away from camera = culled).
	# Arms extend forward ~0.4m+ and are front-face visible. A 0.12m near-clip
	# discards any stray geometry right at the camera lens so there are no z-fight
	# artifacts at the camera origin. Do NOT move the mesh to layer 2 — that hides
	# the arms too.
	if camera_3d != null:
		camera_3d.near = 0.12
	# find_child searches the entire subtree, so it reaches the Skeleton3D inside
	# Brute/Node/ without needing a hardcoded path.
	_skeleton = find_child("Skeleton3D", true, false) as Skeleton3D
	if _skeleton != null:
		_right_hand_bone_idx = _skeleton.find_bone("mixamorigRightHand")
		if _right_hand_bone_idx < 0:
			push_warning("MagePlayer: 'mixamorigRightHand' bone not found — fireball will spawn from fallback position.")
	else:
		push_warning("MagePlayer: Skeleton3D not found — fireball will spawn from fallback position.")

	# Cache the staff tip spawn point. Falls back to right-hand bone if not found.
	_staff_tip = find_child("magic spawn point", true, false) as Node3D

	# ── AnimationPlayer: direct path override ──────────────────────────────────
	# _find_anim_player() does depth-first search and can land on a prop's empty
	# AP (e.g. staff FBX) before reaching the brute's real one.  Pin it by path.
	var brute_ap := get_node_or_null("Mesh/Brute/AnimationPlayer") as AnimationPlayer
	if brute_ap != null:
		anim_player = brute_ap
		_anim_map   = _get_animation_map()   # re-cache against the correct player
	else:
		push_warning("MagePlayer: Brute AnimationPlayer not found at Mesh/Brute/AnimationPlayer")

	# ── Staff material ─────────────────────────────────────────────────────────
	# The FBX has no embedded material data — apply the 4-map PBR material that
	# lives alongside the FBX in addons/props/.
	const STAFF_MAT : String = "res://addons/props/Staff_material.tres"
	if ResourceLoader.exists(STAFF_MAT):
		var staff_mat : StandardMaterial3D = load(STAFF_MAT)
		var staff_node := find_child("Staff", true, false)
		if staff_node != null:
			_apply_material_recursive(staff_node, staff_mat)

	# ── Persistent yellow crosshair dot ────────────────────────────────────────
	# A small dot centered on screen so the player always knows where the fireball
	# will travel. Layer 10 sits above gameplay geometry but below the loading screen.
	_crosshair_layer = CanvasLayer.new()
	_crosshair_layer.layer = 10
	_crosshair_layer.name  = "CrosshairLayer"
	add_child(_crosshair_layer)

	# ── Health bar ─────────────────────────────────────────────────────────────
	_health_bar_bg          = ColorRect.new()
	_health_bar_bg.color    = Color(0.15, 0.0, 0.0, 0.8)
	_health_bar_bg.size     = Vector2(220.0, 22.0)
	_health_bar_bg.position = Vector2(20.0, 20.0)
	_crosshair_layer.add_child(_health_bar_bg)

	_health_bar_fill          = ColorRect.new()
	_health_bar_fill.color    = Color(0.85, 0.1, 0.1, 1.0)
	_health_bar_fill.size     = Vector2(220.0, 22.0)
	_health_bar_fill.position = Vector2(20.0, 20.0)
	_crosshair_layer.add_child(_health_bar_fill)

	_health_label          = Label.new()
	_health_label.position = Vector2(24.0, 20.0)
	_health_label.add_theme_font_size_override("font_size", 14)
	_health_label.add_theme_color_override("font_color", Color.WHITE)
	_crosshair_layer.add_child(_health_label)

	_refresh_health_bar(max_health, max_health)

	# ── Active trap effects panel (bottom-centre, hidden until an effect is active) ──
	_status_panel = ColorRect.new()
	(_status_panel as ColorRect).color = Color(0.0, 0.0, 0.0, 0.65)
	_status_panel.anchor_left   = 0.5
	_status_panel.anchor_top    = 1.0
	_status_panel.anchor_right  = 0.5
	_status_panel.anchor_bottom = 1.0
	_status_panel.offset_left   = -200.0
	_status_panel.offset_top    = -130.0
	_status_panel.offset_right  =  200.0
	_status_panel.offset_bottom = -80.0
	_status_panel.visible       = false
	_status_panel.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_crosshair_layer.add_child(_status_panel)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_status_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.1, 1.0))
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_panel.add_child(_status_label)
	connect("health_changed", _on_health_changed)

	# ── Damage vignette ────────────────────────────────────────────────────────
	# Sits on top of the health bar and fills the screen on hit.
	_damage_vignette = ColorRect.new()
	_damage_vignette.color = Color(0.85, 0.0, 0.0, 0.0)
	_damage_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_damage_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_crosshair_layer.add_child(_damage_vignette)


	# ── Storm charge / duration bar ─────────────────────────────────────────────
	_rapid_attack_bar_bg          = ColorRect.new()
	_rapid_attack_bar_bg.color    = Color(0.08, 0.08, 0.08, 0.8)
	_rapid_attack_bar_bg.size     = Vector2(220.0, 8.0)
	_rapid_attack_bar_bg.position = Vector2(20.0, 46.0)
	_crosshair_layer.add_child(_rapid_attack_bar_bg)

	_rapid_attack_bar_fill          = ColorRect.new()
	_rapid_attack_bar_fill.color    = Color(0.15, 0.5, 0.85, 0.7)
	_rapid_attack_bar_fill.size     = Vector2(0.0, 8.0)
	_rapid_attack_bar_fill.position = Vector2(20.0, 46.0)
	_crosshair_layer.add_child(_rapid_attack_bar_fill)

	_rapid_attack_bar_label          = Label.new()
	_rapid_attack_bar_label.position = Vector2(20.0, 55.0)
	_rapid_attack_bar_label.add_theme_font_size_override("font_size", 11)
	_rapid_attack_bar_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9, 0.7))
	_crosshair_layer.add_child(_rapid_attack_bar_label)
	_refresh_rapid_attack_bar()

	# SURGICAL ADD: Apply hub-purchased perks from the save profile before the run starts.
	_apply_hub_perks()

	# SURGICAL ADD: Spawn Loading Screen instantly to hide spawn lag
	var loading_script := load("res://scripts/loading_screen.gd")
	if loading_script:
		var screen := CanvasLayer.new()
		screen.set_script(loading_script)
		add_child(screen)


# ══════════════════════════════════════════════════════════════
#  HUB PERK APPLICATION  (SURGICAL ADD)
# ══════════════════════════════════════════════════════════════

# Reads the 9-perk store data from the save profile and applies
# each purchased perk level to the appropriate mage stat.
# Called once at the end of _on_ready() before the run begins.
# Perks that have no mage equivalent yet are stubbed with comments.
func _apply_hub_perks() -> void:
	if SaveManager.current_profile.is_empty():
		return

	var perk_levels : Dictionary = SaveManager.current_profile.get("perks", {})

	# ── Magnitude: +2 dome bolts per level ─────────────────────
	var magnitude_lv : int = int(perk_levels.get("magnitude", 0))
	if magnitude_lv > 0:
		dome_bolt_count += magnitude_lv * 2

	# ── Persistence: spell range +15% per level ────────────────
	# Mapped to spell_range — longer range is the mage equivalent of persistence.
	var persistence_lv : int = int(perk_levels.get("persistence", 0))
	if persistence_lv > 0:
		spell_range *= (1.0 + 0.15 * float(persistence_lv))

	# ── Vitality: max health +10 per level ─────────────────────
	# Both max_health and _current_health are updated so the player
	# starts the run at full health with the boosted maximum.
	# health_changed is emitted so the HUD reflects the new values.
	var vitality_lv : int = int(perk_levels.get("vitality", 0))
	if vitality_lv > 0:
		var bonus : float = 10.0 * float(vitality_lv)
		max_health      += bonus
		_current_health  = max_health
		health_changed.emit(_current_health, max_health)

	# ── Adrenaline: attack speed +8% per level ─────────────────
	var adrenaline_lv : int = int(perk_levels.get("adrenaline", 0))
	if adrenaline_lv > 0:
		attack_speed_scale *= (1.0 + 0.08 * float(adrenaline_lv))

	# ── Ferocity: spell damage +10% per level ──────────────────
	var ferocity_lv : int = int(perk_levels.get("ferocity", 0))
	if ferocity_lv > 0:
		spell_damage *= (1.0 + 0.10 * float(ferocity_lv))

	# ── Scavenge: drop rate +5% per level ──────────────────────
	# STUB: No item drop system exists yet. Implement when drops are added.

	# ── Greed: double-drop chance +10% per level ───────────────
	# STUB: No item drop system exists yet. Implement when drops are added.

	# ── Swiftness: move speed +5% of base per level ────────────
	var swiftness_lv : int = int(perk_levels.get("swiftness", 0))
	if swiftness_lv > 0:
		move_speed += move_speed * 0.05 * float(swiftness_lv)

	# ── Regeneration: +0.5 HP/sec per level ───────────────────
	var health_regen_lv : int = int(perk_levels.get("health_regen", 0))
	if health_regen_lv > 0:
		passive_regen += 0.5 * float(health_regen_lv)


# ══════════════════════════════════════════════════════════════
#  PROCESS
# ══════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	if mesh_root != null:
		mesh_root.position = Vector3.ZERO

	if passive_regen > 0.0 and _current_health < max_health and not _is_dead:
		receive_heal(passive_regen * delta)

	_check_kill_stats()
	_tick_kill_haste(delta)


# Mirrors brute_player._check_kill_streak() for stat effects only.
# The mage has no streak-fire particles, but all buff stats work identically.
func _check_kill_stats() -> void:
	var current := CharacterBase.GLOBAL_KILL_COUNT
	if current <= _last_kill_count:
		return
	var new_kills     := current - _last_kill_count
	_last_kill_count   = current
	_kill_streak      += new_kills

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

	if attack_speed_streak > 0.0:
		var new_bonus : float = attack_speed_streak * int(float(_kill_streak) / 5.0)
		if not is_equal_approx(new_bonus, _streak_attack_bonus):
			attack_speed          += new_bonus - _streak_attack_bonus
			_streak_attack_bonus   = new_bonus


# ══════════════════════════════════════════════════════════════
#  HUD
# ══════════════════════════════════════════════════════════════

# Recursively moves every VisualInstance3D under node to visual layer 2
# and removes it from layer 1, so the camera (cull mask excludes layer 2)
# cannot render the mage's own body. Called once in _on_ready().
func _set_mesh_visual_layer(node: Node) -> void:
	if node is VisualInstance3D:
		node.set_layer_mask_value(1, false)
		node.set_layer_mask_value(2, true)
	for child in node.get_children():
		_set_mesh_visual_layer(child)


func _on_health_changed(new_health: float, max_val: float) -> void:
	_refresh_health_bar(new_health, max_val)


func _refresh_health_bar(current: float, max_val: float) -> void:
	if _health_bar_fill == null:
		return
	var pct : float = clampf(current / max_val, 0.0, 1.0)
	_health_bar_fill.size.x = 220.0 * pct
	_health_bar_fill.color  = Color(0.85, 0.1 + 0.6 * pct, 0.1, 1.0)
	if _health_label != null:
		_health_label.text = "%d / %d" % [int(current), int(max_val)]


# Returns the world-space position of the mixamorigRightHand bone at the current
# animation frame. Falls back to get_spawn_position_right() if the skeleton or
# bone wasn't found (e.g. right_hand_marker is set in the Inspector).
func _get_right_hand_world_pos() -> Vector3:
	if _skeleton != null and _right_hand_bone_idx >= 0:
		# get_bone_global_pose() is in Skeleton3D local space.
		# Multiply by skeleton's world transform to get world space.
		var bone_local : Transform3D = _skeleton.get_bone_global_pose(_right_hand_bone_idx)
		return (_skeleton.global_transform * bone_local).origin
	return get_spawn_position_right()


# Override take_damage to block damage that arrives through solid walls.
# When source_node is provided (melee, shove, etc.) a ray on layer 1 checks
# for geometry between the source and the mage. Null-source hits (fireballs)
# need to be fixed at the fireball scene level — set the fireball scene's
# collision_mask to include layer 1 so fireballs stop at walls.
func take_damage(amount: float, source_node: Node3D = null) -> void:
	if _is_dead:
		return
	if _is_sliding:
		return  # Invincible during the evasive slide.
	if _rapid_attack_active:
		return  # Invincible during rapid attack frenzy.

	if source_node != null:
		var space : PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
		var from  : Vector3 = source_node.global_position + Vector3(0.0, 1.0, 0.0)
		var to    : Vector3 = global_position + Vector3(0.0, 1.0, 0.0)
		var q     : PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to)
		q.collision_mask = 1   # World geometry only
		q.exclude         = [source_node.get_rid(), get_rid()]
		# Only level geometry blocks damage; an ally, prop or chest in the line must not
		# make the mage invulnerable.
		if not PhysicsUtil.ray_world(space, q).is_empty():
			return  # Wall between attacker and mage — damage blocked

	# SURGICAL FIX: Apply front block validation identical to the Brute 
	if _is_blocking and source_node != null:
		var to_source : Vector3 = (source_node.global_position - global_position).normalized()
		var forward   : Vector3 = -global_transform.basis.z.normalized()

		if forward.dot(to_source) > 0.7:
			# Play the block impact and hit react grunts
			if block_sound != null and has_node("/root/AudioManager"):
				AudioManager.play_one_shot(block_sound, 2.0, randf_range(0.9, 1.1))
			if hit_grunt_sound != null and has_node("/root/AudioManager"):
				AudioManager.play_one_shot(hit_grunt_sound, 0.0, randf_range(0.9, 1.1))

			# Calculate horizontal knockback away from the hit
			var push_dir : Vector3 = (global_position - source_node.global_position).normalized()
			push_dir.y = 0.0
			velocity = push_dir * block_knockback_force
			
			# We do not restart the block_react animation here, leaving the shield held high.
			return

	# Flash the red vignette on any damage that isn't fully blocked above.
	_vignette_alpha = minf(_vignette_alpha + 0.28, vignette_peak_alpha)
	if _damage_vignette != null:
		_damage_vignette.color.a = _vignette_alpha
	# Flash the shared damage direction fan (points at the hit source).
	if source_node != null:
		_flash_damage_direction(source_node, _yaw)

	super.take_damage(amount, source_node)


# ══════════════════════════════════════════════════════════════
#  KNOCKBACK WALL-HIT RESPONSE
# ══════════════════════════════════════════════════════════════

func _on_knockback_wall_hit() -> void:
	# React sound + minor impact damage when the mage slides into a wall/enemy
	# during a knockback stun. Fires at most once per knockback event.
	if hit_grunt_sound != null and has_node("/root/AudioManager"):
		AudioManager.play_one_shot(hit_grunt_sound, 0.0, randf_range(0.85, 1.05))
	take_damage(3.0, null)


# ══════════════════════════════════════════════════════════════
#  DEATH
# ══════════════════════════════════════════════════════════════

# Called by BuffManager._finalize_close after the day-change slot machine
# closes. Any in-flight action (attack/kick/shove/slide/block) that was
# mid-await when the tree paused would leave its state flag stuck `true`
# forever — the movement input gate then refuses to respond. This clears
# the lot so the player can always act again after a buff pick, regardless
# of what they were doing when Day-N rolled over.
func _on_buff_pick_finished() -> void:
	_is_attacking = false
	_is_blocking  = false
	_is_sliding   = false
	if anim_player != null:
		anim_player.speed_scale = 1.0
	velocity.x = 0.0
	velocity.z = 0.0


func _on_die() -> void:
	# SURGICAL FIX: Stop the day clock immediately on death so buff picks
	# and day ticks cannot fire after the player is dead.
	if has_node("/root/GameClock"):
		GameClock.hide_hud()

	anim_player.speed_scale = death_anim_speed
	_play_anim(pick_death_direction())
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	var you_died_script := load("res://scripts/you_died_screen.gd")
	if you_died_script:
		var screen := CanvasLayer.new()
		screen.set_script(you_died_script)
		get_tree().root.add_child(screen)


# ══════════════════════════════════════════════════════════════
#  INPUT
# ══════════════════════════════════════════════════════════════

func _unhandled_input(event: InputEvent) -> void:
	if _is_pause_event(event):
		if _is_pause_menu_open():
			_resume_game()
		else:
			_pause_game()
		get_viewport().set_input_as_handled()
		return

	if get_tree().paused:
		return

	# See brute_player.gd: ignore the emulated mouse motion a finger produces (touch look is fed separately).
	if event is InputEventMouseMotion and (event as InputEventMouseMotion).device != InputEvent.DEVICE_ID_EMULATION:
		_yaw -= (event as InputEventMouseMotion).relative.x * mouse_sensitivity

	if event.is_action_pressed("attack") and not _is_attacking and not _is_blocking and not _is_sliding and not _is_dead and not _rapid_attack_active:
		_attack_held = true
		_do_spell_attack()

	if event.is_action_released("attack"):
		_attack_held = false
		if _rapid_attack_charge >= 1.0 and _rapid_attack_cooldown_remain <= 0.0 and not _rapid_attack_active:
			_rapid_attack_charge = 0.0
			_start_mage_rapid_attack()
		else:
			_rapid_attack_charge = 0.0
			_refresh_rapid_attack_bar()

	# AOE: lightning dome — fires bolts in all directions, costs 1 potion.
	if event.is_action_pressed("AOE") and _dome_cooldown <= 0.0 and not _is_dead:
		_do_lightning_dome()

	# Right bumper → 2H shove (Standing2HMagicAttack02).
	# Deals melee damage + knockback to enemies in front within shove_range.
	if event.is_action_pressed("kick") and not _is_attacking and not _is_blocking and not _is_sliding and not _is_dead:
		_do_shove()

	# ── Block — single action on D-pad Down (or right mouse). No rotation;
	# block only applies in the direction the player is already facing.
	if not _is_dead and not _is_blocking:
		if event.is_action_pressed("block"):
			_do_block()


# ══════════════════════════════════════════════════════════════
#  MOVEMENT TICK
# ══════════════════════════════════════════════════════════════

func _physics_tick(delta: float) -> void:
	# Fade damage vignette every tick so it disappears smoothly.
	if _vignette_alpha > 0.0 and _damage_vignette != null:
		_vignette_alpha = maxf(_vignette_alpha - vignette_fade_speed * delta, 0.0)
		_damage_vignette.color.a = _vignette_alpha
	_tick_damage_fan(delta)

	if get_tree().paused:
		# Zero horizontal velocity so character_base.move_and_slide() doesn't
		# slide the player with stale momentum while the tree is paused.
		velocity.x = 0.0
		velocity.z = 0.0
		_stop_footsteps()
		return

	# Blocking check moved before view input so the rotation tween
	# in _do_block() owns rotation.y cleanly.
	if _is_blocking:
		# SURGICAL FIX: This move_toward setup is what automatically stops you smoothly
		# after you get spiked back by the new block knockback logic in take_damage!
		velocity.x = move_toward(velocity.x, 0.0, move_deceleration * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_deceleration * delta)
		move_and_slide()
		_update_footsteps(delta)
		return

	# Fall out of dungeon → instant death.
	if global_position.y < -15.0 and not _is_dead:
		take_damage(max_health + 1.0)

	# ── Status effect ticks ────────────────────────────────────────────────────
	if _status_acid and not _is_dead:
		_status_acid_timer -= delta
		take_damage(_status_acid_dps * delta)
		if _status_acid_timer <= 0.0:
			_status_acid = false
	if _status_drunk and _status_drunk_timer > 0.0:
		_status_drunk_timer -= delta
		if _status_drunk_timer <= 0.0:
			_status_drunk = false
	if _status_reversed_controls and _status_controls_timer > 0.0:
		_status_controls_timer -= delta
		if _status_controls_timer <= 0.0:
			_status_reversed_controls = false
	if _status_drunk or _status_reversed_controls or _status_acid or _status_panel != null and _status_panel.visible:
		_status_update_timer -= delta
		if _status_update_timer <= 0.0:
			_status_update_timer = STATUS_UPDATE_INTERVAL
			_refresh_status_label()

	# ── Dome cooldown ──────────────────────────────────────────────────────────
	if _dome_cooldown > 0.0:
		_dome_cooldown = maxf(_dome_cooldown - delta, 0.0)

	# ── Rapid Attack: charge builds while attack is held ────────────────────────────
	if _attack_held and not _rapid_attack_active:
		_rapid_attack_charge = minf(_rapid_attack_charge + delta / rapid_attack_charge_time, 1.0)
		_refresh_rapid_attack_bar()

	if _rapid_attack_cooldown_remain > 0.0:
		_rapid_attack_cooldown_remain = maxf(_rapid_attack_cooldown_remain - delta, 0.0)
		_refresh_rapid_attack_bar()

	# ── Rapid attack (bolt machine gun) active tick ───────────────────────────
	if _rapid_attack_active:
		# Normal first-person view + movement — player keeps full control.
		# Damage immunity is gated in take_damage via _rapid_attack_active.
		_handle_view_input(delta)
		_apply_view_rotation()
		_handle_movement(delta)
		_update_footsteps(delta)
		_apply_head_bob(delta)

		_rapid_attack_timer        -= delta
		_rapid_attack_attack_timer -= delta

		if _rapid_attack_attack_timer <= 0.0:
			_rapid_attack_attack_timer = rapid_attack_attack_rate
			_fire_rapid_attack_bolts()

		_refresh_rapid_attack_bar()

		if _rapid_attack_timer <= 0.0 or _is_dead:
			_end_mage_rapid_attack()
		return

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


func _handle_view_input(delta: float) -> void:
	var look_x : float = Input.get_axis("look_left", "look_right")
	if _status_reversed_controls:
		look_x = -look_x
	if abs(look_x) >= look_deadzone:
		_yaw -= look_x * gamepad_turn_speed * delta


func _apply_view_rotation() -> void:
	var yaw_out : float = _yaw
	if _status_drunk:
		yaw_out += sin(Time.get_ticks_msec() * 0.002) * 0.18
	rotation.y = yaw_out
	var arm : SpringArm3D = get_node_or_null("SpringArm3D") as SpringArm3D
	if arm != null:
		arm.rotation.x = PI if _status_reversed_view else 0.0


func _handle_movement(delta: float) -> void:
	# SURGICAL FIX: Commented out for 1st person pivot to allow free movement during casting/shoving
	# if _is_blocking:
	# 	velocity.x = move_toward(velocity.x, 0.0, move_deceleration * delta)
	# 	velocity.z = move_toward(velocity.z, 0.0, move_deceleration * delta)
	# 	return

	var input_dir : Vector2 = Vector2(
		Input.get_axis("move_left",    "move_right"),
		Input.get_axis("move_forward", "move_back")
	)
	if _status_reversed_controls:
		input_dir = -input_dir

	if input_dir.length() >= move_deadzone:
		input_dir = input_dir.normalized()

		var forward : Vector3 = Vector3(-sin(_yaw), 0.0, -cos(_yaw))
		var right   : Vector3 = Vector3( cos(_yaw), 0.0, -sin(_yaw))
		var dir     : Vector3 = (forward * -input_dir.y + right * input_dir.x).normalized()

		var haste : float = kill_haste_multiplier()
		var target_velocity_x : float = dir.x * move_speed * haste
		var target_velocity_z : float = dir.z * move_speed * haste

		velocity.x = move_toward(velocity.x, target_velocity_x, move_acceleration * delta)
		velocity.z = move_toward(velocity.z, target_velocity_z, move_acceleration * delta)

		if not _is_sliding and not _is_attacking:
			if not _is_reacting:
				anim_player.speed_scale = move_anim_speed

			var local_y : float = input_dir.y
			if local_y > 0.0:
				_change_state("standing_run_back")
			else:
				_change_state("standing_run_forward")

		_idle_timer = 0.0

	else:
		velocity.x = move_toward(velocity.x, 0.0, move_deceleration * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_deceleration * delta)

		if not _is_sliding and not _is_attacking and not _is_blocking:
			if not _is_reacting:
				anim_player.speed_scale = idle_anim_speed

			_idle_timer += delta
			if _idle_timer >= idle_return_delay:
				_change_state(_get_idle_state())


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
			_change_state(_get_idle_state())


func _start_slide() -> void:
	if _is_attacking:
		_is_attacking = false
		anim_player.speed_scale = 1.0
	if _is_blocking:
		_is_blocking = false
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


func _check_slide_knockback() -> void:
	# Only knock one enemy per slide so the player doesn't chain-stun an entire room.
	if _slide_knocked_enemies.size() >= 1:
		return

	var my_pos : Vector3 = global_position
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
			enemy.take_knockback(_slide_direction, 8.0, 1.0)
		_slide_knocked_enemies.append(enemy)

		# Shorten remaining travel to slide_distance_hit after the bump.
		_slide_duration = _slide_timer + 3.0 * slide_distance_hit / maxf(slide_power, 0.1)
		break

	# Kickable props in the slide radius — no per-slide cap, kick each one.
	for prop in get_tree().get_nodes_in_group("kickable_prop"):
		if not (prop is Node3D) or not is_instance_valid(prop):
			continue
		var prop_node : Node3D = prop as Node3D
		if my_pos.distance_to(prop_node.global_position) > slide_knock_radius:
			continue
		if prop_node.has_method("apply_kick"):
			prop_node.apply_kick(_slide_direction, shove_force * 10.0)


# ══════════════════════════════════════════════════════════════
#  SPELL ATTACK
# ══════════════════════════════════════════════════════════════

func _do_spell_attack() -> void:
	_is_attacking = true

	# Direct play — bypass _play_anim lookup chain entirely.
	# Timestamps 0.84–1.05 are tuned for StandingMeleeAttackVer.
	# Running at 1.2× speed so the 0.21 s window becomes 0.175 s real time.
	anim_player.speed_scale = 1.2
	anim_player.play("StandingMeleeAttackVer")
	anim_player.seek(0.84, true)

	# ── Phase 2: let the arm swing to the cast pose at 1.05 s ─────────────────
	# 0.21 s of animation time ÷ 1.2 speed = 0.175 s real time.
	await get_tree().create_timer(0.175).timeout

	if not _is_dead and _is_attacking:
		# ── Phase 3: freeze at the cast pose ───────────────────────────────────
		anim_player.pause()

		# ── Phase 4: fire from the staff tip, aim at crosshair ─────────────────
		var spawn_pos : Vector3
		if _staff_tip != null:
			spawn_pos = _staff_tip.global_position
		else:
			spawn_pos = _get_right_hand_world_pos()

		# Travel in the exact direction the camera is looking.
		# Bolt starts at the staff tip but flies parallel to the line of sight,
		# so it always appears to go straight out from the crosshair.
		var aim_dir : Vector3
		if camera_3d != null:
			aim_dir = camera_3d.project_ray_normal(get_viewport().size / 2.0)
		else:
			aim_dir = Vector3(-sin(_yaw), 0.0, -cos(_yaw))

		_launch_fireball(spawn_pos, aim_dir)

		# Hold the cast pose so the player sees the bolt leave.
		await get_tree().create_timer(0.35).timeout

	if _is_attacking:
		# ── Phase 5: rewind to 0.84 (arm-raised rest) then return idle ─────────
		anim_player.speed_scale = 1.0
		anim_player.seek(0.84, true)
		await get_tree().create_timer(0.12).timeout

	if _is_attacking:
		anim_player.speed_scale = 1.0
		_is_attacking = false
		_change_state(_get_idle_state())


# Launches one fireball from the right hand (and one from the left
# for two-handed attacks). Each fireball is fully self-contained.
func _spawn_projectile(two_handed: bool) -> void:
	# Compute the reticle target point (far end of the camera's aim ray).
	# Each bolt then points FROM its own spawn position TOWARD that target,
	# so both hands converge on the same crosshair point rather than travelling
	# in parallel with a parallax gap between them.
	var aim_target : Vector3
	if camera_3d != null:
		var cam_fwd : Vector3 = -camera_3d.global_transform.basis.z.normalized()
		aim_target = camera_3d.global_position + cam_fwd * spell_range
	else:
		aim_target = global_position + Vector3(-sin(_yaw), 0.0, -cos(_yaw)) * spell_range

	# Right hand always fires.
	var spawn_r : Vector3 = get_spawn_position_right()
	_launch_fireball(spawn_r, (aim_target - spawn_r).normalized())

	# Left hand also fires on two-handed attack animations.
	if two_handed:
		var spawn_l : Vector3 = get_spawn_position_left()
		_launch_fireball(spawn_l, (aim_target - spawn_l).normalized())


# Creates a self-propelled fireball at origin heading in direction.
# The fireball is a runtime Area3D — no external scene required.
# It moves via coroutine each process frame and despawns on hit or
# when it has traveled spell_range metres.
func _launch_fireball(origin: Vector3, direction: Vector3, penetrate_walls: bool = false, max_range: float = -1.0) -> void:
	# ── Collision area ─────────────────────────────────────────────────────────
	var fireball       := Area3D.new()
	var fb_name        := "MageFireball_" + str(Time.get_ticks_usec()) + "_" + str(randi() % 1000)
	fireball.name       = fb_name
	fireball.collision_layer = 0             # Fireball doesn't need to be detected by others
	fireball.collision_mask  = 0xFFFFFFFF    # Hit everything — _on_fireball_hit filters by take_damage
	fireball.monitorable     = false         # Other areas can't detect this fireball
	fireball.monitoring      = false         # Off at spawn — fireball is inside the player's own CollisionShape3D
											# and would self-destruct immediately. Enabled after first travel step.

	var shape_node    := CollisionShape3D.new()
	var sphere        := SphereShape3D.new()
	sphere.radius      = fireball_collision_radius
	shape_node.shape   = sphere
	fireball.add_child(shape_node)

	# ── Shaped bolt cylinder + glow corona ───────────────────────────────────
	fireball.add_child(_build_bolt_body())

	# OmniLight3D so the bolt illuminates dungeon walls. Runs on every
	# difficulty — cluster budget at 4096 has plenty of room for a handful
	# of transient projectile lights, and it meaningfully improves the
	# "cast a spell and light up the room" readability.
	var l              := OmniLight3D.new()
	l.name              = "BoltLight"
	l.light_color       = Color(0.5, 0.75, 1.0)
	l.light_energy      = 2.0
	l.omni_range        = 4.0
	l.shadow_enabled    = false
	fireball.add_child(l)

	# ── Add to scene and position ──────────────────────────────────────────────
	get_parent().add_child(fireball)
	fireball.global_position = origin

	# ── Orient bolt along travel axis like an arrow ───────────────────────────
	var safe_up : Vector3 = Vector3.UP if abs(direction.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	fireball.look_at(origin + direction, safe_up)

	# ── Cast crackle ──────────────────────────────────────────────────────────
	if fireball_cast_sound != null and has_node("/root/AudioManager"):
		AudioManager.play_one_shot(fireball_cast_sound, 0.0, randf_range(0.92, 1.08))

	# ── Hit detection — passing unique string to avoid Lambda capture bugs ─────
	# attack_damage is the flat bonus/penalty applied by buffs (Berserker, Blunted, etc.)
	var damage_val : float = maxf(0.0, spell_damage + attack_damage + get_low_health_attack_bonus())
	# direction is bound so _on_fireball_hit can place a scorch mark at the impact surface.
	fireball.body_entered.connect(_on_fireball_hit.bind(fb_name, damage_val, direction, penetrate_walls))

	# ── Coroutine travel loop ──────────────────────────────────────────────────
	# Orientation was set once with look_at() before the loop — direction is constant
	# so the basis never changes in flight.  Calling look_at every frame introduced
	# floating-point drift that occasionally flipped the transform 90°.
	var range_limit : float = max_range if max_range > 0.0 else spell_range
	var traveled : float = 0.0
	while traveled < range_limit and is_instance_valid(fireball):
		var step : Vector3 = direction * fireball_speed * get_process_delta_time()
		fireball.global_position += step
		traveled                 += step.length()
		# Enable collision detection after the first step so the fireball
		# has physically moved away from the player's spawn-point overlap.
		if not fireball.monitoring:
			fireball.monitoring = true
		await get_tree().process_frame

	# Max range reached — clean up if not already freed by a hit.
	if is_instance_valid(fireball):
		fireball.queue_free()


# Safe callback for fireball hits. By passing a string ID instead of the Node
# reference itself, we completely avoid Godot's "Lambda capture freed" engine panic.
func _on_fireball_hit(body: Node3D, fb_name: String, damage_val: float, travel_dir: Vector3, penetrate_walls: bool = false) -> void:
	# Guard: ignore the caster. The fireball spawns at the hand bone which sits
	# inside the player's own CharacterBody3D. Without this check the fireball
	# would self-destruct the moment monitoring is enabled.
	if body == self:
		return

	# Wall-penetrating bolts (rapid_attack): skip destruction when hitting geometry
	# that has no take_damage method (i.e. walls/floor/ceiling).
	if penetrate_walls:
		var t : Node3D = body
		if not t.has_method("take_damage") and t.get_parent() != null:
			t = t.get_parent() as Node3D
		if t == null or not t.has_method("take_damage"):
			return

	var fb : Node = get_parent().get_node_or_null(NodePath(fb_name))

	# If the fireball is already gone or already processed a hit this frame, do nothing.
	if not is_instance_valid(fb) or fb.has_meta("hit_processed"):
		return

	fb.set_meta("hit_processed", true)
	fb.set_deferred("monitoring", false)

	# Scorch mark at impact point — placed before queue_free so position is still valid.
	_spawn_scorch_mark(fb.global_position, travel_dir)

	var target : Node3D = body
	if not target.has_method("take_damage") and not target.has_method("apply_kick") and target.get_parent() != null:
		target = target.get_parent() as Node3D

	# Fireball / lightning bolt contact with a kickable prop: kick the prop and end the projectile.
	# (fb.queue_free() below handles the "end on contact" half.)
	if target != null and target != self and target.has_method("apply_kick"):
		target.apply_kick(travel_dir, damage_val * 4.0)
	elif target != null and target != self and target.has_method("take_damage"):
		var final_dmg : float = damage_val
		# Executioner: +bonus% when target is below 30% health.
		if low_health_damage > 0.0:
			var cur_hp := float(target.get("_current_health") if "_current_health" in target else max_health)
			var max_hp := float(target.get("max_health")      if "max_health"      in target else 1.0)
			if max_hp > 0.0 and cur_hp / max_hp < 0.3:
				final_dmg *= 1.0 + low_health_damage
		# Pass self so character_base._trigger_death() correctly credits this kill
		# to the player via GLOBAL_KILL_COUNT (kill-streak and potion tracking).
		target.take_damage(final_dmg, self)

	fb.queue_free()


# ══════════════════════════════════════════════════════════════
#  SCORCH MARKS
#  Burn decals left on surfaces where lightning bolts impact.
#  Limited to MAX_SCORCH_MARKS active at once — oldest removed
#  when the pool fills, matching classic footprint-system behaviour.
# ══════════════════════════════════════════════════════════════

const MAX_SCORCH_MARKS  : int = 20

# Shared across all mage instances (and all bolts in flight) so the
# global cap is respected regardless of how many bolts are active.
static var _scorch_pool    : Array          = []
static var _scorch_texture : ImageTexture   = null


# Lazily creates the burn-mark texture once and caches it for the session.
# The texture is a radial gradient: charcoal centre fading to transparent,
# with a faint orange-brown fringe to sell the heat.
static func _get_scorch_texture() -> ImageTexture:
	if _scorch_texture != null:
		return _scorch_texture
	const SZ : int = 64
	var img := Image.create(SZ, SZ, false, Image.FORMAT_RGBA8)
	var ctr := Vector2(SZ * 0.5, SZ * 0.5)
	for y in SZ:
		for x in SZ:
			var d : float = Vector2(x, y).distance_to(ctr) / (SZ * 0.5)
			if d >= 1.0:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
			else:
				# Core: near-black charcoal
				# Fringe (d > 0.55): warm orange-brown scorch ring
				var alpha  : float = pow(1.0 - d, 1.4) * 0.88
				var r      : float = lerpf(0.08, 0.38, smoothstep(0.45, 0.85, d))
				var g      : float = lerpf(0.06, 0.18, smoothstep(0.45, 0.85, d))
				var b      : float = 0.04
				img.set_pixel(x, y, Color(r, g, b, alpha))
	_scorch_texture = ImageTexture.create_from_image(img)
	return _scorch_texture


# Places a Decal at the impact point, oriented so it projects onto the hit surface.
# The bolt's travel direction is used to approximate the surface normal (-travel_dir).
func _spawn_scorch_mark(impact_pos: Vector3, travel_dir: Vector3) -> void:
	# The Decal must live in the scene root so it persists after the fireball is freed.
	var scene_root : Node = get_parent()
	if scene_root == null:
		return

	var decal      := Decal.new()
	decal.name      = "ScorchMark"
	# Projection volume: 0.7 m wide/tall, 0.3 m deep so it reaches slightly into walls.
	decal.size      = Vector3(0.7, 0.3, 0.7)
	decal.texture_albedo = _get_scorch_texture()
	# Lower emission so the mark reads as darkness, not a glow.
	decal.emission_energy = 0.0
	decal.albedo_mix = 0.85

	scene_root.add_child(decal)

	# Position: pull back half the projection depth so the decal volume straddles
	# the surface instead of sitting entirely on one side of it.
	decal.global_position = impact_pos - travel_dir.normalized() * 0.15

	# Orient the Decal so its -Y axis (projection direction) points along travel_dir
	# (into the surface).  Godot Decals project along -Y by default, so we build a
	# basis where +Y = -travel_dir (pointing out of the surface toward us).
	var y_axis : Vector3 = -travel_dir.normalized()
	var ref    : Vector3 = Vector3.FORWARD if abs(y_axis.dot(Vector3.FORWARD)) < 0.99 else Vector3.UP
	var x_axis : Vector3 = y_axis.cross(ref).normalized()
	var z_axis : Vector3 = x_axis.cross(y_axis).normalized()
	decal.global_transform.basis = Basis(x_axis, y_axis, z_axis)

	# Pool management: enqueue and evict the oldest mark when limit is reached.
	_scorch_pool.append(decal)
	if _scorch_pool.size() > MAX_SCORCH_MARKS:
		var oldest = _scorch_pool.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()


# One-shot muzzle burst at the palm when a bolt is cast.
# Uses muzzle_02_rotated.png — electric blue, auto-removes after particles finish.
# Raycasts from screen centre to find the real world point under the reticle.
# Returns the hit position if within range, otherwise the far end of the ray.
# Excludes self so the player's own collision shape does not intercept.
func _raycast_aim_target(range: float) -> Vector3:
	if camera_3d == null:
		return global_position + Vector3(-sin(_yaw), 0.0, -cos(_yaw)) * range
	var screen_center : Vector2 = get_viewport().size / 2.0
	var ray_origin    : Vector3 = camera_3d.project_ray_origin(screen_center)
	var ray_dir       : Vector3 = camera_3d.project_ray_normal(screen_center)
	var ray_end       : Vector3 = ray_origin + ray_dir * range
	var space  := get_world_3d().direct_space_state
	var query  := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	query.exclude        = [get_rid()]
	query.collision_mask = 0xFFFFFFFF
	var result := space.intersect_ray(query)
	if not result.is_empty():
		var collider : Object = result.get("collider")
		var is_enemy : bool   = collider != null and (collider.has_method("take_damage") \
				or (collider.get_parent() != null and collider.get_parent().has_method("take_damage")))
		# Aim at enemies at any range; skip geometry hits closer than 1.5 m so the
		# bolt doesn't vaporise against a wall the player is standing next to.
		if is_enemy or result.position.distance_to(ray_origin) >= 1.5:
			return result.position
	return ray_end


func _spawn_muzzle_flash(origin: Vector3) -> void:
	var p             := GPUParticles3D.new()
	p.name             = "MuzzleFlash"
	p.emitting         = true
	p.one_shot         = true
	p.amount           = 18
	p.lifetime         = 0.25
	p.explosiveness    = 0.85
	p.visibility_aabb  = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))

	var proc := ParticleProcessMaterial.new()
	proc.direction            = Vector3.ZERO
	proc.spread               = 180.0
	proc.initial_velocity_min = 1.5
	proc.initial_velocity_max = 4.5
	proc.gravity              = Vector3.ZERO
	proc.scale_min            = 0.14
	proc.scale_max            = 0.30
	proc.angular_velocity_min = 200.0
	proc.angular_velocity_max = 600.0
	p.process_material = proc

	var quad := QuadMesh.new()
	quad.size = Vector2(0.28, 0.28)
	var mat  := StandardMaterial3D.new()
	mat.billboard_mode             = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled           = true
	mat.emission                   = Color(0.3, 0.7, 1.0)
	mat.emission_energy_multiplier  = 6.0
	mat.albedo_color               = Color(0.5, 0.85, 1.0, 1.0)
	const MUZZLE_TEX : String = "res://addons/kenney_particle_pack/rotated/muzzle_02_rotated.png"
	if ResourceLoader.exists(MUZZLE_TEX):
		mat.albedo_texture = load(MUZZLE_TEX)
	quad.surface_set_material(0, mat)
	p.draw_pass_1 = quad

	get_parent().add_child(p)
	p.global_position = origin
	# Auto-remove after particles finish + fade
	get_tree().create_timer(p.lifetime + 0.15).timeout.connect(
		func() -> void:
			if is_instance_valid(p): p.queue_free(),
		CONNECT_ONE_SHOT)


# Jagged lightning bolt — 4 cylinder segments connected at random kink points.
# Each segment's Y axis is aligned to the direction between its two junction points,
# giving the characteristic zigzag look of an electric discharge.
# The parent Area3D is oriented by look_at() so local -Z = flight direction.
func _build_bolt_body() -> Node3D:
	var root := Node3D.new()
	root.name = "BoltBody"

	var mat := StandardMaterial3D.new()
	mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled           = true
	mat.emission                   = Color(0.45, 0.85, 1.0)
	mat.emission_energy_multiplier = 4.0
	mat.albedo_color               = Color(0.8, 0.95, 1.0, 0.9)

	# Build kink points in local space (local -Z = forward/flight direction).
	const TOTAL  : float = 1.4   # total bolt length
	const SEGS   : int   = 4     # number of segments
	const JAG    : float = 0.07  # max lateral kink per junction

	var pts : Array[Vector3] = []
	pts.append(Vector3.ZERO)
	for i in SEGS - 1:
		pts.append(Vector3(
			randf_range(-JAG, JAG),
			randf_range(-JAG * 0.4, JAG * 0.4),
			-TOTAL * float(i + 1) / float(SEGS)
		))
	pts.append(Vector3(0.0, 0.0, -TOTAL))

	for i in SEGS:
		var p0  : Vector3 = pts[i]
		var p1  : Vector3 = pts[i + 1]
		var seg : Vector3 = p1 - p0
		var seg_len : float = seg.length()
		if seg_len < 0.001:
			continue
		var seg_dir : Vector3 = seg / seg_len

		var mi  := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius      = 0.018
		cyl.bottom_radius   = 0.018
		cyl.height          = seg_len
		cyl.radial_segments = 6
		cyl.rings           = 0
		mi.mesh              = cyl
		mi.material_override = mat
		mi.position          = (p0 + p1) * 0.5

		# Orient cylinder Y axis along seg_dir.
		var ref : Vector3 = Vector3.RIGHT if abs(seg_dir.dot(Vector3.RIGHT)) < 0.99 else Vector3.UP
		var ax_x : Vector3 = seg_dir.cross(ref).normalized()
		var ax_z : Vector3 = ax_x.cross(seg_dir).normalized()
		mi.basis = Basis(ax_x, seg_dir, ax_z)

		root.add_child(mi)

	return root


# Single large lightning bolt — spark_05_rotated.png, bright electric glow.
# One particle at a time so it reads as one solid bolt, not a cloud of sparks.
func _build_fireball_core_particles() -> GPUParticles3D:
	var p             := GPUParticles3D.new()
	p.name             = "LightningBolt"
	p.emitting         = true
	p.one_shot         = false
	p.amount           = 1
	p.lifetime         = 0.5
	p.visibility_aabb  = AABB(Vector3(-2, -2, -2), Vector3(4, 4, 4))

	var proc := ParticleProcessMaterial.new()
	proc.direction            = Vector3.ZERO
	proc.spread               = 0.0   # No scatter — bolt stays centred
	proc.initial_velocity_min = 0.0
	proc.initial_velocity_max = 0.0
	proc.gravity              = Vector3.ZERO
	proc.scale_min            = 1.0
	proc.scale_max            = 1.0
	# No rotation — keep the bolt sprite upright and avoid the sideways tumble glitch
	proc.angular_velocity_min = 0.0
	proc.angular_velocity_max = 0.0
	p.process_material = proc

	var quad := QuadMesh.new()
	quad.size = Vector2(0.9, 0.9)    # Large single bolt quad
	var mat  := StandardMaterial3D.new()
	mat.billboard_mode             = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled           = true
	mat.emission                   = Color(0.45, 0.85, 1.0)
	mat.emission_energy_multiplier = 14.0  # Bright electric glow
	mat.albedo_color               = Color(0.8, 0.95, 1.0, 1.0)
	const SPARK_05 : String = "res://addons/kenney_particle_pack/rotated/spark_05_rotated.png"
	if ResourceLoader.exists(SPARK_05):
		mat.albedo_texture = load(SPARK_05)
	quad.surface_set_material(0, mat)
	p.draw_pass_1 = quad
	return p


# Soft blue-white glow corona — same spark texture as bolt, scaled up at low alpha.
# Using the texture is critical: without it the quad renders as a solid rectangle.
func _build_fireball_trail_particles() -> GPUParticles3D:
	var p             := GPUParticles3D.new()
	p.name             = "LightningGlow"
	p.emitting         = true
	p.one_shot         = false
	p.amount           = 1
	p.lifetime         = 0.5
	p.visibility_aabb  = AABB(Vector3(-2, -2, -2), Vector3(4, 4, 4))

	var proc := ParticleProcessMaterial.new()
	proc.direction            = Vector3.ZERO
	proc.spread               = 0.0
	proc.initial_velocity_min = 0.0
	proc.initial_velocity_max = 0.0
	proc.gravity              = Vector3.ZERO
	proc.scale_min            = 1.0
	proc.scale_max            = 1.0
	p.process_material = proc

	var quad := QuadMesh.new()
	quad.size = Vector2(1.5, 1.5)    # Wide corona behind the bolt sprite
	var mat  := StandardMaterial3D.new()
	mat.billboard_mode             = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled           = true
	mat.emission                   = Color(0.2, 0.6, 1.0)
	mat.emission_energy_multiplier = 5.0
	mat.albedo_color               = Color(0.55, 0.85, 1.0, 0.35)  # Faint blue halo
	# Texture required — a plain quad with no texture renders as a solid rectangle.
	const SPARK_05 : String = "res://addons/kenney_particle_pack/rotated/spark_05_rotated.png"
	if ResourceLoader.exists(SPARK_05):
		mat.albedo_texture = load(SPARK_05)
	quad.surface_set_material(0, mat)
	p.draw_pass_1 = quad
	return p


# ══════════════════════════════════════════════════════════════
#  BLOCK
# ══════════════════════════════════════════════════════════════

func _start_block() -> void:
	_is_blocking = true
	anim_player.speed_scale = block_anim_speed
	_play_anim("block_start")

	var anim_len : float = _current_anim_length() / block_anim_speed
	await get_tree().create_timer(anim_len).timeout

	if _is_blocking:
		_play_anim("block_idle")


func _end_block() -> void:
	_is_blocking = false
	anim_player.speed_scale = block_anim_speed
	_play_anim("block_end")

	var anim_len : float = _current_anim_length() / block_anim_speed
	await get_tree().create_timer(anim_len).timeout

	anim_player.speed_scale = 1.0
	if not _is_attacking and not _is_dead:
		_change_state(_get_idle_state())


# ══════════════════════════════════════════════════════════════
#  SHOVE  (right bumper — Standing2HMagicAttack02)
# ══════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════
#  LIGHTNING DOME  (AOE)
# ══════════════════════════════════════════════════════════════

# Spends 1 potion and fires dome_bolt_count lightning bolts evenly
# around 360° plus 4 diagonal bolts for full 3D coverage.
func _do_lightning_dome() -> void:
	if not has_node("/root/PlayerWallet") or not PlayerWallet.spend_potions(1):
		return
	_dome_cooldown = DOME_COOLDOWN_TIME
	velocity.x = 0.0
	velocity.z = 0.0

	if fireball_cast_sound != null and has_node("/root/AudioManager"):
		AudioManager.play_one_shot(fireball_cast_sound, 3.0, 0.75)

	_play_anim("block_react")

	var origin : Vector3 = global_position + Vector3(0.0, 1.4, 0.0)

	# Flat ring of bolts evenly distributed around 360°
	for i in dome_bolt_count:
		var angle : float = (TAU / float(dome_bolt_count)) * i
		var dir   : Vector3 = Vector3(sin(angle), 0.0, cos(angle))
		_launch_fireball(origin, dir)

	# 4 diagonal bolts at ~20° upward angle offset 45° from the ring
	for i in 4:
		var angle : float = (TAU / 4.0) * i + (TAU / 8.0)
		var dir   : Vector3 = Vector3(sin(angle), 0.35, cos(angle)).normalized()
		_launch_fireball(origin, dir)


# ══════════════════════════════════════════════════════════════
#  LIGHTNING RAPID ATTACK
# ══════════════════════════════════════════════════════════════

func _start_mage_rapid_attack() -> void:
	if _is_dead:
		return

	_rapid_attack_active       = true
	_rapid_attack_timer        = rapid_attack_duration
	_rapid_attack_attack_timer = 0.0
	_is_attacking              = true
	anim_player.speed_scale    = attack_speed_scale * attack_speed * 1.5
	_refresh_rapid_attack_bar()


func _end_mage_rapid_attack() -> void:
	_rapid_attack_active          = false
	_is_attacking                 = false
	_rapid_attack_cooldown_remain = rapid_attack_cooldown
	anim_player.speed_scale       = 1.0
	_refresh_rapid_attack_bar()


# Returns the world-space direction the crosshair is pointing. Using
# viewport * 0.5 keeps aim at the exact screen center at any resolution,
# FOV, or aspect ratio. Falls back to yaw if the camera is missing.
func _get_camera_aim_dir() -> Vector3:
	if camera_3d != null:
		return camera_3d.project_ray_normal(get_viewport().size * 0.5).normalized()
	return Vector3(-sin(_yaw), 0.0, -cos(_yaw))


# Fires a single lightning bolt parallel to the crosshair line-of-sight.
# Origin stays on the staff tip so the bolt visually leaves the weapon,
# but the flight direction comes from the camera — decoupled from whatever
# the arm animation is doing at the moment of fire.
func _fire_rapid_attack_bolts() -> void:
	var origin : Vector3
	if _staff_tip != null:
		origin = _staff_tip.global_position
	else:
		origin = global_position + Vector3(0.0, 1.4, 0.0)

	var aim : Vector3 = _get_camera_aim_dir()
	# Tiny perpendicular cone jitter so repeat bolts aren't a perfect line.
	aim = (aim + Vector3(randf_range(-0.03, 0.03), randf_range(-0.03, 0.03), 0.0)).normalized()
	_launch_fireball(origin, aim, true, 8.0)


func _refresh_rapid_attack_bar() -> void:
	if _rapid_attack_bar_fill == null:
		return
	if _rapid_attack_active:
		var pct : float = clampf(_rapid_attack_timer / rapid_attack_duration, 0.0, 1.0)
		_rapid_attack_bar_fill.size.x = 220.0 * pct
		_rapid_attack_bar_fill.color  = Color(0.1, 0.6, 1.0, 1.0)
		if _rapid_attack_bar_label != null:
			_rapid_attack_bar_label.text = "RAPID ATTACK  %.1fs" % _rapid_attack_timer
	elif _rapid_attack_cooldown_remain > 0.0:
		var pct : float = 1.0 - clampf(_rapid_attack_cooldown_remain / rapid_attack_cooldown, 0.0, 1.0)
		_rapid_attack_bar_fill.size.x = 220.0 * pct
		_rapid_attack_bar_fill.color  = Color(0.2, 0.2, 0.65, 0.85)
		if _rapid_attack_bar_label != null:
			_rapid_attack_bar_label.text = "Cooldown  %.0fs" % _rapid_attack_cooldown_remain
	elif _attack_held:
		_rapid_attack_bar_fill.size.x = 220.0 * _rapid_attack_charge
		_rapid_attack_bar_fill.color  = Color(0.35, 0.8, 1.0, 1.0) if _rapid_attack_charge < 1.0 \
				else Color(0.1, 0.6, 1.0, 1.0)
		if _rapid_attack_bar_label != null:
			_rapid_attack_bar_label.text = "RELEASE!" if _rapid_attack_charge >= 1.0 else "Charging…"
	else:
		_rapid_attack_bar_fill.size.x = 0.0
		if _rapid_attack_bar_label != null:
			_rapid_attack_bar_label.text = ""


# Plays the 2H shove animation and deals melee damage + knockback
# to enemies in a short cone in front of the mage at 85% through
# the animation (same timing window as the fireball spawn).
# Values mirror the brute kick: shove_damage = 15, shove_force = 9.
func _do_shove() -> void:
	_is_attacking = true
	# SURGICAL FIX: Commented out velocity locks for 1st person mobility pivot
	# velocity.x = 0.0
	# velocity.z = 0.0

	anim_player.speed_scale = attack_speed_scale * attack_speed
	anim_player.play("StandingMeleeKickVer")   # direct play — bypass lookup chain

	# Props react INSTANTLY on shove start — don't wait for the 85% anim mark.
	# Enemy shove still waits for the swing apex below so animation sync feels right.
	_apply_shove_to_props()

	var anim_len : float = _current_anim_length() / (attack_speed_scale * attack_speed)

	# Apply shove hit at 85% through the animation.
	await get_tree().create_timer(anim_len * 0.85).timeout

	if not _is_dead and _is_attacking:
		_apply_shove()

	# SURGICAL FIX: Applied standard recovery buffer cancellation here
	var wait_time : float = maxf((anim_len * 0.15) - 0.15, 0.05)
	await get_tree().create_timer(wait_time).timeout

	if _is_attacking:
		anim_player.speed_scale = 1.0
		_is_attacking = false
		_change_state(_get_idle_state())


# Scans enemies in the "enemies" group within shove_range metres and in a
# 90° forward cone. Deals shove_damage and applies knockback to each.
# Uses the same group name and knockback API as the brute kick.
func _apply_shove() -> void:
	var forward  : Vector3 = Vector3(-sin(_yaw), 0.0, -cos(_yaw)).normalized()
	var shove_sq : float   = shove_range * shove_range


	for enemy_node in get_tree().get_nodes_in_group("enemies"):
		# is-guard lets GDScript's flow-analysis narrow enemy_node to Node3D
		# without a nullable as-cast, so .global_position resolves to Vector3.
		if not (enemy_node is Node3D):
			continue
		var enemy : Node3D = enemy_node
		if not is_instance_valid(enemy) or enemy.get("_is_dead") == true:
			continue
		# Flatten to horizontal plane so height differences don't exclude tall enemies.
		var to_enemy : Vector3 = enemy.global_position - global_position
		to_enemy.y = 0.0
		var dist_sq : float = to_enemy.length_squared()
		if dist_sq > shove_sq or dist_sq < 0.01:
			continue
		# 90° cone check — dot > 0 means the enemy is somewhere in front.
		if to_enemy.normalized().dot(forward) <= 0.0:
			continue
		if enemy.has_method("take_damage"):
			enemy.take_damage(shove_damage + maxf(0.0, attack_damage + get_low_health_attack_bonus()), self)
		if enemy.has_method("take_knockback"):
			enemy.take_knockback(forward, shove_force, shove_stun_time)


# Instant prop-kick pass fired at the START of _do_shove, so kicked props move
# the moment you press kick instead of 85% through the anim.
func _apply_shove_to_props() -> void:
	var forward : Vector3 = Vector3(-sin(_yaw), 0.0, -cos(_yaw)).normalized()
	var fwd2 : Vector2 = Vector2(forward.x, forward.z).normalized()
	for prop in get_tree().get_nodes_in_group("kickable_prop"):
		if not (prop is Node3D) or not is_instance_valid(prop):
			continue
		var prop_node : Node3D = prop as Node3D
		if not prop_node.has_method("apply_kick"):
			continue
		var to_prop : Vector3 = prop_node.global_position - global_position
		var horiz : Vector2 = Vector2(to_prop.x, to_prop.z)
		var dist : float = horiz.length()
		if dist > shove_range or dist < 0.01:
			continue
		if (horiz / dist).dot(fwd2) < 0.5:   # cos(60°) → ~120° total arc
			continue
		prop_node.apply_kick(forward, shove_force * 12.0)


# Plays the block animation in the player's current facing direction.
# Holds at the halfway point while the "block" button is held; on release
# the animation resumes at 2.5x to snap out of the stance.
func _do_block() -> void:
	if _is_blocking or _is_dead or _is_sliding:
		return

	# Cancel any active attack before blocking.
	if _is_attacking:
		_is_attacking = false
		if anim_player != null: anim_player.speed_scale = 1.0

	# Lock movement immediately — block is active.
	_is_blocking = true
	velocity.x   = 0.0
	velocity.z   = 0.0

	if anim_player != null: anim_player.speed_scale = 1.0
	_play_anim("block_react")

	var anim_len : float = _current_anim_length()
	var half_time : float = anim_len * 0.5
	var elapsed : float = 0.0
	var released_early : bool = false

	# Wait until we reach the halfway point, polling for premature release
	while elapsed < half_time and _is_blocking:
		if not Input.is_action_pressed("block"):
			released_early = true
			break
		elapsed += get_physics_process_delta_time()
		await get_tree().physics_frame

	# Pause the animation to hold the shield up
	if _is_blocking and not released_early:
		if anim_player != null: anim_player.pause()

		# Wait indefinitely until the player lets go of the button
		while _is_blocking:
			if not Input.is_action_pressed("block"):
				break
			await get_tree().physics_frame

	# Player let go - resume animation at 2.5x speed to snap out of it
	if _is_blocking:
		if anim_player != null:
			anim_player.play()
			anim_player.speed_scale = 2.5

		# Wait for the remaining tail of the animation (adjusted for 2.5x speed)
		var remain_time : float = maxf((anim_len - elapsed) / 2.5, 0.05)
		await get_tree().create_timer(remain_time).timeout

		if _is_blocking:
			_is_blocking = false
			if anim_player != null: anim_player.speed_scale = 1.0
			if not _is_dead:
				_change_state(_get_idle_state())


# ══════════════════════════════════════════════════════════════
#  FOOTSTEPS
# ══════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════
#  STATUS EFFECTS (TRAP SYSTEM)
# ══════════════════════════════════════════════════════════════

# days_duration: for the day-based effects it is the number of in-game days; for "acid_pool" it is
# the duration in SECONDS (0 = default 15). strength: acid damage per second (0 = default 1.0).
func apply_status(effect_name: String, days_duration: int, strength: float = 0.0) -> void:
	match effect_name:
		"reversed_view":
			_status_reversed_view    = true
			_status_day_effects_days = maxi(_status_day_effects_days, days_duration)
			if not GameClock.day_changed.is_connected(_on_day_changed):
				GameClock.day_changed.connect(_on_day_changed)
		"heavy_gravity":
			if not _status_heavy_gravity:
				_status_heavy_gravity    = true
				slide_power             *= 0.5
				_status_day_effects_days = maxi(_status_day_effects_days, days_duration)
			if not GameClock.day_changed.is_connected(_on_day_changed):
				GameClock.day_changed.connect(_on_day_changed)
		"drunk":
			_status_drunk       = true
			_status_drunk_timer = 30.0
		"reversed_controls":
			_status_reversed_controls = true
			_status_controls_timer    = 30.0
		"acid_pool":
			_status_acid       = true
			_status_acid_timer = float(days_duration) if days_duration > 0 else 15.0
			_status_acid_dps   = strength if strength > 0.0 else 1.0
	_refresh_status_label()   # show the new effect immediately


# Builds the active trap effects text and shows/hides the panel (mirrors the Barbarian's).
func _refresh_status_label() -> void:
	if _status_label == null or _status_panel == null:
		return
	var lines : Array[String] = []
	var day_s : String = "s" if _status_day_effects_days != 1 else ""
	if _status_reversed_view:
		lines.append("⚠ Vision Reversed  (%d day%s)" % [_status_day_effects_days, day_s])
	if _status_heavy_gravity:
		lines.append("⚠ Heavy Gravity  (%d day%s)" % [_status_day_effects_days, day_s])
	if _status_drunk:
		lines.append("⚠ Disoriented  (%.0fs)" % _status_drunk_timer)
	if _status_reversed_controls:
		lines.append("⚠ Controls Reversed  (%.0fs)" % _status_controls_timer)
	if _status_acid:
		lines.append("⚠ Acid Burn  (%.0fs)" % _status_acid_timer)
	if lines.is_empty():
		_status_panel.visible = false
	else:
		_status_label.text    = "\n".join(lines)
		_status_panel.visible = true


func _on_day_changed(_day: int) -> void:
	_status_day_effects_days -= 1
	if _status_day_effects_days <= 0:
		_status_reversed_view = false
		if _status_heavy_gravity:
			_status_heavy_gravity = false
			slide_power           *= 2.0
		_status_day_effects_days = 0
		if GameClock.day_changed.is_connected(_on_day_changed):
			GameClock.day_changed.disconnect(_on_day_changed)
	_refresh_status_label()   # keep the on-screen effect list in step with the day count


func _get_effective_move_speed() -> float:
	return maxf(move_speed * kill_haste_multiplier(), 0.001)


# ── MageCharacter overrides (moved here now that we extend BruteCharacter) ────
# Mage is always in staff stance — never unarmed_idle.
func _get_idle_state() -> String:
	return "standing_idle"


# Mage locomotion set includes walk variants that BruteCharacter doesn't have.
func _is_locomotion_state(state_name: String) -> bool:
	return state_name in [
		"standing_idle",
		"standing_run_forward", "standing_run_back",
		"standing_run_left",    "standing_run_right",
		"standing_walk_forward","standing_walk_back",
		"standing_walk_left",   "standing_walk_right",
		"standing_sprint_forward",
	]


# Default death direction — always fall backward (no AI raycasting needed for player).
func pick_death_direction() -> String:
	return "death_backward"


# mage_player extends BruteCharacter (for the shared brute model/physics base),
# but combat animations use the mage-specific map from MageCharacter.
func _get_animation_map() -> Dictionary:
	return MageCharacter.ANIMATION_MAP


# World-space projectile spawn points — use Marker3D if assigned, else chest height.
func get_spawn_position_right() -> Vector3:
	if right_hand_marker != null:
		return right_hand_marker.global_position
	return global_position + Vector3(0.0, 1.5, 0.0)


func get_spawn_position_left() -> Vector3:
	if left_hand_marker != null:
		return left_hand_marker.global_position
	return global_position + Vector3(0.0, 1.5, 0.0)


# ══════════════════════════════════════════════════════════════
#  HELPERS
# ══════════════════════════════════════════════════════════════

# Recursively applies mat to every surface of every MeshInstance3D
# under node.  Used once at startup to skin the staff prop.
func _apply_material_recursive(node: Node, mat: StandardMaterial3D) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		# get_surface_override_material_count() returns 0 until overrides exist.
		# mesh.get_surface_count() is the actual number of surfaces on the mesh.
		if mi.mesh != null:
			for i in mi.mesh.get_surface_count():
				mi.set_surface_override_material(i, mat)
	for child in node.get_children():
		_apply_material_recursive(child, mat)


# ══════════════════════════════════════════════════════════════
#  PAUSE
# ══════════════════════════════════════════════════════════════

func _is_pause_event(event: InputEvent) -> bool:
	if event.is_action_pressed("ui_menu") or event.is_action_pressed("ui_cancel"):
		return true
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			return true
	return false


func _is_pause_menu_open() -> bool:
	if pause_menu != null and pause_menu.has_method("is_menu_open"):
		return bool(pause_menu.call("is_menu_open"))
	return get_tree().paused


func _pause_game() -> void:
	_stop_footsteps()
	if pause_menu != null and pause_menu.has_method("open_menu"):
		pause_menu.call("open_menu")
		return
	get_tree().paused = true
	Input.mouse_mode  = Input.MOUSE_MODE_VISIBLE


func _resume_game() -> void:
	if pause_menu != null and pause_menu.has_method("close_menu"):
		pause_menu.call("close_menu")
		return
	get_tree().paused = false
	Input.mouse_mode  = Input.MOUSE_MODE_CAPTURED


# ══════════════════════════════════════════════════════════════
#  OVERRIDES
# ══════════════════════════════════════════════════════════════

func _smooth_turn(_delta: float) -> void:
	pass
