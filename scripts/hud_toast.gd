# ==============================================================================
# File Name: hud_toast.gd
# Path: res://scripts/hud_toast.gd
#
# Description:
#   The run's one reusable on-screen message layer (group "hud_toast", built once by Juice.ensure_pool): a BANNER (day change,
#   "Room sealed", the first-run objective) that pops in, holds and fades, and a COUNTER line ("Sealed: 3 left") that stays until
#   it is cleared. Two Labels, reused for every message: no node is created while playing. Plain script, no class_name.
# ==============================================================================
extends CanvasLayer

var _banner: Label = null
var _counter: Label = null
var _banner_t: float = 0.0
var _banner_hold: float = 0.0
const FADE_IN := 0.16
const FADE_OUT := 0.6


func _ready() -> void:
	add_to_group("hud_toast")
	layer = 14   # above the HUD and CameraFx's vignette (9), below the damage fan (25), menus and the loading screen
	_banner = Label.new()
	_banner.name = "Banner"
	_banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.modulate.a = 0.0
	_banner.visible = false
	PUI.apply_role(_banner, "screen_title")
	_banner.add_theme_constant_override("outline_size", 8)
	_banner.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	add_child(_banner)
	_counter = Label.new()
	_counter.name = "Counter"
	_counter.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_counter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_counter.visible = false
	PUI.apply_role(_counter, "hud_value", PUI.BLOOD_BRIGHT)
	_counter.add_theme_constant_override("outline_size", 6)
	_counter.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	add_child(_counter)
	set_process(false)


## A banner message: pops in (a small scale-down), holds `seconds`, fades out. A newer banner replaces an older one.
func banner(text: String, seconds: float = 2.2, color: Color = Color(0, 0, 0, 0)) -> void:
	if _banner == null:
		return
	_banner.text = text
	if color.a > 0.0:
		_banner.add_theme_color_override("font_color", color)
	else:
		_banner.add_theme_color_override("font_color", PUI.color("BONE"))
	_place(_banner, 0.2)
	_banner.visible = true
	_banner.modulate.a = 0.0
	_banner_t = 0.0
	_banner_hold = seconds
	set_process(true)


## The persistent counter line; "" hides it.
func counter(text: String) -> void:
	if _counter == null:
		return
	_counter.visible = text != ""
	if text != "":
		_counter.text = text
		_place(_counter, 0.1)


# Centre a label horizontally at `y_frac` of the visible height (the label has to be laid out to know its width, hence the call
# on each change of text; two cheap property writes).
func _place(l: Label, y_frac: float) -> void:
	var vp: Vector2 = get_viewport().get_visible_rect().size if get_viewport() != null else Vector2(1280, 720)
	l.reset_size()
	var w: float = maxf(l.get_combined_minimum_size().x, 10.0)
	l.position = Vector2((vp.x - w) * 0.5, vp.y * y_frac)
	l.pivot_offset = l.size * 0.5


func _process(delta: float) -> void:
	_banner_t += delta
	var total: float = FADE_IN + _banner_hold + FADE_OUT
	if _banner_t >= total:
		_banner.visible = false
		_banner.modulate.a = 0.0
		set_process(false)
		return
	var a: float = 1.0
	if _banner_t < FADE_IN:
		a = _banner_t / FADE_IN
		_banner.scale = Vector2.ONE * lerpf(1.18, 1.0, a)
	elif _banner_t > FADE_IN + _banner_hold:
		a = 1.0 - (_banner_t - FADE_IN - _banner_hold) / FADE_OUT
		_banner.scale = Vector2.ONE
	else:
		_banner.scale = Vector2.ONE
	_banner.modulate.a = clampf(a, 0.0, 1.0)
