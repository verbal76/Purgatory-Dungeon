extends Node
## Pool-reuse regression for enemies. A pooled enemy must behave like a fresh one:
## no death pose, normal animation speed, full health, and no leftover coroutine
## from its previous life may touch the new life.

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


func _find_enemy(manager, gen, want_mage: bool) -> CharacterBase:
	var entries: Array = gen.registered_typed_spawns.duplicate()
	entries.shuffle()
	for e in manager._active_enemies:
		if is_instance_valid(e) and e.visible and ("mage_ai" in e.get_script().resource_path) == want_mage:
			return e
	for entry in entries:
		var forced: Dictionary = entry.duplicate()
		forced["type"] = 2 if want_mage else 1
		var before: int = manager._active_enemies.size()
		if manager._spawn_enemy_from_data(forced) and manager._active_enemies.size() > before:
			var e = manager._active_enemies.back()
			if ("mage_ai" in e.get_script().resource_path) == want_mage:
				return e
	return null


func _exercise(label: String, e: CharacterBase, manager, player) -> void:
	var death_name: String = str(e._anim_map.get("death", ""))
	_check(death_name != "", label + ": death animation is mapped")
	for cycle in 3:
		var tag := "%s cycle %d: " % [label, cycle + 1]
		var spawn_pos: Vector3 = e.global_position
		# Die while standing idle (the state that used to leave the death pose behind).
		e._state = ""
		e._change_state(e._get_idle_state())
		e.take_damage(1.0e6, player)
		_check(e._is_dead, tag + "enemy dies")
		var wait := 0.0
		while e.visible and wait < 8.0:
			await get_tree().create_timer(0.25).timeout
			wait += 0.25
		_check(not e.visible, tag + "corpse returned to pool and hidden (%.2fs)" % wait)
		_check(manager._brute_pool.has(e) or manager._mage_pool.has(e), tag + "enemy is in a pool")
		# Reuse exactly as EnemyManager does.
		e.reset_for_pool(spawn_pos, Vector3.ZERO, manager._waypoints)
		await _frames(3)
		_check(e.visible and not e._is_dead, tag + "reborn alive and visible")
		_check(is_equal_approx(e._current_health, e.max_health), tag + "full health")
		_check(e.collision_layer == 1, tag + "collision restored")
		# A finished non-looping animation reports current_animation == "" while its last
		# pose stays applied, so check the assigned animation and that something is playing.
		_check(e.anim_player.assigned_animation != death_name, tag + "not stuck on the death pose (assigned: %s)" % e.anim_player.assigned_animation)
		_check(e.anim_player.is_playing(), tag + "an animation is playing after rebirth")
		# A reborn enemy that is already inside the player's attack range may legitimately begin ITS OWN attack within these
		# frames (the attack plays at its own speed); what must never survive is the previous life's death / react speed.
		var attacking: bool = "_is_attacking" in e and bool(e.get("_is_attacking"))
		_check(attacking or is_equal_approx(e.anim_player.speed_scale, 1.0), tag + "animation speed reset (%.2f)" % e.anim_player.speed_scale)

	# Leftover coroutine from a previous life must not touch a new life.
	e._is_attacking = false
	if e.has_method("_do_attack"):
		e._do_attack(player)
	else:
		e._do_spell_attack(player)
	await get_tree().physics_frame
	var pre_attack_flag: bool = e._is_attacking
	_check(pre_attack_flag, label + ": attack coroutine started")
	e.take_damage(1.0e6, player)
	e.reset_for_pool(e.global_position, Vector3.ZERO, manager._waypoints)   # instant reuse
	e._is_attacking = true        # sentinel: the new life is attacking
	e._attack_cooldown_timer = 500.0
	await get_tree().create_timer(5.0).timeout
	_check(e._is_attacking, label + ": stale attack coroutine did not clear the new life's attack flag")
	_check(e._attack_cooldown_timer > 400.0, label + ": stale attack coroutine did not overwrite the new life's cooldown (%.1f)" % e._attack_cooldown_timer)
	_check(not e._is_dead and e.visible, label + ": new life not killed/pooled by an old life's timer")


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
	var gen = main.get_node("DungeonGenerationFunction")
	var player = main.get_node("Player")
	# Keep the world quiet so only the enemy under test acts.
	manager.set_physics_process(false)
	for e in manager._active_enemies:
		if is_instance_valid(e):
			e.set_physics_process(false)
	for want_mage in [false, true]:
		var label := "mage" if want_mage else "brute"
		var e: CharacterBase = _find_enemy(manager, gen, want_mage)
		_check(e != null, label + ": found a live enemy to test")
		if e == null:
			continue
		e.set_physics_process(true)
		await _exercise(label, e, manager, player)
	# A freed enemy mage must not leave its fireball pool behind.
	var mage = _find_enemy(manager, gen, true)
	if mage != null:
		var count_fb := func() -> int:
			var n := 0
			for c in get_tree().current_scene.get_children():   # mage_ai parents its pool here
				if c.scene_file_path.ends_with("fireball.tscn"):
					n += 1
			return n
		var before: int = count_fb.call()
		_check(before >= 6, "enemy mage owns a fireball pool (%d fireballs in scene)" % before)
		manager._active_enemies.erase(mage)
		mage.queue_free()
		await _frames(5)
		var after: int = count_fb.call()
		_check(before - after >= 6, "freeing the mage frees its fireball pool (%d -> %d)" % [before, after])
	print("test_enemy_pooling: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
