extends Node
## Starting health of the two playable classes (v8.2): Barbarian 200, Mage 135 (the Mage stays the less durable class). A fresh player
## starts the run at full health, and the enemy scene health is untouched.

const BARBARIAN_HP: float = 200.0
const MAGE_HP: float = 135.0

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _spawn(path: String) -> CharacterBody3D:
	var p: CharacterBody3D = (load(path) as PackedScene).instantiate() as CharacterBody3D
	add_child(p)
	return p


func _ready() -> void:
	var barb: CharacterBody3D = _spawn("res://characters/brute/scenes/brute_player.tscn")
	var mage: CharacterBody3D = _spawn("res://characters/Lutsch Mage/scenes/Mage player.tscn")
	await get_tree().physics_frame
	await get_tree().physics_frame
	var perks: Dictionary = SaveManager.current_profile.get("perks", {}) if SaveManager.current_profile is Dictionary else {}
	var vit: float = 10.0 * float(perks.get("vitality", 0))
	_check(is_equal_approx(float(barb.get("max_health")), BARBARIAN_HP), "Barbarian max health is %d (got %s)" % [int(BARBARIAN_HP), str(barb.get("max_health"))])
	_check(is_equal_approx(float(barb.get("_current_health")), float(barb.get("max_health"))), "Barbarian starts the run at full health")
	_check(is_equal_approx(float(mage.get("max_health")), MAGE_HP + vit), "Mage max health is %d (+%d Vitality perk) (got %s)" % [int(MAGE_HP), int(vit), str(mage.get("max_health"))])
	_check(is_equal_approx(float(mage.get("_current_health")), float(mage.get("max_health"))), "Mage starts the run at full health")
	_check(float(mage.get("max_health")) < float(barb.get("max_health")) + vit, "the Mage stays less durable than the Barbarian")
	var brute_enemy: Node = (load("res://characters/brute/scenes/brute_enemy.tscn") as PackedScene).instantiate()
	_check(is_equal_approx(float(brute_enemy.get("max_health")), 100.0), "enemy scene health is untouched (brute enemy %s)" % str(brute_enemy.get("max_health")))
	brute_enemy.free()
	print("test_starting_health: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
