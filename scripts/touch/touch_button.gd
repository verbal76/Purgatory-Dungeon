# ==============================================================================
# File Name: touch_button.gd
# Path: res://scripts/touch/touch_button.gd
#
# Description:
#   One round on-screen action button. It does not read input itself: TouchControls routes
#   touches to it (so several fingers can work at once) and it only draws and reports.
#   The hit area is larger than the drawn circle so thumbs do not have to be precise.
# ==============================================================================
class_name TouchButton
extends Control

const HIT_SLOP := 1.30   # touch radius = drawn radius * this

enum Mode { HOLD, TOGGLE }

var action    : String = ""
var icon_kind : String = ""
var label     : String = ""
var mode      : Mode   = Mode.HOLD
var radius    : float  = 80.0           # drawn radius, virtual px
var center    : Vector2 = Vector2.ZERO  # in TouchControls space
var pressed_visual : bool = false
var toggled_on     : bool = false
var cooldown       : float = 0.0        # 0..1 fraction remaining (ring over the button)
var badge          : String = ""        # small count in the corner (e.g. potions)
var highlighted    : bool = false       # onboarding pulse
var enabled_look   : bool = true


func setup(p_action: String, p_icon: String, p_mode: Mode = Mode.HOLD) -> void:
	action = p_action
	icon_kind = p_icon
	mode = p_mode
	mouse_filter = Control.MOUSE_FILTER_IGNORE   # touches are routed by TouchControls, not the GUI


func place(p_center: Vector2, p_radius: float) -> void:
	center = p_center
	radius = p_radius
	position = center - Vector2(radius, radius) * HIT_SLOP
	size = Vector2(radius, radius) * 2.0 * HIT_SLOP
	queue_redraw()


func _process(_delta: float) -> void:
	if highlighted:
		queue_redraw()   # animate the onboarding pulse


func hit(p: Vector2) -> bool:
	return visible and p.distance_to(center) <= radius * HIT_SLOP


func _draw() -> void:
	var local_c: Vector2 = size * 0.5
	var down: bool = pressed_visual or toggled_on
	var face := Color(TouchIcons.INK.r, TouchIcons.INK.g, TouchIcons.INK.b, 0.72 if not down else 0.92)
	draw_circle(local_c, radius, face)
	var ring: Color = TouchIcons.EMBER if down else Color(TouchIcons.BONE.r, TouchIcons.BONE.g, TouchIcons.BONE.b, 0.55)
	draw_arc(local_c, radius, 0.0, TAU, 48, ring, maxf(radius * 0.06, 2.0), true)
	if highlighted:
		var t: float = fmod(Time.get_ticks_msec() * 0.001, 1.2) / 1.2
		draw_arc(local_c, radius * (1.05 + 0.30 * t), 0.0, TAU, 48, Color(1.0, 0.8, 0.3, 1.0 - t), maxf(radius * 0.07, 3.0), true)
	TouchIcons.draw_icon(self, icon_kind, local_c, radius * 0.86, TouchIcons.BONE if not down else Color(1, 1, 1, 1))
	if cooldown > 0.0:
		# Dark wedge shrinking as the cooldown runs out.
		var pts := PackedVector2Array([local_c])
		var a0: float = -PI * 0.5
		var a1: float = a0 + TAU * clampf(cooldown, 0.0, 1.0)
		for i in 33:
			pts.append(local_c + Vector2.from_angle(lerpf(a0, a1, float(i) / 32.0)) * radius)
		draw_colored_polygon(pts, Color(0, 0, 0, 0.55))
	if label != "":
		var font := ThemeDB.fallback_font
		var fs: int = int(maxf(radius * 0.24, 12.0))
		var ts: Vector2 = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		draw_string(font, local_c + Vector2(-ts.x * 0.5, radius + ts.y * 0.8), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.8))
	if badge != "":
		var font2 := ThemeDB.fallback_font
		var bfs: int = int(maxf(radius * 0.30, 14.0))
		var bp: Vector2 = local_c + Vector2(radius * 0.62, -radius * 0.62)
		draw_circle(bp, radius * 0.26, TouchIcons.EMBER)
		var bts: Vector2 = font2.get_string_size(badge, HORIZONTAL_ALIGNMENT_LEFT, -1, bfs)
		draw_string(font2, bp + Vector2(-bts.x * 0.5, bts.y * 0.3), badge, HORIZONTAL_ALIGNMENT_LEFT, -1, bfs, Color(0.05, 0.03, 0.03, 1))
