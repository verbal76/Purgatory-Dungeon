# Dev utility: renders a scene at a phone-shaped window and saves a PNG (needs a display, e.g. xvfb-run
# with --rendering-driver opengl3; there is no GPU in CI). Not part of the game.
#   PURGATORY_FORCE_TOUCH=1 xvfb-run -a -s "-screen 0 1496x672x24" godot --rendering-driver opengl3 \
#     --path . --script tools/ui_shot.gd -- res://scenes/MainMenu.tscn /tmp/menu.png [frames]
# Env: SHOT_CALL="method@frame" (or "NodeName.method@frame") calls a method at that frame;
#      SHOT_PRESS="action@frame,..." presses an input action (tap) at those frames;
#      SHOT_CLASS=barbarian|mage sets the run class; SHOT_EXTRA="f1,f2" saves more shots at those
#      frames as <out>_<frame>.png (the first shot is at [frames]).
extends SceneTree

var _scene_path: String = ""
var _out: String = ""
var _frames: int = 90
var _n: int = 0
var _presses: Dictionary = {}
var _extra: Array = []
var _calls: Dictionary = {}


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("usage: -- <scene> <out.png> [frames]")
		quit(2)
		return
	_scene_path = args[0]
	_out = args[1]
	if args.size() > 2:
		_frames = int(args[2])
	for item in OS.get_environment("SHOT_PRESS").split(",", false):
		var parts := item.split("@")
		_presses[int(parts[1])] = parts[0]
	for item in OS.get_environment("SHOT_CALL").split(",", false):
		var parts2 := item.split("@")
		_calls[int(parts2[1])] = parts2[0]
	for f in OS.get_environment("SHOT_EXTRA").split(",", false):
		_extra.append(int(f))
	if OS.get_environment("SHOT_CLASS") != "":
		var gd = root.get_node_or_null("GlobalRunData")
		if gd != null:
			gd.character_class = OS.get_environment("SHOT_CLASS")
	root.content_scale_size = Vector2i(1280, 720)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	var packed := load(_scene_path) as PackedScene
	var inst := packed.instantiate()
	root.add_child(inst)
	current_scene = inst


func _process(_delta: float) -> bool:
	_n += 1
	if _presses.has(_n):
		for pressed in [true, false]:
			var ev := InputEventAction.new()
			ev.action = _presses[_n]
			ev.pressed = pressed
			ev.strength = 1.0 if pressed else 0.0
			Input.parse_input_event(ev)
	if _calls.has(_n) and current_scene != null:
		var spec: String = _calls[_n]
		if spec.contains("."):   # "NodeName.method": call it on that node (found by name anywhere below the scene)
			var parts := spec.split(".")
			var target := current_scene.find_child(parts[0], true, false)
			if target != null:
				target.call(parts[1])
		else:
			current_scene.call(spec)
	if _n in _extra:
		_save(_out.get_basename() + "_%d.png" % _n)
	if _n == _frames:
		_save(_out)
		quit(0)
	return false


func _save(path: String) -> void:
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(path)
	print("saved ", path, " ", img.get_size())
