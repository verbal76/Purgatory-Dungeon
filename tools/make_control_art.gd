# ==============================================================================
# File Name: make_control_art.gd
# Path: res://tools/make_control_art.gd
#
# Dev tool (not shipped): renders the touch-control art OFFLINE into committed PNGs under assets/touch/.
# The art is original, authored here as faceted polygons (per-vertex shading planes, seeded procedural slate
# facets, cracks and bronze wear) in the Purgatory palette, in the direction of docs/art/
# PD_Mobile_Control_Art_Reference.png (art direction only: nothing is traced or cropped from it).
#
# Run (needs a display; the software OpenGL path under xvfb works):
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 --path . \
#       --script tools/make_control_art.gd
# Optional argument: a name filter, e.g.  -- icon_sword   (renders only matching files).
# Then import (godot --headless --path . --import) and commit the PNGs together with their .import files.
#
# Output (assets/touch/), every state baked because a tint cannot do it:
#   base_attack_<state>.png   512x512  chunky segmented bronze rim + cracked slate face + 4 diamond studs
#   base_sub_<state>.png      256x256  the same rim/face for slide, kick, block, burst, USE (no studs)
#   icon_<kind>_<state>.png   256x256  sword, shield, boot, flask, chevrons, key
#   states: default | pressed (ember-lit rim + inner glow + outer glow) | cooldown (cool, desaturated) | disabled (dark grey)
# Geometry: the button disc has radius 1.0 art unit; the canvas half-size is CANVAS_HALF (1.12) units so the
# pressed glow has room. The game draws a base texture at half-size = drawn radius * CANVAS_HALF.
# Each image is rendered at SUPERSAMPLE x and reduced with Lanczos for crisp edges. Seeds are fixed, so a
# re-run reproduces identical art.
# ==============================================================================
extends SceneTree

const OUT_DIR := "res://assets/touch/"
const CANVAS_HALF := 1.12
const STATES: Array[String] = ["default", "pressed", "cooldown", "disabled"]
const LIGHT := Vector2(-0.55, -0.83)   # light comes from the upper left

# Material ramps (PUI-derived: aged brass, blackened slate, bone steel, ember). [hi, mid, lo, deep]
const BRONZE: Array[Color] = [Color("dba062"), Color("a76e39"), Color("6c4223"), Color("3a2211")]
const STEEL: Array[Color] = [Color("e4e0d6"), Color("b2ada3"), Color("736f69"), Color("403d3b")]
const IVORY: Array[Color] = [Color("fff5dc"), Color("eadfc6"), Color("b9ad93"), Color("6f6657")]
const GEM: Array[Color] = [Color("f0675a"), Color("c8322d"), Color("861a1c"), Color("4a0b0e")]
const CORK: Array[Color] = [Color("b07a43"), Color("8a5a2b"), Color("5e3b1c"), Color("341f0e")]
const SLATE := Color("201b18")
const SLATE_DEEP := Color("0e0b0a")
const EMBER := Color("cf8a2e")
const EMBER_BRIGHT := Color("efae4d")

var _jobs: Array = []
var _filter: String = ""


class ArtNode extends Control:
	var drawer: Callable
	func _draw() -> void:
		drawer.call(self)


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_filter = args[0]
	for st in STATES:
		_jobs.append(["base_attack_" + st, 512, 2, _draw_base.bind(true, st)])
		_jobs.append(["base_sub_" + st, 256, 4, _draw_base.bind(false, st)])
		for kind in ["sword", "shield", "boot", "flask", "chevrons", "key"]:
			_jobs.append(["icon_%s_%s" % [kind, st], 256, 4, _draw_icon.bind(kind, st)])
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var n: int = 0
	for job in _jobs:
		if _filter != "" and not String(job[0]).contains(_filter):
			continue
		await _render(job[0], job[1], job[2], job[3])
		n += 1
	print("make_control_art: wrote %d images to %s" % [n, OUT_DIR])
	quit()


func _render(file: String, size_px: int, ss: int, drawer: Callable) -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(size_px * ss, size_px * ss)
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var node := ArtNode.new()
	node.size = Vector2(vp.size)
	node.drawer = drawer
	vp.add_child(node)
	root.add_child(vp)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img: Image = vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	img.fix_alpha_edges()
	img.resize(size_px, size_px, Image.INTERPOLATE_LANCZOS)
	img.save_png(ProjectSettings.globalize_path(OUT_DIR + file + ".png"))
	vp.queue_free()


# ── State toning ──────────────────────────────────────────────────────────────────────────────────

static func _tone(c: Color, state: String, ember: float = 0.0, push: bool = false) -> Color:
	var g: float = c.r * 0.30 + c.g * 0.59 + c.b * 0.11
	match state:
		"pressed":
			var lit := Color(minf(c.r * 1.10 + 0.04, 1.0), minf(c.g * 1.04 + 0.02, 1.0), c.b * 0.92, c.a)
			if push:
				lit = c   # the slate face keeps its value (it is pushed in, not lit)
			var amount: float = clampf(0.30 + ember, 0.0, 1.0)
			if push:
				amount = 0.05
			var out := lit.lerp(Color(EMBER_BRIGHT, c.a), amount)
			if push:
				out = out * Color(0.90, 0.87, 0.85, 1.0)   # the slate face is pushed in: a touch darker
			return out
		"cooldown":
			var grey := Color(g * 0.94, g * 0.98, g * 1.06, c.a)
			return c.lerp(grey, 0.78) * Color(0.82, 0.84, 0.90, 1.0)
		"disabled":
			var grey2 := Color(g, g, g, c.a)
			return c.lerp(grey2, 0.95) * Color(0.50, 0.50, 0.52, 1.0)
	return c


static func _shade(c: Color, k: float) -> Color:
	return Color(clampf(c.r * k, 0.0, 1.0), clampf(c.g * k, 0.0, 1.0), clampf(c.b * k, 0.0, 1.0), c.a)


# ── Geometry helpers (art units; the unit circle maps to `r_px` pixels around `ctr`) ──────────────

class Frame:
	var ci: CanvasItem
	var ctr: Vector2
	var r_px: float
	var state: String

	func p(u: Vector2) -> Vector2:
		return ctr + u * r_px

	func poly(pts: Array, col: Color) -> void:
		var out := PackedVector2Array()
		for u in pts:
			out.append(p(u))
		ci.draw_colored_polygon(out, col)

	func gpoly(pts: Array, cols: Array) -> void:
		var out := PackedVector2Array()
		var cc := PackedColorArray()
		for i in pts.size():
			out.append(p(pts[i]))
			cc.append(cols[i])
		ci.draw_polygon(out, cc)

	func line(a: Vector2, b: Vector2, col: Color, w: float) -> void:
		ci.draw_line(p(a), p(b), col, w * r_px, true)


static func _frame(ci: Control, state: String) -> Frame:
	var f := Frame.new()
	f.ci = ci
	f.ctr = ci.size * 0.5
	f.r_px = ci.size.x * 0.5 / CANVAS_HALF
	f.state = state
	return f


static func _pol(r: float, a: float) -> Vector2:
	return Vector2(cos(a), sin(a)) * r


# ── Base: bronze rim + slate face ─────────────────────────────────────────────────────────────────

func _draw_base(ci: Control, studs: bool, state: String) -> void:
	var f := _frame(ci, state)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7301 if studs else 4417
	var st: String = state

	# pressed: soft outer ember glow (the canvas margin), then everything else on top
	if st == "pressed":
		_glow_ring(f, 1.0, CANVAS_HALF, 0.0, Color(EMBER, 0.0), Color(EMBER_BRIGHT, 0.62))
	# dark backplate (shows in the gaps between rim segments)
	_disc(f, 1.0, _tone(BRONZE[3], st))

	# rim: segmented bronze blocks, two facets each (lit outer bevel, darker inner plane)
	var nseg: int = 24 if studs else 20
	var gap: float = deg_to_rad(0.6)
	for i in nseg:
		var a0: float = TAU * float(i) / float(nseg) + gap
		var a1: float = TAU * float(i + 1) / float(nseg) - gap
		var am: float = (a0 + a1) * 0.5
		# brightest where the segment faces the light
		var facing: float = _pol(1.0, am).dot(-LIGHT)
		var lit: float = clampf(0.86 - 0.22 * facing + rng.randf_range(-0.05, 0.05), 0.62, 1.15)
		var c_out: Color = _tone(_shade(BRONZE[0], lit), st)
		var c_mid: Color = _tone(_shade(BRONZE[1], lit), st)
		var c_in: Color = _tone(_shade(BRONZE[2], lit), st)
		f.gpoly([_pol(0.915, a0), _pol(1.0, a0), _pol(1.0, a1), _pol(0.915, a1)], [c_mid, c_out, c_out, c_mid])
		f.gpoly([_pol(0.80, a0), _pol(0.915, a0), _pol(0.915, a1), _pol(0.80, a1)], [c_in, c_mid, c_mid, c_in])
		# worn edge: a thin bright scratch and an occasional chip
		if rng.randf() < 0.55:
			var sa: float = rng.randf_range(a0 + 0.04, a1 - 0.10)
			f.line(_pol(0.975, sa), _pol(0.975, sa + rng.randf_range(0.05, 0.12)), _tone(_shade(BRONZE[0], 1.12), st), 0.012)
		if rng.randf() < 0.30:
			var ca: float = rng.randf_range(a0 + 0.03, a1 - 0.08)
			f.poly([_pol(0.99, ca), _pol(0.94, ca + 0.04), _pol(0.99, ca + 0.08)], _tone(BRONZE[3], st))   # a chip, kept inside the silhouette
		# dark seam under the segment's inner edge
		f.line(_pol(0.805, a0), _pol(0.805, a1), _tone(BRONZE[3], st), 0.02)

	# studs: four diamonds at the cardinal points (Attack only)
	if studs:
		for k in 4:
			var a: float = TAU * float(k) / 4.0 - PI * 0.5
			_stud(f, a, 0.875, 0.135, 0.092, st)

	# inner bevel: a shadow cast by the rim (upper-left) and a lit lip (lower-right)
	var nb: int = 48
	for i in nb:
		var a0b: float = TAU * float(i) / float(nb)
		var a1b: float = TAU * float(i + 1) / float(nb)
		var t0: float = 0.5 + 0.5 * _pol(1.0, a0b).dot(-LIGHT)
		var t1: float = 0.5 + 0.5 * _pol(1.0, a1b).dot(-LIGHT)
		var d0: Color = _tone(Color("0a0807").lerp(Color("4a3118"), 1.0 - t0), st)
		var d1: Color = _tone(Color("0a0807").lerp(Color("4a3118"), 1.0 - t1), st)
		var i0: Color = _tone(Color("0a0807").lerp(Color("24190f"), 1.0 - t0), st)
		var i1: Color = _tone(Color("0a0807").lerp(Color("24190f"), 1.0 - t1), st)
		f.gpoly([_pol(0.71, a0b), _pol(0.80, a0b), _pol(0.80, a1b), _pol(0.71, a1b)], [i0, d0, d1, i1])

	_slate_face(f, rng, 0.715, st)
	if st == "pressed":
		# inner ember glow: warm light spilling from the rim onto the face
		_inner_glow(f)


func _disc(f: Frame, r: float, col: Color) -> void:
	var pts: Array = []
	for i in 72:
		pts.append(_pol(r, TAU * float(i) / 72.0))
	f.poly(pts, col)


# A ring from r_a (colour c_a) to r_b (colour c_b), used for the outer glow.
func _glow_ring(f: Frame, r_a: float, r_b: float, _unused: float, c_a: Color, c_b: Color) -> void:
	var n: int = 72
	for i in n:
		var a0: float = TAU * float(i) / float(n)
		var a1: float = TAU * float(i + 1) / float(n)
		f.gpoly([_pol(r_a, a0), _pol(r_b, a0), _pol(r_b, a1), _pol(r_a, a1)], [c_b, c_a, c_a, c_b])


func _inner_glow(f: Frame) -> void:
	var n: int = 72
	for i in n:
		var a0: float = TAU * float(i) / float(n)
		var a1: float = TAU * float(i + 1) / float(n)
		var hot := Color(EMBER, 0.30)
		var cold := Color(EMBER, 0.0)
		f.gpoly([_pol(0.715, a0), _pol(0.44, a0), _pol(0.44, a1), _pol(0.715, a1)], [hot, cold, cold, hot])


func _stud(f: Frame, a: float, rc: float, hl: float, hw: float, st: String) -> void:
	var dir := _pol(1.0, a)
	var perp := Vector2(-dir.y, dir.x)
	var c: Vector2 = dir * rc
	var tip: Vector2 = c + dir * hl
	var base: Vector2 = c - dir * hl
	var l: Vector2 = c + perp * hw
	var r: Vector2 = c - perp * hw
	var k: float = 0.85 + 0.25 * (-dir.dot(LIGHT))
	f.poly([tip + dir * 0.0, l, base, r], _tone(_shade(BRONZE[2], 0.9), st))   # silhouette (dark)
	f.poly([tip, l, c], _tone(_shade(BRONZE[0], k), st))
	f.poly([tip, c, r], _tone(_shade(BRONZE[1], k), st))
	f.poly([base, l, c], _tone(_shade(BRONZE[1], k * 0.85), st))
	f.poly([base, c, r], _tone(_shade(BRONZE[2], k), st))
	f.line(tip, base, _tone(BRONZE[3], st), 0.008)


func _slate_face(f: Frame, rng: RandomNumberGenerator, rf: float, st: String) -> void:
	# triangulated, jittered polar grid; one flat colour per triangle gives the faceted planes
	var rings: Array = [0.0, 0.17, 0.33, 0.49, 0.62, rf]
	var n: int = 18
	var pts: Array = []   # pts[ring][j]
	var offs: Array = []
	for _i in rings.size():
		offs.append(0.0)
	for ri in rings.size():
		var row: Array = []
		var cnt: int = 1 if ri == 0 else n
		for j in cnt:
			var a: float = TAU * float(j) / float(n) + (0.0 if ri == 0 else offs[ri])
			var rr: float = float(rings[ri])
			if ri > 0 and ri < rings.size() - 1:
				rr += rng.randf_range(-0.045, 0.045)
				a += rng.randf_range(-0.13, 0.13)
			row.append(_pol(rr, a) if ri > 0 else Vector2.ZERO)
		pts.append(row)
	var tri := func(a: Vector2, b: Vector2, c: Vector2) -> void:
		var cen: Vector2 = (a + b + c) / 3.0
		var tilt := Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1))
		var shade: float = 1.0 + 0.42 * tilt.normalized().dot(-LIGHT) + rng.randf_range(-0.14, 0.14)
		shade *= 1.0 - 0.28 * clampf(cen.length() / rf, 0.0, 1.0)   # darker toward the rim
		var base: Color = SLATE.lerp(Color("3a322c"), rng.randf() * 0.65)
		if rng.randf() < 0.07:
			base = Color("3a322c")   # a lighter chip
		f.poly([a, b, c], _tone(_shade(base, shade), st, -0.2, true))
	for j in n:
		var j2: int = (j + 1) % n
		tri.call(Vector2.ZERO, pts[1][j], pts[1][j2])
	for ri in range(1, rings.size() - 1):
		for j in n:
			var j2b: int = (j + 1) % n
			tri.call(pts[ri][j], pts[ri + 1][j], pts[ri + 1][j2b])
			tri.call(pts[ri][j], pts[ri + 1][j2b], pts[ri][j2b])
	# cracks: jagged dark lines walking in from the edge, each with a faint lit side
	for k in 6:
		var a: float = rng.randf() * TAU
		var p0: Vector2 = _pol(rf * 0.98, a)
		var heading: float = a + PI + rng.randf_range(-0.5, 0.5)
		var length: float = rng.randf_range(0.25, 0.55)
		var cur: Vector2 = p0
		var steps: int = 5
		for s in steps:
			heading += rng.randf_range(-0.8, 0.8)
			var nxt: Vector2 = cur + _pol(length / float(steps), heading)
			if nxt.length() > rf * 0.98:
				break
			var w: float = 0.020 * (1.0 - float(s) / float(steps + 1))
			f.line(cur + Vector2(0.008, 0.010), nxt + Vector2(0.008, 0.010), _tone(Color(0.30, 0.25, 0.21, 0.55), st), w * 0.8)
			f.line(cur, nxt, _tone(Color(0.02, 0.015, 0.012, 0.95), st), w)
			cur = nxt


# ── Icons ─────────────────────────────────────────────────────────────────────────────────────────

func _draw_icon(ci: Control, kind: String, state: String) -> void:
	var f := _frame(ci, state)
	f.r_px = ci.size.x * 0.5 / 1.0   # icons use their whole canvas: art spans about +-0.9 units
	match kind:
		"sword": _icon_sword(f)
		"shield": _icon_shield(f)
		"boot": _icon_boot(f)
		"flask": _icon_flask(f)
		"chevrons": _icon_chevrons(f)
		"key": _icon_key(f)


func _tp(f: Frame, ramp: Array[Color], idx: int, k: float = 1.0) -> Color:
	return _tone(_shade(ramp[idx], k), f.state, -0.14)   # icons warm less than the rim when pressed


# a drop shadow copy of a silhouette, so the icon lifts off the face and survives at small size
func _shadow(f: Frame, pts: Array, off: Vector2 = Vector2(0.035, 0.05)) -> void:
	var moved: Array = []
	for u in pts:
		moved.append(u + off)
	f.poly(moved, Color(0, 0, 0, 0.5))


static func _rot(pts: Array, deg: float, scale: float = 1.0, shift: Vector2 = Vector2.ZERO) -> Array:
	var out: Array = []
	var a: float = deg_to_rad(deg)
	for u in pts:
		out.append((u * scale).rotated(a) + shift)
	return out


func _icon_sword(f: Frame) -> void:
	var rot := func(pts: Array) -> Array: return _rot(pts, 45.0, 1.0, Vector2(0.0, 0.0))
	var blade: Array = [Vector2(0, -1.02), Vector2(-0.15, -0.66), Vector2(-0.12, 0.05), Vector2(0.12, 0.05), Vector2(0.15, -0.66)]
	var guard: Array = [Vector2(-0.36, 0.03), Vector2(0.36, 0.03), Vector2(0.40, 0.14), Vector2(-0.40, 0.14)]
	var grip: Array = [Vector2(-0.06, 0.14), Vector2(0.06, 0.14), Vector2(0.06, 0.50), Vector2(-0.06, 0.50)]
	var pommel: Array = [Vector2(0, 0.46), Vector2(0.12, 0.58), Vector2(0, 0.72), Vector2(-0.12, 0.58)]
	for part in [blade, guard, grip, pommel]:
		_shadow(f, rot.call(part))
	# blade planes: lit left, darker right, brighter bevel along the edges, a fuller groove
	f.poly(rot.call(blade), _tp(f, STEEL, 2))
	f.poly(rot.call([Vector2(0, -1.02), Vector2(-0.15, -0.66), Vector2(-0.12, 0.05), Vector2(0, 0.05)]), _tp(f, STEEL, 0))
	f.poly(rot.call([Vector2(0, -1.02), Vector2(0, 0.05), Vector2(0.12, 0.05), Vector2(0.15, -0.66)]), _tp(f, STEEL, 1, 0.92))
	f.poly(rot.call([Vector2(0, -1.02), Vector2(-0.15, -0.66), Vector2(-0.07, -0.60), Vector2(0, -0.80)]), _tp(f, STEEL, 0, 1.12))
	f.poly(rot.call([Vector2(0.015, -0.66), Vector2(0.075, -0.60), Vector2(0.07, 0.0), Vector2(0.015, 0.0)]), _tp(f, STEEL, 2, 0.9))
	# guard, grip, pommel (bronze)
	f.poly(rot.call(guard), _tp(f, BRONZE, 1))
	f.poly(rot.call([Vector2(-0.36, 0.03), Vector2(0.36, 0.03), Vector2(0.38, 0.07), Vector2(-0.38, 0.07)]), _tp(f, BRONZE, 0))
	f.poly(rot.call([Vector2(-0.40, 0.14), Vector2(0.40, 0.14), Vector2(0.36, 0.17), Vector2(-0.36, 0.17)]), _tp(f, BRONZE, 2))
	f.poly(rot.call(grip), _tp(f, BRONZE, 2, 0.95))
	for k in 3:
		var y: float = 0.22 + 0.10 * float(k)
		f.line((Vector2(-0.06, y)).rotated(deg_to_rad(45)), (Vector2(0.06, y + 0.04)).rotated(deg_to_rad(45)), _tp(f, BRONZE, 3), 0.03)
	f.poly(rot.call(pommel), _tp(f, BRONZE, 1))
	f.poly(rot.call([Vector2(0, 0.46), Vector2(-0.12, 0.58), Vector2(0, 0.58)]), _tp(f, BRONZE, 0))
	f.poly(rot.call([Vector2(0, 0.58), Vector2(0.12, 0.58), Vector2(0, 0.72)]), _tp(f, BRONZE, 2))


func _icon_shield(f: Frame) -> void:
	var outer: Array = [Vector2(-0.64, -0.60), Vector2(0, -0.76), Vector2(0.64, -0.60), Vector2(0.64, -0.04), Vector2(0.40, 0.44), Vector2(0, 0.80), Vector2(-0.40, 0.44), Vector2(-0.64, -0.04)]
	var inner: Array = [Vector2(-0.50, -0.47), Vector2(0, -0.60), Vector2(0.50, -0.47), Vector2(0.50, -0.02), Vector2(0.31, 0.37), Vector2(0, 0.66), Vector2(-0.31, 0.37), Vector2(-0.50, -0.02)]
	_shadow(f, outer)
	# bronze frame, faceted: lit left/top, dark right/bottom
	f.poly(outer, _tp(f, BRONZE, 1))
	f.poly([outer[0], outer[1], inner[1], inner[0]], _tp(f, BRONZE, 0))
	f.poly([outer[1], outer[2], inner[2], inner[1]], _tp(f, BRONZE, 0, 0.92))
	f.poly([outer[7], outer[0], inner[0], inner[7]], _tp(f, BRONZE, 0, 0.98))
	f.poly([outer[2], outer[3], inner[3], inner[2]], _tp(f, BRONZE, 1, 0.9))
	f.poly([outer[3], outer[4], inner[4], inner[3]], _tp(f, BRONZE, 2))
	f.poly([outer[4], outer[5], inner[5], inner[4]], _tp(f, BRONZE, 2, 0.85))
	f.poly([outer[5], outer[6], inner[6], inner[5]], _tp(f, BRONZE, 2, 0.95))
	f.poly([outer[6], outer[7], inner[7], inner[6]], _tp(f, BRONZE, 1, 0.9))
	# steel face: split plane (left light, right darker) plus a top facet and a centre ridge
	f.poly(inner, _tp(f, STEEL, 2))
	f.poly([inner[0], inner[1], Vector2(0, 0.0), inner[7]], _tp(f, STEEL, 1))
	f.poly([inner[7], Vector2(0, 0.0), inner[5], inner[6]], _tp(f, STEEL, 0, 0.95))
	f.poly([inner[1], inner[2], inner[3], Vector2(0, 0.0)], _tp(f, STEEL, 2, 1.15))
	f.poly([Vector2(0, 0.0), inner[3], inner[4], inner[5]], _tp(f, STEEL, 2, 0.88))
	f.poly([inner[0], inner[1], Vector2(0, -0.20), Vector2(-0.30, -0.12)], _tp(f, STEEL, 0, 1.06))
	f.line(Vector2(0, -0.58), Vector2(0, 0.62), _tp(f, STEEL, 3), 0.025)
	f.poly([Vector2(0, -0.14), Vector2(0.12, 0.0), Vector2(0, 0.14), Vector2(-0.12, 0.0)], _tp(f, BRONZE, 0))
	f.poly([Vector2(0, -0.14), Vector2(0.12, 0.0), Vector2(0, 0.0)], _tp(f, BRONZE, 1, 0.9))


func _icon_boot(f: Frame) -> void:
	var shaft: Array = [Vector2(-0.34, -0.74), Vector2(0.14, -0.74), Vector2(0.22, -0.06), Vector2(-0.36, -0.06)]
	var foot: Array = [Vector2(-0.36, -0.06), Vector2(0.22, -0.06), Vector2(0.38, 0.08), Vector2(0.72, 0.22), Vector2(0.76, 0.42), Vector2(-0.48, 0.42), Vector2(-0.46, 0.18)]
	var sole: Array = [Vector2(-0.50, 0.40), Vector2(0.78, 0.40), Vector2(0.78, 0.56), Vector2(-0.50, 0.56)]
	for part in [shaft, foot, sole]:
		_shadow(f, part)
	f.poly(sole, _tp(f, BRONZE, 3, 1.2))
	f.poly([Vector2(-0.50, 0.40), Vector2(0.78, 0.40), Vector2(0.78, 0.45), Vector2(-0.50, 0.45)], _tp(f, BRONZE, 2))
	f.poly(foot, _tp(f, BRONZE, 1))
	f.poly([Vector2(-0.36, -0.06), Vector2(0.22, -0.06), Vector2(0.38, 0.08), Vector2(0.02, 0.10), Vector2(-0.46, 0.18)], _tp(f, BRONZE, 0, 0.98))
	f.poly([Vector2(0.38, 0.08), Vector2(0.72, 0.22), Vector2(0.76, 0.42), Vector2(0.30, 0.42), Vector2(0.20, 0.20)], _tp(f, BRONZE, 0, 0.88))
	f.poly([Vector2(-0.48, 0.42), Vector2(0.30, 0.42), Vector2(0.20, 0.20), Vector2(-0.46, 0.18)], _tp(f, BRONZE, 2, 1.1))
	f.poly(shaft, _tp(f, STEEL, 2, 0.9))
	f.poly([Vector2(-0.34, -0.74), Vector2(-0.07, -0.74), Vector2(-0.08, -0.06), Vector2(-0.36, -0.06)], _tp(f, STEEL, 1, 1.0))
	f.poly([Vector2(-0.07, -0.74), Vector2(0.14, -0.74), Vector2(0.22, -0.06), Vector2(-0.08, -0.06)], _tp(f, STEEL, 2, 1.0))
	f.poly([Vector2(-0.36, -0.74), Vector2(0.14, -0.74), Vector2(0.14, -0.58), Vector2(-0.35, -0.58)], _tp(f, STEEL, 0, 0.96))
	f.poly([Vector2(-0.36, -0.20), Vector2(0.20, -0.20), Vector2(0.22, -0.06), Vector2(-0.36, -0.06)], _tp(f, BRONZE, 0))
	f.line(Vector2(-0.33, -0.42), Vector2(0.16, -0.42), _tp(f, STEEL, 3), 0.03)
	f.line(Vector2(0.40, 0.14), Vector2(0.50, 0.38), _tp(f, BRONZE, 3), 0.025)


func _icon_flask(f: Frame) -> void:
	var cx := Vector2(0, 0.22)
	var body: Array = []
	var inner_body: Array = []
	for i in 8:
		var a: float = TAU * (float(i) + 0.5) / 8.0
		body.append(cx + Vector2(cos(a) * 0.62, sin(a) * 0.58))
		inner_body.append(cx + Vector2(cos(a) * 0.50, sin(a) * 0.47))
	var neck: Array = [Vector2(-0.17, -0.46), Vector2(0.17, -0.46), Vector2(0.20, -0.14), Vector2(-0.20, -0.14)]
	var cork: Array = [Vector2(-0.19, -0.74), Vector2(0.19, -0.74), Vector2(0.15, -0.50), Vector2(-0.15, -0.50)]
	_shadow(f, body)
	_shadow(f, neck)
	f.poly(body, _tp(f, BRONZE, 1))
	for i in 8:
		var j: int = (i + 1) % 8
		f.poly([body[i], body[j], inner_body[j], inner_body[i]], _tp(f, BRONZE, 0 if i in [5, 6, 7] else 2, 1.0))
	f.poly(neck, _tp(f, BRONZE, 1))
	f.poly([Vector2(-0.17, -0.46), Vector2(0.0, -0.46), Vector2(0.0, -0.14), Vector2(-0.20, -0.14)], _tp(f, BRONZE, 0))
	f.poly([Vector2(-0.22, -0.20), Vector2(0.22, -0.20), Vector2(0.25, -0.10), Vector2(-0.25, -0.10)], _tp(f, BRONZE, 0, 0.95))
	# the red gem: fan of facets
	var core: Vector2 = cx + Vector2(-0.08, -0.06)
	for i in 8:
		var j2: int = (i + 1) % 8
		var col: Color
		match i:
			0: col = GEM[1]
			1: col = GEM[1]
			2: col = GEM[2]
			3: col = GEM[3]
			4: col = GEM[2]
			5: col = GEM[1]
			6: col = GEM[0]
			_: col = GEM[0]
		f.poly([inner_body[i], inner_body[j2], core], _tone(col, f.state))
	f.poly([inner_body[5], inner_body[6], core], _tone(_shade(GEM[0], 1.05), f.state))
	f.poly([cx + Vector2(-0.34, -0.20), cx + Vector2(-0.20, -0.30), cx + Vector2(-0.12, -0.18), cx + Vector2(-0.26, -0.08)], _tone(Color(1.0, 0.86, 0.80, 0.85), f.state))
	f.poly(cork, _tp(f, CORK, 1))
	f.poly([Vector2(-0.19, -0.74), Vector2(0.0, -0.74), Vector2(0.0, -0.50), Vector2(-0.15, -0.50)], _tp(f, CORK, 0))
	f.poly([Vector2(-0.22, -0.52), Vector2(0.22, -0.52), Vector2(0.20, -0.44), Vector2(-0.20, -0.44)], _tp(f, BRONZE, 0))


func _icon_chevrons(f: Frame) -> void:
	for k in 3:
		var x: float = -0.74 + 0.46 * float(k)
		var pts: Array = [Vector2(x, -0.58), Vector2(x + 0.26, -0.58), Vector2(x + 0.62, 0.0), Vector2(x + 0.26, 0.58), Vector2(x, 0.58), Vector2(x + 0.36, 0.0)]
		_shadow(f, pts)
		var k2: float = 0.80 + 0.10 * float(k)   # the leading chevron is brightest
		f.poly(pts, _tp(f, IVORY, 1, k2))
		f.poly([pts[0], pts[1], pts[2], pts[5]], _tp(f, IVORY, 0, k2))
		f.poly([pts[5], pts[2], pts[3], pts[4]], _tp(f, IVORY, 2, k2 * 1.02))
		f.line(pts[0], pts[1], _tp(f, BRONZE, 1, 1.0), 0.03)


func _icon_key(f: Frame) -> void:
	var bow_c := Vector2(-0.34, 0.0)
	var ring_o: Array = []
	var ring_i: Array = []
	for i in 12:
		var a: float = TAU * float(i) / 12.0
		ring_o.append(bow_c + _pol(0.34, a))
		ring_i.append(bow_c + _pol(0.15, a))
	var shaft: Array = [Vector2(-0.04, -0.09), Vector2(0.72, -0.09), Vector2(0.72, 0.09), Vector2(-0.04, 0.09)]
	var t1: Array = [Vector2(0.44, 0.09), Vector2(0.58, 0.09), Vector2(0.58, 0.34), Vector2(0.44, 0.34)]
	var t2: Array = [Vector2(0.62, 0.09), Vector2(0.74, 0.09), Vector2(0.74, 0.28), Vector2(0.62, 0.28)]
	_shadow(f, ring_o)
	_shadow(f, shaft)
	for i in 12:
		var j: int = (i + 1) % 12
		var lit: int = 0 if i in [6, 7, 8, 9] else (2 if i in [0, 1, 2, 3] else 1)
		f.poly([ring_o[i], ring_o[j], ring_i[j], ring_i[i]], _tp(f, BRONZE, lit))
	f.poly(shaft, _tp(f, BRONZE, 1))
	f.poly([Vector2(-0.04, -0.09), Vector2(0.72, -0.09), Vector2(0.72, 0.0), Vector2(-0.04, 0.0)], _tp(f, BRONZE, 0))
	for t in [t1, t2]:
		f.poly(t, _tp(f, BRONZE, 2))
		f.poly([t[0], Vector2(t[0].x + (t[1].x - t[0].x) * 0.5, t[0].y), Vector2(t[0].x + (t[1].x - t[0].x) * 0.5, t[2].y), t[3]], _tp(f, BRONZE, 1))
	f.poly([bow_c + Vector2(0, -0.07), bow_c + Vector2(0.07, 0), bow_c + Vector2(0, 0.07), bow_c + Vector2(-0.07, 0)], _tone(EMBER_BRIGHT, f.state))
