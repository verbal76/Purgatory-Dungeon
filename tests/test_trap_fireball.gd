extends Node
## Regression: a trap's homing fireball is aimed at the player. It must fly through enemies
## (no damage, no detonation) and still hit the player exactly once.

var _fails: int = 0
var _checks: int = 0


class FakeBody extends CharacterBody3D:
	var damage_taken: float = 0.0
	func take_damage(amount: float, _src: Node = null) -> void:
		damage_taken += amount


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _body(group: String, pos: Vector3) -> FakeBody:
	var b := FakeBody.new()
	b.add_to_group(group)
	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	shape.shape = cap
	b.add_child(shape)
	add_child(b)
	b.global_position = pos
	return b


func _ready() -> void:
	await get_tree().process_frame   # the root is still 'busy setting up children' during _ready
	var holder := Node3D.new()
	add_child(holder)
	var mgr: Node = (load("res://scripts/trap_manager.gd") as GDScript).new()
	holder.add_child(mgr)
	await get_tree().physics_frame

	for with_enemy in [false, true]:
		var player := _body("player", Vector3(0, 0, 0))
		var enemy: FakeBody = null
		if with_enemy:
			enemy = _body("enemy", Vector3(0, 0, 4))
			enemy.add_to_group("enemies")
		await get_tree().physics_frame
		mgr._launch_homing_fireball(Vector3(0, 0, 8), player)
		for i in 240:
			await get_tree().physics_frame
		var tag := "with an enemy in the path" if with_enemy else "with a clear path"
		_check(is_equal_approx(player.damage_taken, mgr.homing_fireball_damage), "player takes the fireball exactly once %s (took %.1f)" % [tag, player.damage_taken])
		if with_enemy:
			_check(enemy.damage_taken == 0.0, "an enemy in the path takes no damage from a trap fireball (took %.1f)" % enemy.damage_taken)
		player.queue_free()
		if enemy != null:
			enemy.queue_free()
		await get_tree().physics_frame

	print("test_trap_fireball: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
