# ============================================================
#  FILE: brute_animations.gd
#  PATH: res://characters/brute/scripts/brute_animations.gd
# ============================================================

extends CharacterBase
class_name BruteCharacter

# How long the timed trap statuses on the player last. Reversed View deliberately uses the Intoxicated duration (one
# authoritative value): a whole in-game day of an upside-down view was far too long to be interesting.
const STATUS_DRUNK_SECONDS := 30.0
const STATUS_REVERSED_VIEW_SECONDS := STATUS_DRUNK_SECONDS

# ── Repulse (the old backward Slide on the jump / Slide button, now a radial emergency push) ───────────────────────────────
# Tunables, from the physical v8 play: radius of the push, launch speed handed to take_knockback() at point-blank range
# (falls to REPULSE_EDGE_FORCE of that at the edge), how long enemies stay stunned, how long the player is untouchable and
# rooted, and the cool-down before the next one (no HUD meter: it is short).
const REPULSE_RADIUS := 5.0
const REPULSE_FORCE := 14.0
const REPULSE_EDGE_FORCE := 0.6
const REPULSE_STUN := 2.0
const REPULSE_DURATION := 0.45
const REPULSE_COOLDOWN := 3.0
const REPULSE_SOUND_PATH := "res://Music & background images/Sound Effects/Burned A.wav"   # loaded when used: a parse-time preload here slowed the base class load enough to race the threaded scene load


## Pushes every living enemy within `radius` straight away from this character (all directions, including behind) with the
## existing take_knockback() (launch + stun), kicks loose props the same way and plays a quick expanding ring + sound.
## `force_scale` carries Heavy Gravity (it halves slide_power) into the strength. Returns how many enemies were pushed.
func _repulse_burst(force_scale: float = 1.0) -> int:
	var origin : Vector3 = global_position
	var sq_radius : float = REPULSE_RADIUS * REPULSE_RADIUS
	var pushed : int = 0
	for node in get_tree().get_nodes_in_group("enemies"):
		if not (node is Node3D) or not is_instance_valid(node):
			continue
		var enemy : Node3D = node as Node3D
		if enemy.get("_is_dead"):
			continue
		var d : Vector3 = enemy.global_position - origin
		d.y = 0.0
		var dist_sq : float = d.length_squared()
		if dist_sq > sq_radius:
			continue
		# An enemy exactly on top of the player has no direction: send it backwards.
		var dir : Vector3 = d.normalized() if dist_sq > 0.0001 else global_transform.basis.z
		var strength : float = REPULSE_FORCE * force_scale * lerpf(1.0, REPULSE_EDGE_FORCE, sqrt(dist_sq) / REPULSE_RADIUS)
		if enemy.has_method("take_knockback"):
			enemy.take_knockback(dir, strength, REPULSE_STUN)
			pushed += 1
	for prop in get_tree().get_nodes_in_group("kickable_prop"):
		if not (prop is Node3D) or not is_instance_valid(prop):
			continue
		var pd : Vector3 = (prop as Node3D).global_position - origin
		pd.y = 0.0
		if pd.length_squared() > sq_radius or not prop.has_method("apply_kick"):
			continue
		prop.apply_kick(pd.normalized() if pd.length_squared() > 0.0001 else global_transform.basis.z, REPULSE_FORCE * force_scale * 10.0)
	_spawn_repulse_ring()
	if has_node("/root/AudioManager"):
		var snd : AudioStream = load(REPULSE_SOUND_PATH) as AudioStream
		if snd != null:
			AudioManager.play_one_shot(snd, 2.0, 0.7)
	return pushed


## A flat gold shockwave that expands to the push radius and fades (one short-lived node per use).
func _spawn_repulse_ring() -> void:
	var parent : Node = get_parent()
	if parent == null:
		return
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = REPULSE_RADIUS
	sphere.height = REPULSE_RADIUS * 2.0
	sphere.radial_segments = 24
	sphere.rings = 12
	mesh.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(1.0, 0.78, 0.35, 0.45)
	mesh.material_override = mat
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mesh)
	mesh.global_position = global_position + Vector3(0.0, 0.9, 0.0)
	mesh.scale = Vector3.ONE * 0.12
	var tw : Tween = mesh.create_tween().set_parallel(true)
	tw.tween_property(mesh, "scale", Vector3.ONE, 0.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.32)
	tw.chain().tween_callback(mesh.queue_free)

const ANIMATION_MAP := {
	"standing_idle"        : "StandingIdle",
	"unarmed_idle"         : "UnarmedIdleLookingVer",
	"standing_run_forward" : "StandingRunForward",
	"standing_run_back"    : "StandingRunBack",
	"unarmed_run_forward"  : "StandingRunForward",
	"unarmed_run_back"     : "StandingRunBack",
	"unarmed_jump_running" : "UnarmedJumpRunning",
	"attack_360"           : "StandingMeleeAttack360High",
	"attack_backhand"      : "StandingMeleeAttackBackhand",
	"attack_ver"           : "StandingMeleeAttackVer",
	"attack_side"          : "StandingMeleeAttacksidetoSide",
	"kick"                 : "StandingMeleeKickVer",
	"react_gut"            : "StandingReactLargeGut",
	"react_left"           : "StandingReactLargeFromLeft",
	"react_right"          : "StandingReactLargeFromRight",
	"react_back"           : "StandingReactLargeGut",
	"block_react"          : "StandingBlockReactLarge",
	"equip_over_shoulder"  : "StandingEquipOverShoulder",
	"disarm_over_shoulder" : "StandingDisarmOverShoulder",
	"death"                : "StandingReactDeathBackward",
}

const ATTACK_POOL := ["attack_360", "attack_backhand", "attack_ver", "attack_side"]

func _get_animation_map() -> Dictionary: return ANIMATION_MAP
func pick_attack() -> String: return ATTACK_POOL[randi() % ATTACK_POOL.size()]
func _get_idle_state() -> String: return "standing_idle" if _is_armed else "unarmed_idle"
