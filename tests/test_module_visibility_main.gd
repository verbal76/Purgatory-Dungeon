extends Node
## The real main scene with the real minimap: the distance culling is booted by the game script,
## hides far rooms, shows EVERYTHING while the map key is held (the minimap camera renders the
## whole level from 550 m up) and hides them again after, without touching collision.
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


func _hidden_modules(gen: Node) -> int:
	var c := 0
	for m in gen.placed_modules:
		if is_instance_valid(m) and not (m as Node3D).visible:
			c += 1
	return c


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	GlobalRunData.character_class = "barbarian"
	var main: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	add_child(main)
	await _frames(240)
	var gen: Node = main.get_node_or_null("DungeonGenerationFunction")
	var vis: Node = main.get_node_or_null("ModuleVisibility")
	var map: Node = main.get_node_or_null("minimap_function")
	_check(vis != null, "the game script boots ModuleVisibility")
	_check(map != null, "the minimap node exists")
	if vis == null or map == null:
		get_tree().quit(1)
		return
	for i in 12:   # hides are rate limited (40 per update): let it converge
		vis.refresh(false)
	var hidden0 := _hidden_modules(gen)
	print("  metric modules=%d hidden=%d hidden_items=%d" % [gen.placed_modules.size(), hidden0, vis.hidden_count()])
	_check(hidden0 > gen.placed_modules.size() / 3, "far rooms are hidden at the start (%d of %d)" % [hidden0, gen.placed_modules.size()])
	var player: Node3D = main.get_node_or_null("Player")
	_check(player != null and gen.get_module_containing_point(player.global_position) != null, "the player stands in a module")
	var pm: Node3D = gen.get_module_containing_point(player.global_position)
	_check(pm == null or pm.visible, "the player's module is shown")

	# hold the map key
	var action: String = map.minimap_action_name
	Input.action_press(action)
	await _frames(4)
	_check(bool(map._map_visible), "the map is open")
	_check(_hidden_modules(gen) == 0 and vis.hidden_count() == 0, "map open: no module and no item is hidden (%d / %d)" % [_hidden_modules(gen), vis.hidden_count()])
	await _frames(40)
	_check(_hidden_modules(gen) == 0, "map still open: still everything shown")
	Input.action_release(action)
	await _frames(4)
	_check(not bool(map._map_visible), "the map is closed")
	await _frames(60)   # 0.25 s updates, 40 hides each
	var hidden1 := _hidden_modules(gen)
	_check(hidden1 > gen.placed_modules.size() / 3, "after the map closes the far rooms are hidden again (%d)" % hidden1)

	# physics of a hidden module still works: a ray straight down through it hits its floor
	var space: PhysicsDirectSpaceState3D = (main as Node3D).get_world_3d().direct_space_state
	var ok_hits := 0
	var tested := 0
	for m in gen.placed_modules:
		if tested >= 6:
			break
		if is_instance_valid(m) and not (m as Node3D).visible:
			var box: AABB = gen.get_module_aabb(m)
			if box.size == Vector3.ZERO:
				continue
			var top := box.get_center() + Vector3(0, box.size.y + 3.0, 0)
			var q := PhysicsRayQueryParameters3D.create(top, top + Vector3.DOWN * (box.size.y + 10.0))
			q.collision_mask = 1
			tested += 1
			if not space.intersect_ray(q).is_empty():
				ok_hits += 1
	_check(tested > 0 and ok_hits > 0, "rays still hit hidden modules (%d of %d)" % [ok_hits, tested])

	print("test_module_visibility_main: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
