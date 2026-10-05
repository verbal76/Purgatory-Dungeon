# ============================================================
#  FILE: chest.gd
#  PATH: res://scripts/chest.gd
#  SPAWNED BY: chest_manager.gd (one per qualifying end-cap).
#  DESCRIPTION: Locked chest with proximity prompt, key-required
#               unlock, and a hidden mimic flag. Opening a real
#               chest grants a colour-tiered reward; opening a
#               mimic consumes the key, deals small damage, and
#               activates the 5 nearest dormant curse globes.
#
#  PUBLIC FIELDS (set by ChestManager before add_child):
#    color     : "bronze" / "silver" / "gold"
#    is_mimic  : bool
#
#  ALL BEHAVIOR SELF-CONTAINED — no scene file required.
# ============================================================

extends StaticBody3D

const _LOCKED_PATHS : Dictionary = {
	"bronze": "res://addons/props/chests and keys/SM_LockedChestBronze.fbx",
	"silver": "res://addons/props/chests and keys/SM_LockedChestSilver.fbx",
	"gold":   "res://addons/props/chests and keys/SM_LockedChestGold.fbx",
}
const _UNLOCKED_PATHS : Dictionary = {
	"bronze": "res://addons/props/chests and keys/SM_UnlockedChestBronze.fbx",
	"silver": "res://addons/props/chests and keys/SM_UnlockedChestSilver.fbx",
	"gold":   "res://addons/props/chests and keys/SM_UnlockedChestGold.fbx",
}
const _MIMIC_PATHS : Dictionary = {
	"bronze": "res://addons/props/chests and keys/SM_MimicBronze.fbx",
	"silver": "res://addons/props/chests and keys/SM_MimicSilver.fbx",
	"gold":   "res://addons/props/chests and keys/SM_MimicGold.fbx",
}
const _KEY_PATHS : Dictionary = {
	"bronze": "res://addons/props/chests and keys/SM_KeyBronze.fbx",
	"silver": "res://addons/props/chests and keys/SM_KeySilver.fbx",
	"gold":   "res://addons/props/chests and keys/SM_KeyGold.fbx",
}
const _KEY_COLORS : Array[String] = ["bronze", "silver", "gold"]

# Reward rule set — matches user spec.
const _POTION_REWARD : Dictionary = {"bronze": 5, "silver": 10, "gold": 15}

const _DEBRIS_TEX : String = "res://addons/kenney_particle_pack/smoke_07.png"

# The chest/key/mimic FBX files point at texture files that exist only on the artist's machine
# (Mat_Chests_*.tga), so they import untextured. The same textures ship in this folder under
# an "SM_Chests_" prefix: build one shared material from them and apply it to every chest mesh
# (the same approach prop_spawner.gd uses for the general props).
const _TEX_DIR : String = "res://addons/props/chests and keys/SM_Chests_Mat_Chests_"
static var _shared_mat : StandardMaterial3D = null


static func _chest_material() -> StandardMaterial3D:
	if _shared_mat != null:
		return _shared_mat
	var m := StandardMaterial3D.new()
	if ResourceLoader.exists(_TEX_DIR + "AlbedoTransparency.tga"):
		m.albedo_texture = load(_TEX_DIR + "AlbedoTransparency.tga")
	if ResourceLoader.exists(_TEX_DIR + "MetallicSmoothness.tga"):
		var mt : Texture2D = load(_TEX_DIR + "MetallicSmoothness.tga")
		m.metallic                  = 1.0
		m.metallic_texture          = mt
		m.metallic_texture_channel  = BaseMaterial3D.TEXTURE_CHANNEL_RED
		m.roughness                 = 1.0
		m.roughness_texture         = mt
		m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	if ResourceLoader.exists(_TEX_DIR + "Normal.tga"):
		m.normal_enabled = true
		m.normal_texture = load(_TEX_DIR + "Normal.tga")
	_shared_mat = m
	return m


static func _apply_chest_material(root: Node) -> void:
	if root == null:
		return
	var mat := _chest_material()
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).material_override = mat

@export var interact_radius   : float = 2.0
@export var mimic_damage      : float = 8.0
@export var mimic_curse_count : int   = 5
@export var float_key_duration : float = 0.8

# Set by ChestManager BEFORE add_child().
var color    : String = "bronze"
var is_mimic : bool   = false

var _mesh_root : Node3D = null
var _area      : Area3D = null
var _opened    : bool   = false
var _player_in_range : bool = false

# Prompt HUD (local CanvasLayer — only visible while player is in range).
var _use_ctx       : bool        = false   # this chest is currently asking the touch layer for its USE button
var _prompt_layer  : CanvasLayer = null
var _prompt_label  : Label       = null


func _ready() -> void:
	if not _LOCKED_PATHS.has(color):
		color = "bronze"

	collision_layer = 1
	collision_mask  = 1

	# Static collision — chest is anchored and solid (F17, F18).
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.8, 0.6, 0.5)
	col.shape = box
	col.position = Vector3(0.0, 0.3, 0.0)
	add_child(col)

	_swap_mesh(_LOCKED_PATHS[color])

	# Proximity trigger.
	_area = Area3D.new()
	_area.collision_layer = 0
	_area.collision_mask  = 0xFFFFFFFF
	_area.monitoring      = true
	_area.monitorable     = false
	var sphere_col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = interact_radius
	sphere_col.shape = sphere
	_area.add_child(sphere_col)
	add_child(_area)
	_area.body_entered.connect(_on_body_near)
	_area.body_exited.connect(_on_body_leave)

	# Prompt HUD.
	_prompt_layer = CanvasLayer.new()
	_prompt_layer.layer = 8
	_prompt_layer.visible = false
	add_child(_prompt_layer)

	var wrap := Control.new()
	wrap.set_anchors_preset(Control.PRESET_FULL_RECT)
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	PUI.adopt(wrap)   # a CanvasLayer child does not inherit the root theme
	_prompt_layer.add_child(wrap)

	# Outline text over the world (HudValue role): no plate, the dungeon stays visible.
	_prompt_label = PUI.label("", "HudValue")
	_prompt_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_prompt_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_prompt_label.offset_top    = -180.0
	_prompt_label.offset_bottom = -130.0
	wrap.add_child(_prompt_label)

	# Refresh the prompt when the player's key count changes while in range.
	if has_node("/root/PlayerWallet"):
		PlayerWallet.wallet_changed.connect(_on_wallet_changed)

	add_to_group("chest")


func _exit_tree() -> void:
	_set_use_context(false)
	if has_node("/root/PlayerWallet") and PlayerWallet.wallet_changed.is_connected(_on_wallet_changed):
		PlayerWallet.wallet_changed.disconnect(_on_wallet_changed)


func _process(_delta: float) -> void:
	if _opened or not _player_in_range:
		return
	if Input.is_action_just_pressed("equip"):
		_attempt_unlock()


# ══════════════════════════════════════════════════════════════
#  PROMPT / KEY CHECK
# ══════════════════════════════════════════════════════════════

func _on_body_near(body: Node) -> void:
	if _opened:
		return
	if body == null or not body.is_in_group("player"):
		return
	_player_in_range = true
	_refresh_prompt()
	_prompt_layer.visible = true
	_sync_use_context()


func _on_body_leave(body: Node) -> void:
	if body == null or not body.is_in_group("player"):
		return
	_player_in_range = false
	if _prompt_layer != null:
		_prompt_layer.visible = false
	_set_use_context(false)


func _on_wallet_changed(_n: int) -> void:
	if _player_in_range and not _opened:
		_refresh_prompt()
		_sync_use_context()


func _refresh_prompt() -> void:
	if _prompt_label == null:
		return
	var color_title : String = color.capitalize()
	if has_node("/root/PlayerWallet") and PlayerWallet.get_key_count(color) > 0:
		_prompt_label.text = "[%s] Use %s Key" % [_use_glyph(), color_title]
		_prompt_label.add_theme_color_override("font_color", PUI.BONE_BRIGHT)
	else:
		_prompt_label.text = "Locked \u2014 come back with a %s Key" % color_title
		_prompt_label.add_theme_color_override("font_color", PUI.BONE_DIM)


func _use_glyph() -> String:
	return InputManager.glyph("equip") if has_node("/root/InputManager") else "E"


# Phones have no key to press: while the player stands at a chest they can open, the touch layer
# shows its USE button (and hides it again when they walk away, or the chest opens).
func _sync_use_context() -> void:
	_set_use_context(has_node("/root/PlayerWallet") and PlayerWallet.get_key_count(color) > 0)


func _set_use_context(want: bool) -> void:
	if want == _use_ctx or not is_inside_tree():
		return
	_use_ctx = want
	get_tree().call_group(TouchControls.GROUP, "set_use_context", want, "OPEN")


func _attempt_unlock() -> void:
	if not has_node("/root/PlayerWallet"):
		return
	if PlayerWallet.get_key_count(color) <= 0:
		return   # prompt already says to come back; ignore
	if not PlayerWallet.spend_key(color):
		return
	_opened = true
	_set_use_context(false)
	_area.set_deferred("monitoring", false)
	_prompt_layer.visible = false
	_play_unlock_sequence()


# ══════════════════════════════════════════════════════════════
#  UNLOCK ANIMATION
# ══════════════════════════════════════════════════════════════

# Shows a floating key mesh above the chest for ~0.8 s (tween up + spin +
# fade), then commits the reveal — real reward or mimic payload.
func _play_unlock_sequence() -> void:
	if has_node("/root/AudioManager") and AudioManager.has_method("play_buff_choice"):
		AudioManager.play_buff_choice()

	var key_node : Node3D = null
	var key_path : String = _KEY_PATHS.get(color, "")
	if ResourceLoader.exists(key_path):
		var fbx_scene := load(key_path) as PackedScene
		if fbx_scene != null:
			key_node = fbx_scene.instantiate() as Node3D
			if key_node != null:
				key_node.scale = Vector3(0.7, 0.7, 0.7)
				key_node.position = Vector3(0.0, 1.2, 0.0)
				add_child(key_node)
				_apply_chest_material(key_node)

	if key_node != null:
		var tw : Tween = create_tween().set_parallel(true)
		tw.tween_property(key_node, "position:y", 2.0, float_key_duration) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(key_node, "rotation:y", TAU, float_key_duration)
		tw.tween_property(key_node, "scale", Vector3.ZERO, float_key_duration * 0.4) \
			.set_delay(float_key_duration * 0.6)
		await tw.finished
		key_node.queue_free()
	else:
		await get_tree().create_timer(float_key_duration).timeout

	_commit_reveal()


func _commit_reveal() -> void:
	if is_mimic:
		_reveal_mimic()
	else:
		_reveal_real()


# ══════════════════════════════════════════════════════════════
#  REAL CHEST PATH
# ══════════════════════════════════════════════════════════════

func _reveal_real() -> void:
	_swap_mesh(_UNLOCKED_PATHS[color])
	if has_node("/root/PlayerWallet"):
		PlayerWallet.add_potions(_POTION_REWARD.get(color, 0))
	match color:
		"gold":
			_grant_random_perk_level()
		"silver", "bronze":
			if has_node("/root/BuffManager") and BuffManager.has_method("trigger_buff_picks"):
				BuffManager.trigger_buff_picks(3)


# Picks a random perk from SaveManager.current_profile["perks"] and grants +1.
# If the player hasn't unlocked a perk yet this effectively hands them level 1.
func _grant_random_perk_level() -> void:
	if not SaveManager.current_profile_is_valid():
		return
	var perks : Dictionary = SaveManager.current_profile.get("perks", {})
	if perks.is_empty():
		return
	var keys : Array = perks.keys()
	var pick : String = String(keys[randi() % keys.size()])
	perks[pick] = int(perks.get(pick, 0)) + 1
	SaveManager.save_profile()


# ══════════════════════════════════════════════════════════════
#  MIMIC PATH
# ══════════════════════════════════════════════════════════════

func _reveal_mimic() -> void:
	_swap_mesh(_MIMIC_PATHS[color])
	_spawn_mimic_burst()
	if has_node("/root/AudioManager") and AudioManager.has_method("play_buff_choice"):
		AudioManager.play_buff_choice()   # placeholder sting until a dedicated cue exists

	var player : Node = get_tree().get_first_node_in_group("player")
	if player != null and player.has_method("take_damage"):
		player.take_damage(mimic_damage, self)

	if has_node("/root/GlobeManager") and GlobeManager.has_method("activate_nearest_dormant_to"):
		GlobeManager.activate_nearest_dormant_to(global_position, mimic_curse_count)


func _spawn_mimic_burst() -> void:
	var particles := GPUParticles3D.new()
	particles.amount = 20
	particles.lifetime = 1.2
	particles.one_shot = true
	particles.explosiveness = 0.95
	particles.randomness = 0.6
	particles.local_coords = false

	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 170.0
	pm.initial_velocity_min = 1.5
	pm.initial_velocity_max = 4.0
	pm.gravity = Vector3(0.0, -6.0, 0.0)
	pm.scale_min = 0.08
	pm.scale_max = 0.18

	var grad := Gradient.new()
	grad.set_color(0, Color(0.55, 0.15, 0.65, 1.0))
	grad.set_color(1, Color(0.30, 0.0, 0.35, 0.0))
	var ramp := GradientTexture1D.new()
	ramp.gradient = grad
	pm.color_ramp = ramp
	particles.process_material = pm

	var quad := QuadMesh.new()
	quad.size = Vector2(0.20, 0.20)
	var qmat := StandardMaterial3D.new()
	qmat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qmat.shading_mode   = BaseMaterial3D.SHADING_MODE_UNSHADED
	qmat.transparency   = BaseMaterial3D.TRANSPARENCY_ALPHA
	if ResourceLoader.exists(_DEBRIS_TEX):
		qmat.albedo_texture = load(_DEBRIS_TEX)
	quad.material = qmat
	particles.draw_pass_1 = quad

	add_child(particles)
	particles.position = Vector3(0.0, 0.8, 0.0)
	particles.emitting = true
	get_tree().create_timer(particles.lifetime + 0.3).timeout.connect(particles.queue_free)


# ══════════════════════════════════════════════════════════════
#  MESH SWAPPING
# ══════════════════════════════════════════════════════════════

func _swap_mesh(new_path: String) -> void:
	if _mesh_root != null and is_instance_valid(_mesh_root):
		_mesh_root.queue_free()
		_mesh_root = null
	if not ResourceLoader.exists(new_path):
		return
	var fbx_scene := load(new_path) as PackedScene
	if fbx_scene == null:
		return
	_mesh_root = fbx_scene.instantiate() as Node3D
	if _mesh_root != null:
		_mesh_root.scale = Vector3(0.85, 0.85, 0.85)
		add_child(_mesh_root)
		_apply_chest_material(_mesh_root)
