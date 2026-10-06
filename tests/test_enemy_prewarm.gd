extends Node
## Enemy pool pre-warm and recycling (hitch regression). Instantiating an enemy costs several milliseconds on a
## desktop and several times that on a phone, so it must not happen in the middle of play:
##   1. behind the loading screen EnemyManager parks spare enemies in its pools (hidden, dead, collision-less, out of
##      the "enemy" groups, nothing processing, far under the level) and only then lets the entry finish;
##   2. a top-up that draws from the pool adds NO node to the tree (a fresh instantiate adds ~17-45);
##   3. an enemy stuck for 12 s (frustration) is retired into the pool instead of being freed, and can be reborn.
## Real main scene, one process (like the other pooling tests).

const MAIN_SCENE := "res://scenes/Purgatory_Dungeon_main_game_file.tscn"

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _spawn_from_pool(manager: Node, gen: Node, spawn_type: int) -> Node3D:
	var entries: Array = gen.registered_typed_spawns.duplicate()
	entries.shuffle()
	for entry in entries:
		var forced: Dictionary = entry.duplicate()
		forced["type"] = spawn_type
		var before: int = manager._active_enemies.size()
		if manager._spawn_enemy_from_data(forced) and manager._active_enemies.size() > before:
			return manager._active_enemies.back() as Node3D
	return null


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	GlobalRunData.character_class = "barbarian"
	GlobalRunData.seed_hash = 7
	var main: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	add_child(main)
	var guard := 0
	while not bool(main.get("entry_is_complete")) and guard < 4000:
		await get_tree().process_frame
		guard += 1
	_check(bool(main.get("entry_is_complete")), "the entry completes (%d frames)" % guard)
	await _frames(30)
	var manager: Node = main.get_node("EnemyManager")
	var gen: Node = main.get_node("DungeonGenerationFunction")
	# Keep the world quiet: only what this test does spawns or moves.
	manager.set_physics_process(false)
	manager.stop_spawning()
	for e in manager._active_enemies:
		if is_instance_valid(e):
			e.set_physics_process(false)

	# 1. pre-warm ----------------------------------------------------------------------------------------------------
	_check(bool(manager.stage_near_done) and bool(manager.stage_done), "the enemy manager finished its entry stage (pre-warm)")
	var parked: int = manager._brute_pool.size() + manager._mage_pool.size()
	_check(parked >= int(manager.PREWARM_SPARE), "spares are parked in the pools (%d, at least %d)" % [parked, manager.PREWARM_SPARE])
	_check(parked <= int(manager.PREWARM_MAX) + int(manager._current_pop_cap), "the pools stay bounded (%d)" % parked)
	_check(bool(main.get("entry_is_ready")), "the hand-over happened after the pre-warm")
	var all_parked := true
	var why := ""
	for pool in [manager._brute_pool, manager._mage_pool]:
		for e in pool:
			if not is_instance_valid(e) or not e.is_inside_tree():
				all_parked = false
				why = "invalid or outside the tree"
			elif e.visible or e.is_physics_processing() or e.is_processing():
				all_parked = false
				why = "visible or processing (%s)" % e.name
			elif not bool(e.get("_is_dead")) or e.collision_layer != 0:
				all_parked = false
				why = "not dead / collidable (%s)" % e.name
			elif e.is_in_group("enemy") or e.is_in_group("enemies"):
				all_parked = false
				why = "still in an enemy group (%s)" % e.name
			elif e.global_position.y > -100.0:
				all_parked = false
				why = "not parked below the level (%s y=%.1f)" % [e.name, e.global_position.y]
			elif e.anim_player != null and e.anim_player.is_playing():
				all_parked = false
				why = "animation still playing (%s)" % e.name
	_check(all_parked, "every pooled enemy is parked (hidden, dead, collision-less, no groups, idle, below the level) " + why)

	# 2. reuse adds no nodes ---------------------------------------------------------------------------------------
	manager.mage_spawn_chance = 0.0   # type 2 spawn points give brutes: deterministic type
	for want_mage in [false, true]:
		var label := "mage" if want_mage else "brute"
		manager.mage_spawn_chance = 1.0 if want_mage else 0.0
		var pool: Array = manager._mage_pool if want_mage else manager._brute_pool
		if pool.is_empty():
			print("test_enemy_prewarm: no parked %s in this seed's pre-warm, reuse check skipped" % label)
			continue
		var pool_before: int = pool.size()
		var nodes_before: int = get_tree().get_node_count()
		var live_before: int = manager._live_count
		var e: Node3D = _spawn_from_pool(manager, gen, 2)
		var nodes_after: int = get_tree().get_node_count()
		_check(e != null, label + ": a spawn point accepted the pooled enemy")
		if e == null:
			continue
		_check(pool.size() == pool_before - 1, label + ": the pool gave one enemy (%d -> %d)" % [pool_before, pool.size()])
		_check(nodes_after == nodes_before, label + ": reuse added no node (%d -> %d)" % [nodes_before, nodes_after])
		_check(manager._live_count == live_before + 1, label + ": live count +1")
		_check(e.visible and not bool(e.get("_is_dead")) and e.collision_layer == 1, label + ": reborn visible, alive, collidable")
		_check(e.is_in_group("enemy") and e.is_in_group("enemies"), label + ": back in the enemy groups")
		_check(is_equal_approx(float(e.get("_current_health")), float(e.get("max_health"))), label + ": full health")
		await get_tree().process_frame
		_check(e.anim_player.is_playing(), label + ": animating again")

		# 3. a stuck enemy is retired into the pool, not freed -----------------------------------------------------
		e.set_physics_process(false)
		var id_before: int = e.get_instance_id()
		var live_mid: int = manager._live_count
		e._retire_stuck()
		await _frames(3)
		_check(is_instance_valid(e) and e.get_instance_id() == id_before and not e.is_queued_for_deletion(), label + ": a retired enemy is not freed")
		_check(pool.has(e), label + ": the retired enemy is back in its pool")
		_check(not manager._active_enemies.has(e), label + ": no longer in the live list")
		_check(manager._live_count == live_mid - 1, label + ": live count -1 (%d -> %d)" % [live_mid, manager._live_count])
		_check(not e.visible and bool(e.get("_is_dead")) and not e.is_in_group("enemies"), label + ": hidden, dead, out of the groups")
		# ...and can be reborn right away
		var again: Node3D = _spawn_from_pool(manager, gen, 2)
		_check(again == e, label + ": the very same enemy is reborn from the pool")
		if again != null:
			_check(again.visible and not bool(again.get("_is_dead")) and again.is_in_group("enemies"), label + ": reborn alive and in the groups")
	print("test_enemy_prewarm: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
