extends Node
## The Purgatory UI brand is applied and internally consistent: one theme on the root window, every documented
## component variation exists with the documented look, the two bundled font families load, the palette meets its
## documented contrast, and the player-facing UI scripts do not carry stray off-palette colours or the old
## blue/green "software" accents. Runs headless (no rendering needed).

var _fails: int = 0
var _checks: int = 0

# Variations the design doc promises (type -> names).
const VARIATIONS := {
	"Label": ["GameTitle", "ScreenTitle", "SectionHeading", "CardTitle", "SecondaryLabel", "MetaLabel", "HudValue", "HudLabel",
		"WarningLabel", "CaptionLabel", "ParchmentTitle", "ParchmentHeading", "ParchmentCardTitle", "ParchmentBody", "ParchmentMeta"],
	"Button": ["PrimaryButton", "DangerButton", "NavButton", "SelectorButton"],
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
