# ==============================================================================
# File Name: pui_bar.gd
# Path: res://scripts/ui/pui_bar.gd
# Description: HUD meter (health, cooldowns): iron frame, lit fill, a thin highlight and a short "trail" that
#   shows recent loss. Cheap: one _draw, redrawn only when the value changes or the trail is moving.
#       var bar := PUIBar.make(Vector2(240, 22), PUI.BLOOD_BRIGHT)
#       bar.set_value(current / maximum)
# ==============================================================================
class_name PUIBar
extends Control

var fill_top: Color = PUI.BLOOD_BRIGHT
var fill_bottom: Color = PUI.BLOOD
var value: float = 1.0
var _trail: float = 1.0
var _sweep: float = -1.0        # a heal sweeps a bright band along the fill (0..1, -1 = idle)
var _pulse_on: bool = false     # low-health pulse: the whole bar breathes
var _pulse_t: float = 0.0
static var _frame_style: StyleBoxFlat = null   # shared: _draw must not allocate


static func make(p_size: Vector2, p_fill: Color = PUI.BLOOD_BRIGHT) -> PUIBar:
	var b := PUIBar.new()
	b.custom_minimum_size = p_size
	b.size = p_size
	b.fill_top = p_fill
	b.fill_bottom = p_fill.darkened(0.35)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return b


## Re-colour the lit fill (state changes only: ability ready / charging / cooling down).
func set_fill(p_fill: Color, p_bottom: Color = Color(0, 0, 0, 0)) -> void:
	fill_top = p_fill
	fill_bottom = p_bottom if p_bottom.a > 0.0 else p_fill.darkened(0.35)
	queue_redraw()


func set_value(v: float) -> void:
	v = clampf(v, 0.0, 1.0)
	if is_equal_approx(v, value):
		return
	if v > value:
		_trail = v   # healing: no trail
		if v - value > 0.02:
			_sweep = 0.0   # a real heal (not per-tick regeneration) sweeps a bright band along the bar
	value = v
	set_process(_needs_process())
	queue_redraw()


## Low-health pulse: the bar breathes (a slow brightness swell) until switched off.
func set_pulse(on: bool) -> void:
	if on == _pulse_on:
		return
	_pulse_on = on
	if not on:
		modulate = Color.WHITE
	set_process(_needs_process())


func _needs_process() -> bool:
	return _trail > value or _sweep >= 0.0 or _pulse_on


func _ready() -> void:
	set_process(false)


func _process(delta: float) -> void:
	_trail = maxf(value, _trail - delta * 0.55)
	if _sweep >= 0.0:
		_sweep += delta * 2.4
		if _sweep > 1.2:
			_sweep = -1.0
	if _pulse_on:
		_pulse_t += delta
		var s: float = 0.5 + 0.5 * sin(_pulse_t * TAU * 1.1)
		modulate = Color(1.0 + 0.45 * s, 1.0 + 0.1 * s, 1.0 + 0.1 * s, 1.0)
	if is_equal_approx(_trail, value):
		_trail = value
	set_process(_needs_process())
	queue_redraw()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	if _frame_style == null:
		_frame_style = PUI.flat(PUI.IRON_DEEP, PUI.EDGE_BRASS.darkened(0.2), 2, 3)
	draw_style_box(_frame_style, r)
	var inner := r.grow(-3.0)
	if _trail > value:
		draw_rect(Rect2(inner.position, Vector2(inner.size.x * _trail, inner.size.y)), Color(PUI.BONE.r, PUI.BONE.g, PUI.BONE.b, 0.30))
	if value > 0.0:
		var fw: float = inner.size.x * value
		draw_rect(Rect2(inner.position, Vector2(fw, inner.size.y)), fill_bottom)
		draw_rect(Rect2(inner.position, Vector2(fw, inner.size.y * 0.55)), fill_top)
		draw_rect(Rect2(inner.position, Vector2(fw, 1.5)), Color(1, 0.93, 0.8, 0.45))
		if _sweep >= 0.0:
			var bx: float = inner.position.x + (fw + 24.0) * _sweep - 24.0
			var x0: float = maxf(bx, inner.position.x)
			var x1: float = minf(bx + 24.0, inner.position.x + fw)
			if x1 > x0:
				draw_rect(Rect2(Vector2(x0, inner.position.y), Vector2(x1 - x0, inner.size.y)), Color(1.0, 0.95, 0.85, 0.55))
