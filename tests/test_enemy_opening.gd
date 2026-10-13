extends Node
## The opening keeps a growing share of the population near the player: far, off-screen sleepers are recycled (never near or
## on-screen ones), a few per tick, toward a target that ramps from 25 % to 60 % of the cap over the first two minutes.

var _fails: int = 0
var _checks: int = 0


class FakeEnemy extends Node3D:
	var _is_dead: bool = false
	var _is_on_screen: bool = false
	var retired: int = 0
	var em: Node = null
	func _retire_stuck() -> void:
		retired += 1
		em._active_enemies.erase(self)
		em._live_count = maxi(em._live_count - 1, 0)


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
	await _frames(120)
	var player: Node3D = main.get_node("Player")
	var waited := 0
	while (get_tree().paused or not player.is_on_floor()) and waited < 3000:
		await get_tree().physics_frame
		waited += 1
	var em = main.get_node("EnemyManager")
	em.set_physics_process(false)   # drive the manager by hand
	var real: Array = em._active_enemies.duplicate()
	em._active_enemies = []
	em._live_count = 0

	# --- the ramp ------------------------------------------------------------------------------------
	em._current_pop_cap = 15
	em._run_time = 0.0
	_check(em._near_target() == 4, "cap 15 at the start wants 4 near the player (%d)" % em._near_target())
	em._run_time = 60.0
	_check(em._near_target() > 4 and em._near_target() < 9, "...and grows during the ramp (%d at 60 s)" % em._near_target())
	em._run_time = 120.0
	_check(em._near_target() == 9, "...to 9 after two minutes (%d)" % em._near_target())
	em._run_time = 900.0
	_check(em._near_target() == 9, "...and stays there")
	em._current_pop_cap = 30
	em._run_time = 0.0
	_check(em._near_target() == 8, "cap 30 starts at 8 (%d)" % em._near_target())
	em._current_pop_cap = 15

	# --- recycling -----------------------------------------------------------------------------------
	var far: Array = []
	for i in 12:
		var e := FakeEnemy.new()
		e.em = em
		add_child(e)
		e.global_position = player.global_position + Vector3(60.0 + float(i), 0.0, 0.0)
		em._active_enemies.append(e)
		em._live_count += 1
		far.append(e)
	var on_screen := FakeEnemy.new()
	on_screen.em = em
	on_screen._is_on_screen = true
	add_child(on_screen)
	on_screen.global_position = player.global_position + Vector3(70.0, 0.0, 0.0)
	em._active_enemies.append(on_screen)
	em._live_count += 1
	var dead := FakeEnemy.new()
	dead.em = em
	dead._is_dead = true
	add_child(dead)
	dead.global_position = player.global_position + Vector3(80.0, 0.0, 0.0)
	em._active_enemies.append(dead)
	em._live_count += 1

	em._run_time = 0.0
	var n: int = em._recycle_far_sleepers()
	_check(n == em.RECYCLE_PER_TICK, "an empty neighbourhood recycles RECYCLE_PER_TICK (%d) far sleepers per tick (%d)" % [em.RECYCLE_PER_TICK, n])
	_check(em._recycle_far_sleepers(false) == 0, "with recycling not allowed (cap not full) nothing is recycled, the near count is only refreshed")
	var total_retired := 0
	for e in far:
		total_retired += e.retired
	_check(total_retired == 2, "only the 2 recycled by the first tick are gone (%d)" % total_retired)
	em._run_time = 0.0
	_check(on_screen.retired == 0 and dead.retired == 0, "an on-screen enemy and a dead one are never recycled")

	# Near enemies fill the target: nothing more is recycled, and near ones are never touched.
	var near_list: Array = []
	for i in 4:
		var ne := FakeEnemy.new()
		ne.em = em
		add_child(ne)
		ne.global_position = player.global_position + Vector3(10.0 + float(i), 0.0, 0.0)
		em._active_enemies.append(ne)
		em._live_count += 1
		near_list.append(ne)
	_check(em._recycle_far_sleepers() == 0 and em._last_near_count == 4, "with the near target met nothing is recycled (near %d)" % em._last_near_count)
	em._run_time = 120.0   # target 9 now: wants 5 more near, so recycling resumes
	_check(em._recycle_far_sleepers() == em.RECYCLE_PER_TICK, "as the ramp raises the target, recycling resumes")
	var near_retired := 0
	for ne in near_list:
		near_retired += ne.retired
	_check(near_retired == 0, "an enemy near the player is never recycled")

	# The top-up tick runs it before it counts the deficit.
	var src: String = (em.get_script() as GDScript).source_code
	var a: int = src.find("func _top_up_population")
	var b: int = src.find("_recycle_far_sleepers(", a)
	var c: int = src.find("var deficit", a)
	_check(a >= 0 and b > a and b < c, "_top_up_population recycles before it counts the deficit")
	_check(src.find("awake_short", a) > a and src.find("sort_custom", a) > a, "a short opening fills the closest spawn points first")

	print("test_enemy_opening: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
