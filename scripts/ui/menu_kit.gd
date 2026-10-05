# ==============================================================================
# File Name: menu_kit.gd
# Path: res://scripts/ui/menu_kit.gd
# Description: Small, reusable menu pieces that compose the PUI design system for the front-end screens
#   (main menu, character selection, profiles). Nothing here defines new colours or sizes - every colour is
#   a PUI token, every spacing a PUI step. Drawn in code: no image assets, no shaders, no per-frame work.
#     MenuKit.side_veil()          restrained dark gradient behind a left-hand button column
#     MenuKit.Sigil                quiet ember/iron emblem (class sigil, empty portrait, "+" mark)
#     MenuKit.card_style(kind)     the theme's CardPanel / InsetPanel with tighter padding for list rows
#     MenuKit.slot_card(...)       one 10-slot profile card (CardPanel + invisible full-card Button)
# ==============================================================================
class_name MenuKit
extends RefCounted

static var _veil_tex: Texture2D = null
static var _empty_box: StyleBoxEmpty = null


# ── Backdrop ─────────────────────────────────────────────────────────────────────────────────
## Dark horizontal gradient anchored to the left `width_frac` of the screen: darkest at the left edge, gone at the
## right. Keeps the dungeon visible while giving the button column a calm ground. Add it above the picture.
static func side_veil(width_frac: float = 0.55, strength: float = 0.80) -> TextureRect:
	if _veil_tex == null:
		var g := Gradient.new()
		g.set_color(0, Color(0.03, 0.025, 0.02, 1.0))
		g.set_color(1, Color(0.03, 0.025, 0.02, 0.0))
		g.add_point(0.45, Color(0.03, 0.025, 0.02, 0.62))
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_LINEAR
		t.fill_from = Vector2(0.0, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		t.width = 256
		t.height = 4
		_veil_tex = t
	var r := TextureRect.new()
	r.name = "ColumnVeil"
	r.texture = _veil_tex
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.anchor_right = width_frac
	r.offset_right = 0.0
	r.modulate = Color(1, 1, 1, strength)
	return r


# ── Sigil ────────────────────────────────────────────────────────────────────────────────────
## A quiet emblem: an iron disc with a brass ring and four ember ticks, and (optionally) one icon of the family.
## kind: "" (empty ring), "plus" (drawn mark), or any TouchIcons kind ("attack", "burst", ...).
class Sigil extends Control:
	var kind: String = "":
		set(v):
			kind = v
			queue_redraw()
	var max_radius: float = 110.0
	var lit: bool = true:   # false = the quieter, empty-slot version
		set(v):
			lit = v
			queue_redraw()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(48, 48)

	func _draw() -> void:
		var r: float = minf(minf(size.x, size.y) * 0.5, max_radius) - 2.0
		if r < 6.0:
			return
		var c: Vector2 = size * 0.5
		var ring: Color = PUI.EDGE_BRASS if lit else PUI.EDGE
		draw_circle(c, r, PUI.IRON_DEEP)
		draw_arc(c, r, 0.0, TAU, 64, ring, 2.0, true)
		draw_arc(c, r * 0.82, 0.0, TAU, 64, Color(PUI.EDGE.r, PUI.EDGE.g, PUI.EDGE.b, 0.8), 1.0, true)
		var tick: Color = PUI.EMBER_DEEP if lit else PUI.EDGE
		for i in 4:
			var a: float = float(i) * PI * 0.5 - PI * 0.5
			var d := Vector2(cos(a), sin(a))
			draw_line(c + d * (r * 0.82), c + d * (r * 1.0), tick, 3.0, true)
		if kind == "plus":
			var arm: float = r * 0.34
			var col: Color = PUI.EMBER_DEEP if lit else PUI.EDGE_BRASS
			draw_line(c + Vector2(-arm, 0), c + Vector2(arm, 0), col, maxf(r * 0.1, 2.0), true)
			draw_line(c + Vector2(0, -arm), c + Vector2(0, arm), col, maxf(r * 0.1, 2.0), true)
		elif kind != "":
			TouchIcons.draw_icon(self, kind, c, r * (0.52 if r > 40.0 else 0.66), PUI.BONE_DIM if lit else PUI.BONE_FAINT)


# ── Cards ────────────────────────────────────────────────────────────────────────────────────
## The theme's CardPanel ("card") or InsetPanel ("inset") box with list-row padding instead of full panel padding.
static func card_style(kind: String = "card") -> StyleBox:
	var vname: String = "CardPanel" if kind == "card" else "InsetPanel"
	var sb := PUI.theme().get_stylebox("panel", vname).duplicate() as StyleBoxTexture
	sb.content_margin_left = PUI.S4
	sb.content_margin_right = PUI.S4
	sb.content_margin_top = PUI.S3
	sb.content_margin_bottom = PUI.S3
	return sb


static func _no_box() -> StyleBoxEmpty:
	if _empty_box == null:
		_empty_box = StyleBoxEmpty.new()
	return _empty_box


## One profile slot. Returns {"card": PanelContainer, "button": Button}. The Button covers the whole card (it is the
## focus / click target and draws the theme's ember focus ring); the card underneath shows the content.
## `data` is {} for an empty slot, {"broken": true} for a corrupted one, otherwise
## {"name": String, "class": String, "runs": int, "deaths": int}.
static func slot_card(slot_number: int, data: Dictionary) -> Dictionary:
	var empty: bool = data.is_empty()
	var broken: bool = data.get("broken", false)
	var card := PanelContainer.new()
	card.name = "SlotCard%d" % slot_number
	card.add_theme_stylebox_override("panel", card_style("inset" if empty else "card"))
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.custom_minimum_size = Vector2(0, 80 if _is_touch() else 104)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", PUI.S4)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(row)

	var sigil := Sigil.new()
	sigil.custom_minimum_size = Vector2(56, 56)
	sigil.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sigil.max_radius = 28.0
	sigil.lit = not empty
	if empty:
		sigil.kind = "plus"
	elif broken:
		sigil.kind = ""
	else:
		sigil.kind = "burst" if str(data.get("class", "")).to_lower() == "mage" else "attack"
	row.add_child(sigil)

	var mid := VBoxContainer.new()
	mid.add_theme_constant_override("separation", 0)
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(mid)

	var top: Label
	var sub: Label
	if empty:
		top = PUI.label("Empty slot", "StatLabel")
		sub = PUI.label("Slot %d  ·  %s to create a character" % [slot_number, "tap" if _is_touch() else "click"], "MetaLabel")
	elif broken:
		top = PUI.label("Corrupted save", "DangerTitle")
		sub = PUI.label("Slot %d  ·  can be cleared" % slot_number, "MetaLabel")
	else:
		top = PUI.label(str(data.get("name", "")), "CardTitle")
		sub = PUI.label("%s  ·  Slot %d" % [str(data.get("class", "")), slot_number], "StatLabel")
	top.name = "SlotName"
	sub.name = "SlotSub"
	top.clip_text = true
	top.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.add_child(top)
	mid.add_child(sub)

	if not empty and not broken:
		var meta := VBoxContainer.new()
		meta.add_theme_constant_override("separation", 0)
		meta.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(meta)
		for pair in [["Runs", int(data.get("runs", 0))], ["Deaths", int(data.get("deaths", 0))]]:
			var m := PUI.label("%s %d" % [pair[0], pair[1]], "StatLabel")
			m.name = "Meta" + str(pair[0])
			m.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			m.mouse_filter = Control.MOUSE_FILTER_IGNORE
			meta.add_child(m)

	var btn := Button.new()
	btn.name = "SlotButton%d" % slot_number
	btn.flat = true
	btn.focus_mode = Control.FOCUS_ALL
	for st in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		btn.add_theme_stylebox_override(st, _no_box())
	card.add_child(btn)   # a PanelContainer stacks its children: the button lies over the content

	# Hover / focus lift without a per-card stylebox: a gentle brighten of the whole card.
	var lift := func(on: bool) -> void:
		card.self_modulate = Color(1.18, 1.12, 1.05, 1.0) if on else Color.WHITE
	btn.mouse_entered.connect(lift.bind(true))
	btn.mouse_exited.connect(func(): lift.call(btn.has_focus()))
	btn.focus_entered.connect(lift.bind(true))
	btn.focus_exited.connect(lift.bind(false))
	return {"card": card, "button": btn}


static func _is_touch() -> bool:
	return OS.has_feature("android") or OS.has_feature("ios") or OS.get_environment("PURGATORY_FORCE_TOUCH") == "1"
