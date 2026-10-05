# Dev utility: renders a scene at a phone-shaped window and saves a PNG (needs a display, e.g. xvfb-run
# with --rendering-driver opengl3; there is no GPU in CI). Not part of the game.
#   PURGATORY_FORCE_TOUCH=1 xvfb-run -a -s "-screen 0 1496x672x24" godot --rendering-driver opengl3 \
#     --path . --script tools/ui_shot.gd -- res://scenes/MainMenu.tscn /tmp/menu.png [frames]
extends SceneTree

var _scene_path: String = ""
var _out: String = ""
var _frames: int = 90
var _n: int = 0


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
	root.content_scale_size = Vector2i(1280, 720)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	var packed := load(_scene_path) as PackedScene
	var inst := packed.instantiate()
	root.add_child(inst)
	current_scene = inst


func _process(_delta: float) -> bool:
	_n += 1
	if _n == _frames:
		var img := root.get_viewport().get_texture().get_image()
		img.save_png(_out)
		print("saved ", _out, " ", img.get_size())
		quit(0)
	return false
