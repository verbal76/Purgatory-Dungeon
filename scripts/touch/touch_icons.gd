# ==============================================================================
# File Name: touch_icons.gd
# Path: res://scripts/touch/touch_icons.gd
#
# Description:
#   Vector icons for the on-screen action buttons, drawn in code so they stay crisp at any
#   phone resolution and need no image assets. Dark ember palette to match the dungeon.
#   Every icon is drawn into a unit circle of radius `r` around `c`.
# ==============================================================================
class_name TouchIcons
extends RefCounted

const BONE   := Color(0.97, 0.91, 0.78, 1.0)   # icon strokes/fills
const EMBER  := Color(0.95, 0.48, 0.12, 1.0)   # accent
const INK    := Color(0.06, 0.04, 0.04, 1.0)   # button face
const KINDS  : Array[String] = ["attack", "kick", "slide", "block", "burst", "use", "map", "pause"]


static func draw_icon(ci: CanvasItem, kind: String, c: Vector2, r: float, tint: Color = BONE) -> void:
	var w: float = maxf(r * 0.09, 2.0)
	match kind:
		"attack": _sword(ci, c, r, w, tint)
		"kick":   _boot(ci, c, r, w, tint)
		"slide":  _dash(ci, c, r, w, tint)
		"block":  _shield(ci, c, r, w, tint)
		"burst":  _burst(ci, c, r, w, tint)
		"use":    _key(ci, c, r, w, tint)
		"map":    _map(ci, c, r, w, tint)
		"pause":  _pause(ci, c, r, tint)


static func _p(c: Vector2, r: float, x: float, y: float) -> Vector2:
	return c + Vector2(x, y) * r


static func _sword(ci: CanvasItem, c: Vector2, r: float, w: float, col: Color) -> void:
	# Blade from lower-left to upper-right, crossguard and pommel.
	var blade := PackedVector2Array([_p(c, r, -0.38, 0.30), _p(c, r, 0.46, -0.54), _p(c, r, 0.54, -0.46), _p(c, r, -0.30, 0.38)])
	ci.draw_colored_polygon(blade, col)
	var tip := PackedVector2Array([_p(c, r, 0.46, -0.54), _p(c, r, 0.62, -0.62), _p(c, r, 0.54, -0.46)])
	ci.draw_colored_polygon(tip, col)
	ci.draw_line(_p(c, r, -0.52, 0.04), _p(c, r, -0.04, 0.52), EMBER, w * 1.8, true)   # crossguard
	ci.draw_line(_p(c, r, -0.38, 0.38), _p(c, r, -0.58, 0.58), col, w * 1.6, true)     # grip
	ci.draw_circle(_p(c, r, -0.62, 0.62), r * 0.07, EMBER)


static func _boot(ci: CanvasItem, c: Vector2, r: float, w: float, col: Color) -> void:
	var boot := PackedVector2Array([
		_p(c, r, -0.22, -0.55), _p(c, r, 0.12, -0.55), _p(c, r, 0.14, -0.05), _p(c, r, 0.52, 0.12),
		_p(c, r, 0.58, 0.36), _p(c, r, -0.32, 0.36)])
	ci.draw_colored_polygon(boot, col)
	ci.draw_line(_p(c, r, -0.32, 0.36), _p(c, r, 0.58, 0.36), EMBER, w * 1.6, true)    # sole
	# impact lines
	ci.draw_line(_p(c, r, 0.62, -0.18), _p(c, r, 0.82, -0.30), EMBER, w, true)
	ci.draw_line(_p(c, r, 0.66, 0.02), _p(c, r, 0.88, 0.0), EMBER, w, true)


static func _dash(ci: CanvasItem, c: Vector2, r: float, w: float, col: Color) -> void:
	for i in 3:
		var x: float = -0.50 + 0.36 * float(i)
		var a: float = 1.0 - 0.28 * float(2 - i)
		var tint := Color(col.r, col.g, col.b, col.a * a)
		ci.draw_polyline(PackedVector2Array([_p(c, r, x, -0.42), _p(c, r, x + 0.30, 0.0), _p(c, r, x, 0.42)]), tint, w * 1.9, true)


static func _shield(ci: CanvasItem, c: Vector2, r: float, w: float, col: Color) -> void:
	var s := PackedVector2Array([
		_p(c, r, -0.46, -0.50), _p(c, r, 0.0, -0.62), _p(c, r, 0.46, -0.50), _p(c, r, 0.46, 0.0),
		_p(c, r, 0.0, 0.66), _p(c, r, -0.46, 0.0)])
	ci.draw_colored_polygon(s, col)
	var inner := PackedVector2Array([
		_p(c, r, -0.30, -0.36), _p(c, r, 0.0, -0.44), _p(c, r, 0.30, -0.36), _p(c, r, 0.30, -0.02),
		_p(c, r, 0.0, 0.44), _p(c, r, -0.30, -0.02)])
	ci.draw_colored_polygon(inner, INK)
	ci.draw_line(_p(c, r, 0.0, -0.34), _p(c, r, 0.0, 0.30), EMBER, w * 1.5, true)
	ci.draw_line(_p(c, r, -0.20, -0.08), _p(c, r, 0.20, -0.08), EMBER, w * 1.5, true)


static func _burst(ci: CanvasItem, c: Vector2, r: float, w: float, col: Color) -> void:
	# Potion flask with an explosion ring: the potion-powered blast.
	var flask := PackedVector2Array([
		_p(c, r, -0.12, -0.40), _p(c, r, 0.12, -0.40), _p(c, r, 0.12, -0.14), _p(c, r, 0.36, 0.30),
		_p(c, r, 0.30, 0.42), _p(c, r, -0.30, 0.42), _p(c, r, -0.36, 0.30), _p(c, r, -0.12, -0.14)])
	ci.draw_colored_polygon(flask, col)
	ci.draw_colored_polygon(PackedVector2Array([_p(c, r, -0.27, 0.22), _p(c, r, 0.27, 0.22), _p(c, r, 0.31, 0.34), _p(c, r, -0.31, 0.34)]), EMBER)
	ci.draw_line(_p(c, r, -0.16, -0.46), _p(c, r, 0.16, -0.46), col, w * 1.6, true)
	for i in 8:
		var a: float = TAU * float(i) / 8.0
		ci.draw_line(c + Vector2.from_angle(a) * r * 0.60, c + Vector2.from_angle(a) * r * 0.80, EMBER, w, true)


static func _key(ci: CanvasItem, c: Vector2, r: float, w: float, col: Color) -> void:
	ci.draw_arc(_p(c, r, -0.26, -0.04), r * 0.26, 0.0, TAU, 24, col, w * 1.8, true)
	ci.draw_line(_p(c, r, -0.02, -0.04), _p(c, r, 0.56, -0.04), col, w * 1.8, true)
	ci.draw_line(_p(c, r, 0.40, -0.04), _p(c, r, 0.40, 0.18), col, w * 1.8, true)
	ci.draw_line(_p(c, r, 0.56, -0.04), _p(c, r, 0.56, 0.22), col, w * 1.8, true)
	ci.draw_circle(_p(c, r, -0.26, -0.04), r * 0.08, EMBER)


static func _map(ci: CanvasItem, c: Vector2, r: float, w: float, col: Color) -> void:
	var m := PackedVector2Array([
		_p(c, r, -0.55, -0.40), _p(c, r, -0.18, -0.52), _p(c, r, 0.18, -0.40), _p(c, r, 0.55, -0.52),
		_p(c, r, 0.55, 0.40), _p(c, r, 0.18, 0.52), _p(c, r, -0.18, 0.40), _p(c, r, -0.55, 0.52)])
	ci.draw_colored_polygon(m, col)
	ci.draw_line(_p(c, r, -0.18, -0.52), _p(c, r, -0.18, 0.40), INK, w, true)
	ci.draw_line(_p(c, r, 0.18, -0.40), _p(c, r, 0.18, 0.52), INK, w, true)
	ci.draw_circle(_p(c, r, 0.34, 0.02), r * 0.09, EMBER)


static func _pause(ci: CanvasItem, c: Vector2, r: float, col: Color) -> void:
	ci.draw_rect(Rect2(_p(c, r, -0.30, -0.40), Vector2(0.20, 0.80) * r), col)
	ci.draw_rect(Rect2(_p(c, r, 0.10, -0.40), Vector2(0.20, 0.80) * r), col)
