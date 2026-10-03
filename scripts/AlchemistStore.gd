# ==============================================================================
# File Name: AlchemistStore.gd
# Path: res://scripts/AlchemistStore.gd
# Description: 9-Perk hub store with parchment background and page navigation.
#              12 perks across 2 pages (9 per page).
#              Page arrows sit at the bottom of the parchment panel.
#              Load Character (bottom-left) and Start Another Run (bottom-right)
#              sit outside the parchment, always visible regardless of page.
#
#  ADJUSTABLE SETTINGS:
#    PERKS_PER_PAGE   — how many perks show per page (default 9 = 3×3 grid)
#    PARCHMENT_COLOR  — warm tan used as the store background
#    CARD_MIN_SIZE    — minimum pixel size of each perk card
#
#  MOD NOTES:
#  - SURGICAL CHANGE: "Sanctuary" renamed to "Hare's Delight".
#    Save key "sanctuary" preserved so existing saves are not broken.
#  - SURGICAL ADD: Parchment panel built in code to match the minimap aesthetic.
#  - SURGICAL ADD: Pagination system — 9 perks per page, ◄ / ► to navigate.
#  - SURGICAL ADD: Load Character and Start Another Run nav buttons.
# ==============================================================================
extends Control

@export var character_selection_scene : String = "res://scenes/CharacterSelection.tscn"
const DUNGEON_SCENE    : String = "res://scenes/Purgatory_Dungeon_main_game_file.tscn"
const PERKS_PER_PAGE   : int    = 9
const PARCHMENT_COLOR  : Color  = Color(0.82, 0.72, 0.52, 0.97)
const INK_COLOR        : Color  = Color(0.15, 0.09, 0.04, 1.0)
const CARD_MIN_SIZE    : Vector2 = Vector2(210, 138)

@onready var currency_label : Label         = find_child("CurrencyLabel")
@onready var grid           : GridContainer = find_child("PerkGrid")

# ── Pagination state ───────────────────────────────────────────────────────────
var _current_page  : int = 0
var _total_pages   : int = 1

# ── Parchment UI nodes (built in code) ────────────────────────────────────────
var _parchment_panel : Panel    = null
var _page_label      : Label    = null
var _prev_btn        : Button   = null
var _next_btn        : Button   = null

# ── Nav buttons (outside parchment) ───────────────────────────────────────────
var _load_char_btn   : Button   = null
var _new_run_btn     : Button   = null
var _back_btn        : Button   = null   # hidden legacy button

var perks_def : Array = [
	{"key": "magnitude",   "name": "Magnitude",      "desc": "Dome Radius +10%"},
	{"key": "persistence", "name": "Persistence",    "desc": "Dome Duration +15%"},
{"key": "vitality",    "name": "Vitality",        "desc": "Max Health +10"},
	{"key": "adrenaline",  "name": "Adrenaline",      "desc": "Attack Speed +8%"},
	{"key": "ferocity",    "name": "Ferocity",         "desc": "Attack Damage +10%"},
	{"key": "scavenge",    "name": "Scavenge",         "desc": "Drop Rate +5%"},
	{"key": "greed",       "name": "Greed",            "desc": "Double Drop Chance +10%"},
	{"key": "swiftness",   "name": "Swiftness",        "desc": "Move Speed +5%"},
	{"key": "health_regen","name": "Regeneration",     "desc": "+0.5 HP/sec per level"},
	{"key": "cyclone",     "name": "Cyclone",          "desc": "+0.5s Rapid Attack / -3s Cooldown"},
	{"key": "trap_sense",  "name": "Trap Sense",       "desc": "Each level adds 25% chance a trap glows red — requires 5 runs"},
]


func _ready() -> void:
	# The dungeon captures the mouse; make sure menus are clickable after leaving it.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_total_pages = int(ceil(float(perks_def.size()) / float(PERKS_PER_PAGE)))
	_hide_legacy_back_button()
	_build_parchment()
	_build_nav_buttons()
	_update_ui()
	_update_page_controls()
	if _load_char_btn:
		_load_char_btn.call_deferred("grab_focus")
	_wire_button_clicks()


# ══════════════════════════════════════════════════════════════
#  PARCHMENT PANEL
# ══════════════════════════════════════════════════════════════

func _wire_button_clicks() -> void:
	if has_node("/root/AudioManager"):
		AudioManager.wire_click_sounds(self)


func _build_parchment() -> void:
	# Dark vignette behind the parchment
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.55)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# Parchment panel — TextureRect using the actual parchment.jpeg asset,
	# same source as the minimap overlay. A ColorRect child tints it slightly
	# darker so ink-colored text stays readable over the texture variation.
	_parchment_panel = Panel.new()
	_parchment_panel.name = "ParchmentPanel"

	# Transparent panel so the TextureRect beneath shows through.
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	_parchment_panel.add_theme_stylebox_override("panel", style)

	_parchment_panel.anchor_left   = 0.05
	_parchment_panel.anchor_top    = 0.04
	_parchment_panel.anchor_right  = 0.95
	_parchment_panel.anchor_bottom = 0.90

	add_child(_parchment_panel)

	# Parchment texture fills the panel
	var parchment_tex : Texture2D = load("res://Music & background images/parchment.jpeg")
	var tex_rect := TextureRect.new()
	tex_rect.texture      = parchment_tex
	tex_rect.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	tex_rect.stretch_mode = TextureRect.STRETCH_SCALE
	tex_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_parchment_panel.add_child(tex_rect)

	# Slight darkening tint so text is readable over texture highlights
	var tint := ColorRect.new()
	tint.color        = Color(0.0, 0.0, 0.0, 0.18)
	tint.set_anchors_preset(Control.PRESET_FULL_RECT)
	tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_parchment_panel.add_child(tint)

	# ── Title ─────────────────────────────────────────────────
	var title := Label.new()
	title.text = "THE ALCHEMIST'S LAB"
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", INK_COLOR)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.anchor_left   = 0.0
	title.anchor_top    = 0.0
	title.anchor_right  = 1.0
	title.anchor_bottom = 0.0
	title.offset_top    = 18.0
	title.offset_bottom = 58.0
	_parchment_panel.add_child(title)

	# ── Divider under title ────────────────────────────────────
	var divider := ColorRect.new()
	divider.color           = Color(0.45, 0.30, 0.12, 0.6)
	divider.anchor_left     = 0.05
	divider.anchor_right    = 0.95
	divider.anchor_top      = 0.0
	divider.anchor_bottom   = 0.0
	divider.offset_top      = 60.0
	divider.offset_bottom   = 63.0
	_parchment_panel.add_child(divider)

	# ── Currency label ─────────────────────────────────────────
	# If the scene has a CurrencyLabel node, hide it — we build our own
	# inside the parchment so it fits the aesthetic.
	if currency_label != null:
		currency_label.visible = false

	var potions_label := Label.new()
	potions_label.name = "ParchmentCurrencyLabel"
	potions_label.add_theme_font_size_override("font_size", 15)
	potions_label.add_theme_color_override("font_color", INK_COLOR)
	potions_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	potions_label.anchor_left   = 0.0
	potions_label.anchor_top    = 0.0
	potions_label.anchor_right  = 1.0
	potions_label.anchor_bottom = 0.0
	potions_label.offset_top    = 66.0
	potions_label.offset_bottom = 92.0
	_parchment_panel.add_child(potions_label)
	# Keep a reference so _update_ui can write to it
	currency_label = potions_label

	# ── Perk grid ─────────────────────────────────────────────
	# Reuse the scene's GridContainer if present; otherwise use the
	# @onready ref. If neither exists, build one fresh.
	if grid == null:
		grid = GridContainer.new()
		grid.name = "PerkGrid"
	else:
		# Reparent into parchment — grid was already in the scene tree.
		# We do this here (not deferred) because the parchment was just
		# created in the same frame so layout hasn't run yet; no size
		# conflict can occur.
		grid.get_parent().remove_child(grid)
		grid.set_owner(null)

	grid.columns          = 3
	grid.anchor_left      = 0.03
	grid.anchor_top       = 0.0
	grid.anchor_right     = 0.97
	grid.anchor_bottom    = 0.0
	grid.offset_top       = 96.0
	grid.offset_bottom    = -10.0
	grid.anchor_bottom    = 1.0
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	_parchment_panel.add_child(grid)

	# ── Page navigation ────────────────────────────────────────
	# Parented to the root control (not the parchment) so they sit on
	# the same baseline as Load Character and Start Another Run.
	_prev_btn = Button.new()
	_prev_btn.text = "◄"
	_prev_btn.add_theme_font_size_override("font_size", 20)
	_prev_btn.custom_minimum_size = Vector2(52, 52)
	_prev_btn.anchor_left   = 0.5
	_prev_btn.anchor_top    = 1.0
	_prev_btn.anchor_right  = 0.5
	_prev_btn.anchor_bottom = 1.0
	_prev_btn.offset_left   = -110.0
	_prev_btn.offset_top    = -70.0
	_prev_btn.offset_right  = -58.0
	_prev_btn.offset_bottom = -18.0
	_prev_btn.pressed.connect(_on_prev_page)
	add_child(_prev_btn)

	_page_label = Label.new()
	_page_label.add_theme_font_size_override("font_size", 15)
	_page_label.add_theme_color_override("font_color", Color(0.92, 0.92, 0.95, 1.0))
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_page_label.anchor_left   = 0.5
	_page_label.anchor_top    = 1.0
	_page_label.anchor_right  = 0.5
	_page_label.anchor_bottom = 1.0
	_page_label.offset_left   = -55.0
	_page_label.offset_top    = -70.0
	_page_label.offset_right  =  55.0
	_page_label.offset_bottom = -18.0
	add_child(_page_label)

	_next_btn = Button.new()
	_next_btn.text = "►"
	_next_btn.add_theme_font_size_override("font_size", 20)
	_next_btn.custom_minimum_size = Vector2(52, 52)
	_next_btn.anchor_left   = 0.5
	_next_btn.anchor_top    = 1.0
	_next_btn.anchor_right  = 0.5
	_next_btn.anchor_bottom = 1.0
	_next_btn.offset_left   =  58.0
	_next_btn.offset_top    = -70.0
	_next_btn.offset_right  = 110.0
	_next_btn.offset_bottom = -18.0
	_next_btn.pressed.connect(_on_next_page)
	add_child(_next_btn)


# ══════════════════════════════════════════════════════════════
#  NAV BUTTONS (outside parchment)
# ══════════════════════════════════════════════════════════════

func _build_nav_buttons() -> void:
	_load_char_btn = Button.new()
	_load_char_btn.name = "LoadCharacterButton"
	_load_char_btn.text = "← Load Character"
	_load_char_btn.custom_minimum_size = Vector2(220, 52)
	_load_char_btn.add_theme_font_size_override("font_size", 16)
	_load_char_btn.anchor_left   = 0.0
	_load_char_btn.anchor_top    = 1.0
	_load_char_btn.anchor_right  = 0.0
	_load_char_btn.anchor_bottom = 1.0
	_load_char_btn.offset_left   = 20.0
	_load_char_btn.offset_top    = -70.0
	_load_char_btn.offset_right  = 240.0
	_load_char_btn.offset_bottom = -18.0
	add_child(_load_char_btn)
	_load_char_btn.pressed.connect(_go_to_character_selection)

	_new_run_btn = Button.new()
	_new_run_btn.name = "StartAnotherRunButton"
	_new_run_btn.text = "Start Another Run →"
	_new_run_btn.custom_minimum_size = Vector2(220, 52)
	_new_run_btn.add_theme_font_size_override("font_size", 16)
	_new_run_btn.anchor_left   = 1.0
	_new_run_btn.anchor_top    = 1.0
	_new_run_btn.anchor_right  = 1.0
	_new_run_btn.anchor_bottom = 1.0
	_new_run_btn.offset_left   = -240.0
	_new_run_btn.offset_top    = -70.0
	_new_run_btn.offset_right  = -20.0
	_new_run_btn.offset_bottom = -18.0
	add_child(_new_run_btn)
	_new_run_btn.pressed.connect(_start_new_run)


func _hide_legacy_back_button() -> void:
	_back_btn = find_child("BackButton", true, false) as Button
	if _back_btn == null:
		_back_btn = find_child("Back", true, false) as Button
	if _back_btn != null:
		_back_btn.visible = false


# ══════════════════════════════════════════════════════════════
#  PAGINATION
# ══════════════════════════════════════════════════════════════

func _on_prev_page() -> void:
	if _current_page > 0:
		_current_page -= 1
		_update_ui()
		_update_page_controls()


func _on_next_page() -> void:
	if _current_page < _total_pages - 1:
		_current_page += 1
		_update_ui()
		_update_page_controls()


func _update_page_controls() -> void:
	if _page_label != null:
		_page_label.text = "%d / %d" % [_current_page + 1, _total_pages]
	if _prev_btn != null:
		_prev_btn.disabled = (_current_page == 0)
	if _next_btn != null:
		_next_btn.disabled = (_current_page >= _total_pages - 1)


# ══════════════════════════════════════════════════════════════
#  INPUT
# ══════════════════════════════════════════════════════════════

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_go_to_character_selection()


# ══════════════════════════════════════════════════════════════
#  NAVIGATION ACTIONS
# ══════════════════════════════════════════════════════════════

func _go_to_character_selection() -> void:
	PlayerWallet.hide_hud()
	get_tree().change_scene_to_file(character_selection_scene)


func _start_new_run() -> void:
	if not SaveManager.current_profile.is_empty():
		SaveManager.current_profile["run_count"] = \
			int(SaveManager.current_profile.get("run_count", 0)) + 1
		SaveManager.save_profile()

	# Class/difficulty/name must come from the profile: GlobalRunData is only filled by
	# character select, so a fresh launch -> Alchemist -> start ran as a default Barbarian.
	RunLifecycle.sync_run_data_from_profile()
	var run_data := get_node_or_null("/root/GlobalRunData")
	if run_data != null:
		run_data.seed_hash = 0

	RunLifecycle.end_run_cleanup()

	get_tree().change_scene_to_file(DUNGEON_SCENE)


# ══════════════════════════════════════════════════════════════
#  UI POPULATION
# ══════════════════════════════════════════════════════════════

func _update_ui() -> void:
	if SaveManager.current_profile.is_empty():
		SaveManager.load_slot(SaveManager.active_slot_index)
	if SaveManager.current_profile.is_empty():
		if currency_label != null:
			currency_label.text = "Select a Profile First"
		return

	var profile      = SaveManager.current_profile
	var potion_count = int(profile.get("meta_currency", 0))
	if currency_label != null:
		currency_label.text = "Potions Stashed: %d" % potion_count

	if grid == null:
		return

	# Clear previous cards — remove_child first so find_child can't return a
	# dying node when _refocus_perk_btn runs in the same deferred call.
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()

	var user_perks : Dictionary = profile.get("perks", {})
	var run_count  : int        = int(profile.get("run_count", 0))

	var page_start : int = _current_page * PERKS_PER_PAGE
	var page_end   : int = mini(page_start + PERKS_PER_PAGE, perks_def.size())

	for i in range(page_start, page_end):
		var entry  : Dictionary = perks_def[i]
		var key    : String     = entry["key"]
		var lv     : int        = int(user_perks.get(key, 0))
		var locked : bool       = (key == "trap_sense" and run_count < 5)
		_create_perk_card(key, entry, lv, locked)


func _create_perk_card(key: String, data: Dictionary, lv: int, locked: bool) -> void:
	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = CARD_MIN_SIZE
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical   = Control.SIZE_EXPAND_FILL

	# Card background — slightly darker parchment shade
	var card_bg := StyleBoxFlat.new()
	card_bg.bg_color     = Color(0.75, 0.63, 0.43, 0.85)
	card_bg.border_color = Color(0.40, 0.26, 0.10, 0.7)
	card_bg.border_width_left   = 1
	card_bg.border_width_right  = 1
	card_bg.border_width_top    = 1
	card_bg.border_width_bottom = 1
	card_bg.corner_radius_top_left     = 4
	card_bg.corner_radius_top_right    = 4
	card_bg.corner_radius_bottom_left  = 4
	card_bg.corner_radius_bottom_right = 4
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", card_bg)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical   = Control.SIZE_EXPAND_FILL

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 4)

	var title := Label.new()
	title.text = data["name"] + (" 🔒" if locked else "")
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", INK_COLOR)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	var info := Label.new()
	if locked:
		info.text = "Requires 5 runs"
		info.add_theme_color_override("font_color", Color(0.35, 0.22, 0.08, 0.7))
	else:
		info.text = "Lv. %d\n%s" % [lv, data["desc"]]
		info.add_theme_color_override("font_color", Color(0.25, 0.15, 0.05, 1.0))
	info.add_theme_font_size_override("font_size", 12)
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	var cost : int = _calculate_cost(lv)
	var btn  := Button.new()
	btn.name = "UpgradeBtn_" + key
	if locked:
		btn.text     = "Locked"
		btn.disabled = true
	else:
		btn.text = "Trade %d Potion%s" % [cost, "s" if cost > 1 else ""]
		btn.pressed.connect(_on_upgrade_pressed.bind(key, cost))
	btn.add_theme_font_size_override("font_size", 12)

	inner.add_child(title)
	inner.add_child(info)
	inner.add_child(btn)
	panel.add_child(inner)
	vbox.add_child(panel)
	grid.add_child(vbox)


func _calculate_cost(lv: int) -> int:
	var base := int(pow(2, lv))
	if has_node("/root/GlobalRunData") and GlobalRunData.difficulty == "easy":
		return maxi(1, int(base * 0.8))   # 20% discount, minimum 1 potion
	return base


func _on_upgrade_pressed(key: String, cost: int) -> void:
	if PlayerWallet.spend_potions(cost):
		var profile = SaveManager.current_profile
		if not profile.has("perks"):
			profile["perks"] = {}
		profile["perks"][key] = int(profile["perks"].get(key, 0)) + 1
		SaveManager.save_profile()
		# Defer the grid rebuild so the gamepad button-release event is fully
		# processed before any nodes are queue_freed. Destroying the focused
		# button mid-press leaves the joypad input system in a stuck state.
		call_deferred("_rebuild_and_refocus", key)
	else:
		push_warning("AlchemistStore: not enough potions — have %d need %d." % [
			int(SaveManager.current_profile.get("meta_currency", 0)), cost])


func _rebuild_and_refocus(key: String) -> void:
	_update_ui()
	_update_page_controls()
	_refocus_perk_btn(key)


func _refocus_perk_btn(key: String) -> void:
	var btn := find_child("UpgradeBtn_" + key, true, false) as Button
	if btn != null and not btn.disabled:
		btn.grab_focus()
