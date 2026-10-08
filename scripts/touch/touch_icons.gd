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
	# A KICK: a leg driving up and to the right, the boot at its end, an impact star where the toe strikes.
	var a: float = deg_to_rad(-30.0)
	var k: float = 0.86
	var o := Vector2(-0.22, 0.20)
	var leg := PackedVector2Array([Vector2(-0.80, -0.17), Vector2(0.06, -0.19), Vector2(0.06, 0.21), Vector2(-0.80, 0.19)])
	var foot := PackedVector2Array([Vector2(0.06, -0.20), Vector2(0.38, -0.23), Vector2(0.68, -0.14), Vector2(0.98, 0.02), Vector2(0.96, 0.12), Vector2(0.66, 0.18), Vector2(0.06, 0.20)])
	var sole := PackedVector2Array([Vector2(0.06, 0.18), Vector2(0.66, 0.16), Vector2(0.96, 0.10), Vector2(0.98, 0.21), Vector2(0.68, 0.30), Vector2(0.06, 0.32)])
	ci.draw_colored_polygon(_tf(c, r, leg, a, k, o), Color(col.r, col.g, col.b, col.a * 0.8))
	ci.draw_colored_polygon(_tf(c, r, sole, a, k, o), EMBER)
	ci.draw_colored_polygon(_tf(c, r, foot, a, k, o), col)
	var star := PackedVector2Array()
	for i in 12:
		star.append(_tf1(c, r, Vector2(1.22, 0.0) + Vector2.from_angle(TAU * float(i) / 12.0) * (0.30 if i % 2 == 0 else 0.14), a, k, o))
	ci.draw_colored_polygon(star, EMBER)
	ci.draw_line(_tf1(c, r, Vector2(-0.62, -0.40), a, k, o), _tf1(c, r, Vector2(-0.10, -0.40), a, k, o), col, w * 0.9, true)
	ci.draw_line(_tf1(c, r, Vector2(-0.74, 0.46), a, k, o), _tf1(c, r, Vector2(-0.20, 0.46), a, k, o), col, w * 0.9, true)


static func _tf1(c: Vector2, r: float, u: Vector2, ang: float, k: float, o: Vector2) -> Vector2:
	return c + ((u * k).rotated(ang) + o) * r


static func _tf(c: Vector2, r: float, pts: PackedVector2Array, ang: float, k: float, o: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for u in pts:
		out.append(_tf1(c, r, u, ang, k, o))
	return out


static func _repulse(ci: CanvasItem, c: Vector2, r: float, w: float, col: Color) -> void:
	# Radial pushback: a centre point (the player) and eight arrows driving outward in every direction.
	for i in 8:
		var ang: float = TAU * float(i) / 8.0 - PI * 0.5
		var big: bool = i % 2 == 0
		var k: float = 1.0 if big else 0.82
		var d := Vector2.from_angle(ang)
		var n := Vector2(-d.y, d.x)
		ci.draw_line(c + d * r * 0.34 * k, c + d * r * 0.62 * k, col, w * 1.5, true)
		var tip: Vector2 = c + d * r * 0.92 * k
		var base: Vector2 = c + d * r * 0.58 * k
		ci.draw_colored_polygon(PackedVector2Array([tip, base + n * r * 0.20 * k, base - n * r * 0.20 * k]), col)
	ci.draw_circle(c, r * 0.28, col)
	ci.draw_circle(c, r * 0.17, INK)
	ci.draw_circle(c, r * 0.10, EMBER)


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
