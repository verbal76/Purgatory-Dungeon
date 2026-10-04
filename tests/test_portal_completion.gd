extends Node
## The Day-30 portal must never be permanently shut by enemy accounting: no reinforcements after
## the lock, no stale count, no enemy stranded below the world, no sealed-in last survivors, and
## no stacking hint layers.

var _fails: int = 0
var _checks: int = 0


class FakeEnemy extends Node3D:
	var _is_dead: bool = false
	func take_damage(_amount: float, _src: Node = null) -> void:
		_is_dead = true


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
	var player: Node3D = main.get_node("Player")
	var gen = main.get_node("DungeonGenerationFunction")
	manager.set_physics_process(false)
	for e in manager._active_enemies:
		if is_instance_valid(e):
			e.queue_free()
	manager._active_enemies.clear()
	manager._live_count = 0
	await _frames(3)

	# --- No reinforcements once spawning is locked (pressure spawn) ---------------------------
	# Use a type-3 spawn point the player cannot see, so the unlocked control really spawns.
	var hidden: Dictionary = {}
	var min_d: float = manager.min_spawn_distance
	for entry in manager._all_spawns:
		if int(entry.get("type", 1)) != 3:
			continue
		var pos: Vector3 = entry.get("position", Vector3.ZERO)
		if player.global_position.distance_to(pos) > min_d + 1.0 and not manager._player_can_see_spawn(pos):
			hidden = entry
			break
	_check(not hidden.is_empty(), "found a hidden type-3 spawn point for the pressure-spawn check")
	if not hidden.is_empty():
		manager._all_spawns = [hidden]
		CharacterBase.GLOBAL_PLAYER_LAST_DAMAGE_TIME = Time.get_ticks_msec() * 0.001 - 60.0
		var before: int = manager._active_enemies.size()
		manager._check_pressure_spawn()
		_check(manager._active_enemies.size() == before + 1, "control: pressure spawn adds an enemy when spawning is unlocked")
		manager.stop_spawning()
		var locked_before: int = manager._active_enemies.size()
		var live_before: int = manager._live_count
		for i in 5:
			manager._check_pressure_spawn()
		_check(manager._active_enemies.size() == locked_before and manager._live_count == live_before,
			"pressure spawn adds nothing after the Day-30 lock (%d -> %d)" % [locked_before, manager._active_enemies.size()])
		manager.resume_spawning()
	manager._active_enemies.clear()
	manager._live_count = 0

	# --- Portal accounting ----------------------------------------------------------------------
	var portal := Node3D.new()
	portal.set_script(load("res://scripts/portal_manager.gd"))
	add_child(portal)
	var root := Node3D.new()
	add_child(root)
	root.global_position = player.global_position
	portal._portal_root = root
	portal._player = player
	portal._enemy_mgr = manager
	portal._dungeon_gen = gen

	manager._live_count = 7   # stale: the sweep has not run, nothing is actually alive
	_check(portal._enemies_remaining() == 0, "a stale _live_count does not hold the portal shut")
	portal._recheck_entry()
	_check(portal._entry_shown, "portal opens when no enemy is actually alive")
	portal._entry_shown = false
	manager._live_count = 0

	# An enemy below the world is rescued (killed) so it cannot hold the portal shut.
	var fallen := FakeEnemy.new()
	add_child(fallen)
	fallen.global_position = Vector3(0, -50, 0)
	manager._active_enemies.append(fallen)
	_check(portal._enemies_remaining() == 1, "an enemy below the world still counts until rescued")
	portal._rescue_stranded()
	_check(fallen._is_dead and portal._enemies_remaining() == 0, "an enemy that fell out of the world is rescued")
	manager._active_enemies.clear()

	# Sealed-in survivors: only a few remain and none dies for STALL_SECONDS -> the portal opens.
	var stuck: Array = []
	for i in 3:
		var e := FakeEnemy.new()
		add_child(e)
		e.global_position = player.global_position
		stuck.append(e)
		manager._active_enemies.append(e)
	portal._update_stall(1.0)
	_check(not portal._entry_ready(), "3 survivors keep the portal shut at first")
	for i in 3:
		portal._update_stall(portal.STALL_SECONDS / 2.0)
	_check(portal._entry_ready(), "3 unreachable survivors no longer hold the portal shut after the stall window")
	(stuck[0] as FakeEnemy)._is_dead = true
	portal._update_stall(1.0)
	_check(portal._stall_time == 0.0, "the stall timer restarts when an enemy dies")
	manager._active_enemies.clear()
	for i in 6:
		var e2 := FakeEnemy.new()
		add_child(e2)
		manager._active_enemies.append(e2)
	portal._update_stall(portal.STALL_SECONDS * 2.0)
	_check(not portal._entry_ready(), "many survivors are never waved through by the failsafe")
	manager._active_enemies.clear()

	# --- Last-stand minimap markers -----------------------------------------------------------------------
	var stub_map := Node.new()
	var stub_src := GDScript.new()
	stub_src.source_code = "extends Node\nvar last: Array = [null]\nfunc set_enemy_markers(p: Array) -> void:\n\tlast = p\n"
	stub_src.reload()
	stub_map.set_script(stub_src)
	add_child(stub_map)
	portal._minimap = stub_map
	var survivors: Array = []
	for i in 3:
		var e3 := FakeEnemy.new()
		add_child(e3)
		e3.global_position = Vector3(10.0 * i, 0, 5)
		survivors.append(e3)
		manager._active_enemies.append(e3)
	portal._update_enemy_markers()
	_check(stub_map.last.size() == 3, "the last 3 enemies are marked on the minimap (%d markers)" % stub_map.last.size())
	for i in 6:
		var e4 := FakeEnemy.new()
		add_child(e4)
		manager._active_enemies.append(e4)
	portal._update_enemy_markers()
	_check(stub_map.last.size() == 0, "with many enemies left nothing is marked (the map is not cluttered)")
	manager._active_enemies.clear()
	portal._update_enemy_markers()
	_check(stub_map.last.size() == 0, "nothing is marked when no enemy remains")
	var real_map = main.get_node_or_null("minimap_function")
	if real_map != null:
		real_map._bounds_valid = true
		real_map.set_enemy_markers([Vector3(1, 0, 1), Vector3(2, 0, 2), Vector3(3, 0, 3)])
		real_map._update_enemy_dots()
		var shown := 0
		for d in real_map._enemy_dots:
			if d.visible:
				shown += 1
		_check(shown == 3, "the minimap draws one dot per marked enemy (%d)" % shown)
		real_map.set_enemy_markers([])
		var still := 0
		for d in real_map._enemy_dots:
			if d.visible:
				still += 1
		_check(still == 0, "clearing the markers hides every dot")
		_check(real_map._enemy_dots.size() <= real_map.MAX_ENEMY_MARKERS, "dots are capped (%d)" % real_map._enemy_dots.size())
	for e5 in survivors:
		e5.queue_free()

	# --- Guards cannot be placed in the void ---------------------------------------------------
	var outside := Vector3(9000.0, 0.0, 9000.0)
	var guard_pos: Vector3 = portal._valid_guard_position(outside, player.global_position)
	_check(gen.is_position_inside_dungeon(guard_pos), "a guard origin outside the dungeon falls back to a valid position (%s)" % guard_pos)

	# --- One hint layer, however often the portal is re-entered --------------------------------
	portal._show_not_ready_hint(5)
	portal._show_not_ready_hint(4)
	portal._show_not_ready_hint(3)
	var layers: int = 0
	for c in get_tree().root.get_children():
		if c is CanvasLayer and (c as CanvasLayer).layer == 15 and c.get_child_count() == 1 and c.get_child(0) is Label \
				and (c.get_child(0) as Label).text.contains("enemies remain"):
			layers += 1
	_check(layers == 1, "re-entering the portal reuses one hint layer (found %d)" % layers)
	portal._update_hint(10.0)
	await get_tree().process_frame
	await get_tree().process_frame
	layers = 0
	for c in get_tree().root.get_children():
		if c is CanvasLayer and (c as CanvasLayer).layer == 15 and c.get_child_count() == 1 and c.get_child(0) is Label \
				and (c.get_child(0) as Label).text.contains("enemies remain"):
			layers += 1
	_check(layers == 0, "the hint layer is removed after its time (found %d)" % layers)

	print("test_portal_completion: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
