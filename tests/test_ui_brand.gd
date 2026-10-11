extends Node
## The Purgatory UI brand is applied and internally consistent: one theme on the root window, every documented
## component variation exists with the documented look, the two bundled font families load, the palette meets its
## documented contrast, and the player-facing UI scripts do not carry stray off-palette colours or the old
## blue/green "software" accents. Runs headless (no rendering needed).

var _fails: int = 0
var _checks: int = 0

# THE TYPE RULE, as data (owner decision): Cinzel = identity (titles, headings, card titles, buttons, tabs, names,
# short labels, numbers); Source Sans 3 = reading (sentences, descriptions, notes, lore, diagnostics, fields).
const CINZEL := "Cinzel"
const SOURCE := "SourceSans3"
const ROLE_FAMILY := {
	"game_title": CINZEL, "screen_title": CINZEL, "section": CINZEL, "card_title": CINZEL, "button": CINZEL,
	"button_primary": CINZEL, "label": CINZEL, "stat": CINZEL, "hud_value": CINZEL, "hud_label": CINZEL,
	"body": SOURCE, "body_secondary": SOURCE, "metadata": SOURCE, "field": SOURCE, "warning": SOURCE, "caption": SOURCE,
}
# Label theme variations -> family (the variations screens actually use).
const LABEL_FAMILY := {
	"GameTitle": CINZEL, "ScreenTitle": CINZEL, "SectionHeading": CINZEL, "CardTitle": CINZEL, "ShortLabel": CINZEL,
	"StatLabel": CINZEL, "DangerTitle": CINZEL, "HudValue": CINZEL, "HudLabel": CINZEL,
	"ParchmentTitle": CINZEL, "ParchmentHeading": CINZEL, "ParchmentCardTitle": CINZEL, "ParchmentLabel": CINZEL, "ParchmentStat": CINZEL,
	"SecondaryLabel": SOURCE, "MetaLabel": SOURCE, "WarningLabel": SOURCE, "CaptionLabel": SOURCE,
	"ParchmentBody": SOURCE, "ParchmentMeta": SOURCE, "Label": SOURCE,
}
# Other theme types -> [font item, family].
const CONTROL_FAMILY := {
	"Button": ["font", CINZEL], "PrimaryButton": ["font", CINZEL], "DangerButton": ["font", CINZEL],
	"NavButton": ["font", CINZEL], "SelectorButton": ["font", CINZEL], "FieldButton": ["font", SOURCE], "MenuButton": ["font", CINZEL],
	"TabContainer": ["font", CINZEL], "TabBar": ["font", CINZEL], "Window": ["title_font", CINZEL],
	"OptionButton": ["font", SOURCE], "CheckBox": ["font", SOURCE], "CheckButton": ["font", SOURCE],
	"LineEdit": ["font", SOURCE], "TextEdit": ["font", SOURCE], "PopupMenu": ["font", SOURCE], "ItemList": ["font", SOURCE],
	"TooltipLabel": ["font", SOURCE], "ProgressBar": ["font", SOURCE],
	"RichTextLabel": ["normal_font", SOURCE], "ParchmentRich": ["normal_font", SOURCE],
}


static func _family_of(f: Font) -> String:
	var fv := f as FontVariation
	if fv == null or fv.base_font == null:
		return "?"
	return (fv.base_font.resource_path.get_file() as String).split("-")[0]

# Variations the design doc promises (type -> names).
const VARIATIONS := {
	"Label": ["GameTitle", "ScreenTitle", "SectionHeading", "CardTitle", "ShortLabel", "StatLabel", "DangerTitle", "SecondaryLabel",
		"MetaLabel", "HudValue", "HudLabel", "WarningLabel", "CaptionLabel", "ParchmentTitle", "ParchmentHeading", "ParchmentCardTitle",
		"ParchmentLabel", "ParchmentStat", "ParchmentBody", "ParchmentMeta"],
	"Button": ["PrimaryButton", "DangerButton", "NavButton", "SelectorButton", "FieldButton"],
	"PanelContainer": ["CardPanel", "ParchmentPanel", "VeilPanel", "InsetPanel"],
	"HSeparator": ["BrassDivider"],
}


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


static func _lum(c: Color) -> float:
	var f := func(v: float) -> float: return v / 12.92 if v <= 0.03928 else pow((v + 0.055) / 1.055, 2.4)
	return 0.2126 * f.call(c.r) + 0.7152 * f.call(c.g) + 0.0722 * f.call(c.b)


static func _contrast(a: Color, b: Color) -> float:
	var la := _lum(a)
	var lb := _lum(b)
	if la < lb:
		var t := la
		la = lb
		lb = t
	return (la + 0.05) / (lb + 0.05)


func _ready() -> void:
	var theme: Theme = get_tree().root.theme
	_check(theme != null and theme == PUI.theme(), "the Purgatory theme is applied to the root window (UiTheme autoload)")

	# --- components exist -------------------------------------------------------------------------------------
	for base in VARIATIONS:
		for v in VARIATIONS[base]:
			_check(theme.get_type_variation_base(v) == base, "variation %s derives from %s" % [v, base])
	for need in [["Button", "normal"], ["Button", "pressed"], ["Button", "hover"], ["Button", "disabled"], ["Button", "focus"],
			["SelectorButton", "pressed"], ["PrimaryButton", "normal"], ["LineEdit", "normal"], ["LineEdit", "focus"],
			["HSlider", "slider"], ["HSlider", "grabber_area"], ["TabContainer", "tab_selected"], ["TabContainer", "tab_unselected"],
			["PanelContainer", "panel"], ["CardPanel", "panel"], ["ParchmentPanel", "panel"], ["VScrollBar", "grabber"]]:
		_check(theme.has_stylebox(need[1], need[0]), "theme has %s/%s" % [need[0], need[1]])
	for need in [["HSlider", "grabber"], ["CheckBox", "checked"], ["CheckBox", "unchecked"], ["CheckButton", "checked"]]:
		_check(theme.has_icon(need[1], need[0]), "theme has icon %s/%s" % [need[0], need[1]])

	# --- state language is not colour-only ---------------------------------------------------------------------
	var n: StyleBoxTexture = theme.get_stylebox("normal", "SelectorButton")
	var p: StyleBoxTexture = theme.get_stylebox("pressed", "SelectorButton")
	_check(n != null and p != null and n.texture != p.texture, "selected selector has a different surface than unselected (not only text colour)")
	_check(theme.get_color("font_pressed_color", "SelectorButton").is_equal_approx(PUI.EMBER_BRIGHT), "selected text uses the ember accent")
	_check(theme.get_stylebox("disabled", "Button") != theme.get_stylebox("normal", "Button"), "disabled buttons look different")
	_check(theme.get_color("font_disabled_color", "Button").is_equal_approx(PUI.BONE_FAINT), "disabled text is dimmed")

	# --- typography ----------------------------------------------------------------------------------------------
	for key in PUI.FONT_PATHS:
		var f: Font = PUI.font(key)
		_check(f != null and f.get_string_size("Purgatory Dungeon", HORIZONTAL_ALIGNMENT_LEFT, -1, 24).x > 20.0, "font '%s' loads and measures text" % key)
	_check((PUI.font("display_bold") as FontVariation).base_font != (PUI.font("body_regular") as FontVariation).base_font, "display and body faces differ")
	var families := {}
	for key in PUI.FONT_PATHS:
		families[(PUI.FONT_PATHS[key] as String).get_file().split("-")[0]] = true
	_check(families.size() == 2, "exactly two font families are used (%s)" % [families.keys()])
	for role in PUI.ROLES:
		_check(PUI.fs(role) >= 14, "type role %s is readable (%d px)" % [role, PUI.fs(role)])
		_check(ROLE_FAMILY.has(role), "type role %s has a decided family" % role)
		_check(_family_of(PUI.font(PUI.ROLES[role][0])) == ROLE_FAMILY.get(role, "?"), "role %s uses %s (uses %s)" % [role, ROLE_FAMILY.get(role, "?"), _family_of(PUI.font(PUI.ROLES[role][0]))])
		# Cinzel's lowercase is small caps: it needs more pixels than the body face to stay legible
		var floor_px: int = PUI.MIN_DISPLAY_SIZE if ROLE_FAMILY.get(role, SOURCE) == CINZEL else PUI.MIN_BODY_SIZE
		_check(PUI.fs(role) >= floor_px, "role %s clears its floor (%d >= %d px)" % [role, PUI.fs(role), floor_px])
	_check(ROLE_FAMILY.size() == PUI.ROLES.size(), "every type role is in the family map")
	for v in LABEL_FAMILY:
		var lf: Font = theme.get_font("font", v)
		_check(_family_of(lf) == LABEL_FAMILY[v], "Label variation %s is %s (is %s)" % [v, LABEL_FAMILY[v], _family_of(lf)])
		_check(theme.get_font_size("font_size", v) > 0, "Label variation %s has a size" % v)
	for ty in CONTROL_FAMILY:
		var spec: Array = CONTROL_FAMILY[ty]
		var cf: Font = theme.get_font(spec[0], ty)
		_check(_family_of(cf) == spec[1], "%s %s is %s (is %s)" % [ty, spec[0], spec[1], _family_of(cf)])
	# the sentences stay readable: warnings, notes and descriptions are never Cinzel
	for v in ["WarningLabel", "MetaLabel", "SecondaryLabel", "CaptionLabel", "ParchmentBody"]:
		_check(_family_of(theme.get_font("font", v)) == SOURCE, "%s (sentence-length text) stays Source Sans" % v)
	# text the player types keeps its case (Cinzel folds lowercase into small caps)
	_check(_family_of(theme.get_font("font", "LineEdit")) == SOURCE, "typed text is Source Sans")
	# glyph guarantee: every font a theme item can use draws the functional symbols through its fallback chain
	for key in PUI.FONT_PATHS:
		_check(PUI.can_render(key, "\u00b7\u2014\u2013\u2026\u00d7\u2191\u2193"), "font '%s' draws the dash, dot, ellipsis, multiplication sign and arrows through its chain" % key)
	for ty in CONTROL_FAMILY:
		var item: String = CONTROL_FAMILY[ty][0]
		var ff: Font = theme.get_font(item, ty)
		_check(ff.has_char(0x2014) and ff.has_char(0x00b7) and ff.has_char(0x2026), "%s font draws the em dash, middle dot and ellipsis" % ty)
	_check(theme.get_font_size("font_size", "SectionHeading") == PUI.fs("section"), "SectionHeading uses the section role size")
	_check(theme.get_color("font_color", "SectionHeading").is_equal_approx(PUI.EMBER), "section headings use the accent, not blue")

	# --- palette contrast (documented numbers) ------------------------------------------------------------
	for surface in [PUI.IRON, PUI.IRON_RAISED, PUI.IRON_DEEP]:
		_check(_contrast(PUI.BONE, surface) >= 11.0, "bone on iron >= 11:1")
		_check(_contrast(PUI.BONE_DIM, surface) >= 5.5, "dim bone on iron >= 5.5:1")
		_check(_contrast(PUI.EMBER_BRIGHT, surface) >= 7.0, "bright ember on iron >= 7:1")
		_check(_contrast(PUI.BLOOD_BRIGHT, surface) >= 4.5, "danger text on iron >= 4.5:1")
	_check(_contrast(PUI.INK, PUI.PARCHMENT) >= 10.0, "ink on parchment >= 10:1")
	_check(_contrast(PUI.INK_DIM, PUI.PARCHMENT) >= 6.0, "dim ink on parchment >= 6:1")
	_check(_contrast(PUI.BONE, PUI.EMBER_DEEP.darkened(0.5)) >= 7.0, "bone stays readable on ember-tinted surfaces")

	# --- no stray accents in the player-facing UI code -----------------------------------------------------------
	# The old look used blue headings/active states and green call-to-actions. Those colours may not come back.
	var offenders := _scan_for_stray_accents()
	_check(offenders.is_empty(), "no blue/green UI accents in player-facing scripts: %s" % [offenders])

	print("test_ui_brand: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


const UI_SCRIPTS := [
	"res://scripts/main_menu.gd", "res://scripts/character_selection.gd", "res://scripts/profile_screen.gd",
	"res://scripts/options_screen.gd", "res://scripts/pause_menu_function.gd", "res://scripts/AlchemistStore.gd",
	"res://scripts/CodexScreen.gd", "res://scripts/virtual_keyboard.gd", "res://scripts/loading_screen.gd",
	"res://scripts/run_end_screen.gd", "res://scripts/you_died_screen.gd", "res://scripts/trap_banner_hud.gd",
	"res://autoloads/PlayerWallet.gd", "res://autoloads/GameClock.gd",
]


## Looks for Color(...) literals that are clearly blue-ish or green-ish accents (not in PUI). Returns "file:line" strings.
func _scan_for_stray_accents() -> Array:
	var out: Array = []
	var rx := RegEx.new()
	rx.compile("Color\\(\\s*([0-9.]+)\\s*,\\s*([0-9.]+)\\s*,\\s*([0-9.]+)")
	for path in UI_SCRIPTS:
		if not FileAccess.file_exists(path):
			continue
		var lines := FileAccess.get_file_as_string(path).split("\n")
		for i in lines.size():
			var line: String = lines[i]
			if line.strip_edges().begins_with("#"):
				continue
			for m in rx.search_all(line):
				var r := float(m.get_string(1))
				var g := float(m.get_string(2))
				var b := float(m.get_string(3))
				var is_blue: bool = b > 0.55 and b > r + 0.2 and b >= g
				var is_green: bool = g > 0.55 and g > r + 0.2 and g > b + 0.15
				if is_blue or is_green:
					out.append("%s:%d" % [path.get_file(), i + 1])
	return out
