extends Node
## Mixed input (master standard 12.3): mouse look and right-stick look are summed, neither disables the other. Steam Deck trackpad / gyro send mouse
## motion while the stick is also in use. Measures the player's real yaw for mouse only, stick only, and both at once, for both classes.

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


func _mouse(dx: float) -> void:
	var m := InputEventMouseMotion.new()
	m.relative = Vector2(dx, 0.0)
	m.position = Vector2(100, 100)
	Input.parse_input_event(m)


## Turns the player by `mouse_dx` pixels and/or by holding the stick for `stick_frames` physics frames; returns the yaw change in radians.
func _turn(player: Node3D, mouse_dx: float, stick_frames: int) -> float:
	var start: float = player.rotation.y
	if stick_frames > 0:
		Input.action_press("look_right", 1.0)
	if mouse_dx != 0.0:
		await _frames(1)
		_mouse(mouse_dx)
	await _frames(maxi(stick_frames, 2))
	Input.action_release("look_right")
	await _frames(3)
	return angle_difference(start, player.rotation.y)


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	for cls in ["barbarian", "mage"]:
		GlobalRunData.character_class = cls
		var main: Node = (load("res://scenes/Purgatory_Dungeon_main_game_file.tscn") as PackedScene).instantiate()
		add_child(main)
		await _frames(120)
		var manager = main.get_node("EnemyManager")
		manager.set_physics_process(false)
		var player: Node3D = main.get_node("Player")
		var mouse_only: float = await _turn(player, 120.0, 0)
		var stick_only: float = await _turn(player, 0.0, 6)
		var both: float = await _turn(player, 120.0, 6)
		_check(absf(mouse_only) > 0.05, "%s: mouse look turns the player (%.3f rad)" % [cls, mouse_only])
		_check(absf(stick_only) > 0.05, "%s: stick look turns the player (%.3f rad)" % [cls, stick_only])
		_check(signf(mouse_only) == signf(stick_only), "%s: mouse right and stick right turn the same way" % cls)
		var expected: float = mouse_only + stick_only
		_check(absf(both - expected) <= absf(expected) * 0.2 + 0.02, "%s: both together add up (%.3f vs %.3f + %.3f)" % [cls, both, mouse_only, stick_only])
		_check(absf(both) > absf(mouse_only) and absf(both) > absf(stick_only), "%s: neither source cancels the other" % cls)
		main.queue_free()
		await _frames(10)
	print("test_mixed_look: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
