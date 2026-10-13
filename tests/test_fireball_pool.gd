extends Node
## Regression: pooled enemy fireballs (initialised the way mage_ai does) must
## still damage the player they hit.

var _fails: int = 0
var _checks: int = 0


class FakePlayer extends CharacterBody3D:
	var damage_taken: float = 0.0
	func take_damage(amount: float, _src: Node = null) -> void:
		damage_taken += amount


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _ready() -> void:
	var scene: PackedScene = load("res://characters/Lutsch Mage/projectiles/fireball.tscn")
	for offset_x in [0.0, 0.3, -0.3]:
		var player := FakePlayer.new()
		player.add_to_group("player")
		var shape := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = 0.4
		cap.height = 1.8
		shape.shape = cap
		player.add_child(shape)
		add_child(player)
		player.global_position = Vector3(0, 1, 0)

		var fb = scene.instantiate()
		add_child(fb)
		# Exactly what mage_ai._init_fireball_pool does:
		fb.visible = false
		fb.set_physics_process(false)
		fb._is_active = false
		if "monitoring" in fb:
			fb.set_deferred("monitoring", false)
		await get_tree().physics_frame
		await get_tree().physics_frame
		fb.global_position = Vector3(offset_x, 1, 8)
		fb.activate(10.0, Vector3(0, 0, -1))
		for i in 120:
			await get_tree().physics_frame
		_check(player.damage_taken == 10.0, "pooled fireball (x offset %.1f) damages player exactly once (took %.1f)" % [offset_x, player.damage_taken])
		_check(not fb._is_active, "fireball deactivated after impact")
		player.queue_free()
		fb.queue_free()
		await get_tree().physics_frame

	print("test_fireball_pool: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
