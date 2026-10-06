extends Node
## Physics-query regressions: rays meant to see "world geometry only" must not be
## blocked by enemies, props or chests (everything shares collision layer 1).
## Run with PHYS_CLASS=barbarian (default) or PHYS_CLASS=mage.

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


func _capsule_body(pos: Vector3, group: String) -> CharacterBody3D:
	var b := CharacterBody3D.new()
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	cs.shape = cap
	cs.position = Vector3(0, 0.9, 0)
	b.add_child(cs)
	b.add_to_group(group)
	add_child(b)
	b.global_position = pos
	return b


func _wall(pos: Vector3) -> StaticBody3D:
	var w := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.3, 3.0, 4.0)
	cs.shape = box
	cs.position = Vector3(0, 1.5, 0)
	w.add_child(cs)
	add_child(w)
	w.global_position = pos
	return w


func _floor_y(space: PhysicsDirectSpaceState3D, p: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 2, 0), p + Vector3(0, -6, 0))
	q.collision_mask = 1
	var r := space.intersect_ray(q)
	return r.position.y if not r.is_empty() else NAN


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	var cls := OS.get_environment("PHYS_CLASS")
	if cls == "":
		cls = "barbarian"
	GlobalRunData.character_class = cls
	var main: Node = (load("res://scenes/Purgatory_Dungeon_main_game_file.tscn") as PackedScene).instantiate()
	add_child(main)
	await _frames(240)
	var manager = main.get_node("EnemyManager")
	var player: CharacterBody3D = main.get_node("Player")
	# The frame count above is not real time: the entry loading screen holds the tree paused for a wall-clock floor, so a fast
	# headless run could sample the player mid-drop (its height varied 0.9-2.6 m from run to run, and the start room's own
	# lintel then sat on the attacker's line in about 1 run in 60). Wait until play has really started and the player stands.
	var waited := 0
	while (get_tree().paused or not player.is_on_floor()) and waited < 3000:
		await get_tree().physics_frame
		waited += 1
	await _frames(30)
	manager.set_physics_process(false)
	for e in manager._active_enemies:
		if is_instance_valid(e):
			e.queue_free()
	manager._active_enemies.clear()
	await _frames(3)
	var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	var base: Vector3 = player.global_position

	# Find a clear spot in the start room with open floor in some direction.
	var dir := Vector3.ZERO
	var target := Vector3.ZERO
	var ref_floor := INF   # the room's floor level: the lowest first surface found around the player
	for i in 8:
		var fy0 := _floor_y(space, base + Vector3.FORWARD.rotated(Vector3.UP, i * PI / 4.0) * 5.0)
		if not is_nan(fy0):
			ref_floor = minf(ref_floor, fy0)
	for i in 8:
		var d := Vector3.FORWARD.rotated(Vector3.UP, i * PI / 4.0)
		var t := base + d * 5.0
		var fy := _floor_y(space, t)
		if is_nan(fy):
			continue
		# The start room is random per run: a tall prop or obstacle on the spot makes the raw floor ray hit its top
		# (1.7 m above the real floor in the one CI failure), which then contradicts the floor snap that ignores props.
		# Only a spot whose first surface is the room's floor tests what these checks mean to test.
		if fy - ref_floor > 0.3:
			continue
		var q := PhysicsRayQueryParameters3D.create(base + Vector3(0, 1.6, 0), t + Vector3(0, 1.0, 0))
		q.collision_mask = 1
		q.exclude = [player.get_rid()]
		if not space.intersect_ray(q).is_empty():
			continue
		# The brute's own sight ray runs level at 1 m from its feet to the player's 1 m, so the
		# line-of-sight checks below need that exact ray clear too. The start room is random per
		# run; without this a low static obstacle on that ray made two checks fail intermittently.
		var level := PhysicsRayQueryParameters3D.create(base + Vector3(0, 1.0, 0), Vector3(t.x, base.y + 1.0, t.z))
		level.collision_mask = 1
		level.exclude = [player.get_rid()]
		if space.intersect_ray(level).is_empty():
			dir = d
			target = t
			break
	_check(dir != Vector3.ZERO, "found open floor with clear sight 5 m from the player")
	if dir == Vector3.ZERO:
		get_tree().quit(1)
		return
	var floor_y := _floor_y(space, target)

	if cls == "barbarian":
		# --- spawn floor snap ignores props -----------------------------------
		var snap_base: Vector3 = manager._snap_to_floor(Vector3(target.x, floor_y, target.z))
		_check(absf(snap_base.y - (floor_y + 0.15)) < 0.05, "baseline: snaps to the floor (%.2f vs %.2f)" % [snap_base.y, floor_y + 0.15])
		var prop := RigidBody3D.new()
		var ps := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(1, 1, 1)
		ps.shape = box
		ps.position = Vector3(0, 0.5, 0)
		prop.add_child(ps)
		prop.freeze = true
		add_child(prop)
		prop.global_position = Vector3(target.x, floor_y, target.z)
		prop.add_to_group("kickable_prop")
		await _frames(2)
		var snap_prop: Vector3 = manager._snap_to_floor(Vector3(target.x, floor_y, target.z))
		_check(absf(snap_prop.y - (floor_y + 0.15)) < 0.05, "a prop at the spawn point does not lift the spawn onto its top (%.2f)" % snap_prop.y)
		prop.queue_free()

		# --- 'can the player see this spawn' is not blocked by an enemy ----------
		var ally := _capsule_body(base + dir * 2.5, "enemy")
		await _frames(2)
		var sees: bool = manager._player_can_see_spawn(target)
		_check(sees, "an enemy standing in the line does not hide a visible spawn point from the check")
		ally.queue_free()
		var wall := _wall(base + dir * 2.5)
		wall.look_at(wall.global_position + dir)
		await _frames(2)
		_check(not manager._player_can_see_spawn(target), "a real wall still hides the spawn point")
		wall.queue_free()
		await _frames(2)

		# --- brute line of sight sees through allies --------------------------
		var brute = null
		for entry in main.get_node("DungeonGenerationFunction").registered_typed_spawns:
			var forced: Dictionary = entry.duplicate()
			forced["type"] = 1
			if manager._spawn_enemy_from_data(forced):
				brute = manager._active_enemies.back()
				break
		_check(brute != null, "spawned a brute for the line-of-sight check")
		if brute != null:
			brute.set_physics_process(false)
			brute.global_position = base + dir * 5.0
			var ally2 := _capsule_body(base + dir * 2.5, "enemy")
			await _frames(2)
			brute._has_los = false
			brute._los_timer = 99.0
			brute._update_los(player, 0.0)
			_check(brute._has_los, "brute keeps line of sight when an ally stands between it and the player")
			ally2.queue_free()
			await _frames(2)
			brute._los_timer = 99.0
			brute._update_los(player, 0.0)
			_check(brute._has_los, "line of sight holds once the ally leaves")
			var wall2 := _wall(base + dir * 2.5)
			wall2.look_at(wall2.global_position + dir)
			await _frames(2)
			brute._los_timer = 99.0
			brute._update_los(player, 0.0)
			_check(not brute._has_los, "a real wall still blocks the brute's line of sight")
			wall2.queue_free()
	else:
		# --- mage takes damage through an ally -------------------------------
		var attacker := CharacterBody3D.new()   # real damage sources are bodies/areas (have a RID)
		add_child(attacker)
		attacker.global_position = base + dir * 5.0
		var hp0: float = player._current_health
		player.take_damage(10.0, attacker)
		await _frames(1)
		_check(player._current_health < hp0, "baseline: mage takes damage from a clear attacker (%.1f -> %.1f)" % [hp0, player._current_health])
		player._current_health = hp0
		var ally3 := _capsule_body(base + dir * 2.5, "enemy")
		await _frames(2)
		player.take_damage(10.0, attacker)
		_check(player._current_health < hp0, "mage still takes damage when an ally stands between it and the attacker (%.1f -> %.1f)" % [hp0, player._current_health])
		ally3.queue_free()
		await _frames(2)
		player._current_health = hp0
		var wall3 := _wall(base + dir * 2.5)
		wall3.look_at(wall3.global_position + dir)
		await _frames(2)
		player.take_damage(10.0, attacker)
		_check(is_equal_approx(player._current_health, hp0), "a real wall still blocks damage to the mage")
		wall3.queue_free()

	print("test_physics_queries: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
