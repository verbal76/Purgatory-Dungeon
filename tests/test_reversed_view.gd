extends Node
## Reversed View (trap) lasts exactly as long as Intoxicated, expires back to a normal camera, and can never stay stuck:
## pause, death, day changes and a fresh run (what a load / floor change produces) are covered.
## Run with REVERSE_CLASS=barbarian (default) or REVERSE_CLASS=mage.

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


func _arm_x(player: Node) -> float:
	var arm := player.get_node_or_null("SpringArm3D") as Node3D
	return arm.rotation.x if arm != null else NAN


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	var cls := OS.get_environment("REVERSE_CLASS")
	if cls == "":
		cls = "barbarian"
	GlobalRunData.character_class = cls
	var main: Node = (load("res://scenes/Purgatory_Dungeon_main_game_file.tscn") as PackedScene).instantiate()
	add_child(main)
	await _frames(120)
	var player: Node = main.get_node("Player") if cls == "barbarian" else get_tree().get_first_node_in_group("player")
	# Real time, not frames: the entry loading screen holds the tree paused for a wall-clock floor.
	var waited := 0
	while (get_tree().paused or not player.is_on_floor()) and waited < 3000:
		await get_tree().physics_frame
		waited += 1
	await _frames(10)

	# --- one authoritative duration -------------------------------------------------------------
	_check(BruteCharacter.STATUS_REVERSED_VIEW_SECONDS == BruteCharacter.STATUS_DRUNK_SECONDS, "Reversed View and Intoxicated share one duration constant")
	player.apply_status("drunk", 0)
	player.apply_status("reversed_view", 0)
	_check(is_equal_approx(player._status_reversed_view_timer, player._status_drunk_timer), "the %s starts Reversed View with the same time as Intoxicated (%.1f vs %.1f s)" % [cls, player._status_reversed_view_timer, player._status_drunk_timer])
	_check(is_equal_approx(player._status_reversed_view_timer, BruteCharacter.STATUS_DRUNK_SECONDS), "Reversed View uses the Intoxicated duration (%.1f s)" % player._status_reversed_view_timer)
	# The old behaviour was one in-game day regardless of the day argument: a large day count must not stretch it.
	player.apply_status("reversed_view", 5)
	_check(is_equal_approx(player._status_reversed_view_timer, BruteCharacter.STATUS_DRUNK_SECONDS), "the day count no longer sets the Reversed View duration")
	_check(player._status_day_effects_days == 0, "Reversed View no longer takes part in the day-based effect count")

	# --- view flips while active, ticks down with the game ---------------------------------------
	await _frames(3)
	_check(is_equal_approx(_arm_x(player), PI), "the camera is upside-down while Reversed View is active")
	var before: float = player._status_reversed_view_timer
	await _frames(30)
	_check(player._status_reversed_view_timer < before - 0.5, "the Reversed View timer counts down with physics time (%.2f -> %.2f)" % [before, player._status_reversed_view_timer])

	# --- an in-game day passing does not touch it (it is not day-based) -------------------------
	var left: float = player._status_reversed_view_timer
	GameClock.day_changed.emit(GameClock.current_day + 1 if "current_day" in GameClock else 2)
	await _frames(2)
	_check(player._status_reversed_view and player._status_reversed_view_timer <= left, "a day change neither ends nor extends Reversed View")

	# --- pause: the countdown stops with the game ----------------------------------------------
	get_tree().paused = true
	var paused_at: float = player._status_reversed_view_timer
	await _frames(40)
	_check(is_equal_approx(player._status_reversed_view_timer, paused_at), "Reversed View does not count down while paused")
	get_tree().paused = false
	await _frames(2)

	# --- expiry restores the normal camera ----------------------------------------------------
	player._status_reversed_view_timer = 0.05
	await _frames(6)
	_check(not player._status_reversed_view, "Reversed View ends when its time is up")
	await _frames(3)
	_check(is_equal_approx(_arm_x(player), 0.0), "the camera is back to normal after Reversed View ends (%.2f)" % _arm_x(player))

	# --- re-apply refreshes, then death clears everything ---------------------------------------
	player.apply_status("reversed_view", 0)
	player.apply_status("drunk", 0)
	player.apply_status("reversed_controls", 0)
	player.apply_status("acid_pool", 8, 1.0)
	_check(player._status_reversed_view, "Reversed View re-applies after expiring")
	player.clear_timed_statuses()
	_check(not player._status_reversed_view and not player._status_drunk and not player._status_reversed_controls and not player._status_acid, "clear_timed_statuses ends every timed trap status")
	player.apply_status("reversed_view", 0)
	player.take_damage(1.0e9)
	await _frames(10)
	_check(player._is_dead, "the player died from lethal damage")
	_check(not player._status_reversed_view and is_zero_approx(player._status_reversed_view_timer), "dying clears Reversed View")
	await _frames(5)
	_check(is_equal_approx(_arm_x(player), 0.0), "the camera is not left upside-down after death")

	# --- a fresh player (a loaded game / next floor) never starts with the effect --------------
	var fresh_scene: PackedScene = load("res://characters/brute/scenes/brute_player.tscn" if cls == "barbarian" else "res://characters/Lutsch Mage/scenes/Mage player.tscn")
	var fresh: Node = fresh_scene.instantiate()
	_check(not fresh._status_reversed_view and is_zero_approx(fresh._status_reversed_view_timer), "a new player instance starts without Reversed View")
	fresh.free()
	var save_src := FileAccess.get_file_as_string("res://scripts/save_manager.gd")
	_check(save_src.find("reversed_view") < 0 and save_src.find("_status_") < 0, "saves never persist trap statuses (nothing to restore stuck on load)")

	print("test_reversed_view (%s): %d checks, %d failures" % [cls, _checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
