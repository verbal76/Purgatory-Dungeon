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
