# ==============================================================================
# File Name: touch_button.gd
# Path: res://scripts/touch/touch_button.gd
#
# Description:
#   One round on-screen action button. It does not read input itself: TouchControls routes
#   touches to it (so several fingers can work at once) and it only draws and reports.
#   The hit area is larger than the drawn circle so thumbs do not have to be precise.
#
#   Look (Purgatory brand, docs/UI_DESIGN_SYSTEM.md section 7): a blackened-iron disc (cached radial
#   gradient texture) with a brass/iron rim, a bone icon and ember accents. Tiers keep one component
#   family with a clear hierarchy: PRIMARY (attack: heaviest rim), COMBAT (kick, slide, block, burst),
#   CONTEXT (USE/OPEN: ember rim, the contextual primary), QUIET (pause, map: lower contrast).
#   Drawing is a handful of primitives and only happens when the state changes (plus the onboarding
#   pulse while a hint is highlighting a button).
# ==============================================================================
class_name TouchButton
extends Control

const HIT_SLOP := 1.30   # touch radius = drawn radius * this

enum Mode { HOLD, TOGGLE }
enum Tier { COMBAT, PRIMARY, CONTEXT, QUIET }

const RIM_SEGMENTS := 56
# Typography rule: short labels (USE / OPEN, the potion count) are Cinzel; 16 px is the smallest caption.
# TODO: switch to PUI.MIN_DISPLAY_SIZE once the typography branch lands (it is the same 16).
const CAPTION_MIN_FS := 16

var action    : String = ""
var icon_kind : String = ""
var label     : String = ""
var mode      : Mode   = Mode.HOLD
var tier      : Tier   = Tier.COMBAT
var radius    : float  = 80.0           # drawn radius, virtual px
var center    : Vector2 = Vector2.ZERO  # in TouchControls space
var pressed_visual : bool = false
var toggled_on     : bool = false
var cooldown       : float = 0.0        # 0..1 fraction remaining (ring over the button)
var charge         : float = 0.0        # 0..1 hold-to-charge progress (ember ring on the rim)
var badge          : String = ""        # small count in the corner (e.g. potions)
var highlighted    : bool = false       # onboarding pulse
var enabled_look   : bool = true

# Text metrics are cached: shaping a string on every pulse frame would be wasted work.
var _label_key : String = ""
var _label_size : Vector2 = Vector2.ZERO
var _badge_key : String = ""
var _badge_size : Vector2 = Vector2.ZERO
var _badge_fs : int = 14

static var _skin : Dictionary = {}


static func tier_for(p_action: String) -> Tier:
	match p_action:
		"attack": return Tier.PRIMARY
		"equip": return Tier.CONTEXT
		"ui_menu", "minimap": return Tier.QUIET
	return Tier.COMBAT


func setup(p_action: String, p_icon: String, p_mode: Mode = Mode.HOLD) -> void:
	action = p_action
	icon_kind = p_icon
	mode = p_mode
	tier = tier_for(p_action)
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


# ── Cached materials ──────────────────────────────────────────────────────────

## A round radial-gradient texture whose last stop is transparent, so the square texture reads as a disc.
## stops: [[offset, Color], ...] (the final stop should have alpha 0 at offset 1.0).
static func _radial(key: String, stops: Array, px: int) -> Texture2D:
	if _skin.has(key):
		return _skin[key]
	var g := Gradient.new()
	var offs := PackedFloat32Array()
	var cols := PackedColorArray()
	for s in stops:
		offs.append(float(s[0]))
		cols.append(s[1])
	g.offsets = offs
	g.colors = cols
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)   # offset 1.0 is the disc edge
	t.width = px
	t.height = px
	_skin[key] = t
	return t


static func _clear(c: Color) -> Color:
	return Color(c.r, c.g, c.b, 0.0)


## Button face: iron lifted at the centre, blackened toward the rim. down = pressed / toggled (a faint ember warmth).
static func body_texture(p_tier: int, down: bool) -> Texture2D:
	var key := "body|%d|%s" % [p_tier, down]
	if _skin.has(key):
		return _skin[key]
	var hi: Color = PUI.IRON_RAISED
	var mid: Color = PUI.IRON
	var lo: Color = PUI.IRON_DEEP
	var a: float = 0.94
	match p_tier:
		Tier.PRIMARY:
			hi = PUI.IRON_HOVER.darkened(0.05)
			mid = PUI.IRON_RAISED.darkened(0.18)
		Tier.CONTEXT:
			hi = PUI.IRON_RAISED.lerp(PUI.EMBER_DEEP, 0.22)
			mid = PUI.IRON.lerp(PUI.EMBER_DEEP, 0.10)
		Tier.QUIET:
			hi = PUI.IRON
			mid = PUI.IRON.darkened(0.12)
			lo = PUI.IRON_DEEP.darkened(0.2)
			a = 0.84
	if down:
		hi = hi.lerp(PUI.EMBER_DEEP, 0.38)
		mid = mid.darkened(0.25)
		lo = lo.darkened(0.2)
	var edge := Color(lo.r, lo.g, lo.b, a)
	return _radial(key, [
		[0.0, Color(hi.r, hi.g, hi.b, a)],
		[0.62, Color(mid.r, mid.g, mid.b, a)],
		[0.97, edge],
		[1.0, _clear(edge)],
	], 128)


## Joystick base: a dark well, a touch lighter toward its rim; the iron rim ring is drawn on top.
static func stick_base_texture() -> Texture2D:
	return _radial("stick_base", [
		[0.0, Color(PUI.VOID.r, PUI.VOID.g, PUI.VOID.b, 0.40)],
		[0.60, Color(PUI.IRON_DEEP.r, PUI.IRON_DEEP.g, PUI.IRON_DEEP.b, 0.52)],
		[0.96, Color(PUI.IRON.r, PUI.IRON.g, PUI.IRON.b, 0.66)],
		[1.0, _clear(PUI.IRON)],
	], 160)


## Joystick thumb: a polished bone / iron knob, lit from the centre.
static func stick_knob_texture() -> Texture2D:
	var bone: Color = PUI.BONE_DIM
	var rim: Color = PUI.EDGE_BRASS.darkened(0.35)
	return _radial("stick_knob", [
		[0.0, Color(bone.r, bone.g, bone.b, 0.96)],
		[0.55, Color(bone.darkened(0.30).r, bone.darkened(0.30).g, bone.darkened(0.30).b, 0.96)],
		[0.96, Color(rim.r, rim.g, rim.b, 0.96)],
		[1.0, _clear(rim)],
	], 96)


# ── Drawing ───────────────────────────────────────────────────────────────────

func _rim_color(down: bool) -> Color:
	var rim: Color
	match tier:
		Tier.PRIMARY: rim = PUI.EDGE_BRASS.darkened(0.22)
		Tier.CONTEXT: rim = PUI.EMBER_DEEP
		Tier.QUIET:   rim = PUI.EDGE.darkened(0.05)
		_:            rim = PUI.EDGE.lightened(0.28)
	if down:
		rim = PUI.EMBER if tier != Tier.QUIET else PUI.EMBER_DEEP
	if tier == Tier.CONTEXT and down:
		rim = PUI.EMBER_BRIGHT
	return rim


func _draw() -> void:
	var c: Vector2 = size * 0.5
	var r: float = radius
	var down: bool = pressed_visual or toggled_on
	var quiet: bool = tier == Tier.QUIET
	var rw: float = maxf(r * (0.088 if tier == Tier.PRIMARY else (0.056 if quiet else 0.072)), 2.5)

	# contact shadow, face, rim (+ bevel), groove between rim and face
	draw_arc(c, r + 1.5, 0.0, TAU, RIM_SEGMENTS, Color(0, 0, 0, 0.30), 3.0, true)
	draw_texture_rect(body_texture(tier, down), Rect2(c - Vector2(r, r), Vector2(r, r) * 2.0), false)
	var rim: Color = _rim_color(down)
	draw_arc(c, r - rw * 0.5, 0.0, TAU, RIM_SEGMENTS, rim, rw, true)
	if not quiet:
		draw_arc(c, r - rw * 0.28, PI * 1.02, PI * 1.62, 20, rim.lightened(0.42), rw * 0.36, true)   # lit upper-left edge
		draw_arc(c, r - rw * 0.76, PI * 0.06, PI * 0.74, 20, rim.darkened(0.55), rw * 0.46, true)    # shaded lower edge
	draw_arc(c, r - rw - 1.0, 0.0, TAU, RIM_SEGMENTS, Color(0, 0, 0, 0.5), 2.0, true)
	if down:
		draw_arc(c, r - rw - r * 0.09, 0.0, TAU, RIM_SEGMENTS, Color(PUI.EMBER.r, PUI.EMBER.g, PUI.EMBER.b, 0.26), r * 0.14, true)

	# hold-to-charge: the rim fills with ember
	if charge > 0.0:
		draw_arc(c, r - rw * 0.9, -PI * 0.5, -PI * 0.5 + TAU * clampf(charge, 0.0, 1.0), RIM_SEGMENTS, PUI.EMBER_BRIGHT, rw * 1.8, true)

	# onboarding pulse: a single expanding ember ring
	if highlighted:
		var t: float = fmod(Time.get_ticks_msec() * 0.001, 1.2) / 1.2
		draw_arc(c, r * (1.05 + 0.30 * t), 0.0, TAU, RIM_SEGMENTS, Color(PUI.EMBER_BRIGHT.r, PUI.EMBER_BRIGHT.g, PUI.EMBER_BRIGHT.b, 1.0 - t), maxf(r * 0.07, 3.0), true)

	var icon_tint: Color = PUI.BONE_BRIGHT if down else (PUI.BONE_DIM if quiet else PUI.BONE)
	TouchIcons.draw_icon(self, icon_kind, c + Vector2(0.0, r * 0.03 if down else 0.0), r * 0.84, icon_tint)

	if cooldown > 0.0:
		# Dark wedge over the face and an ember arc on the rim, both shrinking as the cooldown runs out.
		var a0: float = -PI * 0.5
		var a1: float = a0 + TAU * clampf(cooldown, 0.0, 1.0)
		var ri: float = r - rw
		draw_arc(c, ri * 0.5, a0, a1, 32, Color(0.03, 0.02, 0.02, 0.58), ri, false)
		draw_arc(c, r - rw * 0.5, a0, a1, RIM_SEGMENTS, PUI.EMBER, rw, true)

	if label != "":
		_draw_label(c, r)
	if badge != "":
		_draw_badge(c, r)


func _draw_label(c: Vector2, r: float) -> void:
	var font: Font = PUI.font("display_semi")
	var fs: int = int(maxf(r * 0.27, float(CAPTION_MIN_FS)))
	var key := "%s|%d" % [label, fs]
	if key != _label_key:
		_label_key = key
		_label_size = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var pos: Vector2 = c + Vector2(-_label_size.x * 0.5, r + _label_size.y * 0.8)
	var col: Color = PUI.EMBER_BRIGHT if tier == Tier.CONTEXT else PUI.BONE_BRIGHT
	draw_string_outline(font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 6, Color(0.03, 0.02, 0.02, 0.92))
	draw_string(font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _draw_badge(c: Vector2, r: float) -> void:
	var font: Font = PUI.font("display_bold")
	var br: float = r * 0.26
	var bp: Vector2 = c + Vector2(r * 0.62, -r * 0.62)
	var key := "%s|%.1f" % [badge, r]
	if key != _badge_key:
		_badge_key = key
		var fs: int = int(maxf(r * 0.30, 14.0))
		var ts: Vector2 = font.get_string_size(badge, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		if ts.x > br * 1.7:   # long counts shrink to stay inside the plate
			fs = maxi(int(float(fs) * br * 1.7 / ts.x), 9)
			ts = font.get_string_size(badge, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		_badge_fs = fs
		_badge_size = ts
	draw_circle(bp, br + 1.5, Color(0, 0, 0, 0.45))
	draw_circle(bp, br, PUI.IRON_DEEP)
	draw_arc(bp, br - 1.0, 0.0, TAU, 28, PUI.EMBER, 2.0, true)
	var base: Vector2 = bp + Vector2(-_badge_size.x * 0.5, (font.get_ascent(_badge_fs) - font.get_descent(_badge_fs)) * 0.5)
	draw_string(font, base, badge, HORIZONTAL_ALIGNMENT_LEFT, -1, _badge_fs, PUI.BONE_BRIGHT)
