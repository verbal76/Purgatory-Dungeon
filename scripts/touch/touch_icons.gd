# ==============================================================================
# File Name: touch_icons.gd
# Path: res://scripts/touch/touch_icons.gd
#
# Description:
#   THE Purgatory icon family: vector icons drawn in code so they stay crisp at any resolution and need
#   no image assets. One stroke weight (r * 0.09), one palette (PUI bone strokes + ember accent), one
#   construction (filled bone silhouette, ember detail). Used by the touch buttons, the HUD and menus.
#   Every icon is drawn into a unit circle of radius `r` around `c`.
# ==============================================================================
class_name TouchIcons
extends RefCounted

const BONE   := PUI.BONE         # icon strokes/fills
const EMBER  := PUI.EMBER_BRIGHT # accent
const INK    := PUI.IRON_DEEP    # button face / cut-outs
const KINDS  : Array[String] = ["attack", "kick", "repulse", "block", "burst", "use", "map", "pause",
	"potion", "key", "hourglass", "blade", "chevron_left", "chevron_right"]


static func draw_icon(ci: CanvasItem, kind: String, c: Vector2, r: float, tint: Color = BONE) -> void:
	var w: float = maxf(r * 0.09, 2.0)
	match kind:
		"attack": _sword(ci, c, r, w, tint)
		"kick":   _boot(ci, c, r, w, tint)
		"repulse": _repulse(ci, c, r, w, tint)
		"block":  _shield(ci, c, r, w, tint)
		"burst":  _burst(ci, c, r, w, tint)
		"use":    _key(ci, c, r, w, tint)
		"map":    _map(ci, c, r, w, tint)
		"pause":  _pause(ci, c, r, tint)
		"potion": _potion(ci, c, r, w, tint)
		"key":    _key(ci, c, r, w, tint)
		"hourglass": _hourglass(ci, c, r, w, tint)
		"blade":  _blade(ci, c, r, w, tint)
		"chevron_left":  _chevron(ci, c, r, w, tint, -1.0)
		"chevron_right": _chevron(ci, c, r, w, tint, 1.0)


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
	# A KICK: the boot (shin, ankle, heel, sole, toe) swung up and forward, a swing trail under it, an impact star at the toe.
	var a: float = deg_to_rad(-34.0)
	var k: float = 0.80
	var o := Vector2(-0.08, 0.04)
	var shaft := PackedVector2Array([Vector2(-0.34, -0.74), Vector2(0.14, -0.74), Vector2(0.22, -0.06), Vector2(-0.36, -0.06)])
	var foot := PackedVector2Array([Vector2(-0.36, -0.06), Vector2(0.22, -0.06), Vector2(0.38, 0.08), Vector2(0.72, 0.22), Vector2(0.76, 0.42), Vector2(-0.48, 0.42), Vector2(-0.46, 0.18)])
	var sole := PackedVector2Array([Vector2(-0.50, 0.40), Vector2(0.78, 0.40), Vector2(0.78, 0.56), Vector2(-0.50, 0.56)])
	var trail := PackedVector2Array()
	for i in 9:
		var t: float = float(i) / 8.0
		trail.append(_tf1(c, r, Vector2(-0.95 + 1.95 * t, 0.78 + 0.18 * sin(t * PI) - 0.62 * t * t), a, k, o))
	ci.draw_polyline(trail, Color(col.r, col.g, col.b, col.a * 0.6), w * 1.2, true)
	ci.draw_colored_polygon(_tf(c, r, shaft, a, k, o), Color(col.r, col.g, col.b, col.a * 0.8))
	ci.draw_colored_polygon(_tf(c, r, sole, a, k, o), EMBER)
	ci.draw_colored_polygon(_tf(c, r, foot, a, k, o), col)
	var star := PackedVector2Array()
	for i in 12:
		star.append(_tf1(c, r, Vector2(1.08, 0.12) + Vector2.from_angle(TAU * float(i) / 12.0) * (0.30 if i % 2 == 0 else 0.15), a, k, o))
	ci.draw_colored_polygon(star, EMBER)


static func _tf1(c: Vector2, r: float, u: Vector2, ang: float, k: float, o: Vector2) -> Vector2:
	return c + ((u * k).rotated(ang) + o) * r


static func _tf(c: Vector2, r: float, pts: PackedVector2Array, ang: float, k: float, o: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for u in pts:
		out.append(_tf1(c, r, u, ang, k, o))
	return out


static func _repulse(ci: CanvasItem, c: Vector2, r: float, w: float, col: Color) -> void:
	# "Get back from me": an open palm held out, shock rings spreading from it in every direction.
	for ring in 2:
		var rad: float = 0.70 if ring == 0 else 0.93
		for q in 4:
			var a0: float = deg_to_rad(90.0 * float(q) - 90.0 + 16.0)
			var a1: float = deg_to_rad(90.0 * float(q) - 90.0 + 74.0)
			ci.draw_arc(c, r * rad, a0, a1, 10, EMBER if ring == 0 else Color(EMBER.r, EMBER.g, EMBER.b, 0.75), w * (1.6 if ring == 0 else 1.2), true)
	var hs: float = 0.95
	var palm := PackedVector2Array([Vector2(-0.27, -0.04), Vector2(0.27, -0.04), Vector2(0.29, 0.28), Vector2(0.17, 0.50), Vector2(-0.17, 0.50), Vector2(-0.29, 0.28)])
	var thumb := PackedVector2Array([Vector2(-0.26, 0.08), Vector2(-0.56, -0.12), Vector2(-0.47, -0.27), Vector2(-0.20, -0.02)])
	ci.draw_colored_polygon(_tf(c, r, palm, 0.0, hs, Vector2(0.0, 0.04)), col)
	ci.draw_colored_polygon(_tf(c, r, thumb, 0.0, hs, Vector2(0.0, 0.04)), col)
	var tops: Array = [-0.46, -0.58, -0.52, -0.36]
	for i in 4:
		var x0: float = -0.27 + 0.1375 * float(i)
		var t: float = float(tops[i])
		ci.draw_colored_polygon(_tf(c, r, PackedVector2Array([Vector2(x0, -0.02), Vector2(x0 + 0.12, -0.02), Vector2(x0 + 0.12, t + 0.06), Vector2(x0 + 0.06, t), Vector2(x0, t + 0.06)]), 0.0, hs, Vector2(0.0, 0.04)), col)


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


static func _potion(ci: CanvasItem, c: Vector2, r: float, w: float, col: Color) -> void:
	# A plain flask (the burst icon without the rays): stash / currency.
	var flask := PackedVector2Array([
		_p(c, r, -0.12, -0.52), _p(c, r, 0.12, -0.52), _p(c, r, 0.12, -0.20), _p(c, r, 0.42, 0.30),
		_p(c, r, 0.36, 0.50), _p(c, r, -0.36, 0.50), _p(c, r, -0.42, 0.30), _p(c, r, -0.12, -0.20)])
	ci.draw_colored_polygon(flask, col)
	ci.draw_colored_polygon(PackedVector2Array([_p(c, r, -0.31, 0.20), _p(c, r, 0.31, 0.20), _p(c, r, 0.38, 0.40), _p(c, r, -0.38, 0.40)]), EMBER)
	ci.draw_line(_p(c, r, -0.18, -0.58), _p(c, r, 0.18, -0.58), col, w * 1.6, true)


static func _hourglass(ci: CanvasItem, c: Vector2, r: float, w: float, col: Color) -> void:
	var top := PackedVector2Array([_p(c, r, -0.38, -0.54), _p(c, r, 0.38, -0.54), _p(c, r, 0.04, -0.02), _p(c, r, -0.04, -0.02)])
	var bot := PackedVector2Array([_p(c, r, -0.04, 0.02), _p(c, r, 0.04, 0.02), _p(c, r, 0.38, 0.54), _p(c, r, -0.38, 0.54)])
	ci.draw_colored_polygon(top, col)
	ci.draw_colored_polygon(bot, col)
	ci.draw_colored_polygon(PackedVector2Array([_p(c, r, -0.20, 0.54), _p(c, r, 0.20, 0.54), _p(c, r, 0.0, 0.26)]), EMBER)
	ci.draw_line(_p(c, r, -0.46, -0.58), _p(c, r, 0.46, -0.58), col, w * 1.6, true)
	ci.draw_line(_p(c, r, -0.46, 0.58), _p(c, r, 0.46, 0.58), col, w * 1.6, true)


static func _blade(ci: CanvasItem, c: Vector2, r: float, w: float, col: Color) -> void:
	# Two crossed blades: kills.
	for flip in [-1.0, 1.0]:
		var a := PackedVector2Array([_p(c, r, -0.50 * flip, 0.46), _p(c, r, 0.46 * flip, -0.50), _p(c, r, 0.54 * flip, -0.42), _p(c, r, -0.42 * flip, 0.54)])
		ci.draw_colored_polygon(a, col)
		ci.draw_line(_p(c, r, -0.58 * flip, 0.20), _p(c, r, -0.20 * flip, 0.58), EMBER, w * 1.5, true)


static func _chevron(ci: CanvasItem, c: Vector2, r: float, w: float, col: Color, dir: float) -> void:
	ci.draw_polyline(PackedVector2Array([_p(c, r, -0.18 * dir, -0.46), _p(c, r, 0.22 * dir, 0.0), _p(c, r, -0.18 * dir, 0.46)]), col, w * 2.2, true)
