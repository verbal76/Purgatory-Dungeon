# Dev utility (not shipped): boots the real dungeon scene and saves the gameplay HUD at three moments:
#   <prefix>_a  idle at the start of a run
#   <prefix>_b  hurt, with trap statuses, kills, wallet counts and the rapid-attack bar
#   <prefix>_c  the minimap overlay open (compass letters, portal and enemy markers)
# Used by tools/ui_review.sh (HUD=1). Needs a display (xvfb) and is slow in software GL:
#   SHOT_CLASS=barbarian|mage PURGATORY_FORCE_TOUCH=1 godot --rendering-driver opengl3 --path . \
#     --script tools/hud_shot.gd -- res://scenes/Purgatory_Dungeon_main_game_file.tscn /tmp/out_prefix
# Env: HUD_DMG (damage taken at the _b moment, default 60).
extends SceneTree

var _n := 0
var _out := ""
var inst: Node


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_out = args[1]
	var gd = root.get_node_or_null("GlobalRunData")
	if gd != null and OS.get_environment("SHOT_CLASS") != "":
		gd.character_class = OS.get_environment("SHOT_CLASS")
	if OS.get_environment("PURGATORY_FORCE_TOUCH") == "1":   # the phone build stretches to a 1280x720 canvas
		root.content_scale_size = Vector2i(1280, 720)
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	inst = (load(args[0]) as PackedScene).instantiate()
	root.add_child(inst)
	current_scene = inst


func _process(_d: float) -> bool:
	_n += 1
	var p = get_first_node_in_group("player")
	if _n == 40:
		_save("_a")
	if _n == 45 and p != null:
		var sm = root.get_node("SaveManager")
		sm.current_profile = {"meta_currency": 37, "keys": {"bronze": 2, "silver": 0, "gold": 1}}
		root.get_node("PlayerWallet").refresh_hud()
		var dmg: String = OS.get_environment("HUD_DMG")
		p.take_damage(float(dmg) if dmg != "" else 60.0)
		p.apply_status("drunk", 0)
		p.apply_status("acid_pool", 15)
		p.apply_status("heavy_gravity", 3)
		p._attack_held = true
		p._rapid_attack_charge = 0.6
		p._refresh_rapid_attack_bar()
	if _n == 55:
		current_scene.kill_counter_label.text = "Kills: 27"
	if _n == 60:
		_save("_b")
	if _n == 61 and p != null:
		var mm = current_scene.get_node("minimap_function")
		var pp: Vector3 = p.global_position
		mm.set_portal_position(pp + Vector3(30, 0, -20))
		mm.set_enemy_markers([pp + Vector3(-25, 0, 10), pp + Vector3(15, 0, 25)])
	if _n == 62:
		Input.action_press("minimap")
	if _n == 85:
		_save("_c")
		Input.action_release("minimap")
		quit(0)
	return false


func _save(tag: String) -> void:
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(_out + tag + ".png")
	print("saved ", _out + tag, " ", img.get_size())
