extends Node
## The player starts looking into the useful open space with the nearest wall behind them. Pure scoring cases, real physics
## rays against synthetic rooms (wall behind, corner, corridor, doorway, props, chests), and (SPAWN_CLASS=barbarian|mage) the
## real Barbarian / Mage placed in the real starter room of generated dungeons.

const MAIN_SCENE := "res://scenes/Purgatory_Dungeon_main_game_file.tscn"
const Main = preload("res://scripts/Purgatory_Dungeon_main_game_file.gd")

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _ready() -> void:
	var cls: String = OS.get_environment("SPAWN_CLASS")
	if cls == "":
		_scoring_tests()
		await _geometry_tests()
	else:
		await _real_player_tests(cls)
	print("test_spawn_facing%s: %d checks, %d failures" % ["" if cls == "" else " (" + cls + ")", _checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _fwd(yaw: float) -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


func _ang_diff(a: float, b: float) -> float:
	return absf(angle_difference(a, b))


# ── pure scoring ────────────────────────────────────────────────────────────────
func _clear_array(fn: Callable) -> PackedFloat32Array:
	var n: int = Main.SPAWN_RAY_COUNT
	var a := PackedFloat32Array()
	a.resize(n)
	for i in n:
		a[i] = minf(float(fn.call(TAU * float(i) / float(n))), Main.SPAWN_OPEN_CAP)
	return a


func _scoring_tests() -> void:
	# open on all sides: deterministic (lowest yaw)
	_check(Main.spawn_yaw_from_clearances(_clear_array(func(_y): return 30.0)) == 0.0, "an open space gives the deterministic default yaw 0")
	_check(Main.spawn_yaw_from_clearances(PackedFloat32Array()) == 0.0, "no data gives yaw 0")
	# a wall 1 m straight ahead of the default facing (yaw 0 looks along -Z), open everywhere else: never face it
	var wall_ahead: PackedFloat32Array = _clear_array(func(y): return 1.0 if _ang_diff(y, 0.0) < deg_to_rad(40.0) else 30.0)
	var y1: float = Main.spawn_yaw_from_clearances(wall_ahead)
	_check(_ang_diff(y1, PI) < deg_to_rad(15.0), "a wall straight ahead: turn round to face away from it (%.0f deg)" % rad_to_deg(y1))
	# the nearest wall is on the left (yaw +90 deg is left): the wall ends up behind, never ahead
	var wall_left: PackedFloat32Array = _clear_array(func(y): return 1.5 if _ang_diff(y, PI * 0.5) < deg_to_rad(40.0) else 30.0)
	var y2: float = Main.spawn_yaw_from_clearances(wall_left)
	_check(_ang_diff(y2, -PI * 0.5) < deg_to_rad(40.0), "a wall on the left: face away from it (%.0f deg)" % rad_to_deg(y2))
	# two equidistant parallel walls (a corridor-like room): face along the corridor, not into either wall
	var corridor: PackedFloat32Array = _clear_array(func(y): return 5.0 / maxf(absf(sin(y)) , 0.05) if absf(sin(y)) > 0.3 else 30.0)
	var y3: float = Main.spawn_yaw_from_clearances(corridor)
	_check(_ang_diff(y3, 0.0) < deg_to_rad(20.0) or _ang_diff(y3, PI) < deg_to_rad(20.0), "a corridor: face along it (%.0f deg)" % rad_to_deg(y3))
	# a solid enclosure with one slit: the broad open side beats the single narrow slit
	var slit: PackedFloat32Array = _clear_array(func(y): return 30.0 if _ang_diff(y, 1.0) < deg_to_rad(3.0) else (9.0 if _ang_diff(y, 3.5) < deg_to_rad(50.0) else 2.0))
	var y4: float = Main.spawn_yaw_from_clearances(slit)
	_check(_ang_diff(y4, 3.5) < deg_to_rad(25.0), "a thin slit does not outweigh a broad open side (%.0f deg)" % rad_to_deg(y4))


# ── real physics against synthetic geometry ────────────────────────────────────────────────
func _box(parent: Node, centre: Vector3, size: Vector3, kind: String = "wall") -> void:
	var body: CollisionObject3D
	if kind == "prop":
		var rb := RigidBody3D.new()
		rb.freeze = true
		body = rb
	else:
		body = StaticBody3D.new()
		if kind == "chest":
			body.add_to_group("chest")
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)
	parent.add_child(body)
	body.global_position = centre


func _room(parent: Node, half_x: float, half_z: float) -> void:
	_box(parent, Vector3(0, 1, -half_z - 0.5), Vector3(half_x * 2.0 + 2.0, 4, 1))
	_box(parent, Vector3(0, 1, half_z + 0.5), Vector3(half_x * 2.0 + 2.0, 4, 1))
	_box(parent, Vector3(-half_x - 0.5, 1, 0), Vector3(1, 4, half_z * 2.0 + 2.0))
	_box(parent, Vector3(half_x + 0.5, 1, 0), Vector3(1, 4, half_z * 2.0 + 2.0))


func _yaw_at(origin: Vector3) -> float:
	return Main.compute_spawn_yaw(get_viewport().world_3d.direct_space_state, origin + Vector3(0, 1.0, 0), [])


func _geometry_tests() -> void:
	# A 20 x 20 room, player 1.5 m from the north wall (the default facing, -Z, looks straight at it).
	var root := Node3D.new()
	add_child(root)
	_room(root, 10.0, 10.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var y: float = _yaw_at(Vector3(0, 0, -8.5))
	_check(_ang_diff(y, PI) < deg_to_rad(30.0), "1.5 m from the north wall: faces south, into the room (%.0f deg)" % rad_to_deg(y))
	y = _yaw_at(Vector3(8.5, 0, 0))   # east wall close: face west (yaw +90 deg looks along -X)
	_check(_ang_diff(y, PI * 0.5) < deg_to_rad(30.0), "1.5 m from the east wall: faces west (%.0f deg)" % rad_to_deg(y))
	# corner (north-west): faces the diagonal into the room (south-east)
	y = _yaw_at(Vector3(-8.5, 0, -8.5))
	var f: Vector3 = _fwd(y)
	_check(f.x > 0.3 and f.z > 0.3, "in the north-west corner: faces the room's diagonal (forward %s)" % f)
	# a prop and a chest right in front do not count as walls: the wall behind still decides
	_box(root, Vector3(0, 0.5, -5.5), Vector3(1.5, 1, 1.5), "prop")
	_box(root, Vector3(0.0, 0.5, -4.5), Vector3(1.5, 1, 1.5), "chest")
	y = _yaw_at(Vector3(0, 0, -7.5))
	_check(_ang_diff(y, PI) < deg_to_rad(30.0), "props and chests are not walls (faces south, %.0f deg)" % rad_to_deg(y))
	root.queue_free()
	await get_tree().physics_frame

	# a narrow corridor along X (4 m wide, 40 m long): faces along it
	var c := Node3D.new()
	add_child(c)
	_box(c, Vector3(0, 1, -2.5), Vector3(40, 4, 1))
	_box(c, Vector3(0, 1, 2.5), Vector3(40, 4, 1))
	_box(c, Vector3(-20.5, 1, 0), Vector3(1, 4, 6))
	await get_tree().physics_frame
	await get_tree().physics_frame
	y = _yaw_at(Vector3(-15, 0, 0.5))
	var fc: Vector3 = _fwd(y)
	_check(fc.x > 0.9, "in a dead-end corridor: faces out along it, the end wall behind (forward %s)" % fc)
	y = _yaw_at(Vector3(0, 0, 0.5))
	_check(absf(_fwd(y).x) > 0.9, "in the middle of a corridor: faces along it, not into a side wall (forward %s)" % _fwd(y))
	c.queue_free()
	await get_tree().physics_frame

	# a doorway: a room whose only exit is a gap in the east wall: faces the doorway or the room's far side, never the near wall
	var d := Node3D.new()
	add_child(d)
	_box(d, Vector3(0, 1, -5.5), Vector3(12, 4, 1))
	_box(d, Vector3(0, 1, 5.5), Vector3(12, 4, 1))
	_box(d, Vector3(-6.5, 1, 0), Vector3(1, 4, 12))
	_box(d, Vector3(6.5, 1, -3.5), Vector3(1, 4, 4))
	_box(d, Vector3(6.5, 1, 3.5), Vector3(1, 4, 4))
	await get_tree().physics_frame
	await get_tree().physics_frame
	y = _yaw_at(Vector3(-4.5, 0, 0))
	_check(_fwd(y).x > 0.5, "near the back wall of a room with a doorway: faces the room / doorway (forward %s)" % _fwd(y))
	d.queue_free()


# ── the real players in the real starter room ───────────────────────────────────────────────────
func _real_player_tests(cls: String) -> void:
	for seed_value in [11, 5, 2024]:
		SaveManager.load_slot(0)
		SaveManager.create_initial_identity("SpawnTester", cls)
		GlobalRunData.character_class = cls
		GlobalRunData.seed_hash = seed_value
		var main: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
		add_child(main)
		var player: CharacterBody3D = null
		for i in 1500:
			await get_tree().physics_frame
			player = main.get_node_or_null("Player") as CharacterBody3D
			if player != null and not get_tree().paused and player.is_on_floor() and Vector2(player.global_position.x, player.global_position.z).length() < 0.6:
				break
		_check(player != null, "[%s/%d] player exists" % [cls, seed_value])
		if player == null:
			main.queue_free()
			continue
		await get_tree().physics_frame
		var space := player.get_world_3d().direct_space_state
		var origin: Vector3 = Vector3(player.global_position.x, 1.5, player.global_position.z)   # the game's own ray height (spawn marker + 1 m)
		var yaw: float = float(player.get("_yaw"))
		var fwd: Vector3 = Vector3(-sin(player.rotation.y), 0.0, -cos(player.rotation.y))
		_check(_ang_diff(player.rotation.y, yaw) < 0.01, "[%s/%d] the body and the view agree on the facing (%.3f vs %.3f)" % [cls, seed_value, player.rotation.y, yaw])
		var ahead: float = Main.spawn_clearance(space, origin, player.rotation.y, [player.get_rid()])
		var behind: float = Main.spawn_clearance(space, origin, player.rotation.y + PI, [player.get_rid()])
		var best: float = 0.0
		var nearest: float = INF
		var nearest_dir: float = 0.0
		for i in 36:
			var c: float = Main.spawn_clearance(space, origin, TAU * float(i) / 36.0, [player.get_rid()])
			best = maxf(best, minf(c, Main.SPAWN_OPEN_CAP))
			if c < nearest:
				nearest = c
				nearest_dir = TAU * float(i) / 36.0
		print("spawn facing [%s/%d]: ahead %.1f m, behind %.1f m, nearest wall %.1f m at %.0f deg from forward" % [cls, seed_value, ahead, behind, nearest, rad_to_deg(angle_difference(player.rotation.y, nearest_dir))])
		_check(ahead >= minf(best, Main.SPAWN_OPEN_CAP) * 0.9, "[%s/%d] the player looks into the open space (%.1f m ahead, best %.1f m)" % [cls, seed_value, ahead, best])
		_check(ahead > nearest + 0.5 or ahead >= Main.SPAWN_OPEN_CAP, "[%s/%d] not facing the nearest wall (ahead %.1f, nearest %.1f)" % [cls, seed_value, ahead, nearest])
		main.queue_free()
		for i in 5:
			await get_tree().process_frame
