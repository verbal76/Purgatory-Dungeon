extends Node
## MANUAL TOOL (not part of run_tests.sh): renders the game-feel layer for a visual check. Needs a renderer (software Vulkan works):
##   export PURGATORY_SAVE_ROOT=$(mktemp -d)/PurgetoryDungeon
##   JUICE_OUT=/tmp/juice_shots nice -n 19 xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver vulkan \
##     --rendering-method mobile --resolution 1280x720 --path . res://tests/juice_shots.tscn
## Saves PNGs (HUD included): 00_base, 01_hit_vignette, 02_bursts, 03_banner_counter, 04_enemy_bar_elite, 05_low_health, 06_death.

const Juice := preload("res://scripts/juice.gd")
const MAIN_SCENE : String = "res://scenes/Purgatory_Dungeon_main_game_file.tscn"
var _out : String = ""


func _shot(name: String) -> void:
	await get_tree().process_frame
	RenderingServer.force_draw()
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [_out, name])
	print("saved ", name)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _ready() -> void:
	_out = OS.get_environment("JUICE_OUT")
	if _out == "":
		_out = ProjectSettings.globalize_path("user://juice_shots")
	DirAccess.make_dir_recursive_absolute(_out)
	GlobalRunData.character_class = "barbarian"
	GlobalRunData.seed_hash = 0
	var main: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	main.use_random_seed = false
	main.fixed_seed = 12345
	add_child(main)
	await _frames(200)
	var player: Node = get_tree().get_first_node_in_group("player")
	var waited := 0
	while (get_tree().paused or not player.is_on_floor() or get_tree().get_first_node_in_group("loading_screen") != null) and waited < 4000:
		await get_tree().physics_frame
		waited += 1
	await _frames(240)   # the loading screen fades out
	var em: Node = main.get_node_or_null("EnemyManager")
	if em != null:
		em.set_physics_process(false)
	for e in get_tree().get_nodes_in_group("enemies"):
		(e as Node3D).global_position += Vector3(0, -200, 0)   # out of the picture
	await _shot("00_base")

	var fx: Node = player.get("camera_fx")
	player._current_health = player.max_health
	player.take_damage(player.max_health * 0.25, null)
	fx._update_screen(0.0)   # (a software-rendered frame can last a second: draw this one before the tint decays)
	RenderingServer.force_draw()
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png("%s/01_hit_vignette.png" % _out)
	print("saved 01_hit_vignette")
	await _frames(60)

	# Bursts, a number and a flash straight ahead of the camera.
	var cam: Camera3D = player.get("camera_3d")
	var fwd: Vector3 = -cam.global_transform.basis.z
	var origin: Vector3 = cam.global_position + fwd * 5.0
	var presets: Array = ["hit", "block", "magic", "gold", "heal", "spark", "ember", "soul"]
	for i in presets.size():
		var off: Vector3 = cam.global_transform.basis.x * (float(i) - 3.5) * 0.9 + Vector3(0, -0.3, 0)
		Juice.burst(presets[i], origin + off, Vector3.UP, 1.0)
	Juice.number(origin + Vector3(0, 1.2, 0), "37", Color(1.0, 0.7, 0.3), 1.2)
	Juice.flash(origin, Color(1.0, 0.6, 0.3), 3.0, 0.5, 6.0)
	await get_tree().process_frame
	await _shot("02_bursts")
	await _frames(40)

	Juice.banner("SEALED", 3.0, PUI.BLOOD_BRIGHT)
	Juice.counter("Sealed: 4 left")
	await _frames(14)
	await _shot("03_banner_counter")
	await _frames(40)

	# An elite, hurt enemy in front of the camera.
	var gen: Node = main.get_node("DungeonGenerationFunction")
	var entries: Array = gen.registered_typed_spawns.duplicate()
	var enemy: Node3D = null
	for entry in entries:
		var forced: Dictionary = entry.duplicate()
		forced["type"] = 1
		var before: int = em._active_enemies.size()
		if em._spawn_enemy_from_data(forced) and em._active_enemies.size() > before:
			enemy = em._active_enemies.back()
			break
	if enemy != null:
		var want: Vector3 = player.global_position + (-player.global_transform.basis.z) * 5.0
		enemy.global_position = em._snap_to_floor(want)
		enemy.velocity = Vector3.ZERO
		enemy.set_physics_process(false)
		enemy.apply_red_glow()
		enemy.take_damage(enemy.max_health * 0.4, player)
		await _frames(4)
		var bar: Node3D = enemy.get("_bar")
		print("bar visible=", bar.visible, " in_tree=", bar.is_visible_in_tree(), " pos=", bar.global_position, " screen=", cam.unproject_position(bar.global_position), " behind=", cam.is_position_behind(bar.global_position))
		Juice.number(enemy.global_position + Vector3(0, 2.0, 0), "40", Color(1, 0.6, 0.3), 1.4)
		await _shot("04_enemy_bar_elite")
	player._current_health = player.max_health
	player.take_damage(player.max_health * 0.82, null)
	await _frames(20)
	fx._update_screen(0.0)
	RenderingServer.force_draw()
	var img2: Image = get_viewport().get_texture().get_image()
	img2.save_png("%s/05_low_health.png" % _out)
	print("saved 05_low_health")
	player.take_damage(1.0e9, null)
	await _frames(70)
	await _shot("06_death")
	get_tree().quit(0)
