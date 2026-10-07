extends Node
## Repulse (the old backward Slide on the jump / Slide input): a radial emergency push of every enemy around the player,
## with a short protected, rooted window and a cool-down. REPULSE_CLASS=barbarian (default) | mage.

var _fails: int = 0
var _checks: int = 0


class FakeEnemy extends CharacterBody3D:
	var _is_dead: bool = false
	var pushes: int = 0
	var last_dir: Vector3 = Vector3.ZERO
	var last_force: float = 0.0
	var last_stun: float = 0.0
	func take_knockback(direction: Vector3, force: float, stun: float = 1.0) -> void:
		pushes += 1
		last_dir = direction
		last_force = force
		last_stun = stun


class FakeProp extends Node3D:
	var kicks: int = 0
	func apply_kick(_dir: Vector3, _force: float) -> void:
		kicks += 1


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _press_jump() -> void:
	Input.action_press("jump")
	await _frames(2)
	Input.action_release("jump")
	await _frames(1)


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	var cls := OS.get_environment("REPULSE_CLASS")
	if cls == "":
		cls = "barbarian"
	GlobalRunData.character_class = cls
	var main: Node = (load("res://scenes/Purgatory_Dungeon_main_game_file.tscn") as PackedScene).instantiate()
	add_child(main)
	await _frames(120)
	var player: Node = main.get_node("Player") if cls == "barbarian" else get_tree().get_first_node_in_group("player")
	var waited := 0
	while (get_tree().paused or not player.is_on_floor()) and waited < 3000:
		await get_tree().physics_frame
		waited += 1
	await _frames(10)
	# Only the fakes below take part: park the real enemies and props out of the way.
	var em = main.get_node_or_null("EnemyManager")
	if em != null:
		em.set_physics_process(false)
	for e in get_tree().get_nodes_in_group("enemies"):
		e.remove_from_group("enemies")
	for p in get_tree().get_nodes_in_group("kickable_prop"):
		p.remove_from_group("kickable_prop")

	var radius: float = BruteCharacter.REPULSE_RADIUS
	_check(radius >= 4.0 and BruteCharacter.REPULSE_FORCE > 9.0, "Repulse reaches a crowd and pushes harder than a kick (radius %.1f m, force %.1f)" % [radius, BruteCharacter.REPULSE_FORCE])

	# Eight enemies on a ring, one in every direction (two directly behind), one beyond the radius, one dead, one on top of the player.
	var ring: Array = []
	for i in 8:
		var a := TAU * float(i) / 8.0
		var e := FakeEnemy.new()
		e.add_to_group("enemies")
		add_child(e)
		e.global_position = player.global_position + Vector3(cos(a), 0.0, sin(a)) * (1.5 + 0.4 * float(i % 4))
		ring.append(e)
	var far := FakeEnemy.new()
	far.add_to_group("enemies")
	add_child(far)
	far.global_position = player.global_position + Vector3(radius + 1.5, 0.0, 0.0)
	var dead := FakeEnemy.new()
	dead._is_dead = true
	dead.add_to_group("enemies")
	add_child(dead)
	dead.global_position = player.global_position + Vector3(0.0, 0.0, 2.0)
	var on_top := FakeEnemy.new()
	on_top.add_to_group("enemies")
	add_child(on_top)
	on_top.global_position = player.global_position
	var prop := FakeProp.new()
	prop.add_to_group("kickable_prop")
	add_child(prop)
	prop.global_position = player.global_position + Vector3(2.0, 0.0, 2.0)
	await _frames(2)

	# --- the input does it ------------------------------------------------------------------------------
	var hp0: float = player._current_health
	await _press_jump()
	for i in 8:
		var e: FakeEnemy = ring[i]
		var outward: Vector3 = e.global_position - player.global_position
		outward.y = 0.0
		outward = outward.normalized()
		_check(e.pushes == 1, "enemy %d on the ring is pushed exactly once" % i)
		_check(e.last_dir.dot(outward) > 0.99, "enemy %d is pushed straight away from the player (dot %.3f)" % [i, e.last_dir.dot(outward)])
		_check(e.last_force >= BruteCharacter.REPULSE_FORCE * BruteCharacter.REPULSE_EDGE_FORCE - 0.01 and e.last_force <= BruteCharacter.REPULSE_FORCE + 0.01,
				"enemy %d force %.1f is between the edge and the full strength" % [i, e.last_force])
		_check(is_equal_approx(e.last_stun, BruteCharacter.REPULSE_STUN), "enemy %d is stunned for the Repulse stun" % i)
	_check(far.pushes == 0, "an enemy beyond the radius is not pushed")
	_check(dead.pushes == 0, "a dead enemy is not pushed")
	_check(on_top.pushes == 1 and on_top.last_dir.length() > 0.99, "an enemy exactly on the player still gets a direction")
	_check(prop.kicks == 1, "a prop in range is kicked once")

	# --- protected and rooted during the short window ------------------------------------------------------
	_check(player._is_sliding, "the player is in the Repulse window")
	player.take_damage(25.0, null)
	_check(is_equal_approx(player._current_health, hp0), "the player takes no damage during Repulse (%.1f -> %.1f)" % [hp0, player._current_health])
	_check(is_zero_approx(player.velocity.x) and is_zero_approx(player.velocity.z), "the player stays put during Repulse")
	await get_tree().create_timer(BruteCharacter.REPULSE_DURATION + 0.25).timeout
	_check(not player._is_sliding, "the window ends after about %.2f s" % BruteCharacter.REPULSE_DURATION)
	player.take_damage(25.0, null)
	_check(player._current_health < hp0, "the player is vulnerable again afterwards")
	player._current_health = hp0

	# --- cool-down: an immediate second press does nothing; after it, it works again -----------------
	await _press_jump()
	_check(ring[0].pushes == 1, "a second press inside the cool-down does not push again")
	player._repulse_cooldown = 0.0
	await _press_jump()
	_check(ring[0].pushes == 2, "after the cool-down Repulse works again")
	await get_tree().create_timer(BruteCharacter.REPULSE_DURATION + 0.25).timeout

	# --- Heavy Gravity halves the push (it halves slide_power) ------------------------------------------
	var full: float = ring[1].last_force
	player.apply_status("heavy_gravity", 1)
	player._repulse_cooldown = 0.0
	await _press_jump()
	_check(ring[1].pushes == 3 and absf(ring[1].last_force - full * 0.5) < 0.05, "Heavy Gravity halves the push (%.2f -> %.2f)" % [full, ring[1].last_force])

	# --- the old slide is gone ---------------------------------------------------------------------------
	_check(not player.has_method("_check_slide_knockback"), "the backward slide knockback no longer exists")

	print("test_repulse (%s): %d checks, %d failures" % [cls, _checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
