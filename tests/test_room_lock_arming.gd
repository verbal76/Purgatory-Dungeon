extends Node
## A brand-new run must not be hit by a red-barrier swarm room before the player's first daily buff
## selection. Real game scene, completely fresh character. One seed per process (LOCK_SEED, default 11).
##
## Progression checked:
##   1. fresh run, nothing armed; the player walks into a large room -> nothing happens, room not used up
##   2. the first buff selection happens while the player is STILL in that room -> no retroactive swarm
##   3. the player leaves and comes back -> now the room seals and the swarm spawns
## plus the buff-roulette-off path (arms on the day the first pick would have fired).

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


func _seconds(s: float) -> void:
	await _frames(int(ceil(s * 30.0)))   # physics runs at 30 ticks/s


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	var seed_value := int(OS.get_environment("LOCK_SEED")) if OS.get_environment("LOCK_SEED") != "" else 11

	# --- a completely fresh character --------------------------------------------------------------
	SaveManager.load_slot(9)
	SaveManager.current_profile = SaveManager.get_default_profile()
	SaveManager.create_initial_identity("FreshSwarmTest", "barbarian")
	BuffManager.reset()
	GlobalRunData.character_class = "barbarian"
	GlobalRunData.seed_hash = seed_value
	GlobalRunData.debug_no_buffs = false
	_check(BuffManager.get_active_buffs().is_empty(), "fresh character has no buffs")

	var main: Node = (load("res://scenes/Purgatory_Dungeon_main_game_file.tscn") as PackedScene).instantiate()
	add_child(main)
	await _frames(240)
	var gen = main.get_node("DungeonGenerationFunction")
	var player: CharacterBody3D = main.get_node("Player")
	var mgr = main.get_node_or_null("RoomLockManager")
	_check(mgr != null, "RoomLockManager is part of the run")
	if mgr == null:
		get_tree().quit(1)
		return
	_check(not mgr.is_armed(), "a new run starts with swarm rooms dormant")

	# Find a large room with its lock trigger.
	var room: Node3D = null
	var trigger: Area3D = null
	for m in gen.placed_modules:
		if not is_instance_valid(m) or not (m.scene_file_path in mgr.LARGE_ROOM_PATHS):
			continue
		for c in m.get_children():
			if c is Area3D and c.has_meta("lock_module"):
				room = m
				trigger = c
		if room != null:
			break
	_check(room != null, "seed %d has a large (swarm) room" % seed_value)
	if room == null:
		get_tree().quit(1)
		return
	var aabb: AABB = gen.get_module_aabb(room)
	var inside := Vector3(aabb.get_center().x, aabb.position.y + 1.0, aabb.get_center().z)
	var start_pos: Vector3 = player.global_position

	# Kill ambient enemies so only the swarm shows up in the counts.
	for e in get_tree().get_nodes_in_group("enemies"):
		if is_instance_valid(e) and e.has_method("take_damage"):
			e.take_damage(1.0e6, null)

	# --- 1. before the first buff: walking in does nothing ----------------------------------------------
	player.velocity = Vector3.ZERO
	player.global_position = inside
	await _seconds(7.0)   # longer than the lock's own 4.8 s inside-confirmation window
	_check(mgr._active_locks.is_empty(), "no red-barrier lock before the first buff selection")
	_check(not mgr._cleared.has(room), "the room is not used up by an early visit")
	_check(is_instance_valid(trigger) and not trigger.is_queued_for_deletion(), "its trigger is still there for later")
	_check(_count_blockers(room) == 0, "no red barriers in the room")

	# --- 2. the first buff is chosen while still standing in the room: not retroactive -----------------
	BuffManager.buff_chosen.emit({"id": "test_first_pick"})
	_check(mgr.is_armed(), "the first buff selection arms swarm rooms")
	await _seconds(7.0)
	_check(mgr._active_locks.is_empty() and _count_blockers(room) == 0, "a room already occupied at arming time does not swarm retroactively")
	_check(not mgr._cleared.has(room), "...and it is still eligible")

	# --- 3. leave and come back: the next qualifying entry swarms ----------------------------------------
	player.velocity = Vector3.ZERO
	player.global_position = start_pos
	await _seconds(1.0)
	player.velocity = Vector3.ZERO
	player.global_position = inside
	await _seconds(7.0)
	_check(mgr._active_locks.size() == 1, "re-entering after arming seals the room (%d locks)" % mgr._active_locks.size())
	_check(_count_blockers(room) > 0, "red barriers are up (%d)" % _count_blockers(room))
	_check(mgr._cleared.has(room), "the room is now used up (swarms once per run)")

	# --- 4. buff roulette switched off: arms on the day the first pick would have been --------------
	var solo = (load("res://scripts/room_lock_manager.gd") as GDScript).new()
	GlobalRunData.debug_no_buffs = true
	add_child(solo)
	solo.boot(player, null, null)
	_check(not solo.is_armed(), "roulette-off run starts dormant too")
	GameClock.day_changed.emit(1)
	_check(not solo.is_armed(), "still dormant on day 1")
	GameClock.day_changed.emit(maxi(GameClock.buff_every_n_days, 2))
	_check(solo.is_armed(), "arms on the day the first pick would have fired")
	GlobalRunData.debug_no_buffs = false
	solo.queue_free()

	# A normal run's manager ignores day changes: only the buff selection arms it.
	var solo2 = (load("res://scripts/room_lock_manager.gd") as GDScript).new()
	add_child(solo2)
	solo2.boot(player, null, null)
	GameClock.day_changed.emit(5)
	_check(not solo2.is_armed(), "days passing alone do not arm a normal run")
	BuffManager.buff_chosen.emit({})
	_check(solo2.is_armed(), "buff_chosen arms it")
	solo2.queue_free()

	print("test_room_lock_arming (seed %d): %d checks, %d failures" % [seed_value, _checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _count_blockers(room: Node3D) -> int:
	var n := 0
	for c in room.get_children():
		if c is StaticBody3D and c.get_child_count() > 0:
			for g in c.get_children():
				if g is MeshInstance3D and (g as MeshInstance3D).material_override is StandardMaterial3D \
						and ((g as MeshInstance3D).material_override as StandardMaterial3D).emission_enabled \
						and ((g as MeshInstance3D).material_override as StandardMaterial3D).emission.r > 0.9:
					n += 1
	return n
