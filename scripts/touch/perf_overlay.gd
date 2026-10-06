# ==============================================================================
# File Name: perf_overlay.gd
# Path: res://scripts/touch/perf_overlay.gd
#
# Description:
#   Optional frame-time readout for phone playtests (Options > Gameplay > "Show performance readout",
#   off by default). The owner cannot attach a profiler to a phone, so this reports what the player
#   actually gets: FPS, the slowest 1 % of recent frames, the worst frame, draw calls and objects.
#   It samples every frame into a pre-allocated ring (no per-frame allocation) and only formats text
#   twice a second while visible. A one-line summary also goes to the log (adb logcat) every 30 s.
# ==============================================================================
class_name PerfOverlay
extends CanvasLayer

const KEY := "ShowPerf"
const RING := 600            # ~10 s at 60 fps
const REFRESH := 0.5
const LOG_EVERY := 30.0

var _ring: PackedFloat32Array = PackedFloat32Array()
var _n: int = 0
var _head: int = 0
var _label: Label = null
var _since_refresh: float = 0.0
var _since_log: float = 0.0
var _worst: float = 0.0
var _scratch: PackedFloat32Array = PackedFloat32Array()


static func install(tree: SceneTree) -> Node:
	var n: Node = (load("res://scripts/touch/perf_overlay.gd") as GDScript).new()
	n.name = "PerfOverlay"
	tree.root.add_child.call_deferred(n)
	return n


func _ready() -> void:
	layer = 120
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(MobileUi.GROUP_OPT_OUT)
	_ring.resize(RING)
	_scratch.resize(RING)
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_color_override("font_color", Color(0.7, 1.0, 0.7))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_label.add_theme_constant_override("outline_size", 6)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_label.offset_top = 6.0
	_label.visible = false
	add_child(_label)


func _process(delta: float) -> void:
	_ring[_head] = delta
	_head = (_head + 1) % RING
	_n = mini(_n + 1, RING)
	if delta > _worst:
		_worst = delta
	_since_refresh += delta
	_since_log += delta
	if _since_refresh < REFRESH:
		return
	_since_refresh = 0.0
	var show: bool = bool(SettingsManager.gameplay_settings.get(KEY, false))
	_label.visible = show
	if show or _since_log >= LOG_EVERY:
		var text := summary()
		if show:
			_label.text = text
		if _since_log >= LOG_EVERY:
			_since_log = 0.0
			print("perf: ", text)
			_worst = 0.0


## "58 fps | low 1%: 41 | worst 52 ms | draws 812 | objects 1403"
func summary() -> String:
	if _n == 0:
		return "no frames yet"
	var sum := 0.0
	for i in _n:
		_scratch[i] = _ring[i]
		sum += _ring[i]
	var avg_fps := float(_n) / maxf(sum, 0.0001)
	# 1 % low: the mean of the slowest 1 % of frames (at least one), as FPS.
	var view := _scratch.slice(0, _n)
	view.sort()
	var k: int = maxi(1, int(_n * 0.01))
	var slow := 0.0
	for i in k:
		slow += view[_n - 1 - i]
	var low_fps := float(k) / maxf(slow, 0.0001)
	var draws: int = int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
	var objs: int = int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME))
	return "%d fps | low 1%%: %d | worst %d ms | draws %d | objects %d" % [
		int(round(avg_fps)), int(round(low_fps)), int(round(_worst * 1000.0)), draws, objs]
