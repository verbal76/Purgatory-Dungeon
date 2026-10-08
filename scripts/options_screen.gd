# ==============================================================================
# File Name: options_screen.gd
# Path: res://scripts/options_screen.gd
# Description: Fully code-built options screen.
#              Clears any .tscn content in _ready() and builds all UI from
#              scratch so node names and layout are never ambiguous.
#              Tabbed layout: Sound | Video | Gameplay | Accessibility | (Controls, desktop only) | About
#              All settings read from and written to SettingsManager.
#
#  ADJUSTABLE SETTINGS:
#    main_menu_scene — fallback return path when Back is pressed
#
#  NAVIGATION:
#    OptionsScreen._return_scene (static var) is set by callers before
#    navigating here. Pause menu sets it to the dungeon scene path.
#    Main menu leaves it empty — Back falls back to main_menu_scene.
#
#  MOD NOTES:
#  - L1/R1 (ui_focus_prev/next) cycle tabs on gamepad.
#  - Escape / ui_cancel fires Back.
# ==============================================================================
extends Control

@export var main_menu_scene : String = "res://scenes/MainMenu.tscn"

# Set by the caller before changing scene here.  Cleared when Back fires.
static var _return_scene : String = ""

# When true the screen is an overlay inside a running scene (e.g. opened from the
# in-game pause menu). Back then emits `closed` and frees itself instead of changing
# scene, so the active run is left untouched. Set before adding to the tree.
var embedded : bool = false
signal closed

# ── Built nodes ────────────────────────────────────────────────────────────────
var _tab_container : TabContainer = null
var _back_btn      : Button       = null
var _suppress      : bool         = false
var _margin        : MarginContainer = null

# widest the settings column grows (px) - rows read badly when stretched across a big monitor
const MAX_COLUMN_W : int = 1180

# ── Controls-tab remapping state ───────────────────────────────────────────────
var _listening_action : String = ""   # action name currently being rebound
var _listening_type   : String = ""   # "keyboard" or "gamepad"
var _listening_btn    : Button = null # the button showing "Press key…"
var _controls_tab_vb  : VBoxContainer = null

const REMAPPABLE_ACTIONS : Array = [
	{"name": "move_forward",  "label": "Move Forward"},
	{"name": "move_back",     "label": "Move Back"},
	{"name": "move_left",     "label": "Strafe Left"},
	{"name": "move_right",    "label": "Strafe Right"},
	{"name": "jump",          "label": "Repulse"},
	{"name": "attack",        "label": "Attack"},
	{"name": "kick",          "label": "Kick / Shove"},
	{"name": "AOE",           "label": "AOE Blast"},
	{"name": "block",         "label": "Block (hold)"},
	{"name": "toggle_walk",   "label": "Walk Toggle"},
	{"name": "minimap",       "label": "Minimap"},
	{"name": "equip",         "label": "Equip / Use"},
]

# Populated as controls are built — used by _load_settings().
var _sliders    : Dictionary = {}   # key → HSlider
var _checkboxes : Dictionary = {}   # key → CheckBox
var _val_labels : Dictionary = {}   # key → value display Label

# Gameplay tab: touch control scheme selector (phones only)
var _scheme_buttons : Dictionary = {}   # "twin"/"classic" -> Button (a ButtonGroup of selector buttons)
var _scheme_hint    : Label = null

# About tab (see scripts/about_info.gd): the status model is pure; this screen only draws it.
var about_provider : Node = null   # test hook: stands in for the Boot autoload (same methods); null = the real one
var _about_values   : Dictionary = {}   # row key -> value Label
var _about_status   : Label = null
var _about_detail   : Label = null
var _about_check    : Button = null
var _about_copy     : Button = null
var _about_copied   : Label = null
var _about_checking : bool = false
var _about_dev_box  : VBoxContainer = null
var _about_taps     : int = 0
var _about_last_tap : int = -1

# Video tab
var _display_option  : OptionButton    = null
var _res_option      : OptionButton    = null
var _resolution_list : Array[Vector2i] = []


# ══════════════════════════════════════════════════════════════════════════════
#  BOOT
# ══════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	# The dungeon captures the mouse; make sure menus are clickable after leaving it.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Controls directly under a CanvasLayer (the pause overlay) do not inherit the root window's theme.
	if get_parent() is CanvasLayer:
		theme = PUI.theme()
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_build_ui()
	_load_settings()
	if _back_btn:
		_back_btn.call_deferred("grab_focus")
	_wire_button_clicks()


func _wire_button_clicks() -> void:
	if has_node("/root/AudioManager"):
		AudioManager.wire_click_sounds(self)


func _input(event: InputEvent) -> void:
	# While waiting for a rebind, swallow all input here.
	if _listening_action != "":
		_handle_listen_input(event)
		return

	if _tab_container == null: return
	var n : int = _tab_container.get_tab_count()
	if event.is_action_pressed("ui_focus_next"):
		_tab_container.current_tab = (_tab_container.current_tab + 1) % n
	elif event.is_action_pressed("ui_focus_prev"):
		_tab_container.current_tab = (_tab_container.current_tab - 1 + n) % n
	elif event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_go_back()


# ══════════════════════════════════════════════════════════════════════════════
#  UI CONSTRUCTION
# ══════════════════════════════════════════════════════════════════════════════

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var touch := TouchControls.is_touch_platform()

	# System screen: near-black void with a faint warm vignette. Over a paused run: the veil, so the
	# dungeon stays faintly visible behind the iron surface.
	add_child(PUI.background("veil" if embedded else "void"))

	_margin = MarginContainer.new()
	_margin.name = "Margin"
	_margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_margin)
	resized.connect(_fit_margins)

	var outer := VBoxContainer.new()
	outer.name = "VBox"
	outer.add_theme_constant_override("separation", PUI.S3 if touch else PUI.S4)
	_margin.add_child(outer)

	var title := PUI.label("Options", "ScreenTitle")
	title.name = "Title"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	outer.add_child(title)

	_tab_container = TabContainer.new()
	_tab_container.name = "TabContainer"
	_tab_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(_tab_container)

	_build_sound_tab()
	_build_video_tab()
	_build_gameplay_tab()
	_build_accessibility_tab()
	if not touch:
		_build_controls_tab()   # key/button remapping means nothing on a phone (touch layout: Gameplay tab)
	_build_about_tab()          # always the last tab (5th on a phone, where there is no Controls tab)

	_back_btn = PUI.button("Back", "nav")
	_back_btn.name = "BackButton"
	_back_btn.custom_minimum_size.x = 200.0
	_back_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_back_btn.pressed.connect(_go_back)
	outer.add_child(_back_btn)
	_fit_margins()


# The column is capped at ~1180 px so slider rows never stretch across a 1920 px monitor; on a phone the
# margins stay tight because the canvas is only 720 high.
func _fit_margins() -> void:
	if _margin == null:
		return
	var touch := TouchControls.is_touch_platform()
	var v : int = PUI.S5 if touch else PUI.S6
	var h : int = maxi(PUI.S5 if touch else PUI.SCREEN_MARGIN, int((size.x - MAX_COLUMN_W) * 0.5))
	_margin.add_theme_constant_override("margin_left", h)
	_margin.add_theme_constant_override("margin_right", h)
	_margin.add_theme_constant_override("margin_top", v)
	_margin.add_theme_constant_override("margin_bottom", v)


# ── Shared builders ────────────────────────────────────────────────────────────

func _new_tab(tab_name: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = tab_name
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	_tab_container.add_child(scroll)
	_tab_container.set_tab_title(_tab_container.get_tab_count() - 1, tab_name)
	# a wider scroll bar is a usable one under a thumb
	scroll.get_v_scroll_bar().custom_minimum_size.x = 22.0 if TouchControls.is_touch_platform() else 14.0
	var m := MarginContainer.new()
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.add_theme_constant_override("margin_left",  PUI.S2)
	m.add_theme_constant_override("margin_right", PUI.S4)
	m.add_theme_constant_override("margin_top",   PUI.S2)
	m.add_theme_constant_override("margin_bottom", PUI.S2)
	scroll.add_child(m)
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", PUI.S3)
	m.add_child(vb)
	return vb


func _section(parent: VBoxContainer, text: String, note: String = "") -> void:
	SettingsRows.section(parent, text, note)


func _row(parent: VBoxContainer, label_text: String, note: String = "") -> HBoxContainer:
	return SettingsRows.row(parent, label_text, note)


func _slider(parent: VBoxContainer, row_label: String, key: String,
		lo: float, hi: float, step: float) -> HSlider:
	var row := _row(parent, row_label)
	var sl  := HSlider.new()
	sl.min_value = lo; sl.max_value = hi; sl.step = step
	SettingsRows.prepare_slider(sl)
	row.add_child(sl)
	var vl := SettingsRows.value_label()
	row.add_child(vl)
	_sliders[key]    = sl
	_val_labels[key] = vl
	sl.value_changed.connect(func(v: float) -> void:
		vl.text = "%.0f%%" % v
		if _suppress: return
		SettingsManager.update_setting(key, v)
		# Accessibility: the lighting manager re-reads the setting and applies it live (no polling).
		if key == "AmbientBrightness":
			get_tree().call_group("lighting_manager", "refresh_brightness")
			return
		# Keep AudioManager's runtime state in sync for live volume changes.
		var _am := get_node_or_null("/root/AudioManager")
		if _am == null: return
		if key == "MasterSlider":  _am.set_master_volume(v / 100.0)
		elif key == "MusicSlider": _am.set_music_volume(v / 100.0)
		elif key == "SFXSlider":   _am.set_sfx_volume(v / 100.0))
	return sl


func _checkbox(parent: VBoxContainer, row_label: String, key: String) -> CheckBox:
	var row := _row(parent, row_label)
	var cb  := CheckBox.new()
	cb.custom_minimum_size = Vector2(SettingsRows.ROW_H, SettingsRows.ROW_H - PUI.S2)
	row.add_child(cb)
	_checkboxes[key] = cb
	# The state is spelled out so it is never colour-only.
	var state := PUI.label("", "SecondaryLabel")
	state.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(state)
	cb.toggled.connect(func(on: bool) -> void:
		state.text = "On" if on else "Off"
		if _suppress: return
		SettingsManager.update_setting(key, on))
	state.text = "On" if cb.button_pressed else "Off"
	return cb


func _hint(parent: VBoxContainer, text: String) -> void:
	SettingsRows.hint(parent, text)


# ══════════════════════════════════════════════════════════════════════════════
#  TABS
# ══════════════════════════════════════════════════════════════════════════════

func _build_sound_tab() -> void:
	var t := _new_tab("Sound")
	_section(t, "Volume")
	_slider(t, "Master Volume", "MasterSlider", 0.0, 100.0, 1.0)
	_slider(t, "Music Volume",  "MusicSlider",  0.0, 100.0, 1.0)
	_slider(t, "SFX Volume",    "SFXSlider",    0.0, 100.0, 1.0)


func _build_video_tab() -> void:
	var t := _new_tab("Video")
	_section(t, "Display")

	if TouchControls.is_touch_platform():
		_hint(t, "The game always runs full-screen on this device.")
		_section(t, "Performance")
		_checkbox(t, "Enable V-Sync", "VSync")
		return
	var dm := _row(t, "Display Mode")
	_display_option = OptionButton.new()
	_display_option.add_item("Windowed",              0)
	_display_option.add_item("Maximized Window",      1)
	_display_option.add_item("Borderless Fullscreen", 2)
	_display_option.add_item("Exclusive Fullscreen",  3)
	_display_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dm.add_child(_display_option)
	_display_option.item_selected.connect(_on_display_mode_selected)

	var rr := _row(t, "Resolution", "Windowed mode only")
	_res_option = OptionButton.new()
	_res_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rr.add_child(_res_option)
	_build_resolution_list()
	_res_option.item_selected.connect(_on_resolution_selected)

	_section(t, "Performance")
	_checkbox(t, "Enable V-Sync", "VSync")


func _build_resolution_list() -> void:
	if _res_option == null: return
	_res_option.clear(); _resolution_list.clear()
	var desktop := DisplayServer.screen_get_size()
	var cands : Array[Vector2i] = [
		Vector2i(1280,720), Vector2i(1366,768), Vector2i(1600,900),
		Vector2i(1920,1080), Vector2i(2560,1440), Vector2i(3840,2160),
	]
	cands.append(desktop); cands.append(DisplayServer.window_get_size())
	var seen : Dictionary = {}
	for s in cands:
		if s.x < 800 or s.y < 600 or s.x > desktop.x or s.y > desktop.y: continue
		var k := str(s.x) + "x" + str(s.y)
		if seen.has(k): continue
		seen[k] = true; _resolution_list.append(s)
	_resolution_list.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x if a.x != b.x else a.y < b.y)
	for i in range(_resolution_list.size()):
		var s := _resolution_list[i]
		var lbl := "%d x %d%s" % [s.x, s.y, "  (Desktop)" if s == desktop else ""]
		_res_option.add_item(lbl, i)


func _on_display_mode_selected(index: int) -> void:
	if _suppress or _display_option == null: return
	var mode : int = _display_option.get_item_id(index)
	SettingsManager.apply_window_mode(mode)
	if _res_option != null:
		_res_option.disabled = (mode != 0)


func _on_resolution_selected(index: int) -> void:
	if _suppress or index < 0 or index >= _resolution_list.size(): return
	# Resolution override only applies in Windowed mode.
	if int(SettingsManager.gameplay_settings.get("WindowMode", 2)) != 0: return
	var s := _resolution_list[index]
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(s)
	var sc := DisplayServer.screen_get_size()
	DisplayServer.window_set_position(
		Vector2i(int((sc.x - s.x) / 2), int((sc.y - s.y) / 2)))


func _build_gameplay_tab() -> void:
	var t := _new_tab("Gameplay")
	_section(t, "Feel")
	_slider(t, "Screen Shake",  "ShakeSlider",  0.0, 100.0, 1.0)
	_section(t, "Difficulty", "Takes effect next run")
	_slider(t, "Enemy Speed",   "SpeedSlider",  50.0, 200.0, 5.0)
	_slider(t, "Enemy Damage",  "DamageSlider", 50.0, 200.0, 5.0)
	_hint(t, "50% is easier, 100% is normal, 200% is brutal.")
	if TouchControls.is_touch_platform():
		_section(t, "Touch Controls")
		_build_scheme_row(t)
		_slider(t, "Control Opacity",   TouchControls.KEY_OPACITY, 20.0, 100.0, 5.0)
		_slider(t, "Control Size",      TouchControls.KEY_SCALE,   70.0, 150.0, 5.0)
		_slider(t, "Look Sensitivity",  TouchControls.KEY_LOOK,    40.0, 250.0, 5.0)


const SCHEME_HINTS : Dictionary = {
	"twin": "Left thumb moves. The big Attack button also aims: drag from it to look around and turn while you attack.",
	"classic": "Swipe the right side of the screen to look around.",
}


## "Control scheme": Twin-stick (default) or Classic (swipe to look). Two selector buttons in one group; the
## choice is stored at once and the touch layer picks it up live (also while this screen is open over a paused run).
func _build_scheme_row(t: VBoxContainer) -> void:
	var row := _row(t, "Control scheme")
	var group := ButtonGroup.new()
	for entry in [["twin", "Twin-stick"], ["classic", "Classic"]]:
		var b := PUI.button(entry[1], "selector")
		b.name = "Scheme_" + String(entry[0])
		b.button_group = group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
		_scheme_buttons[entry[0]] = b
		var key: String = entry[0]
		b.toggled.connect(func(on: bool) -> void:
			if not on:
				return
			_scheme_hint_update(key)
			if _suppress: return
			SettingsManager.update_setting(TouchControls.KEY_SCHEME, key))
	_scheme_hint = SettingsRows.hint(t, SCHEME_HINTS["twin"])


func _scheme_hint_update(key: String) -> void:
	if _scheme_hint != null:
		_scheme_hint.text = SCHEME_HINTS.get(key, "")


func _build_accessibility_tab() -> void:
	var t := _new_tab("Accessibility")
	_section(t, "Difficulty", "Takes effect next run")
	_slider(t, "Enemy Health",  "HealthSlider", 50.0, 200.0, 5.0)
	_hint(t, "Controls how much health enemies spawn with each run.")
	_section(t, "Visibility", "Applies immediately")
	_slider(t, "Ambient Brightness", "AmbientBrightness", 0.0, 100.0, 5.0)
	_hint(t, "Raises the dim background light so floors, walls and enemies stay readable. 0% is the standard dark look.")


# ══════════════════════════════════════════════════════════════════════════════
#  ABOUT TAB
#  What build this is and whether it is up to date. All facts and wording come from AboutInfo (pure, tested);
#  the OTA facts come from the native `Boot` autoload and "Check for updates" goes through Boot.check_now():
#  this screen has no network code and no second updater. Without Boot (desktop, tests) it shows a calm note.
# ══════════════════════════════════════════════════════════════════════════════

const ABOUT_ROWS : Array = [
	["version", "Game version"], ["app", "App version"], ["update", "Update"], ["staged", "Waiting to start"],
]
const ABOUT_TECH_ROWS : Array = [
	["runtime", "Runtime"], ["fingerprint", "Runtime fingerprint"], ["channel", "Update channel"],
	["engine", "Engine"], ["platform", "Platform"], ["checked", "Last check"],
]

var last_copied_text : String = ""   # what Copy diagnostics put on the clipboard (tests read it)
var _about_row_boxes : Dictionary = {}   # row key -> HBoxContainer


func _build_about_tab() -> void:
	var t := _new_tab("About")

	var title := PUI.label("", "CardTitle")
	title.name = "AboutTitle"
	title.mouse_filter = Control.MOUSE_FILTER_STOP     # seven quick taps unlock the developer tools
	title.gui_input.connect(_on_about_title_input)
	t.add_child(title)
	_about_values["title"] = title

	_section(t, "Updates")
	var plate := PUI.panel("inset")
	plate.name = "AboutStatusPlate"
	t.add_child(plate)
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", PUI.S1)
	plate.add_child(pv)
	_about_status = Label.new()
	_about_status.name = "AboutStatus"
	_about_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_about_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pv.add_child(_about_status)
	_about_detail = PUI.label("", "SecondaryLabel")
	_about_detail.name = "AboutDetail"
	_about_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_about_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pv.add_child(_about_detail)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", PUI.S4)
	t.add_child(buttons)
	_about_check = PUI.button("Check for updates", "secondary")
	_about_check.name = "CheckUpdatesButton"
	_about_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_about_check.pressed.connect(_on_about_check_pressed)
	buttons.add_child(_about_check)
	_about_copy = PUI.button("Copy diagnostics", "secondary")
	_about_copy.name = "CopyDiagnosticsButton"
	_about_copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_about_copy.pressed.connect(_on_about_copy_pressed)
	buttons.add_child(_about_copy)
	_about_copied = PUI.label("", "SecondaryLabel")
	_about_copied.name = "AboutCopied"
	t.add_child(_about_copied)
	_hint(t, "Updates download in the background and start the next time you open the game. Copy diagnostics puts the details above on the clipboard, without any personal data, so you can paste them into a bug report.")

	_section(t, "Version")
	for r in ABOUT_ROWS:
		_about_value_row(t, r[0], r[1])

	_section(t, "Technical details")
	for r in ABOUT_TECH_ROWS:
		_about_value_row(t, r[0], r[1])

	# Developer tools: hidden until the version is tapped seven times. Never shown to a normal player.
	_about_dev_box = VBoxContainer.new()
	_about_dev_box.name = "DeveloperTools"
	_about_dev_box.add_theme_constant_override("separation", PUI.S3)
	t.add_child(_about_dev_box)
	_section(_about_dev_box, "Developer tools")
	_checkbox(_about_dev_box, "Show performance readout", PerfOverlay.KEY)
	_hint(_about_dev_box, "FPS, slowest 1% of frames, draw calls (phones).")
	var diag := PUI.button("Open update diagnostics", "secondary")
	diag.name = "OpenDiagnosticsButton"
	diag.pressed.connect(_on_about_open_diagnostics)
	_about_dev_box.add_child(diag)
	var hide_dev := PUI.button("Hide developer tools", "nav")
	hide_dev.name = "HideDeveloperToolsButton"
	hide_dev.pressed.connect(func() -> void: _set_developer_mode(false))
	_about_dev_box.add_child(hide_dev)
	_about_dev_box.visible = _developer_mode()

	var b = AboutInfo.boot_node(about_provider)
	if b != null and b.has_signal("status_changed"):
		b.status_changed.connect(_refresh_about)
	_refresh_about()


func _about_value_row(parent: VBoxContainer, key: String, label_text: String) -> void:
	var r := _row(parent, label_text)
	r.name = "AboutRow_" + key
	var v := Label.new()
	v.name = "Value"
	v.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r.add_child(v)
	_about_values[key] = v
	_about_row_boxes[key] = r


func _developer_mode() -> bool:
	return has_node("/root/SettingsManager") and SettingsManager.is_developer_mode()


func _set_developer_mode(on: bool) -> void:
	if has_node("/root/SettingsManager"):
		SettingsManager.set_developer_mode(on)
	if _about_dev_box != null:
		_about_dev_box.visible = on
	if _checkboxes.has(PerfOverlay.KEY):
		_suppress = true
		(_checkboxes[PerfOverlay.KEY] as CheckBox).button_pressed = bool(SettingsManager.gameplay_settings.get(PerfOverlay.KEY, false)) if on else false
		_suppress = false


func _on_about_title_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var now: int = Time.get_ticks_msec()
		_about_taps = AboutInfo.dev_tap(_about_taps, _about_last_tap, now)
		_about_last_tap = now
		if _about_taps >= AboutInfo.DEV_TAPS:
			_about_taps = 0
			_set_developer_mode(not _developer_mode())


## Redraws the tab from the current snapshot. Connected to Boot.status_changed, so progress appears by itself.
func _refresh_about() -> void:
	if _about_status == null or not is_instance_valid(_about_status):
		return
	var model: Dictionary = AboutInfo.build_model(AboutInfo.snapshot(about_provider), _about_checking)
	(_about_values["title"] as Label).text = model["title"]
	for key in _about_row_boxes.keys():
		(_about_row_boxes[key] as Control).visible = false
	for entry in (model["rows"] as Array) + (model["tech"] as Array):
		var k: String = entry["key"]
		if _about_values.has(k):
			(_about_values[k] as Label).text = entry["value"]
			(_about_row_boxes[k] as Control).visible = true
	var st: Dictionary = model["status"]
	_about_status.text = st["text"]
	_about_status.add_theme_color_override("font_color", {
		AboutInfo.KIND_OK: PUI.MOSS, AboutInfo.KIND_WARN: PUI.EMBER_BRIGHT,
		AboutInfo.KIND_ERROR: PUI.BLOOD_BRIGHT}.get(st["kind"], PUI.BONE))
	_about_detail.text = st.get("detail", "")
	_about_detail.visible = _about_detail.text != ""
	_about_check.disabled = not model["can_check"]
	_about_check.text = model["check_label"]


## "Check for updates": the native client's own check (Boot.check_now): signed manifest, verification, download, staging.
## A second press while one runs is ignored. The result is only a state change; nothing is applied until a restart.
func _on_about_check_pressed() -> void:
	if _about_checking:
		return
	var b = AboutInfo.boot_node(about_provider)
	if b == null or not b.has_method("check_now"):
		_refresh_about()
		return
	_about_checking = true
	_refresh_about()
	await b.check_now()
	_about_checking = false
	if is_inside_tree():
		_refresh_about()


func about_diagnostics_text() -> String:
	var b = AboutInfo.boot_node(about_provider)
	var boot_text: String = str(b.diagnostics_text()) if b != null and b.has_method("diagnostics_text") else ""
	return AboutInfo.diagnostics_text(AboutInfo.snapshot(about_provider), AboutInfo.device_info(), boot_text)


func _on_about_copy_pressed() -> void:
	last_copied_text = about_diagnostics_text()
	DisplayServer.clipboard_set(last_copied_text)
	_about_copied.text = "Copied to the clipboard."


func _on_about_open_diagnostics() -> void:
	var b = AboutInfo.boot_node(about_provider)
	if b != null and b.has_method("show_diagnostics"):
		b.show_diagnostics()


# ══════════════════════════════════════════════════════════════════════════════
#  CONTROLS TAB
# ══════════════════════════════════════════════════════════════════════════════

func _build_controls_tab() -> void:
	var t := _new_tab("Controls")
	_controls_tab_vb = t
	_populate_controls_tab(t)


func _populate_controls_tab(t: VBoxContainer) -> void:
	# ── Quick Reference (read-only) ─────────────────────────────────────────
	_section(t, "Quick Reference")

	const REF : Array = [
		["Move",          "W A S D",           "Left Stick"],
		["Look",          "Mouse",             "Right Stick"],
		["Slide (Evade)", "Space",             "B  (Cross)"],
		["Attack",        "LMB",               "RT  (R2)"],
		["Kick / Shove",  "F",                 "R Stick Click"],
		["Block",         "RMB",               "L Stick Click"],
		["AOE Blast",     "Q",                 "L Stick Click"],
		["Walk Toggle",   "Shift",             "RB  (R1)"],
		["Minimap",       "Tab",               "LT  (L2)"],
		["Equip / Use",   "E",                 "A  (Square)"],
		["Pause",         "Esc  or  F4",       "Start / Menu"],
	]

	# the reference is a recessed, read-only plate; the remap rows below are real controls
	var ref_panel := PUI.panel("inset")
	t.add_child(ref_panel)
	var ref_vb := VBoxContainer.new()
	ref_vb.add_theme_constant_override("separation", PUI.S1)
	ref_panel.add_child(ref_vb)
	_table_header(ref_vb)
	for entry in REF:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", PUI.S4)
		ref_vb.add_child(row)

		var a := Label.new()
		a.text = entry[0]
		a.custom_minimum_size.x = SettingsRows.LABEL_W
		a.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(a)

		for i in [1, 2]:
			var v := Label.new()
			v.text = entry[i]
			v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			v.size_flags_stretch_ratio = 1.0
			v.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
			v.vertical_alignment    = VERTICAL_ALIGNMENT_CENTER
			v.add_theme_color_override("font_color", PUI.EMBER_BRIGHT)
			row.add_child(v)

	# ── Remappable bindings ──────────────────────────────────────────────────
	_section(t, "Remap Bindings")
	_hint(t, "Select a binding to remap it. Press Esc to cancel.")
	_table_header(t)

	# ── One row per action ──────────────────────────────────────────────────
	for entry in REMAPPABLE_ACTIONS:
		var action : String = entry["name"]
		if not InputMap.has_action(action):
			continue

		var row := _row(t, entry["label"])

		var kb_btn := Button.new()
		kb_btn.text = _get_kb_label(action)
		kb_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		kb_btn.pressed.connect(_start_listen.bind(action, "keyboard", kb_btn))
		row.add_child(kb_btn)

		var gp_btn := Button.new()
		gp_btn.text = _get_gp_label(action)
		gp_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		gp_btn.pressed.connect(_start_listen.bind(action, "gamepad", gp_btn))
		row.add_child(gp_btn)

	# ── Reset button ────────────────────────────────────────────────────────
	var reset_btn := PUI.button("Reset Controls to Default")
	reset_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	reset_btn.pressed.connect(_reset_controls)
	t.add_child(reset_btn)


# Column captions for the two binding tables (same columns as the rows beneath them).
func _table_header(parent: Control) -> void:
	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", PUI.S4)
	parent.add_child(hdr)
	var h_act := PUI.label("Action", "MetaLabel")
	h_act.custom_minimum_size.x = SettingsRows.LABEL_W
	hdr.add_child(h_act)
	for col_text in ["Keyboard / Mouse", "Gamepad"]:
		var h := PUI.label(col_text, "MetaLabel")
		h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hdr.add_child(h)


# ── Remapping helpers ──────────────────────────────────────────────────────────

func _start_listen(action: String, bind_type: String, btn: Button) -> void:
	if _listening_btn != null:
		_cancel_listen()
	_listening_action = action
	_listening_type   = bind_type
	_listening_btn    = btn
	btn.text          = "Press a key..." if bind_type == "keyboard" else "Press a button..."
	_set_listening_look(btn, true)


# The waiting button wears the same ember look as a selected choice elsewhere in the game.
func _set_listening_look(btn: Button, on: bool) -> void:
	if not is_instance_valid(btn):
		return
	if on:
		var sel: StyleBox = PUI.theme().get_stylebox("pressed", "SelectorButton")
		for st in ["normal", "hover", "pressed", "hover_pressed"]:
			btn.add_theme_stylebox_override(st, sel)
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			btn.add_theme_color_override(c, PUI.EMBER_BRIGHT)
	else:
		for st in ["normal", "hover", "pressed", "hover_pressed"]:
			btn.remove_theme_stylebox_override(st)
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			btn.remove_theme_color_override(c)


func _cancel_listen() -> void:
	if _listening_btn != null:
		var a := _listening_action
		var t := _listening_type
		if is_instance_valid(_listening_btn):
			_listening_btn.text = _get_kb_label(a) if t == "keyboard" else _get_gp_label(a)
			_set_listening_look(_listening_btn, false)
	_listening_action = ""
	_listening_type   = ""
	_listening_btn    = null


func _handle_listen_input(event: InputEvent) -> void:
	# Escape always cancels
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ESCAPE or event.keycode == KEY_ESCAPE:
			_cancel_listen()
			get_viewport().set_input_as_handled()
			return

	if _listening_type == "keyboard":
		if event is InputEventKey and event.pressed and not event.echo:
			_apply_remap(_listening_action, "keyboard", event)
			get_viewport().set_input_as_handled()
		elif event is InputEventMouseButton and event.pressed:
			_apply_remap(_listening_action, "keyboard", event)
			get_viewport().set_input_as_handled()
	elif _listening_type == "gamepad":
		if event is InputEventJoypadButton and event.pressed:
			_apply_remap(_listening_action, "gamepad", event)
			get_viewport().set_input_as_handled()
		elif event is InputEventJoypadMotion and absf(event.axis_value) > 0.5:
			_apply_remap(_listening_action, "gamepad", event)
			get_viewport().set_input_as_handled()


func _is_type_event(e: InputEvent, bind_type: String) -> bool:
	if bind_type == "keyboard":
		return e is InputEventKey or e is InputEventMouseButton
	return e is InputEventJoypadButton or e is InputEventJoypadMotion


# First binding of `bind_type` on `action`, or null.
func _binding_of(action: String, bind_type: String) -> InputEvent:
	for e in InputMap.action_get_events(action):
		if _is_type_event(e, bind_type):
			return e
	return null


# Another remappable action already using `event`, or "" if it is free.
func _find_conflict(action: String, bind_type: String, event: InputEvent) -> String:
	for entry in REMAPPABLE_ACTIONS:
		var other : String = entry["name"]
		if other == action or not InputMap.has_action(other):
			continue
		for e in InputMap.action_get_events(other):
			if _is_type_event(e, bind_type) and e.is_match(event, true):
				return other
	return ""


func _set_binding(action: String, bind_type: String, new_event: InputEvent) -> void:
	var to_erase : Array = []
	for e in InputMap.action_get_events(action):
		if _is_type_event(e, bind_type):
			to_erase.append(e)
	for e in to_erase:
		InputMap.action_erase_event(action, e)
	InputMap.action_add_event(action, new_event)

	var controls : Dictionary = SettingsManager.gameplay_settings.get("controls", {})
	if not controls.has(action):
		controls[action] = {}
	controls[action][bind_type] = SettingsManager.serialize_event(new_event)
	SettingsManager.gameplay_settings["controls"] = controls


func _apply_remap(action: String, bind_type: String, event: InputEvent) -> void:
	var new_event := event.duplicate() as InputEvent
	new_event.device = -1

	# One input must never drive two actions. If another action already uses it, the two actions
	# swap bindings (so neither is left unbound); if this action has nothing to hand over, refuse.
	var other : String = _find_conflict(action, bind_type, new_event)
	if other != "":
		var old_event : InputEvent = _binding_of(action, bind_type)
		if old_event == null:
			push_warning("OptionsScreen: that input is already used by '%s'." % other)
			_cancel_listen()
			return
		var handed : InputEvent = old_event.duplicate() as InputEvent
		handed.device = -1
		_set_binding(other, bind_type, handed)

	_set_binding(action, bind_type, new_event)
	SettingsManager.save_settings()

	if other != "" and _controls_tab_vb != null:
		_rebuild_controls_rows()   # the other action's button label changed too

	if _listening_btn != null and is_instance_valid(_listening_btn):
		_listening_btn.text = _event_label(new_event)
		_set_listening_look(_listening_btn, false)
	_listening_action = ""
	_listening_type   = ""
	_listening_btn    = null


func _reset_controls() -> void:
	_cancel_listen()   # a pending 'Press key…' button is about to be freed
	SettingsManager.gameplay_settings.erase("controls")
	SettingsManager.save_settings()
	InputMap.load_from_project_settings()
	# Rebuild rows to show restored defaults
	_rebuild_controls_rows()


func _rebuild_controls_rows() -> void:
	if _controls_tab_vb == null:
		return
	for child in _controls_tab_vb.get_children():
		child.queue_free()
	await get_tree().process_frame
	if is_instance_valid(_controls_tab_vb):
		_populate_controls_tab(_controls_tab_vb)


# ── Label helpers ──────────────────────────────────────────────────────────────

func _get_kb_label(action: String) -> String:
	for e in InputMap.action_get_events(action):
		if e is InputEventKey or e is InputEventMouseButton:
			return _event_label(e)
	return "Unbound"


func _get_gp_label(action: String) -> String:
	for e in InputMap.action_get_events(action):
		if e is InputEventJoypadButton or e is InputEventJoypadMotion:
			return _event_label(e)
	return "Unbound"


func _event_label(e: InputEvent) -> String:
	if e is InputEventKey:
		var kc : int = e.keycode if e.keycode != 0 else e.physical_keycode
		if kc != 0:
			return OS.get_keycode_string(kc as Key)
		return e.as_text()
	if e is InputEventMouseButton:
		match e.button_index:
			MOUSE_BUTTON_LEFT:   return "LMB"
			MOUSE_BUTTON_RIGHT:  return "RMB"
			MOUSE_BUTTON_MIDDLE: return "MMB"
			_: return "Mouse %d" % e.button_index
	if e is InputEventJoypadButton:
		return "Pad Btn %d" % e.button_index
	if e is InputEventJoypadMotion:
		return "Pad Axis%d%s" % [e.axis, "+" if e.axis_value > 0 else "-"]
	return "Unbound"


# ══════════════════════════════════════════════════════════════════════════════
#  LOAD SETTINGS FROM SETTINGSMANAGER
# ══════════════════════════════════════════════════════════════════════════════

func _load_settings() -> void:
	if not has_node("/root/SettingsManager"): return
	_suppress = true

	# Sliders — apply saved value and update display label
	var defaults : Dictionary = {
		"MasterSlider": 100.0, "MusicSlider": 65.0, "SFXSlider": 100.0,
		"ShakeSlider": 50.0, "SpeedSlider": 100.0, "DamageSlider": 100.0,
		"TouchOpacity": 70.0, "TouchScale": 100.0, "TouchLookSens": 100.0,
		"HealthSlider": 100.0, "AmbientBrightness": 0.0,
	}
	for key in _sliders.keys():
		var v : float = SettingsManager.get_setting(key, defaults.get(key, 100.0))
		_sliders[key].value = v
		if _val_labels.has(key):
			_val_labels[key].text = "%.0f%%" % v

	# Touch control scheme
	if not _scheme_buttons.is_empty():
		var sk: String = TouchControls.scheme_from(SettingsManager.gameplay_settings.get(TouchControls.KEY_SCHEME, TouchControls.DEFAULT_SCHEME))
		(_scheme_buttons[sk] as Button).button_pressed = true
		_scheme_hint_update(sk)

	# Checkboxes
	for key in _checkboxes.keys():
		_checkboxes[key].button_pressed = bool(
			SettingsManager.gameplay_settings.get(key, true))

	# Display mode
	if _display_option != null:
		var mode : int = int(SettingsManager.gameplay_settings.get("WindowMode", 2))
		for i in _display_option.item_count:
			if _display_option.get_item_id(i) == mode:
				_display_option.select(i)
				break
		if _res_option != null:
			_res_option.disabled = (mode != 0)

	# Resolution — select closest match to current window
	if _res_option != null and not _resolution_list.is_empty():
		var cur := DisplayServer.window_get_size()
		var best := 0; var bs := 9999999
		for i in range(_resolution_list.size()):
			var sc : int = abs(_resolution_list[i].x - cur.x) + abs(_resolution_list[i].y - cur.y)
			if sc < bs: bs = sc; best = i
		_res_option.select(best)

	_suppress = false


# ══════════════════════════════════════════════════════════════════════════════
#  NAVIGATION
# ══════════════════════════════════════════════════════════════════════════════

func _go_back() -> void:
	if embedded:
		closed.emit()
		queue_free()
		return
	var dest : String = _return_scene
	_return_scene = ""
	get_tree().change_scene_to_file(dest if not dest.is_empty() else main_menu_scene)
