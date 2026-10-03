extends Node
## Boots the real main game scene headlessly and exercises player spawn,
## dungeon generation, enemy spawning and a kill with credit.
## Run via tests/run_tests.sh (needs PURGATORY_SAVE_ROOT).

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
		await get_tree().physics_frame


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	var char_class := OS.get_environment("SMOKE_CLASS")
	if char_class == "":
		char_class = "barbarian"
	GlobalRunData.character_class = char_class
	print("smoke class: ", char_class)
	var main: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	add_child(main)
	await _frames(240)

	# --- dungeon -------------------------------------------------------------
	var gen = main.get_node_or_null("DungeonGenerationFunction")
	_check(gen != null, "generator node present")
	_check(gen.placed_modules.size() > 100, "dungeon placed >100 modules (%d)" % gen.placed_modules.size())
	_check(gen.counted_piece_total >= gen.target_piece_count, "room target met (%d/%d)" % [gen.counted_piece_total, gen.target_piece_count])
	_check(gen.registered_typed_spawns.size() > 0, "typed enemy spawns registered")
	_check(gen.registered_waypoints.size() > 0, "waypoints registered")

	_check(Time.get_ticks_msec() * 0.001 - CharacterBase.GLOBAL_PLAYER_LAST_DAMAGE_TIME < 30.0, "pressure-spawn timer starts at run start, not already expired")
	GameClock.enter_legendary_mode()
	GameClock.start_run()
	_check(not GameClock.legendary_mode and GameClock.max_days == 30, "starting a run clears Legendary state")

	# --- player --------------------------------------------------------------
	var players := get_tree().get_nodes_in_group("player")
	_check(players.size() == 1, "exactly one player in group (%d)" % players.size())
	var player: CharacterBase = players[0] as CharacterBase if players.size() > 0 else null
	_check(player != null, "player is a CharacterBase")
	_check(main.get_node_or_null("Player") != null, "main scene can find its child named 'Player' (name not auto-renamed)")
	if player != null:
		_check(gen.is_position_inside_dungeon(player.global_position), "player stands inside the dungeon bounds")
		_check(player.global_position.y > -1.0 and player.global_position.y < 10.0, "player did not fall through the floor (y=%.2f)" % player.global_position.y)
		var hp_before: float = player._current_health if "_current_health" in player else -1.0
		player.take_damage(5.0, null)
		if hp_before >= 0.0:
			_check(player._current_health < hp_before, "player takes damage")

	# --- enemies -----------------------------------------------------------
	# Enemies spawn by proximity (a ring around the player), so a stationary player in
	# a start room with no spawn points nearby may legitimately see none for a while.
	# Give natural spawning a bounded chance, then fall back to the manager's real
	# spawn function so the rest of the pipeline is still exercised deterministically.
	var manager = main.get_node_or_null("EnemyManager")
	_check(manager != null, "EnemyManager booted")
	var live: Array = []
	var waited := 0
	var natural := true
	var skip_natural := OS.get_environment("SMOKE_SKIP_NATURAL") != ""   # lets CI exercise the fallback
	for e in get_tree().get_nodes_in_group("enemy"):
		if skip_natural and e is CharacterBase:
			e.queue_free()
	while not skip_natural:
		live.clear()
		for e in get_tree().get_nodes_in_group("enemy"):
			if e is CharacterBase and e.visible and not e._is_dead:
				live.append(e)
		if live.size() >= 2 or waited >= 300:
			break
		await _frames(10)
		waited += 10
	if skip_natural:
		live.clear()
	if live.size() < 2 and manager != null and player != null:
		natural = false
		var spawns: Array = gen.registered_typed_spawns.duplicate()
		spawns.sort_custom(func(a, b): return player.global_position.distance_squared_to(a["position"]) > player.global_position.distance_squared_to(b["position"]))
		for entry in spawns:
			if manager._spawn_enemy_from_data(entry):
				await _frames(5)
			live.clear()
			for e in get_tree().get_nodes_in_group("enemy"):
				if e is CharacterBase and e.visible and not e._is_dead:
					live.append(e)
			if live.size() >= 2:
				break
	print("metric: %d live enemies; natural proximity spawn within %d frames: %s" % [live.size(), waited, str(natural)])
	_check(live.size() > 0, "enemies spawned (%d live)" % live.size())

	var fallen := 0
	for e in live:
		if e.global_position.y < -1.0:
			fallen += 1
	_check(fallen == 0, "no live enemy fell through the floor (%d fell)" % fallen)
	var explored := 0
	for m in gen.placed_modules:
		if m.has_meta("explored") and bool(m.get_meta("explored")):
			explored += 1
	_check(explored > 0, "exploration reveals modules around the player (%d explored)" % explored)

	# --- combat: kill with credit, kill without credit ---------------------
	if live.size() >= 2 and player != null:
		var kills_before: int = CharacterBase.GLOBAL_KILL_COUNT
		var victim: CharacterBase = live[0]
		var died_flag := [false]
		victim.died.connect(func(): died_flag[0] = true)
		victim.take_damage(1.0e6, player)
		_check(victim._is_dead, "enemy dies from lethal damage")
		_check(died_flag[0], "died signal emitted")
		_check(CharacterBase.GLOBAL_KILL_COUNT == kills_before + 1, "player kill is credited exactly once")
		victim.take_damage(1.0e6, player)
		_check(CharacterBase.GLOBAL_KILL_COUNT == kills_before + 1, "second hit on a corpse does not double-credit")
		var culled: CharacterBase = live[1]
		culled.take_damage(1.0e6, null)
		_check(CharacterBase.GLOBAL_KILL_COUNT == kills_before + 1, "sourceless death (cull/trap) is not credited")
		await get_tree().create_timer(4.0).timeout
		_check(not victim.visible or not is_instance_valid(victim) or victim.is_queued_for_deletion(), "corpse is hidden/pooled/freed after death animation")

	# Legendary Mode brings reinforcements back (spawning is locked when the run ends).
	if manager != null:
		manager.stop_spawning()
		var end_screen := CanvasLayer.new()
		end_screen.set_script(load("res://scripts/run_end_screen.gd"))
		add_child(end_screen)
		end_screen._on_legendary_pressed()
		_check(not manager._spawning_locked, "choosing Legendary Mode re-enables enemy spawning")
		_check(GameClock.legendary_mode, "legendary mode active")

	print("test_gameplay_smoke: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
