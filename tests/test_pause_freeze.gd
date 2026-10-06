extends Node
## While the game is paused (pause menu), always-process managers must freeze:
## no enemy timers/spawns, no pressure-spawn timeout accrual, no flying homing fireballs.

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	GlobalRunData.character_class = "barbarian"
	var main: Node = (load("res://scenes/Purgatory_Dungeon_main_game_file.tscn") as PackedScene).instantiate()
	add_child(main)
	await _frames(240)
	var manager = main.get_node("EnemyManager")
	var traps = main.get_node("TrapManager")
	var player = main.get_node("Player")
	var pause = main.get_node("pause_menu_function")
	# 240 frames is not real time: the entry loading screen keeps the tree paused for a wall-clock floor, so a fast headless
	# run can reach this point with the player still dropping into the start room (the fireball then spawned in a wall). Wait
	# until play has really started and the player stands.
	var waited := 0
	while (get_tree().paused or not player.is_on_floor()) and waited < 3000:
		await get_tree().physics_frame
		waited += 1
	await _frames(30)
	# The player must start on the room floor: no prop (a 1.7 m crate, a table) may be furnished onto the spawn point.
	var under := PhysicsRayQueryParameters3D.create(player.global_position, player.global_position + Vector3(0, -4, 0))
	under.exclude = [player.get_rid()]
	var under_hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(under)
	var under_body: Node = under_hit.get("collider") as Node
	_check(under_body == null or not under_body.is_in_group("kickable_prop"), "the player does not start standing on a prop (%s)" % [str(under_body.name) if under_body != null else "nothing"])

	# Launch a homing fireball from open space (a spot in a wall would free it on contact). The dungeon
	# is random: a free ray does not guarantee a 0.3 m sphere clear of props at the spawn point, so try
	# each open direction until one fireball survives its first frames.
	var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	var fb: Area3D = null
	var found_open := false
	for i in 8:
		var d := Vector3.FORWARD.rotated(Vector3.UP, i * PI / 4.0)
		var q := PhysicsRayQueryParameters3D.create(player.global_position + Vector3(0, 1.0, 0), player.global_position + Vector3(0, 1.0, 0) + d * 6.0)
		q.collision_mask = 1
		q.exclude = [player.get_rid()]
		if not space.intersect_ray(q).is_empty():
			continue
		found_open = true
		traps._launch_homing_fireball(player.global_position + d * 5.0, player)
		await _frames(2)
		if traps._homing_fireballs.size() > 0 and is_instance_valid(traps._homing_fireballs.back()):
			fb = traps._homing_fireballs.back()
			break
	_check(found_open, "found open space for the fireball")
	_check(fb != null, "homing fireball is in flight")
	if fb == null:
		get_tree().quit(1)
		return
	pause.open_menu()
	await _frames(2)
	_check(get_tree().paused, "paused")
	var fb_pos: Vector3 = fb.global_position
	var respawn_timer: float = manager._respawn_timer
	var cull_timer: float = manager._cull_timer
	var live_before: int = manager._live_count
	# Pretend the last damage was 10 s ago, then sit paused for 2 real seconds.
	var now_s: float = Time.get_ticks_msec() * 0.001
	CharacterBase.GLOBAL_PLAYER_LAST_DAMAGE_TIME = now_s - 10.0
	await get_tree().create_timer(2.0).timeout
	_check(fb.global_position.distance_to(fb_pos) < 0.01, "homing fireball does not fly while paused (moved %.2f m)" % fb.global_position.distance_to(fb_pos))
	_check(is_equal_approx(manager._respawn_timer, respawn_timer) and is_equal_approx(manager._cull_timer, cull_timer), "enemy manager timers do not run while paused")
	_check(manager._live_count == live_before, "no enemies spawn while paused (%d -> %d)" % [live_before, manager._live_count])

	pause.close_menu()
	await _frames(3)
	var gap: float = Time.get_ticks_msec() * 0.001 - CharacterBase.GLOBAL_PLAYER_LAST_DAMAGE_TIME
	_check(gap < 10.5, "time spent paused does not count towards the pressure-spawn timeout (%.1f s since 'last damage', expected ~10)" % gap)
	_check(not get_tree().paused, "unpaused")

	print("test_pause_freeze: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
