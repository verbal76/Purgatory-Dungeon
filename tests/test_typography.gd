extends Node
## Typography guarantees (docs/UI_DESIGN_SYSTEM.md section 2, docs/TYPOGRAPHY_AUDIT.md):
##   1. GLYPHS: every character of every user-visible string the game ships can be drawn by every UI font
##      INCLUDING its fallback chain (Cinzel -> Source Sans 3 -> engine font). Functional symbols such as the em dash,
##      the middle dot, the ellipsis and the multiplication sign never show a missing-glyph box. Strings come from a
##      conservative scan of the UI scripts, scenes and data files, plus fixed role samples.
##   2. CHAIN: the fallback chain is explicit and built the way the design system documents it.
##   3. SIZES: every Cinzel role stays at or above the legible floor at desktop AND phone scale.
##   4. FIT: with the real screens laid out at the desktop (1920x1080) or phone (1602x720 canvas) shape, no label or
##      button is trimmed, clipped by its panel or pushed off screen, and the HUD plates are wide enough for their text.
## Runs headless. The layout half follows the platform it runs on (desktop, or phone with PURGATORY_FORCE_TOUCH=1).

var _fails: int = 0
var _checks: int = 0
var _strings: int = 0

const SCAN_DIRS := ["res://scripts", "res://autoloads", "res://scenes"]
const SCAN_SKIP := ["res://scripts/ota"]   # updater internals are never shown in the UI
const FONT_KEYS := ["display_black", "display_bold", "display_semi", "body_regular", "body_semi", "body_bold"]

# Functional symbols the UI is allowed to use. Each one must render in every font through the chain.
const FUNCTIONAL := "·—–…×↑↓•’“”%+/:()[]-'\"&!?,.;#*=<>@"
# Symbols NO bundled font draws: they may not appear in any shipped string (draw an icon instead, see PUIIcon).
const FORBIDDEN := "→←✓✔✕⚠☰Ⓐ"

# Samples per role: the shortest and the widest strings the role really carries.
const ROLE_SAMPLES := {
	"game_title": ["Purgatory", "YOU DIED"],
	"screen_title": ["Options", "Choose Your Fate", "Day 30 — an exit has appeared in the depths"],
	"section": ["Volume", "Developer toggles"],
	"card_title": ["Barbarian", "Potent Curse Sensed", "Vitality Surge (+25)"],
	"button": ["Back", "Reset Controls to Default", "Stay Below — Legendary Mode"],
	"button_primary": ["Start Run", "Trade 1 Potion"],
	"label": ["Master Volume", "Level 3"],
	"stat": ["Runs 12", "Barbarian  ·  Slot 3", "1 / 2"],
	"hud_value": ["142 / 150", "Kills: 27", "Day 12 / 30", "100%", "Reversed controls", "30s", "[E] Use Bronze Key"],
	"hud_label": ["Potions", "Rapid attack  3.2s", "Berserk — 1:14"],
	"body": ["Dome Radius +10%", "A voice inside your skull whispers…"],
	"body_secondary": ["Press E to stop", "50% is easier, 100% is normal."],
	"metadata": ["Purgatory Dungeon · development build after v5", "Slot 3  ·  tap to create a character"],
	"field": ["Borderless Fullscreen", "1920 x 1080  (Desktop)", "Pad Btn 12"],
	"warning": ["Enter a name first!", "Locked — come back with a Bronze Key"],
	"caption": ["A ticked box keeps the feature in the run."],
}


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	_test_chain()
	_test_ascii_and_functional()
	_test_role_samples()
	_test_scanned_strings()
	_test_data_strings()
	_test_sizes()
	await _test_fit()
	print("test_typography: %d checks (%d strings scanned), %d failures" % [_checks, _strings, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


# ── 2. the explicit fallback chain ──────────────────────────────────────────────────────────────────────────────────
func _test_chain() -> void:
	for key in FONT_KEYS:
		var fv := PUI.font(key) as FontVariation
		_check(fv != null and fv.base_font != null, "font '%s' is a FontVariation over a bundled face" % key)
		var chain: Array = fv.fallbacks
		if (key as String).begins_with("display"):
			_check(chain.size() == 2, "display font '%s' falls back to the body face, then the engine font" % key)
			var expect_body: String = PUI.DISPLAY_FALLBACK[key]
			_check(chain.size() >= 1 and chain[0] == PUI.font(expect_body), "display font '%s' falls back to '%s' (same weight)" % [key, expect_body])
		else:
			_check(chain.size() == 1, "body font '%s' falls back to the engine font only" % key)
		_check(chain.size() >= 1 and chain[chain.size() - 1] == ThemeDB.fallback_font, "'%s' ends its chain in the engine font" % key)
	# The base faces are what the design system says they are: Cinzel is NOT enough on its own for ASCII + symbols.
	var cinzel_base: Font = (PUI.font("display_semi") as FontVariation).base_font
	_check(not cinzel_base.has_char(0x2191), "(documents the gap) Cinzel's subset itself lacks the up arrow; the chain supplies it")
	_check(PUI.font("display_semi").has_char(0x2191), "the up arrow is drawn through the chain")


# ── 1a. ASCII and functional symbols ─────────────────────────────────────────────────────────────────────────────────
func _test_ascii_and_functional() -> void:
	var ascii := ""
	for code in range(33, 127):
		ascii += String.chr(code)
	for key in FONT_KEYS:
		_check(PUI.can_render(key, ascii), "'%s' draws all printable ASCII (missing: '%s')" % [key, PUI.missing_glyphs(key, ascii)])
		_check(PUI.can_render(key, FUNCTIONAL), "'%s' draws every functional symbol (missing: '%s')" % [key, PUI.missing_glyphs(key, FUNCTIONAL)])
		var gap: String = PUI.missing_glyphs(key, FORBIDDEN)
		_check(gap.length() == FORBIDDEN.length(), "(documents the gap) '%s' cannot draw %s - they must never be used as text" % [key, FORBIDDEN])
	_check(PUI.missing_glyphs("display_semi", "A → B\n").length() == 1, "missing_glyphs reports the arrow only (spaces and newlines are fine)")


# ── 1b. fixed samples per role ──────────────────────────────────────────────────────────────────────────────────────
func _test_role_samples() -> void:
	for role in ROLE_SAMPLES:
		var key: String = PUI.ROLES[role][0]
		for s in ROLE_SAMPLES[role]:
			_check(PUI.can_render(key, s), "role %s (%s) draws '%s' (missing '%s')" % [role, key, s, PUI.missing_glyphs(key, s)])
	_check(ROLE_SAMPLES.size() == PUI.ROLES.size(), "every type role has samples (%d of %d)" % [ROLE_SAMPLES.size(), PUI.ROLES.size()])


# ── 1c. every string literal in the UI code and scenes ────────────────────────────────────────────────────────────────
var _literal_rx: RegEx = null
var _unicode_rx: RegEx = null
var _seen_non_ascii: Dictionary = {}


func _test_scanned_strings() -> void:
	_literal_rx = RegEx.new()
	_literal_rx.compile("\"((?:[^\"\\\\]|\\\\.)*)\"")
	_unicode_rx = RegEx.new()
	_unicode_rx.compile("\\\\u([0-9a-fA-F]{4})")
	var files: Array = []
	for d in SCAN_DIRS:
		_collect(d, files)
	_check(files.size() > 40, "the scan found the UI scripts and scenes (%d files)" % files.size())
	for path in files:
		var is_scene: bool = (path as String).ends_with(".tscn")
		var text: String = FileAccess.get_file_as_string(path)
		if is_scene:
			_scan_text(path, text, 0)
		else:
			var lines: PackedStringArray = text.split("\n")
			for i in lines.size():
				var line: String = _strip_comment(lines[i])
				var t: String = line.strip_edges()
				if t == "" or t.begins_with("print") or t.begins_with("push_") or t.begins_with("assert") or t.begins_with("##"):
					continue
				_scan_text(path, line, i + 1)
	_check(_strings > 200, "the scan read a meaningful number of string literals (%d)" % _strings)
	# the dash / dot / ellipsis really are in use (so the check above is not vacuous)
	_check(_seen_non_ascii.has(0x2014) and _seen_non_ascii.has(0x00b7), "the scan saw the em dash and the middle dot (%s)" % [_seen_non_ascii.keys()])
	print("typography: non-ASCII characters in shipped UI strings: ", _describe(_seen_non_ascii))


func _describe(d: Dictionary) -> String:
	var out: PackedStringArray = []
	for code in d:
		out.append("U+%04X %s" % [code, String.chr(code)])
	return ", ".join(out)


func _collect(dir_path: String, out: Array) -> void:
	if dir_path in SCAN_SKIP:
		return
	for f in DirAccess.get_files_at(dir_path):
		if f.ends_with(".gd") or f.ends_with(".tscn"):
			out.append(dir_path + "/" + f)
	for d in DirAccess.get_directories_at(dir_path):
		_collect(dir_path + "/" + d, out)


## Removes a trailing `# comment` that is not inside a string literal.
func _strip_comment(line: String) -> String:
	var in_str: bool = false
	var i: int = 0
	while i < line.length():
		var c: String = line[i]
		if in_str:
			if c == "\\":
				i += 1
			elif c == "\"":
				in_str = false
		else:
			if c == "\"":
				in_str = true
			elif c == "#":
				return line.substr(0, i)
		i += 1
	return line


## Checks every string literal of `text` (a line, or a whole scene file when `line_no` is 0).
func _scan_text(path: String, text: String, line_no: int) -> void:
	for m in _literal_rx.search_all(text):
		var raw: String = m.get_string(1)
		var s: String = _decode(raw)
		_strings += 1
		var has_non_ascii: bool = false
		for i in s.length():
			var code: int = s.unicode_at(i)
			if code > 126:
				has_non_ascii = true
				_seen_non_ascii[code] = true
		if not has_non_ascii:
			continue   # printable ASCII is proven renderable in _test_ascii_and_functional
		for key in FONT_KEYS:
			var gap: String = PUI.missing_glyphs(key, s)
			_check(gap == "", "%s:%d '%s' would show a missing-glyph box for '%s' in font %s" % [path, line_no, s.left(60), gap, key])
		_check(not _has_forbidden(s), "%s:%d '%s' uses a symbol no bundled font has (use an icon)" % [path, line_no, s.left(60)])


func _has_forbidden(s: String) -> bool:
	for i in FORBIDDEN.length():
		if s.contains(FORBIDDEN[i]):
			return true
	return false


## Decodes \uXXXX and the common escapes so a literal is checked as the player will see it.
func _decode(raw: String) -> String:
	var s: String = raw
	for m in _unicode_rx.search_all(raw):
		s = s.replace(m.get_string(0), String.chr(("0x" + m.get_string(1)).hex_to_int()))
	return s.replace("\\n", "\n").replace("\\t", "\t").replace("\\\"", "\"").replace("\\\\", "\\")


# ── 1d. data files that are displayed ────────────────────────────────────────────────────────────────────────────────
func _test_data_strings() -> void:
	var shown := 0
	for path in ["res://data/buffs.json", "res://data/globe_effects.json"]:
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		_check(parsed is Array, "%s parses" % path)
		if parsed is Array:
			for entry in parsed:
				shown += _check_json_strings(path, entry)
	_check(shown > 100, "the data scan found the buff / globe strings (%d)" % shown)
	var lore: PackedStringArray = FileAccess.get_file_as_string("res://data/codex_lore.txt").split("\n")
	var entries := 0
	for line in lore:
		if line.strip_edges() == "" or line.begins_with("#"):
			continue
		entries += 1
		for key in FONT_KEYS:
			_check(PUI.can_render(key, line), "codex lore line %d draws in %s (missing '%s')" % [entries, key, PUI.missing_glyphs(key, line)])
	_check(entries >= 10, "the codex has entries (%d)" % entries)


func _check_json_strings(path: String, v) -> int:
	var n := 0
	if v is Dictionary:
		for k in v:
			if (k as String).begins_with("_"):
				continue   # "_comment" lines are authoring notes, never displayed
			n += _check_json_strings(path, v[k])
	elif v is Array:
		for item in v:
			n += _check_json_strings(path, item)
	elif v is String:
		n += 1
		for key in FONT_KEYS:
			if not PUI.can_render(key, v):
				_check(false, "%s string '%s' has glyphs %s cannot draw ('%s')" % [path, (v as String).left(50), key, PUI.missing_glyphs(key, v)])
				break
		_check(not _has_forbidden(v), "%s string '%s' uses a symbol no bundled font has" % [path, (v as String).left(50)])
	return n


# ── 3. sizes ────────────────────────────────────────────────────────────────────────────────────────────────────────
func _test_sizes() -> void:
	for role in PUI.ROLES:
		var spec: Array = PUI.ROLES[role]
		var display: bool = (spec[0] as String).begins_with("display")
		var base: float = float(spec[1])
		for scale_name in ["desktop", "phone"]:
			var px: int = int(round(base * (PUI.TYPE_SCALE_DESKTOP if scale_name == "desktop" else 1.0)))
			if display:
				_check(px >= PUI.MIN_DISPLAY_SIZE, "Cinzel role %s is legible on %s (%d px >= %d)" % [role, scale_name, px, PUI.MIN_DISPLAY_SIZE])
				if scale_name == "phone":
					_check(px >= 20, "Cinzel role %s is at least 20 px on phones (%d)" % [role, px])
			else:
				_check(px >= PUI.MIN_BODY_SIZE, "Source Sans role %s is legible on %s (%d px >= %d)" % [role, scale_name, px, PUI.MIN_BODY_SIZE])
	# Cinzel's lowercase is small caps: the smallest Cinzel role must clear the rule even before any phone minimum.
	_check(PUI.MIN_DISPLAY_SIZE >= 16, "the Cinzel floor is at least 16 px")


# ── 4. fit: real screens, real layout ──────────────────────────────────────────────────────────────────────────────────
const SCREENS: Array[String] = [
	"res://scenes/MainMenu.tscn",
	"res://scenes/CharacterSelection.tscn",
	"res://scenes/ProfileScreen.tscn",
	"res://scenes/OptionsScreen.tscn",
	"res://scenes/CodexScreen.tscn",
	"res://scenes/AlchemistStore.tscn",
	"res://scenes/VirtualKeyboard.tscn",
	"res://scenes/pause_menu_function.tscn",
]


func _test_fit() -> void:
	var touch: bool = TouchControls.is_touch_platform()
	var win := get_window()
	if touch:
		win.content_scale_size = Vector2i(1280, 720)
		win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
		win.size = Vector2i(1496, 672)
	else:
		win.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
		win.size = Vector2i(1920, 1080)
	for i in 5:
		await get_tree().process_frame
	var view: Rect2 = get_viewport().get_visible_rect()
	print("typography: layout audit on a %s canvas %s" % ["phone" if touch else "desktop", view.size])
	# a realistic roster: a long (but legal) name and a short one
	SaveManager.load_slot(0)
	SaveManager.create_initial_identity("Wilhelmina Longname", "mage")
	SaveManager.load_slot(1)
	SaveManager.create_initial_identity("Bob", "barbarian")
	SaveManager.load_slot(0)
	for path in SCREENS:
		var inst := (load(path) as PackedScene).instantiate()
		add_child(inst)
		for i in 12:
			await get_tree().process_frame
		if path.ends_with("pause_menu_function.tscn") and inst.has_method("open_menu"):
			inst.call("open_menu")
			for i in 4:
				await get_tree().process_frame
		if path.ends_with("VirtualKeyboard.tscn") and inst.has_method("open_with_text"):
			inst.call("open_with_text", "WWWWWWWWWWWWWWWWWWWW")   # the keyboard is built hidden; open it
			for i in 4:
				await get_tree().process_frame
		_audit_fit(inst, path, view)
		if path.ends_with("OptionsScreen.tscn"):
			var tabs := inst.find_children("*", "TabContainer", true, false)
			if tabs.size() == 1:
				var tc := tabs[0] as TabContainer
				for t in tc.get_tab_count():
					tc.current_tab = t
					for i in 4:
						await get_tree().process_frame
					_audit_fit(inst, "%s [tab %s]" % [path, tc.get_tab_title(t)], view)
					if tc.get_tab_title(t) == "Controls":
						var fields := 0
						for b in inst.find_children("*", "Button", true, false):
							if b.get_class() == "Button" and (b as Button).theme_type_variation == &"FieldButton":
								fields += 1
						_check(fields >= 20, "key-binding values are body-face FieldButtons, never Cinzel (%d found)" % fields)
		inst.queue_free()
		await get_tree().process_frame
	await _audit_hud(view)


func _audit_fit(root: Node, label: String, view: Rect2) -> void:
	var seen := 0
	for n in _controls(root):
		var c := n as Control
		if not c.is_visible_in_tree():
			continue
		var r: Rect2 = c.get_global_rect()
		if c is Label and (c as Label).text.strip_edges() != "":
			var lbl := c as Label
			seen += 1
			var font: Font = lbl.get_theme_font("font")
			var fsz: int = lbl.get_theme_font_size("font_size")
			if lbl.autowrap_mode == TextServer.AUTOWRAP_OFF:
				var w: float = _widest_line(font, lbl.text, fsz)
				_check(w <= r.size.x + 1.5, "%s: label '%s' (%s) is not trimmed (text %.0f px in %.0f px)" % [label, lbl.name, lbl.text.left(30), w, r.size.x])
			_check(_inside_scroll_or_view(c, r, view), "%s: label '%s' (%s) stays on screen (%s in %s)" % [label, lbl.name, lbl.text.left(30), r, view])
		elif c is Button and (c as Button).text.strip_edges() != "":
			var b := c as Button
			seen += 1
			var bfont: Font = b.get_theme_font("font")
			var bsz: int = b.get_theme_font_size("font_size")
			var sb: StyleBox = b.get_theme_stylebox("normal")
			var margins: float = (sb.get_margin(SIDE_LEFT) + sb.get_margin(SIDE_RIGHT)) if sb != null else 0.0
			var tw: float = _widest_line(bfont, b.text, bsz)
			_check(tw + margins <= r.size.x + 1.5, "%s: button '%s' (%s) fits its text (%.0f + %.0f margins in %.0f px)" % [label, b.name, b.text.left(30), tw, margins, r.size.x])
			_check(_inside_scroll_or_view(c, r, view), "%s: button '%s' (%s) stays on screen (%s in %s)" % [label, b.name, b.text.left(30), r, view])
		elif c is TabContainer:
			var tc := c as TabContainer
			var bar: TabBar = tc.get_tab_bar()
			var bw: float = 0.0
			for t in tc.get_tab_count():
				bw += bar.get_tab_rect(t).size.x
			_check(bw <= tc.get_global_rect().size.x + 1.5, "%s: the %d tab labels fit one row (%.0f px in %.0f px)" % [label, tc.get_tab_count(), bw, tc.get_global_rect().size.x])
			_check(not bar.scrolling_enabled or bar.get_offset_buttons_visible() == false, "%s: no tab-scroll arrows are needed" % label)
	_check(seen > 0, "%s has text to audit" % label)


## A control must lie on screen. Controls inside a vertical scroll area only need to fit horizontally.
func _inside_scroll_or_view(c: Control, r: Rect2, view: Rect2) -> bool:
	var p: Node = c.get_parent()
	while p != null:
		if p is ScrollContainer:
			return r.position.x >= view.position.x - 2.0 and r.end.x <= view.end.x + 2.0
		p = p.get_parent()
	return view.grow(2.0).encloses(r)


func _widest_line(font: Font, text: String, size: int) -> float:
	var w: float = 0.0
	for line in text.split("\n"):
		w = maxf(w, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x)
	return w


func _controls(n: Node) -> Array:
	var out: Array = []
	for c in n.get_children():
		if c is Control:
			out.append(c)
		out.append_array(_controls(c))
	return out


# The HUD plates and rows are sized to their text. The widest strings the HUD really shows (Cinzel is wider than the
# old body face) must fit the boxes that were reserved for them.
func _audit_hud(_view: Rect2) -> void:
	var vitals := HudVitals.new()
	add_child(vitals)
	await get_tree().process_frame
	var f: Font = vitals.health_label.get_theme_font("font")
	var fs: int = vitals.health_label.get_theme_font_size("font_size")
	var need: float = f.get_string_size("1000 / 1000", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	_check(vitals.health_label.custom_minimum_size.x >= need - 0.5, "the health read-out box fits '1000 / 1000' (%.0f px box, %.0f px text)" % [vitals.health_label.custom_minimum_size.x, need])
	var ability_need: float = 0.0
	var af: Font = vitals.ability_label.get_theme_font("font")
	var asz: int = vitals.ability_label.get_theme_font_size("font_size")
	for s in ["Charging...", "Release!", "Rapid attack  10.0s", "Cooldown  120s"]:
		ability_need = maxf(ability_need, af.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, asz).x)
	_check(HudKit.BAR_W + ability_need + float(PUI.S3) < 700.0, "the ability caption fits beside the bar (%.0f px)" % ability_need)
	# the heading plate: widest compass letter plus the plate margins must fit COMPASS_W
	var hf: Font = PUI.font("display_bold")
	var hsz: int = PUI.fs("hud_value")
	var plate: StyleBoxTexture = HudKit.plate_style()
	var widest: float = 0.0
	for letter in ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]:
		widest = maxf(widest, hf.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, hsz).x)
	_check(widest + plate.content_margin_left + plate.content_margin_right <= HudKit.COMPASS_W + 0.5,
		"the heading plate fits the widest heading (%.0f + margins in %.0f px)" % [widest, HudKit.COMPASS_W])
	vitals.queue_free()
