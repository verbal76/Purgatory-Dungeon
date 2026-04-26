# ============================================================
#  FILE: mage_base.gd
#  PATH: res://characters/Lutsch Mage/scripts/mage_base.gd
#  ATTACHED TO: Inherited by MageCharacter
#  USED BY: character_base.gd, mage_player.gd, mage_ai.gd
#  NOTES:
#  Maps generic state names to GLTF animation string names.
#  Contains attack pool, hand spawn point references, and
#  helpers for 1H vs 2H attack logic.
#
#  Animation names remapped to Brute_multi.gltf (brute model used as mage stand-in).
#  Original mage animation names preserved as comments for when the real mage model
#  is reintroduced.
# ============================================================

extends CharacterBase
class_name MageCharacter

# ── Hand spawn points (assign in Inspector or scene) ────────
# These are Marker3D nodes positioned on each hand in the scene.
# Projectiles / particles will spawn from these positions.
@export var left_hand_marker  : Marker3D
@export var right_hand_marker : Marker3D

# ── Animation map ──────────────────────────────────────────
# Mapped to Brute_multi.gltf animations (brute model stand-in).
# Brute has no strafing, separate walk, or multi-directional death anims —
# those keys fall back to the closest available equivalent.
const ANIMATION_MAP := {
	# Idle
	"standing_idle"           : "StandingIdle",

	# Movement — run (brute has no strafe anims; fall back to fwd/back)
	"standing_run_forward"    : "StandingRunForward",
	"standing_run_back"       : "StandingRunBack",
	"standing_run_left"       : "StandingRunForward",
	"standing_run_right"      : "StandingRunForward",
	"standing_sprint_forward" : "StandingRunForward",

	# Movement — walk (brute has no walk anims; use run)
	"standing_walk_forward"   : "StandingRunForward",
	"standing_walk_back"      : "StandingRunBack",
	"standing_walk_left"      : "StandingRunForward",
	"standing_walk_right"     : "StandingRunForward",

	# Turns (no dedicated turn anims; hold idle)
	"standing_turn_left_90"   : "StandingIdle",
	"standing_turn_right_90"  : "StandingIdle",

	# Jump (brute has UnarmedJumpRunning; no separate land anim)
	"standing_jump"                 : "UnarmedJumpRunning",
	"standing_jump_running"         : "UnarmedJumpRunning",
	"standing_jump_running_landing" : "StandingIdle",
	"standing_land_to_idle"         : "StandingIdle",

	# 1H cast → vertical staff strike / backhand / side sweep
	"attack_1h_cast_01"   : "StandingMeleeAttackVer",        # vertical = staff thrust downward
	"attack_1h_01"        : "StandingMeleeAttackBackhand",   # backhand = magic flick
	"attack_1h_03"        : "StandingMeleeAttacksidetoSide", # side sweep = wide cast

	# 2H cast → same pool + spin for AOE
	"attack_2h_cast_01"   : "StandingMeleeAttack360High",    # 360 spin = AOE cast
	"attack_2h_01"        : "StandingMeleeAttackVer",
	"attack_2h_02"        : "StandingMeleeKickVer",          # shove → kick
	"attack_2h_03"        : "StandingMeleeAttackBackhand",
	"attack_2h_05"        : "StandingMeleeAttack360High",
	"attack_2h_area_01"   : "StandingMeleeAttack360High",
	"attack_2h_area_02"   : "StandingMeleeAttacksidetoSide",

	# Block (brute has no block_start/idle/end — hold idle, react on hit)
	"block_start"   : "StandingIdle",
	"block_idle"    : "StandingIdle",
	"block_end"     : "StandingIdle",
	"block_react"   : "StandingBlockReactLarge",

	# React — large (brute has gut/left/right but not separate front/back)
	"react_large_front" : "StandingReactLargeGut",
	"react_large_back"  : "StandingReactLargeGut",
	"react_large_left"  : "StandingReactLargeFromLeft",
	"react_large_right" : "StandingReactLargeFromRight",

	# React — small (brute has no small react; use large)
	"react_small_front" : "StandingReactLargeGut",
	"react_small_back"  : "StandingReactLargeGut",
	"react_small_left"  : "StandingReactLargeFromLeft",
	"react_small_right" : "StandingReactLargeFromRight",

	# Death (brute only has backward; all directions map to it)
	"death_backward" : "StandingReactDeathBackward",
	"death_forward"  : "StandingReactDeathBackward",
	"death_left"     : "StandingReactDeathBackward",
	"death_right"    : "StandingReactDeathBackward",

	# Legacy fallbacks
	"react_gut"  : "StandingReactLargeGut",
	"react_left" : "StandingReactLargeFromLeft",
	"react_right": "StandingReactLargeFromRight",
	"react_back" : "StandingReactLargeGut",
	"death"      : "StandingReactDeathBackward",
}

# ── Attack pools ───────────────────────────────────────────
const ATTACK_POOL := [
	"attack_1h_cast_01",
	"attack_1h_01",
	"attack_1h_03",
	"attack_2h_cast_01",
	"attack_2h_01",
	"attack_2h_02",
	"attack_2h_03",
	"attack_2h_05",
	"attack_2h_area_01",
	"attack_2h_area_02",
]

const TWO_HANDED_ATTACKS := [
	"attack_2h_cast_01",
	"attack_2h_01",
	"attack_2h_02",
	"attack_2h_03",
	"attack_2h_05",
	"attack_2h_area_01",
	"attack_2h_area_02",
]

# ── Death directions ──────────────────────────────────────
const DEATH_ANIMS := {
	"backward" : "death_backward",
	"forward"  : "death_forward",
	"left"     : "death_left",
	"right"    : "death_right",
}


func _get_animation_map() -> Dictionary:
	return ANIMATION_MAP


# Mage is always in magic stance, no armed/unarmed toggle
func _get_idle_state() -> String:
	return "standing_idle"


func _is_locomotion_state(state_name: String) -> bool:
	return state_name in [
		"standing_idle",
		"standing_run_forward", "standing_run_back", "standing_run_left", "standing_run_right",
		"standing_walk_forward", "standing_walk_back", "standing_walk_left", "standing_walk_right",
		"standing_sprint_forward",
	]


func pick_attack() -> String:
	return ATTACK_POOL[randi() % ATTACK_POOL.size()]


# 1H-only pool — used by the player for right-trigger attacks.
# 2H animations are reserved for the shove (right bumper).
const ATTACK_POOL_1H := [
	"attack_1h_cast_01",
	"attack_1h_01",
	"attack_1h_03",
]

func pick_1h_attack() -> String:
	return ATTACK_POOL_1H[randi() % ATTACK_POOL_1H.size()]


func is_two_handed(attack_key: String) -> bool:
	return attack_key in TWO_HANDED_ATTACKS


func pick_death_direction() -> String:
	# Override in AI to pick based on open space.
	# Default fallback: backward.
	return "death_backward"


func get_spawn_position_right() -> Vector3:
	if right_hand_marker != null:
		return right_hand_marker.global_position
	return global_position + Vector3(0.0, 1.5, 0.0)


func get_spawn_position_left() -> Vector3:
	if left_hand_marker != null:
		return left_hand_marker.global_position
	return global_position + Vector3(0.0, 1.5, 0.0)
