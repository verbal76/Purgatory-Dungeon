extends Node
## Regression: on Android the window is larger than the visible canvas (canvas_items + expand), e.g. a Pixel
## 10 Pro XL is 2992x1344 with a 1602x720 visible rect. The Mage once aimed with get_viewport().size / 2 and
## fired ~58 degrees right and down of the crosshair (straight into the floor). This test builds that exact
## shape, proves the OLD calculation is badly off (so the test would fail on the old code), and proves the real
## MagePlayer aim ray, raycast target and a cast fireball all line up with the crosshair now.

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


func _angle_deg(a: Vector3, b: Vector3) -> float:
	return rad_to_deg(a.normalized().angle_to(b.normalized()))


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	GlobalRunData.character_class = "mage"
	var main: Node = (load("res://scenes/Purgatory_Dungeon_main_game_file.tscn") as PackedScene).instantiate()
	add_child(main)
	await _frames(240)
	var manager = main.get_node("EnemyManager")
	manager.set_physics_process(false)
	for e in manager._active_enemies:
		if is_instance_valid(e):
			e.queue_free()
	manager._active_enemies.clear()
	var player: CharacterBody3D = main.get_node("Player")
	var cam: Camera3D = player.camera_3d
	_check(cam != null, "the Mage has a camera")

	# Shapes to exercise: desktop (window == canvas) and the Pixel-shaped Android window.
	var shapes := [
		{"name": "desktop 1920x1080", "win": Vector2i(1920, 1080), "mismatch": false},
		{"name": "Pixel 10 Pro XL 2992x1344 (canvas_items, expand, 1280x720)", "win": Vector2i(2992, 1344), "mismatch": true},
		{"name": "tall-ish phone 2400x1080", "win": Vector2i(2400, 1080), "mismatch": true},
	]
	var root_win: Window = get_tree().root
	root_win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root_win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	root_win.content_scale_size = Vector2i(1280, 720)
	for sh in shapes:
		var label: String = sh["name"]
		root_win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS if bool(sh["mismatch"]) else Window.CONTENT_SCALE_MODE_DISABLED
		root_win.size = sh["win"]
		await _frames(3)
		var fwd: Vector3 = -cam.global_transform.basis.z
		var vp: Viewport = player.get_viewport()
		print("  [%s] window=%s visible_rect=%s viewport=%s" % [label, root_win.size, vp.get_visible_rect().size, vp.size])
		var old_dir: Vector3 = cam.project_ray_normal(Vector2(vp.size) * 0.5)
		var old_off: float = _angle_deg(old_dir, fwd)
		if bool(sh["mismatch"]):
			# The test environment really reproduces the Android defect: the old calculation is far off.
			_check(old_off > 20.0, "[%s] reproduces the defect: window/2 is %.1f deg off the crosshair" % [label, old_off])
		else:
			_check(old_off < 0.1, "[%s] desktop: old and new agree (%.2f deg)" % [label, old_off])

		var aim: Vector3 = player._get_camera_aim_dir()
		_check(_angle_deg(aim, fwd) < 0.1, "[%s] Mage aim direction is on the crosshair (%.3f deg)" % [label, _angle_deg(aim, fwd)])

		# The raycast target lies on the crosshair ray from the camera.
		var target: Vector3 = player._raycast_aim_target(30.0)
		var to_target: Vector3 = target - cam.global_position
		_check(_angle_deg(to_target, fwd) < 0.5, "[%s] aim target is on the crosshair ray (%.3f deg)" % [label, _angle_deg(to_target, fwd)])

		# A real cast: the fireball must travel along the crosshair, not into the floor.
		for n in main.get_children():
			if str(n.name).begins_with("MageFireball_"):
				n.queue_free()
		player._is_attacking = false
		player._do_spell_attack()
		var seen: Array = []
		var deadline: int = 90
		while deadline > 0 and seen.size() < 3:
			await get_tree().physics_frame
			deadline -= 1
			for n in get_tree().root.find_children("MageFireball_*", "Area3D", true, false):
				seen.append((n as Area3D).global_position)
				break
		_check(seen.size() >= 2, "[%s] a fireball is launched by the cast" % label)
		if seen.size() >= 2:
			var travel: Vector3 = (seen[seen.size() - 1] as Vector3) - (seen[0] as Vector3)
			var pitch_off: float = absf(rad_to_deg(asin(clampf(travel.normalized().y, -1.0, 1.0))) - rad_to_deg(asin(clampf(fwd.y, -1.0, 1.0))))
			_check(travel.length() > 0.05, "[%s] the fireball actually travels" % label)
			_check(pitch_off < 8.0, "[%s] fireball pitch follows the crosshair (off by %.1f deg; floor-bound would be ~20+)" % [label, pitch_off])
			var flat_t := Vector3(travel.x, 0, travel.z).normalized()
			var flat_f := Vector3(fwd.x, 0, fwd.z).normalized()
			_check(_angle_deg(flat_t, flat_f) < 8.0, "[%s] fireball heading follows the crosshair (off by %.1f deg yaw)" % [label, _angle_deg(flat_t, flat_f)])
		player._is_attacking = false
		await _frames(30)
	print("test_mage_aim: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
