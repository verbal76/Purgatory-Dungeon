# ==============================================================================
# File Name: pui.gd
# Path: res://scripts/ui/pui.gd
#
# PURGATORY UI - the one interface language for the whole game.
#   Dark dungeon + aged iron + warm firelight + restrained parchment.
#   Reference: docs/UI_DESIGN_SYSTEM.md
#
# What lives here
#   * canonical palette (semantic roles, never ad-hoc colours)
#   * spacing / size tokens
#   * type roles (two bundled OFL families: Cinzel display, Source Sans 3 body)
#   * procedural "iron" materials: tiny 9-slice textures generated once at start-up
#     (no art assets, no shaders, no per-frame cost)
#   * the Godot Theme that styles every Control, with theme type VARIATIONS for each component
#     (PrimaryButton, SelectorButton, CardPanel, SectionHeading, ...)
#   * small helpers for UI that is built in code
#
# Use it:   control.theme_type_variation = &"PrimaryButton"    (or PUI.button("Start", "primary"))
# The theme is applied to the root window by the UiTheme autoload, so every scene inherits it.
# ==============================================================================
class_name PUI
extends RefCounted

# ── Palette (semantic roles) ─────────────────────────────────────────────────────────────────
const VOID          := Color("0b0908")   # behind full-screen UI where the dungeon is not visible
const IRON_DEEP     := Color("15110f")   # recessed / inset surfaces (inputs, tracks)
const IRON          := Color("1e1916")   # primary menu panels and button surfaces
const IRON_RAISED   := Color("2b241f")   # cards, tabs, selected panels, interactive surfaces
const IRON_HOVER    := Color("372e27")   # hover / focus lift
const EDGE          := Color("4d4034")   # border / divider: aged iron
const EDGE_BRASS    := Color("85693a")   # dark brass: emphasised borders
const BONE          := Color("eadfc6")   # primary text: warm bone / ivory
const BONE_BRIGHT   := Color("fff5dc")   # hover / emphasised text
const BONE_DIM      := Color("ab9f89")   # secondary text
const BONE_FAINT    := Color("6f6657")   # disabled text
const EMBER         := Color("cf8a2e")   # THE accent: selection, focus, active, primary action
const EMBER_BRIGHT  := Color("efae4d")   # accent on hover / pressed / highlighted values
const EMBER_DEEP    := Color("8a5a1d")   # accent edges at rest, fills under the accent
const BLOOD         := Color("8c2a28")   # danger edges / fills (semantic only)
const BLOOD_BRIGHT  := Color("e2685d")   # danger text
const MOSS          := Color("7f9a58")   # positive / available (semantic only - never an accent)
const PARCHMENT     := Color("d3bf93")   # aged paper (lore, records, the Alchemist's ledger)
const PARCHMENT_DK  := Color("b09665")   # paper shading / edges
const INK           := Color("1a1008")   # text on parchment
const INK_DIM       := Color("4a3a25")   # secondary text on parchment
const SCRIM         := Color(0.04, 0.03, 0.03, 0.62)   # veil over the dungeon behind menus

# Key metals: the one documented triple that tints the "key" icon for bronze / silver / gold keys (HUD, Alchemist).
const KEY_BRONZE    := Color("b0723a")
const KEY_SILVER    := Color("b9c0c6")
const KEY_GOLD      := Color("e0b84a")

# ── Spacing / size tokens (virtual px; multiples of 4) ───────────────────────────────────────
const S1 := 4
const S2 := 8
const S3 := 12
const S4 := 16
const S5 := 24
const S6 := 32
const S7 := 48
const SCREEN_MARGIN := 48
const PANEL_PAD := 20
const CARD_GAP := 16
const SECTION_GAP := 24
const BUTTON_H := 56          # desktop; MobileUi lifts it to 72 on phones
const BUTTON_H_PRIMARY := 64
const RADIUS := 6

# ── Type roles ───────────────────────────────────────────────────────────────────────────────
# role -> [font key, base size, colour]. Sizes are the PHONE-legible values (>= 20); desktop applies TYPE_SCALE_DESKTOP.
const TYPE_SCALE_DESKTOP := 0.86
const ROLES := {
	"game_title":     ["display_black", 72, "BONE"],
	"screen_title":   ["display_bold", 42, "BONE"],
	"section":        ["display_semi", 22, "EMBER"],
	"card_title":     ["display_semi", 26, "BONE"],
	"button":         ["body_semi", 26, "BONE"],
	"button_primary": ["display_bold", 28, "BONE_BRIGHT"],
	"body":           ["body_regular", 22, "BONE"],
	"body_secondary": ["body_regular", 20, "BONE_DIM"],
	"metadata":       ["body_regular", 18, "BONE_DIM"],
	"hud_value":      ["body_bold", 24, "BONE"],
	"hud_label":      ["body_semi", 18, "BONE_DIM"],
	"warning":        ["body_semi", 22, "BLOOD_BRIGHT"],
	"caption":        ["body_regular", 16, "BONE_DIM"],
}

const FONT_PATHS := {
	"display_black": "res://assets/fonts/Cinzel-Black.woff2",
	"display_bold":  "res://assets/fonts/Cinzel-Bold.woff2",
	"display_semi":  "res://assets/fonts/Cinzel-SemiBold.woff2",
	"body_regular":  "res://assets/fonts/SourceSans3-Regular.woff2",
	"body_semi":     "res://assets/fonts/SourceSans3-SemiBold.woff2",
	"body_bold":     "res://assets/fonts/SourceSans3-Bold.woff2",
}

static var _fonts: Dictionary = {}
static var _boxes: Dictionary = {}
static var _icons: Dictionary = {}
static var _theme: Theme = null
static var type_scale: float = 1.0
static var _scale_ready: bool = false


# ══════════════════════════════════════════════════════════════════════════════════════════════
#  PUBLIC API
# ══════════════════════════════════════════════════════════════════════════════════════════════

## The shared Theme (built once). Applied to the root window by the UiTheme autoload.
static func theme() -> Theme:
	if _theme == null:
		_ensure_scale()
		_theme = _build_theme()
	return _theme


static func _ensure_scale() -> void:
	if not _scale_ready:
		_scale_ready = true
		type_scale = 1.0 if _is_touch() else TYPE_SCALE_DESKTOP


static func _is_touch() -> bool:
	return OS.has_feature("android") or OS.has_feature("ios") or OS.get_environment("PURGATORY_FORCE_TOUCH") == "1"


## Scaled font size for a type role.
static func fs(role: String) -> int:
	_ensure_scale()
	return int(round(float(ROLES[role][1]) * type_scale))


static func color(role_name: String) -> Color:
	match role_name:
		"BONE": return BONE
		"BONE_BRIGHT": return BONE_BRIGHT
		"BONE_DIM": return BONE_DIM
		"EMBER": return EMBER
		"BLOOD_BRIGHT": return BLOOD_BRIGHT
		"INK": return INK
		"INK_DIM": return INK_DIM
	return BONE


## Tint for a key metal: "bronze" | "silver" | "gold" (anything else falls back to bone).
static func key_tint(metal: String) -> Color:
	match metal:
		"bronze": return KEY_BRONZE
		"silver": return KEY_SILVER
		"gold": return KEY_GOLD
	return BONE


static func font(key: String) -> Font:
	if not _fonts.has(key):
		var base := load(FONT_PATHS[key]) as Font
		var fv := FontVariation.new()
		fv.base_font = base
		fv.fallbacks = [ThemeDB.fallback_font]   # arrows / check marks the Latin subset lacks
		if key.begins_with("display"):
			fv.spacing_glyph = 1
		_fonts[key] = fv
	return _fonts[key]


## Apply a type role to a label-like control directly (for one-off controls built in code).
static func apply_role(c: Control, role: String, tint: Color = Color(0, 0, 0, 0)) -> void:
	var spec: Array = ROLES[role]
	c.add_theme_font_override("font", font(spec[0]))
	c.add_theme_font_size_override("font_size", fs(role))
	var col: Color = tint if tint.a > 0.0 else color(spec[2])
	c.add_theme_color_override("font_color", col)
	c.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.55))
	c.add_theme_constant_override("outline_size", 0)


static func label(text: String, variation: String = "") -> Label:
	var l := Label.new()
	l.text = text
	if variation != "":
		l.theme_type_variation = variation
	return l


## kind: "secondary" (default) | "primary" | "danger" | "nav" | "selector"
static func button(text: String, kind: String = "secondary") -> Button:
	var b := Button.new()
	b.text = text
	style_button(b, kind)
	return b


static func style_button(b: Button, kind: String = "secondary") -> void:
	match kind:
		"primary":
			b.theme_type_variation = &"PrimaryButton"
			b.custom_minimum_size.y = maxf(b.custom_minimum_size.y, BUTTON_H_PRIMARY)
		"danger":
			b.theme_type_variation = &"DangerButton"
		"nav":
			b.theme_type_variation = &"NavButton"
		"selector":
			b.theme_type_variation = &"SelectorButton"
			b.toggle_mode = true
			b.custom_minimum_size.y = maxf(b.custom_minimum_size.y, BUTTON_H)
		_:
			b.theme_type_variation = &""
	if kind != "primary":
		b.custom_minimum_size.y = maxf(b.custom_minimum_size.y, BUTTON_H)
	b.focus_mode = Control.FOCUS_ALL


## kind: "surface" | "card" | "parchment" | "veil" | "inset"
static func panel(kind: String = "surface") -> PanelContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = {"surface": &"", "card": &"CardPanel", "parchment": &"ParchmentPanel",
		"veil": &"VeilPanel", "inset": &"InsetPanel"}.get(kind, &"")
	return p


## Full-screen background. "void": opaque near-black with a faint warm vignette (menus with no world behind).
## "veil": translucent darkening + vignette over the visible dungeon. Returns the root Control (add it first).
static func background(kind: String = "void") -> Control:
	var root := Control.new()
	root.name = "UiBackground"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var base := ColorRect.new()
	base.set_anchors_preset(Control.PRESET_FULL_RECT)
	base.color = VOID if kind == "void" else Color(0.03, 0.025, 0.02, 0.50)
	base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(base)
	var vig := TextureRect.new()
	vig.texture = _vignette_texture()
	vig.set_anchors_preset(Control.PRESET_FULL_RECT)
	vig.stretch_mode = TextureRect.STRETCH_SCALE
	vig.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	vig.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(vig)
	return root


## Thin brass divider line.
static func divider() -> HSeparator:
	var s := HSeparator.new()
	s.theme_type_variation = &"BrassDivider"
	return s


## A Control whose parent is a CanvasLayer does NOT inherit the root window's theme (Godot's theme lookup stops at
## the CanvasLayer). Give every top-level Control built under a CanvasLayer in code this theme; children inherit it.
static func adopt(c: Control) -> Control:
	c.theme = theme()
	return c


# ── Rarity ramp (additive block: buff cards, pickups) ────────────────────────────────────────
# Restrained and built only from the palette: common = bone-dim edge, rare = dark brass, epic = ember,
# legendary = bright ember + a glow rising from the base, cursed = blood. Rarity is ALWAYS also written
# as a text tag (never colour alone). Reference: docs/UI_DESIGN_SYSTEM.md section 3.
const RARITY_EDGES := {
	"common": BONE_FAINT, "rare": EDGE_BRASS, "epic": EMBER, "legendary": EMBER_BRIGHT, "cursed": BLOOD,
}
const RARITY_TEXTS := {
	"common": BONE_DIM, "rare": EMBER, "epic": EMBER_BRIGHT, "legendary": EMBER_BRIGHT, "cursed": BLOOD_BRIGHT,
}
const RARITY_GLOW_ALPHA := {"common": 0.0, "rare": 0.0, "epic": 0.14, "legendary": 0.34, "cursed": 0.20}


static func rarity_edge(rarity: String) -> Color:
	return RARITY_EDGES.get(rarity, BONE_FAINT)


static func rarity_text(rarity: String) -> Color:
	return RARITY_TEXTS.get(rarity, BONE_DIM)


## Raised iron card whose edge (and, from epic up, base glow) carries the rarity. Cached; callers get a copy.
static func rarity_card(rarity: String) -> StyleBoxTexture:
	var key := "rarity_card|" + rarity
	if _boxes.has(key):
		return (_boxes[key] as StyleBoxTexture).duplicate()
	var edge: Color = rarity_edge(rarity)
	var glow_src: Color = BLOOD if rarity == "cursed" else EMBER
	var sb := box(IRON_RAISED, edge, IRON_RAISED.darkened(0.10), 0.10, 0.32, 0.016,
		Color(glow_src.r, glow_src.g, glow_src.b, float(RARITY_GLOW_ALPHA.get(rarity, 0.0))))
	sb.content_margin_left = PANEL_PAD
	sb.content_margin_right = PANEL_PAD
	sb.content_margin_top = PANEL_PAD
	sb.content_margin_bottom = PANEL_PAD
	_boxes[key] = sb
	return sb.duplicate()


# ══════════════════════════════════════════════════════════════════════════════════════════════
#  PROCEDURAL MATERIALS
# ══════════════════════════════════════════════════════════════════════════════════════════════

static func _hash(x: int, y: int, s: int) -> float:
	var v: float = sin(float(x) * 12.9898 + float(y) * 78.233 + float(s) * 37.719) * 43758.5453
	return v - floorf(v)


## One rounded 9-slice box: vertical fill gradient, 2 px edge, inner top highlight, inner bottom shadow, grain,
## optional ember glow rising from the bottom. Cached by parameters.
static func box(fill: Color, edge: Color, fill_bottom: Color = Color(0, 0, 0, 0), hi: float = 0.10, lo: float = 0.30,
		noise: float = 0.016, glow: Color = Color(0, 0, 0, 0), radius: int = RADIUS, seed_val: int = 3) -> StyleBoxTexture:
	var key := "%s|%s|%s|%.2f|%.2f|%.3f|%s|%d|%d" % [fill.to_html(), edge.to_html(), fill_bottom.to_html(), hi, lo, noise, glow.to_html(), radius, seed_val]
	if _boxes.has(key):
		return _boxes[key].duplicate()   # duplicate: callers may tweak margins
	var size := 40
	var edge_w := 2
	var bottom: Color = fill_bottom if fill_bottom.a > 0.0 else fill.darkened(0.12)
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var half: float = float(size) * 0.5
	for y in size:
		for x in size:
			var px: float = absf(float(x) + 0.5 - half) - (half - float(radius))
			var py: float = absf(float(y) + 0.5 - half) - (half - float(radius))
			var d: float = Vector2(maxf(px, 0.0), maxf(py, 0.0)).length() + minf(maxf(px, py), 0.0) - float(radius)
			var cov: float = clampf(0.5 - d, 0.0, 1.0)
			if cov <= 0.0:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			var depth: float = -d
			var t: float = float(y) / float(size - 1)
			var c: Color = fill.lerp(bottom, t)
			var n: float = (_hash(x, y, seed_val) - 0.5) * noise
			c = Color(clampf(c.r + n, 0.0, 1.0), clampf(c.g + n, 0.0, 1.0), clampf(c.b + n, 0.0, 1.0), c.a)
			if glow.a > 0.0 and t > 0.55:
				c = c.lerp(Color(glow.r, glow.g, glow.b, c.a), glow.a * (t - 0.55) / 0.45)
			var a: float = fill.a
			if depth < float(edge_w):
				c = Color(edge.r, edge.g, edge.b, edge.a)
				a = edge.a
			elif depth < float(edge_w) + 1.2:
				if y < size / 2:
					c = c.lerp(Color(1, 0.93, 0.8, c.a), hi)
				else:
					c = c.lerp(Color(0, 0, 0, c.a), lo)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, a * cov))
	var sb := StyleBoxTexture.new()
	sb.texture = ImageTexture.create_from_image(img)
	var m: float = float(radius + edge_w + 4)
	sb.texture_margin_left = m
	sb.texture_margin_right = m
	sb.texture_margin_top = m
	sb.texture_margin_bottom = m
	sb.content_margin_left = S4 + S1
	sb.content_margin_right = S4 + S1
	sb.content_margin_top = S3
	sb.content_margin_bottom = S3
	_boxes[key] = sb
	return sb.duplicate()


## Flat box for thin things (tracks, focus rings) where texture grain is wasted.
static func flat(fill: Color, edge: Color = Color(0, 0, 0, 0), border: int = 0, radius: int = 3) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = fill
	s.border_color = edge
	s.set_border_width_all(border)
	s.set_corner_radius_all(radius)
	return s


static func _focus_ring() -> StyleBoxFlat:
	var s := flat(Color(0, 0, 0, 0), EMBER_BRIGHT, 2, RADIUS + 2)
	s.set_expand_margin_all(3)
	return s


static func _vignette_texture() -> Texture2D:
	if _icons.has("vignette"):
		return _icons["vignette"]
	var g := Gradient.new()
	g.set_color(0, Color(0, 0, 0, 0))
	g.set_color(1, Color(0, 0, 0, 0.62))
	g.set_offset(0, 0.55)
	g.set_offset(1, 1.0)
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.05, 1.05)
	t.width = 128
	t.height = 128
	_icons["vignette"] = t
	return t


## Round slider thumb: brass ring, bone centre, soft shadow. size px.
static func _thumb_texture(size: int, ring: Color, centre: Color) -> Texture2D:
	var key := "thumb|%d|%s|%s" % [size, ring.to_html(), centre.to_html()]
	if _icons.has(key):
		return _icons[key]
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c: float = float(size) * 0.5
	var r: float = c - 3.0
	for y in size:
		for x in size:
			var d: float = Vector2(float(x) + 0.5 - c, float(y) + 0.5 - c).length()
			var col := Color(0, 0, 0, 0)
			if d <= r + 1.0:
				var cov: float = clampf(r + 0.5 - d, 0.0, 1.0)
				var inner: Color = centre.lerp(centre.darkened(0.25), clampf((float(y) / float(size)) - 0.3, 0.0, 1.0))
				if d > r - 4.0:
					col = Color(ring.r, ring.g, ring.b, cov)
				else:
					col = Color(inner.r, inner.g, inner.b, cov)
			elif d <= r + 3.0:
				col = Color(0, 0, 0, 0.22 * clampf(1.0 - (d - r - 1.0) / 2.0, 0.0, 1.0))
			img.set_pixel(x, y, col)
	var tex := ImageTexture.create_from_image(img)
	_icons[key] = tex
	return tex


## Check box: iron square, optional ember tick.
static func _check_texture(checked: bool, enabled: bool = true) -> Texture2D:
	var key := "check|%s|%s" % [checked, enabled]
	if _icons.has(key):
		return _icons[key]
	var size := 40
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var edge: Color = (EMBER if checked else EDGE_BRASS) if enabled else EDGE
	var fill: Color = IRON_DEEP
	for y in size:
		for x in size:
			var px: float = absf(float(x) + 0.5 - 20.0) - 14.0
			var py: float = absf(float(y) + 0.5 - 20.0) - 14.0
			var d: float = Vector2(maxf(px, 0.0), maxf(py, 0.0)).length() + minf(maxf(px, py), 0.0) - 4.0
			var cov: float = clampf(0.5 - d, 0.0, 1.0)
			if cov <= 0.0:
				continue
			var col: Color = edge if -d < 2.5 else fill
			img.set_pixel(x, y, Color(col.r, col.g, col.b, cov))
	if checked:
		var tick: Color = (EMBER_BRIGHT if enabled else BONE_FAINT)
		_thick_line(img, Vector2(11, 21), Vector2(18, 28), 3.2, tick)
		_thick_line(img, Vector2(18, 28), Vector2(30, 12), 3.2, tick)
	var tex := ImageTexture.create_from_image(img)
	_icons[key] = tex
	return tex


static func _thick_line(img: Image, a: Vector2, b: Vector2, w: float, col: Color) -> void:
	var steps: int = int(a.distance_to(b) * 2.0)
	for i in steps + 1:
		var p: Vector2 = a.lerp(b, float(i) / float(maxi(steps, 1)))
		for yy in range(int(p.y - w), int(p.y + w) + 1):
			for xx in range(int(p.x - w), int(p.x + w) + 1):
				if xx < 0 or yy < 0 or xx >= img.get_width() or yy >= img.get_height():
					continue
				var cov: float = clampf(w + 0.5 - Vector2(float(xx) - p.x, float(yy) - p.y).length(), 0.0, 1.0)
				if cov > 0.0:
					var old: Color = img.get_pixel(xx, yy)
					var a_out: float = maxf(old.a, cov)
					img.set_pixel(xx, yy, Color(col.r, col.g, col.b, a_out))


# ══════════════════════════════════════════════════════════════════════════════════════════════
#  THEME
# ══════════════════════════════════════════════════════════════════════════════════════════════

static func _build_theme() -> Theme:
	var t := Theme.new()
	t.default_font = font("body_regular")
	t.default_font_size = fs("body")

	_theme_labels(t)
	_theme_buttons(t)
	_theme_panels(t)
	_theme_inputs(t)
	_theme_sliders_and_bars(t)
	_theme_tabs(t)
	_theme_popups(t)
	return t


static func _role_label(t: Theme, variation: String, role: String, tint: Color = Color(0, 0, 0, 0), outline: int = 0) -> void:
	var spec: Array = ROLES[role]
	t.set_type_variation(variation, "Label")
	t.set_font("font", variation, font(spec[0]))
	t.set_font_size("font_size", variation, fs(role))
	t.set_color("font_color", variation, tint if tint.a > 0.0 else color(spec[2]))
	t.set_color("font_outline_color", variation, Color(0.02, 0.015, 0.01, 0.9))
	t.set_constant("outline_size", variation, outline)
	t.set_constant("line_spacing", variation, 2)


static func _theme_labels(t: Theme) -> void:
	# base Label
	t.set_font("font", "Label", font("body_regular"))
	t.set_font_size("font_size", "Label", fs("body"))
	t.set_color("font_color", "Label", BONE)
	t.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.0))
	t.set_color("font_outline_color", "Label", Color(0.02, 0.015, 0.01, 0.9))
	_role_label(t, "GameTitle", "game_title", Color(0, 0, 0, 0), 6)
	_role_label(t, "ScreenTitle", "screen_title", Color(0, 0, 0, 0), 4)
	_role_label(t, "SectionHeading", "section")
	_role_label(t, "CardTitle", "card_title")
	_role_label(t, "SecondaryLabel", "body_secondary")
	_role_label(t, "MetaLabel", "metadata")
	_role_label(t, "HudValue", "hud_value", Color(0, 0, 0, 0), 5)
	_role_label(t, "HudLabel", "hud_label", Color(0, 0, 0, 0), 4)
	_role_label(t, "WarningLabel", "warning")
	_role_label(t, "CaptionLabel", "caption")
	# parchment contexts: same hierarchy, ink colours
	_role_label(t, "ParchmentTitle", "screen_title", INK)
	_role_label(t, "ParchmentHeading", "section", Color("6b3f0f"))
	_role_label(t, "ParchmentCardTitle", "card_title", INK)
	_role_label(t, "ParchmentBody", "body", INK)
	_role_label(t, "ParchmentMeta", "metadata", INK_DIM)
	for v in ["ParchmentTitle", "ParchmentHeading", "ParchmentCardTitle", "ParchmentBody", "ParchmentMeta"]:
		t.set_constant("outline_size", v, 0)
	# rich text
	t.set_font("normal_font", "RichTextLabel", font("body_regular"))
	t.set_font("bold_font", "RichTextLabel", font("body_bold"))
	t.set_font_size("normal_font_size", "RichTextLabel", fs("body"))
	t.set_font_size("bold_font_size", "RichTextLabel", fs("body"))
	t.set_color("default_color", "RichTextLabel", BONE)
	t.set_type_variation("ParchmentRich", "RichTextLabel")
	t.set_color("default_color", "ParchmentRich", INK)
	t.set_font("normal_font", "ParchmentRich", font("body_regular"))
	t.set_font_size("normal_font_size", "ParchmentRich", fs("body"))
	# divider
	t.set_type_variation("BrassDivider", "HSeparator")
	# StyleBoxLine: a flat box with no content size would collapse the separator to 0 px.
	var brass_line := StyleBoxLine.new()
	brass_line.color = EDGE_BRASS
	brass_line.thickness = 2
	t.set_stylebox("separator", "BrassDivider", brass_line)
	t.set_constant("separation", "BrassDivider", 6)
	var iron_line := StyleBoxLine.new()
	iron_line.color = EDGE
	iron_line.thickness = 2
	t.set_stylebox("separator", "HSeparator", iron_line)
	t.set_constant("separation", "HSeparator", 6)


static func _button_styles(t: Theme, type_name: String, fill: Color, edge: Color, fill_hover: Color, edge_hover: Color,
		pressed_fill: Color, pressed_edge: Color, glow: Color, font_key: String, font_role: String, font_col: Color,
		font_hover: Color, font_pressed: Color, margins: Vector2 = Vector2(S5, S3)) -> void:
	var normal := box(fill, edge, fill.darkened(0.14), 0.10, 0.34, 0.016, glow)
	var hover := box(fill_hover, edge_hover, fill_hover.darkened(0.12), 0.14, 0.34, 0.016, glow)
	var pressed := box(pressed_fill, pressed_edge, pressed_fill.darkened(0.2), 0.0, 0.5, 0.016, Color(EMBER.r, EMBER.g, EMBER.b, 0.28))
	var disabled := box(IRON.darkened(0.15), EDGE.darkened(0.35), IRON.darkened(0.25), 0.0, 0.2, 0.02)
	for sb in [normal, hover, pressed, disabled]:
		sb.content_margin_left = margins.x
		sb.content_margin_right = margins.x
		sb.content_margin_top = margins.y
		sb.content_margin_bottom = margins.y
	pressed.content_margin_top = margins.y + 2
	pressed.content_margin_bottom = margins.y - 2   # a small tactile depression
	t.set_stylebox("normal", type_name, normal)
	t.set_stylebox("hover", type_name, hover)
	t.set_stylebox("pressed", type_name, pressed)
	t.set_stylebox("hover_pressed", type_name, pressed)
	t.set_stylebox("disabled", type_name, disabled)
	t.set_stylebox("focus", type_name, _focus_ring())
	t.set_font("font", type_name, font(font_key))
	t.set_font_size("font_size", type_name, fs(font_role))
	t.set_color("font_color", type_name, font_col)
	t.set_color("font_hover_color", type_name, font_hover)
	t.set_color("font_focus_color", type_name, font_hover)
	t.set_color("font_pressed_color", type_name, font_pressed)
	t.set_color("font_hover_pressed_color", type_name, font_pressed)
	t.set_color("font_disabled_color", type_name, BONE_FAINT)
	t.set_color("font_outline_color", type_name, Color(0, 0, 0, 0.5))
	t.set_constant("outline_size", type_name, 0)
	t.set_constant("h_separation", type_name, S3)


static func _theme_buttons(t: Theme) -> void:
	# SECONDARY (the default Button): blackened iron, brass-grey edge, bone label.
	_button_styles(t, "Button", IRON_RAISED, EDGE, IRON_HOVER, EDGE_BRASS, IRON, EMBER_DEEP, Color(0, 0, 0, 0),
		"body_semi", "button", BONE, BONE_BRIGHT, EMBER_BRIGHT)
	# PRIMARY: more weight - brass/ember edge, warm glow rising from the base, display face.
	t.set_type_variation("PrimaryButton", "Button")
	_button_styles(t, "PrimaryButton", IRON_RAISED, EMBER_DEEP, IRON_HOVER, EMBER, IRON, EMBER_BRIGHT,
		Color(EMBER.r, EMBER.g, EMBER.b, 0.20), "display_bold", "button_primary", BONE_BRIGHT, Color.WHITE, EMBER_BRIGHT,
		Vector2(S6, S4))
	# DANGER: restrained blood edge.
	t.set_type_variation("DangerButton", "Button")
	_button_styles(t, "DangerButton", IRON_RAISED, BLOOD, IRON_HOVER, BLOOD_BRIGHT, IRON, BLOOD_BRIGHT, Color(BLOOD.r, BLOOD.g, BLOOD.b, 0.18),
		"body_semi", "button", BONE, BONE_BRIGHT, BLOOD_BRIGHT)
	# NAV (Back / Next / pagers): quieter, same family.
	t.set_type_variation("NavButton", "Button")
	_button_styles(t, "NavButton", IRON, EDGE, IRON_RAISED, EDGE_BRASS, IRON_DEEP, EMBER_DEEP, Color(0, 0, 0, 0),
		"body_semi", "button", BONE_DIM, BONE_BRIGHT, EMBER_BRIGHT, Vector2(S5, S3))
	# SELECTOR (class / difficulty / segmented choices): toggled-on = amber edge + ember tint (not just text colour).
	t.set_type_variation("SelectorButton", "Button")
	_button_styles(t, "SelectorButton", IRON, EDGE, IRON_RAISED, EDGE_BRASS, Color("3a2b19"), EMBER, Color(EMBER.r, EMBER.g, EMBER.b, 0.30),
		"body_semi", "button", BONE_DIM, BONE_BRIGHT, EMBER_BRIGHT, Vector2(S5, S3))
	# the selected look must not "depress" like a click
	var sel := box(Color("3a2b19"), EMBER, Color("2c200f"), 0.12, 0.4, 0.016, Color(EMBER.r, EMBER.g, EMBER.b, 0.30))
	sel.content_margin_left = S5
	sel.content_margin_right = S5
	sel.content_margin_top = S3
	sel.content_margin_bottom = S3
	t.set_stylebox("pressed", "SelectorButton", sel)
	t.set_stylebox("hover_pressed", "SelectorButton", sel)
	# toggles reuse the base box style
	_button_styles(t, "OptionButton", IRON_RAISED, EDGE, IRON_HOVER, EDGE_BRASS, IRON, EMBER_DEEP, Color(0, 0, 0, 0),
		"body_semi", "button", BONE, BONE_BRIGHT, EMBER_BRIGHT)
	t.set_constant("arrow_margin", "OptionButton", S3)
	# LinkButton / MenuButton fall back to body styling
	t.set_font("font", "MenuButton", font("body_semi"))
	t.set_font_size("font_size", "MenuButton", fs("button"))
	t.set_color("font_color", "MenuButton", BONE)
	# check box / check button / radio
	for ty in ["CheckBox", "CheckButton"]:
		t.set_icon("checked", ty, _check_texture(true))
		t.set_icon("unchecked", ty, _check_texture(false))
		t.set_icon("checked_disabled", ty, _check_texture(true, false))
		t.set_icon("unchecked_disabled", ty, _check_texture(false, false))
		t.set_icon("radio_checked", ty, _check_texture(true))
		t.set_icon("radio_unchecked", ty, _check_texture(false))
		t.set_font("font", ty, font("body_regular"))
		t.set_font_size("font_size", ty, fs("body"))
		t.set_color("font_color", ty, BONE)
		t.set_color("font_hover_color", ty, BONE_BRIGHT)
		t.set_color("font_pressed_color", ty, EMBER_BRIGHT)
		t.set_color("font_hover_pressed_color", ty, EMBER_BRIGHT)
		t.set_color("font_focus_color", ty, BONE_BRIGHT)
		t.set_color("font_disabled_color", ty, BONE_FAINT)
		t.set_constant("h_separation", ty, S3)
		for st in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
			t.set_stylebox(st, ty, StyleBoxEmpty.new())
		t.set_stylebox("focus", ty, _focus_ring())


static func _theme_panels(t: Theme) -> void:
	var surface := box(IRON, EDGE, IRON.darkened(0.10), 0.07, 0.30, 0.015)
	var raised := box(IRON_RAISED, EDGE_BRASS.darkened(0.25), IRON_RAISED.darkened(0.10), 0.10, 0.32, 0.016)
	var parch := box(PARCHMENT, PARCHMENT_DK.darkened(0.35), PARCHMENT.darkened(0.08), 0.28, 0.18, 0.04)
	var veil := box(Color(0.06, 0.05, 0.04, 0.72), EDGE.darkened(0.2), Color(0.04, 0.03, 0.03, 0.80), 0.05, 0.25, 0.02)
	var inset := box(IRON_DEEP, EDGE.darkened(0.25), IRON_DEEP.darkened(0.15), 0.0, 0.5, 0.025)
	for pair in [["Panel", surface], ["PanelContainer", surface]]:
		var sb: StyleBoxTexture = pair[1]
		sb.content_margin_left = PANEL_PAD
		sb.content_margin_right = PANEL_PAD
		sb.content_margin_top = PANEL_PAD
		sb.content_margin_bottom = PANEL_PAD
		t.set_stylebox("panel", pair[0], sb.duplicate())
	for pair in [["CardPanel", raised], ["ParchmentPanel", parch], ["VeilPanel", veil], ["InsetPanel", inset]]:
		var sb2: StyleBoxTexture = (pair[1] as StyleBoxTexture).duplicate()
		sb2.content_margin_left = PANEL_PAD
		sb2.content_margin_right = PANEL_PAD
		sb2.content_margin_top = PANEL_PAD
		sb2.content_margin_bottom = PANEL_PAD
		t.set_type_variation(pair[0], "PanelContainer")
		t.set_stylebox("panel", pair[0], sb2)
		# the same names also work on Panel nodes
		t.set_type_variation(pair[0] + "Flat", "Panel")
		t.set_stylebox("panel", pair[0] + "Flat", sb2.duplicate())
	# tooltips
	var tip := box(Color("120f0d"), EDGE_BRASS, Color("0d0b09"), 0.06, 0.3, 0.02)
	tip.content_margin_left = S3
	tip.content_margin_right = S3
	tip.content_margin_top = S2
	tip.content_margin_bottom = S2
	t.set_stylebox("panel", "TooltipPanel", tip)
	t.set_font("font", "TooltipLabel", font("body_regular"))
	t.set_font_size("font_size", "TooltipLabel", fs("body_secondary"))
	t.set_color("font_color", "TooltipLabel", BONE)


static func _theme_inputs(t: Theme) -> void:
	var normal := box(IRON_DEEP, EDGE, IRON_DEEP.darkened(0.12), 0.0, 0.5, 0.025)
	var focus := box(IRON_DEEP, EMBER, IRON_DEEP.darkened(0.12), 0.0, 0.5, 0.025)
	var ro := box(IRON, EDGE.darkened(0.3), IRON.darkened(0.1), 0.0, 0.3, 0.02)
	for sb in [normal, focus, ro]:
		sb.content_margin_left = S4
		sb.content_margin_right = S4
		sb.content_margin_top = S3
		sb.content_margin_bottom = S3
	t.set_stylebox("normal", "LineEdit", normal)
	t.set_stylebox("focus", "LineEdit", focus)
	t.set_stylebox("read_only", "LineEdit", ro)
	t.set_font("font", "LineEdit", font("body_regular"))
	t.set_font_size("font_size", "LineEdit", fs("body"))
	t.set_color("font_color", "LineEdit", BONE)
	t.set_color("font_placeholder_color", "LineEdit", BONE_FAINT)
	t.set_color("caret_color", "LineEdit", EMBER_BRIGHT)
	t.set_color("selection_color", "LineEdit", Color(EMBER.r, EMBER.g, EMBER.b, 0.40))
	t.set_color("font_uneditable_color", "LineEdit", BONE_DIM)
	t.set_constant("caret_width", "LineEdit", 2)
	t.set_stylebox("normal", "TextEdit", normal.duplicate())
	t.set_stylebox("focus", "TextEdit", focus.duplicate())
	t.set_font("font", "TextEdit", font("body_regular"))
	t.set_font_size("font_size", "TextEdit", fs("body"))
	t.set_color("font_color", "TextEdit", BONE)


static func _theme_sliders_and_bars(t: Theme) -> void:
	# HSlider: dark iron track, ember active portion, brass-ringed thumb
	var track := flat(IRON_DEEP, EDGE.darkened(0.2), 1, 4)
	track.content_margin_top = 5
	track.content_margin_bottom = 5
	var fill := flat(EMBER_DEEP, EMBER, 1, 4)
	fill.content_margin_top = 5
	fill.content_margin_bottom = 5
	var fill_hi := flat(EMBER, EMBER_BRIGHT, 1, 4)
	fill_hi.content_margin_top = 5
	fill_hi.content_margin_bottom = 5
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill_hi)
	var thumb := _thumb_texture(32, EDGE_BRASS, BONE)
	var thumb_hi := _thumb_texture(32, EMBER_BRIGHT, BONE_BRIGHT)
	t.set_icon("grabber", "HSlider", thumb)
	t.set_icon("grabber_highlight", "HSlider", thumb_hi)
	t.set_icon("grabber_disabled", "HSlider", _thumb_texture(32, EDGE, BONE_FAINT))
	t.set_constant("center_grabber", "HSlider", 0)
	t.set_constant("grabber_offset", "HSlider", 0)
	# VSlider mirrors it
	var vtrack := flat(IRON_DEEP, EDGE.darkened(0.2), 1, 4)
	vtrack.content_margin_left = 5
	vtrack.content_margin_right = 5
	t.set_stylebox("slider", "VSlider", vtrack)
	t.set_icon("grabber", "VSlider", thumb)
	t.set_icon("grabber_highlight", "VSlider", thumb_hi)
	# scroll bars
	var sc_track := flat(Color(IRON_DEEP.r, IRON_DEEP.g, IRON_DEEP.b, 0.85), Color(0, 0, 0, 0), 0, 5)
	var sc_grab := flat(EDGE_BRASS.darkened(0.15), Color(0, 0, 0, 0), 0, 5)
	var sc_grab_hi := flat(EMBER_DEEP, Color(0, 0, 0, 0), 0, 5)
	var sc_grab_pr := flat(EMBER, Color(0, 0, 0, 0), 0, 5)
	for ty in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", ty, sc_track)
		t.set_stylebox("scroll_focus", ty, sc_track)
		t.set_stylebox("grabber", ty, sc_grab)
		t.set_stylebox("grabber_highlight", ty, sc_grab_hi)
		t.set_stylebox("grabber_pressed", ty, sc_grab_pr)
	sc_track.content_margin_left = 7
	sc_track.content_margin_right = 7
	sc_track.content_margin_top = 7
	sc_track.content_margin_bottom = 7
	# generic progress bar (HUD bars use PUIBar)
	t.set_stylebox("background", "ProgressBar", flat(IRON_DEEP, EDGE, 1, 3))
	t.set_stylebox("fill", "ProgressBar", flat(EMBER, EMBER_BRIGHT, 0, 3))
	t.set_font("font", "ProgressBar", font("body_semi"))
	t.set_font_size("font_size", "ProgressBar", fs("metadata"))
	t.set_color("font_color", "ProgressBar", BONE)


static func _theme_tabs(t: Theme) -> void:
	var sel := box(IRON_RAISED, EMBER, IRON_RAISED.darkened(0.08), 0.12, 0.3, 0.015, Color(EMBER.r, EMBER.g, EMBER.b, 0.22))
	var unsel := box(IRON, EDGE, IRON.darkened(0.1), 0.06, 0.3, 0.015)
	var hov := box(IRON_HOVER, EDGE_BRASS, IRON_HOVER.darkened(0.1), 0.1, 0.3, 0.015)
	for sb in [sel, unsel, hov]:
		sb.content_margin_left = S5
		sb.content_margin_right = S5
		sb.content_margin_top = S3
		sb.content_margin_bottom = S3
	for ty in ["TabContainer", "TabBar"]:
		t.set_stylebox("tab_selected", ty, sel)
		t.set_stylebox("tab_unselected", ty, unsel)
		t.set_stylebox("tab_hovered", ty, hov)
		t.set_stylebox("tab_focus", ty, _focus_ring())
		t.set_stylebox("tab_disabled", ty, unsel)
		t.set_font("font", ty, font("body_semi"))
		t.set_font_size("font_size", ty, fs("button"))
		t.set_color("font_selected_color", ty, EMBER_BRIGHT)
		t.set_color("font_unselected_color", ty, BONE_DIM)
		t.set_color("font_hovered_color", ty, BONE_BRIGHT)
		t.set_color("font_disabled_color", ty, BONE_FAINT)
		t.set_constant("h_separation", ty, S2)
	var pan := box(IRON, EDGE, IRON.darkened(0.08), 0.05, 0.3, 0.015)
	pan.content_margin_left = S4
	pan.content_margin_right = S4
	pan.content_margin_top = S4
	pan.content_margin_bottom = S4
	t.set_stylebox("panel", "TabContainer", pan)


static func _theme_popups(t: Theme) -> void:
	# OptionButton drop-down / context menus
	var pm := box(IRON, EDGE_BRASS, IRON.darkened(0.08), 0.06, 0.3, 0.025)
	pm.content_margin_left = S3
	pm.content_margin_right = S3
	pm.content_margin_top = S2
	pm.content_margin_bottom = S2
	t.set_stylebox("panel", "PopupMenu", pm)
	t.set_stylebox("hover", "PopupMenu", flat(Color(EMBER.r, EMBER.g, EMBER.b, 0.25), EMBER_DEEP, 1, 4))
	t.set_stylebox("separator", "PopupMenu", flat(EDGE, Color(0, 0, 0, 0), 0, 0))
	t.set_font("font", "PopupMenu", font("body_regular"))
	t.set_font_size("font_size", "PopupMenu", fs("body"))
	t.set_color("font_color", "PopupMenu", BONE)
	t.set_color("font_hover_color", "PopupMenu", BONE_BRIGHT)
	t.set_color("font_disabled_color", "PopupMenu", BONE_FAINT)
	t.set_constant("v_separation", "PopupMenu", S3)
	t.set_icon("checked", "PopupMenu", _check_texture(true))
	t.set_icon("unchecked", "PopupMenu", _check_texture(false))
	t.set_icon("radio_checked", "PopupMenu", _check_texture(true))
	t.set_icon("radio_unchecked", "PopupMenu", _check_texture(false))
	# Dialog windows (AcceptDialog / ConfirmationDialog, embedded)
	var wb := box(IRON, EDGE_BRASS, IRON.darkened(0.08), 0.06, 0.35, 0.015)
	wb.content_margin_left = S5
	wb.content_margin_right = S5
	wb.content_margin_top = 56
	wb.content_margin_bottom = S5
	t.set_stylebox("embedded_border", "Window", wb)
	t.set_stylebox("embedded_unfocused_border", "Window", wb)
	t.set_font("title_font", "Window", font("display_semi"))
	t.set_font_size("title_font_size", "Window", fs("section"))
	t.set_color("title_color", "Window", EMBER)
	t.set_constant("title_height", "Window", 40)
	t.set_constant("title_outline_size", "Window", 0)
	t.set_stylebox("panel", "AcceptDialog", box(IRON, EDGE_BRASS, IRON.darkened(0.08), 0.06, 0.35, 0.03))
	# item lists
	t.set_stylebox("panel", "ItemList", box(IRON_DEEP, EDGE, IRON_DEEP.darkened(0.1), 0.0, 0.4, 0.025))
	t.set_stylebox("selected", "ItemList", flat(Color(EMBER.r, EMBER.g, EMBER.b, 0.28), EMBER, 1, 4))
	t.set_stylebox("selected_focus", "ItemList", flat(Color(EMBER.r, EMBER.g, EMBER.b, 0.28), EMBER_BRIGHT, 1, 4))
	t.set_font("font", "ItemList", font("body_regular"))
	t.set_font_size("font_size", "ItemList", fs("body"))
	t.set_color("font_color", "ItemList", BONE)
	t.set_color("font_selected_color", "ItemList", EMBER_BRIGHT)


# ══════════════════════════════════════════════════════════════════════════════════════════════
#  PAPER  (additive block: the Codex page and the Alchemist's ledger)
#  The owner's parchment.jpeg, toned once into a light aged-paper 9-slice with a burnt edge and a dark
#  brass-brown rim, so ink (PUI.INK) reads at >= 10:1 and the sheet sits inside the iron UI like a physical
#  artifact. Controls placed on it stay iron/brass (Button, PrimaryButton, NavButton).
# ══════════════════════════════════════════════════════════════════════════════════════════════

const PAPER_SOURCE := "res://Music & background images/parchment.jpeg"
const PAPER_BASE := Color("e8d8ae")      # light aged paper: INK on it is ~11:1
const PAPER_SLIP := Color("f0e3bf")      # a slip/label pasted on the sheet (a touch lighter)
const PAPER_SLIP_DIM := Color("cfc3a2")  # the same slip when it is unavailable (greyer, darker)
const PAPER_RIM := Color("4a3a24")       # dark brass-brown edge of the sheet


## The paper sheet: PanelContainer with the toned parchment stylebox. `content_pad` = inner margins.
static func paper_panel(content_pad: Vector2 = Vector2(32, 22)) -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "ParchmentPanel"
	var sb: StyleBoxTexture = paper_box()
	sb.content_margin_left = content_pad.x
	sb.content_margin_right = content_pad.x
	sb.content_margin_top = content_pad.y
	sb.content_margin_bottom = content_pad.y
	p.add_theme_stylebox_override("panel", sb)
	return p


## Toned parchment.jpeg as a 9-slice (cached). Falls back to flat paper if the file is missing.
static func paper_box(radius: int = RADIUS) -> StyleBoxTexture:
	var key := "paper|%d" % radius
	if _boxes.has(key):
		return _boxes[key].duplicate()
	var w := 192
	var h := 128
	var burn_w := 22.0
	var src: Image = null
	if ResourceLoader.exists(PAPER_SOURCE):
		var tex := load(PAPER_SOURCE) as Texture2D
		if tex != null:
			src = tex.get_image()
			if src != null:
				if src.is_compressed():
					src.decompress()
				src.resize(w, h, Image.INTERPOLATE_BILINEAR)
	# mean luminance (coarse grid) so the stains are expressed relative to the sheet's own average
	var mean_l: float = 0.78
	if src != null:
		var acc: float = 0.0
		var n: int = 0
		for gy in range(4, h, 8):
			for gx in range(4, w, 8):
				var sc: Color = src.get_pixel(gx, gy)
				acc += 0.299 * sc.r + 0.587 * sc.g + 0.114 * sc.b
				n += 1
		mean_l = acc / float(maxi(n, 1))
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var rim_w := 2.0
	var hw: float = float(w) * 0.5
	var hh: float = float(h) * 0.5
	var burn_col: Color = PARCHMENT_DK.darkened(0.25)
	for y in h:
		for x in w:
			var px: float = absf(float(x) + 0.5 - hw) - (hw - float(radius))
			var py: float = absf(float(y) + 0.5 - hh) - (hh - float(radius))
			var d: float = Vector2(maxf(px, 0.0), maxf(py, 0.0)).length() + minf(maxf(px, py), 0.0) - float(radius)
			var cov: float = clampf(0.5 - d, 0.0, 1.0)
			if cov <= 0.0:
				continue
			var depth: float = -d
			var c: Color
			if depth < rim_w:
				c = PAPER_RIM
			else:
				var k: float = 1.0
				if src != null:
					var sc2: Color = src.get_pixel(x, y)
					k = clampf(1.0 + ((0.299 * sc2.r + 0.587 * sc2.g + 0.114 * sc2.b) - mean_l) * 1.1, 0.90, 1.03)
				# stains darken and warm (blue falls fastest) instead of greying, and never drop below the contrast floor
				c = Color(PAPER_BASE.r * (0.5 + 0.5 * k), PAPER_BASE.g * k, PAPER_BASE.b * k * k, 1.0)
				c.r = clampf(c.r + (_hash(x, y, 11) - 0.5) * 0.02, 0.0, 1.0)
				c.g = clampf(c.g + (_hash(x, y, 11) - 0.5) * 0.02, 0.0, 1.0)
				c.b = clampf(c.b + (_hash(x, y, 11) - 0.5) * 0.02, 0.0, 1.0)
				var burn: float = clampf(1.0 - (depth - rim_w) / burn_w, 0.0, 1.0)
				c = c.lerp(burn_col, pow(burn, 1.8) * 0.55)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, cov))
	var sb := StyleBoxTexture.new()
	sb.texture = ImageTexture.create_from_image(img)
	var m: float = burn_w + rim_w + 2.0
	sb.texture_margin_left = m
	sb.texture_margin_right = m
	sb.texture_margin_top = m
	sb.texture_margin_bottom = m
	sb.content_margin_left = S6
	sb.content_margin_right = S6
	sb.content_margin_top = S5
	sb.content_margin_bottom = S5
	_boxes[key] = sb
	return sb.duplicate()


## A slip of paper on the sheet (an upgrade card, a lore entry). state: "active" (ember edge, warm base),
## "normal" (brown edge), "dim" (unavailable: greyer, darker, muted edge).
static func paper_slip(state: String = "normal") -> StyleBoxTexture:
	match state:
		"active":
			return box(PAPER_SLIP, EMBER, PAPER_SLIP.darkened(0.06), 0.0, 0.10, 0.02, Color(EMBER.r, EMBER.g, EMBER.b, 0.20))
		"dim":
			return box(PAPER_SLIP_DIM, PARCHMENT_DK.darkened(0.25), PAPER_SLIP_DIM.darkened(0.06), 0.0, 0.10, 0.02)
	return box(PAPER_SLIP, PARCHMENT_DK.darkened(0.45), PAPER_SLIP.darkened(0.06), 0.0, 0.10, 0.02)


## Ink colour for text on a dimmed slip (still >= 6:1).
static func ink_muted() -> Color:
	return INK.lerp(INK_DIM, 0.5)


## Draws a PUIIcon chevron inside a button (arrows are not in the Latin font subset). `centered` = in the middle
## (icon-only pager buttons); otherwise at the leading edge (chevron_left) or trailing edge (chevron_right).
static func button_chevron(btn: Button, kind: String, centered: bool = false, px: float = 28.0) -> PUIIcon:
	var tint: Color = BONE_DIM if btn.theme_type_variation == &"NavButton" else BONE_BRIGHT
	var ic := PUIIcon.make(kind, px, tint)
	var half: float = px * 0.5
	if centered:
		ic.set_anchors_preset(Control.PRESET_CENTER)
		ic.offset_left = -half
		ic.offset_right = half
	else:
		var left: bool = kind == "chevron_left"
		ic.anchor_left = 0.0 if left else 1.0
		ic.anchor_right = ic.anchor_left
		ic.anchor_top = 0.5
		ic.anchor_bottom = 0.5
		ic.offset_left = float(S5 - S1) if left else -(float(S5 - S1) + px)
		ic.offset_right = ic.offset_left + px
	ic.offset_top = -half
	ic.offset_bottom = half
	btn.add_child(ic)
	return ic

