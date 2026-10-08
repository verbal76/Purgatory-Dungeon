# ============================================================
#  FILE: dungeon_entry.gd
#  PATH: res://scripts/dungeon_entry.gd
#  DESCRIPTION: Starts a run without freezing the screen. change_scene_to_file() loads the whole dungeon scene
#  (module meshes, both player classes, the enemies, the minimap, the pause menu...) on the main thread: about
#  2.5 s on a desktop during which nothing is drawn and no input is read, several times that on a phone. Here the
#  scene is loaded on worker threads instead, under the same "Loading the dungeon" screen the dungeon itself
#  shows (so the hand-over to it is seamless), and the scene switch happens only when it is ready.
#
#  USE:  DungeonEntry.start(get_tree(), "res://scenes/Purgatory_Dungeon_main_game_file.tscn")
#        (preload this script: there is deliberately no global class name)
# ============================================================
extends CanvasLayer

const SELF_PATH : String = "res://scripts/dungeon_entry.gd"
## Give up on the threaded load after this long and let the plain (blocking) scene change try instead.
const GIVE_UP_SECONDS : float = 45.0

var _path        : String = ""
var _old_scene   : Node   = null
var _switched    : bool   = false
var _frames_after : int   = 0
var _elapsed     : float  = 0.0
var _dots        : Label  = null
var _dot_timer   : float  = 0.0
var _dot_count   : int    = 0


# Begins loading `path` in the background and switches to it when ready. Falls back to the ordinary blocking scene
# change when a threaded load cannot be started. A second call while one is running is ignored.
static func start(tree: SceneTree, path: String) -> void:
	if tree.root.has_node("DungeonEntryOverlay"):
		return
	if ResourceLoader.load_threaded_request(path, "PackedScene", true) != OK:
		tree.change_scene_to_file(path)
		return
	var overlay : CanvasLayer = (load(SELF_PATH) as GDScript).new()
	overlay.name = "DungeonEntryOverlay"
	overlay.set("_path", path)
	overlay.set("_old_scene", tree.current_scene)
	tree.root.add_child(overlay)


func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 128   # above the dungeon's own loading screen (120) so the switch between them is never visible


func _ready() -> void:
	var bg : Control = PUI.background("void")
	bg.theme = PUI.theme()
	bg.mouse_filter = Control.MOUSE_FILTER_STOP   # a second click on the start button must not do anything
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.theme = PUI.theme()
	add_child(center)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", PUI.S3)
	center.add_child(column)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	column.add_child(row)
	var left_pad := Control.new()
	left_pad.custom_minimum_size.x = 64.0
	row.add_child(left_pad)
	var label : Label = PUI.label("Loading the dungeon", "ScreenTitle")
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(label)
	_dots = PUI.label("", "ScreenTitle")
	_dots.custom_minimum_size.x = 64.0
	row.add_child(_dots)
	column.add_child(PUI.divider())


func _process(delta: float) -> void:
	_elapsed += delta
	_dot_timer += delta
	if _dot_timer > 0.5:
		_dot_timer = 0.0
		_dot_count = (_dot_count + 1) % 4
		_dots.text = ".".repeat(_dot_count)

	if not _switched:
		var status : int = ResourceLoader.load_threaded_get_status(_path)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			var packed : PackedScene = ResourceLoader.load_threaded_get(_path) as PackedScene
			_switched = true
			if packed != null:
				get_tree().change_scene_to_packed(packed)
			else:
				get_tree().change_scene_to_file(_path)
		elif status != ResourceLoader.THREAD_LOAD_IN_PROGRESS or _elapsed > GIVE_UP_SECONDS:
			_switched = true
			get_tree().change_scene_to_file(_path)
		return

	# The switch happens at the end of a frame; once the dungeon's own loading screen exists (its player's
	# _ready has run) this overlay is no longer needed.
	if get_tree().current_scene != _old_scene or _old_scene == null:
		_frames_after += 1
		if _frames_after >= 3:
			queue_free()
	elif _elapsed > GIVE_UP_SECONDS + 15.0:
		queue_free()
