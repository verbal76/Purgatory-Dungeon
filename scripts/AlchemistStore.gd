# ==============================================================================
# File Name: AlchemistStore.gd
# Path: res://scripts/AlchemistStore.gd
# Description: The Alchemist's Lab - the perk ledger, on the Purgatory design system
#              (docs/UI_DESIGN_SYSTEM.md). A parchment sheet (PUI.paper_panel) on the void background,
#              upgrade slips of paper with iron/brass buttons, and a bottom bar of iron controls:
#                  [ Load Character ]       [ < 1 / 2 > ]       [ Start Another Run ]
#              Perks per page: 9 (3x3) on desktop, 6 (3x2) on touch - see perks_per_page().
#
#  MOD NOTES:
#  - "Sanctuary" was renamed "Hare's Delight"; save key "sanctuary" is preserved.
#  - Mechanics (costs, caps, requirements, the single-write purchase) are untouched by the visual pass.
#  - Test hooks kept: visible_perks(), perks_per_page(), _purchase_perk(), _start_new_run(), and the
#    nodes UpgradeBtn_<key>, LoadCharacterButton, StartAnotherRunButton.
# ==============================================================================
extends Control

@export var character_selection_scene : String = "res://scenes/CharacterSelection.tscn"
const DUNGEON_SCENE    : String = "res://scenes/Purgatory_Dungeon_main_game_file.tscn"
const PERKS_PER_PAGE   : int    = 9
const PERKS_PER_PAGE_PHONE : int = 6   # 3x2: thumb-sized Trade buttons need the room
const CARD_MIN_SIZE    : Vector2 = Vector2(210, 138)
const MAX_SHEET_WIDTH  : float  = 1560.0   # the ledger never stretches across an ultra-wide window

# Built in code (the scene is only the root + this script).
var currency_label : Label         = null   # "Potions Stashed"
var grid           : GridContainer = null   # PerkGrid

# -- Pagination state -----------------------------------------------------------
var _current_page  : int = 0
var _total_pages   : int = 1

# -- Nodes built in code ---------------------------------------------------------
var _margin          : MarginContainer = null
var _parchment_panel : PanelContainer  = null   # the ledger sheet ("ParchmentPanel")
var _scroll          : ScrollContainer = null
var _count_label     : Label           = null   # the potion count (HudValue, ember)
var _page_label      : Label           = null
var _prev_btn        : Button          = null
var _next_btn        : Button          = null
var _prev_icon       : PUIIcon         = null
var _next_icon       : PUIIcon         = null
var _nav_bar         : HBoxContainer   = null
var _load_char_btn   : Button          = null
var _new_run_btn     : Button          = null
var _back_btn        : Button          = null   # hidden legacy button (old scenes)

var perks_def : Array = [
	{"key": "magnitude",   "name": "Magnitude",      "desc": "Dome Radius +10%", "desc_mage": "+2 Dome Bolts", "desc_barbarian": "AOE Blast Radius +10%"},
	{"key": "persistence", "name": "Persistence",    "desc": "Dome Duration +15%", "desc_mage": "Spell Range +15%", "hide_for": ["barbarian"]},
	{"key": "vitality",    "name": "Vitality",        "desc": "Max Health +10"},
	{"key": "adrenaline",  "name": "Adrenaline",      "desc": "Attack Speed +8%"},
	{"key": "ferocity",    "name": "Ferocity",         "desc": "Attack Damage +10%"},
	{"key": "scavenge",    "name": "Scavenge",         "desc": "Potion Drop Rate +3%"},
	{"key": "greed",       "name": "Greed",            "desc": "Double Drop Chance +5%"},
	{"key": "swiftness",   "name": "Swiftness",        "desc": "Move Speed +5%"},
	{"key": "health_regen","name": "Regeneration",     "desc": "+0.5 HP/sec per level"},
	{"key": "cyclone",     "name": "Cyclone",          "desc": "+0.5s Rapid Attack / -3s Cooldown"},
	{"key": "trap_sense",  "name": "Trap Sense",       "desc": "Each level adds 25% chance a trap glows red — requires 5 runs"},
]


func perks_per_page() -> int:
	return PERKS_PER_PAGE_PHONE if TouchControls.is_touch_platform() else PERKS_PER_PAGE


func _ready() -> void:
	# The dungeon captures the mouse; make sure menus are clickable after leaving it.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_total_pages = maxi(1, int(ceil(float(visible_perks().size()) / float(perks_per_page()))))
	_hide_legacy_back_button()
	_build_parchment()
	_build_nav_buttons()
	_update_ui()
	_update_page_controls()
	if _load_char_btn:
		_load_char_btn.call_deferred("grab_focus")
	_wire_button_clicks()
	resized.connect(_apply_margins)
	_apply_margins()


# ══════════════════════════════════════════════════════════════
#  LEDGER SHEET
# ══════════════════════════════════════════════════════════════

func _wire_button_clicks() -> void:
	if has_node("/root/AudioManager"):
		AudioManager.wire_click_sounds(self)


# Screen margins: phone-safe on touch, a roomy 48 on desktop, and the sheet is held to a readable
# maximum width on very wide windows.
func _apply_margins() -> void:
	if _margin == null:
		return
	var touch: bool = TouchControls.is_touch_platform()
	var side: float = float(PUI.S6 + PUI.S2) if touch else float(PUI.SCREEN_MARGIN)
	side = maxf(side, (size.x - MAX_SHEET_WIDTH) * 0.5)
	var vert: float = float(PUI.S3) if touch else float(PUI.S5)
	_margin.add_theme_constant_override("margin_left", int(side))
	_margin.add_theme_constant_override("margin_right", int(side))
	_margin.add_theme_constant_override("margin_top", int(vert))
	_margin.add_theme_constant_override("margin_bottom", int(vert))


func _build_parchment() -> void:
	# The scene is only the root + script: everything is built here on the shared design system.
	add_child(PUI.background("void"))

	_margin = MarginContainer.new()
	_margin.name = "Margin"
	_margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_margin)

	var touch: bool = TouchControls.is_touch_platform()
	var root_v := VBoxContainer.new()
	root_v.name = "MainLayout"
	root_v.add_theme_constant_override("separation", PUI.S3 if touch else PUI.S4)
	_margin.add_child(root_v)

	# The paper ledger (parchment.jpeg, toned once by PUI.paper_box).
	_parchment_panel = PUI.paper_panel(Vector2(PUI.S6, PUI.S5 if touch else PUI.S5 + PUI.S1))
	_parchment_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_parchment_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_v.add_child(_parchment_panel)

	var sheet_v := VBoxContainer.new()
	sheet_v.add_theme_constant_override("separation", PUI.S3)
	_parchment_panel.add_child(sheet_v)

	# Header: title on the left, the iron potion plate on the right.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", PUI.S4)
	sheet_v.add_child(header)

	var title := PUI.label("The Alchemist's Lab", "ParchmentTitle")
	title.name = "Title"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.clip_text = true
	header.add_child(title)

	header.add_child(_build_potion_plate())
	sheet_v.add_child(PUI.divider())

	# Perk grid inside a scroller: nothing is ever clipped on a short or narrow window.
	_scroll = ScrollContainer.new()
	_scroll.name = "PerkScroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.follow_focus = true
	sheet_v.add_child(_scroll)

	grid = GridContainer.new()
	grid.name = "PerkGrid"
	grid.columns = 3
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", PUI.CARD_GAP)
	grid.add_theme_constant_override("v_separation", PUI.CARD_GAP)
	_scroll.add_child(grid)
	_scroll.resized.connect(_fit_grid_to_scroll)


# Keeps the card rows filling the sheet when there is room (they scroll when there is not).
func _fit_grid_to_scroll() -> void:
	if grid == null or _scroll == null:
		return
	var h: float = maxf(0.0, _scroll.size.y)
	if absf(grid.custom_minimum_size.y - h) > 0.5:
		grid.custom_minimum_size.y = h


# The "Potions Stashed" plate: a small iron plate, bone potion icon, dim label, ember count.
func _build_potion_plate() -> PanelContainer:
	var plate := PanelContainer.new()
	plate.name = "PotionPlate"
	var sb: StyleBoxTexture = PUI.box(PUI.IRON, PUI.EDGE_BRASS, PUI.IRON.darkened(0.12), 0.08, 0.32, 0.016)
	sb.content_margin_left = PUI.S4
	sb.content_margin_right = PUI.S4
	sb.content_margin_top = PUI.S2
	sb.content_margin_bottom = PUI.S2
	plate.add_theme_stylebox_override("panel", sb)
	plate.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", PUI.S3)
	plate.add_child(row)

	var icon := PUIIcon.make("potion", 40.0 if TouchControls.is_touch_platform() else 34.0)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(icon)

	currency_label = PUI.label("Potions Stashed", "HudLabel")
	currency_label.name = "CurrencyLabel"
	currency_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(currency_label)

	_count_label = PUI.label("0", "HudValue")
	_count_label.name = "PotionCount"
	_count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_count_label.add_theme_color_override("font_color", PUI.EMBER_BRIGHT)
	_count_label.add_theme_font_size_override("font_size", PUI.fs("card_title"))
	row.add_child(_count_label)
	return plate


# ══════════════════════════════════════════════════════════════
#  NAV BAR (iron controls on the void, below the sheet)
# ══════════════════════════════════════════════════════════════

func _build_nav_buttons() -> void:
	var root_v := _parchment_panel.get_parent() as VBoxContainer
	_nav_bar = HBoxContainer.new()
	_nav_bar.name = "NavBar"
	_nav_bar.add_theme_constant_override("separation", PUI.S4)
	root_v.add_child(_nav_bar)

	_load_char_btn = PUI.button("Load Character", "nav")
	_load_char_btn.name = "LoadCharacterButton"
	_load_char_btn.custom_minimum_size = Vector2(280, PUI.BUTTON_H)
	_load_char_btn.pressed.connect(_go_to_character_selection)
	PUI.button_chevron(_load_char_btn, "chevron_left")
	_nav_bar.add_child(_load_char_btn)

	_nav_bar.add_child(_expander())

	# Pager: [<]  1 / 2  [>]
	_prev_btn = PUI.button("", "nav")
	_prev_btn.name = "PrevPageButton"
	_prev_btn.custom_minimum_size = Vector2(PUI.BUTTON_H, PUI.BUTTON_H)
	_prev_btn.pressed.connect(_on_prev_page)
	_prev_icon = PUI.button_chevron(_prev_btn, "chevron_left", true)
	_nav_bar.add_child(_prev_btn)

	_page_label = PUI.label("1 / 1", "SecondaryLabel")
	_page_label.name = "PageLabel"
	_page_label.custom_minimum_size.x = 96.0
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_nav_bar.add_child(_page_label)

	_next_btn = PUI.button("", "nav")
	_next_btn.name = "NextPageButton"
	_next_btn.custom_minimum_size = Vector2(PUI.BUTTON_H, PUI.BUTTON_H)
	_next_btn.pressed.connect(_on_next_page)
	_next_icon = PUI.button_chevron(_next_btn, "chevron_right", true)
	_nav_bar.add_child(_next_btn)

	_nav_bar.add_child(_expander())

	_new_run_btn = PUI.button("Start Another Run", "primary")
	_new_run_btn.name = "StartAnotherRunButton"
	_new_run_btn.custom_minimum_size = Vector2(280, PUI.BUTTON_H_PRIMARY)
	_new_run_btn.pressed.connect(_start_new_run)
	PUI.button_chevron(_new_run_btn, "chevron_right")
	_nav_bar.add_child(_new_run_btn)

	if TouchControls.is_touch_platform():
		_fit_nav_for_phone()
		_fit_pager_for_phone()


func _expander() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


# Phones: a 72-high bottom bar with wider buttons. The ledger takes the remaining height.
func _fit_nav_for_phone() -> void:
	for b in [_load_char_btn, _new_run_btn]:
		b.custom_minimum_size = Vector2(320, 72)


func _fit_pager_for_phone() -> void:
	for b in [_prev_btn, _next_btn]:
		b.custom_minimum_size = Vector2(72, 72)
	_page_label.custom_minimum_size.x = 110.0


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
		_reset_scroll()


func _on_next_page() -> void:
	if _current_page < _total_pages - 1:
		_current_page += 1
		_update_ui()
		_update_page_controls()
		_reset_scroll()


func _reset_scroll() -> void:
	if _scroll != null:
		_scroll.scroll_vertical = 0


func _update_page_controls() -> void:
	if _page_label != null:
		_page_label.text = "%d / %d" % [_current_page + 1, _total_pages]
	if _prev_btn != null:
		_prev_btn.disabled = (_current_page == 0)
		_prev_icon.tint = PUI.BONE_FAINT if _prev_btn.disabled else PUI.BONE_DIM
	if _next_btn != null:
		_next_btn.disabled = (_current_page >= _total_pages - 1)
		_next_icon.tint = PUI.BONE_FAINT if _next_btn.disabled else PUI.BONE_DIM
	# a pager arrow that just went dead must not strand the gamepad focus
	if _prev_btn != null and _prev_btn.disabled and _prev_btn.has_focus() and not _next_btn.disabled:
		_next_btn.grab_focus()
	elif _next_btn != null and _next_btn.disabled and _next_btn.has_focus() and not _prev_btn.disabled:
		_prev_btn.grab_focus()


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
		RunLifecycle.grant_starter_potion()
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
		if _count_label != null:
			_count_label.text = ""
		return

	var profile      = SaveManager.current_profile
	var potion_count = int(profile.get("meta_currency", 0))
	if currency_label != null:
		currency_label.text = "Potions Stashed"
	if _count_label != null:
		_count_label.text = str(potion_count)

	if grid == null:
		return

	# Clear previous cards — remove_child first so find_child can't return a
	# dying node when _refocus_perk_btn runs in the same deferred call.
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()

	var user_perks : Dictionary = profile.get("perks", {})
	var run_count  : int        = int(profile.get("run_count", 0))

	var shown : Array = visible_perks()
	var per_page : int = perks_per_page()
	var page_start : int = _current_page * per_page
	var page_end   : int = mini(page_start + per_page, shown.size())

	for i in range(page_start, page_end):
		var entry  : Dictionary = shown[i]
		var key    : String     = entry["key"]
		var lv     : int        = int(user_perks.get(key, 0))
		var locked : bool       = (key == "trap_sense" and run_count < 5)
		_create_perk_card(key, entry, lv, locked)

	# Empty cells keep the 3-column rhythm on the last page (a lone card must not stretch to fill the sheet).
	for _i in range(page_end - page_start, per_page):
		var gap := Control.new()
		gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		gap.size_flags_vertical = Control.SIZE_EXPAND_FILL
		grid.add_child(gap)


# One upgrade slip: title + level, effect, and the iron "Trade" button. States (never colour only):
#   can afford -> ember edge, warm base, live PrimaryButton;
#   cannot     -> greyer slip, dimmed ink, the button disabled and "Need N more potions" spelled out;
#   locked     -> the same dim slip, "Locked" and the requirement.
func _create_perk_card(key: String, data: Dictionary, lv: int, locked: bool) -> void:
	var potions : int  = int(SaveManager.current_profile.get("meta_currency", 0))
	var cost    : int  = _calculate_cost(lv)
	var can_buy : bool = (not locked) and potions >= cost
	var dim     : bool = not can_buy

	var panel := PanelContainer.new()
	panel.name = "PerkCard_" + key
	panel.custom_minimum_size = CARD_MIN_SIZE
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	panel.mouse_filter = Control.MOUSE_FILTER_PASS   # lets a finger drag the list scroll
	var sb: StyleBoxTexture = PUI.paper_slip("dim" if dim else "active")
	sb.content_margin_left = PUI.S4
	sb.content_margin_right = PUI.S4
	sb.content_margin_top = PUI.S3
	sb.content_margin_bottom = PUI.S3
	panel.add_theme_stylebox_override("panel", sb)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", PUI.S2)
	panel.add_child(inner)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", PUI.S3)
	inner.add_child(head)

	var title := PUI.label(str(data["name"]), "ParchmentCardTitle")
	title.name = "Title"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.add_child(title)

	var level := PUI.label("Locked" if locked else "Level %d" % lv, "ParchmentHeading")
	level.name = "Level"
	level.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(level)

	var info := PUI.label("Requires 5 runs" if locked else _perk_desc(data), "ParchmentBody")
	info.name = "Effect"
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.size_flags_vertical = Control.SIZE_EXPAND_FILL
	info.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	inner.add_child(info)

	if dim:
		var muted: Color = PUI.ink_muted()
		title.add_theme_color_override("font_color", muted)
		info.add_theme_color_override("font_color", muted)
		level.add_theme_color_override("font_color", PUI.INK_DIM)

	if not locked and not can_buy:
		var need: int = cost - potions
		var short := PUI.label("Need %d more potion%s" % [need, "s" if need > 1 else ""], "ParchmentBody")
		short.name = "Shortfall"
		short.add_theme_color_override("font_color", PUI.INK_DIM)
		short.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		inner.add_child(short)

	var btn := PUI.button("", "primary")
	btn.name = "UpgradeBtn_" + key
	btn.custom_minimum_size.y = PUI.BUTTON_H
	if locked:
		btn.text     = "Locked"
		btn.disabled = true
	else:
		var cost_text := "Trade %d Potion%s" % [cost, "s" if cost > 1 else ""]
		btn.text = cost_text
		btn.disabled = not can_buy
		btn.pressed.connect(_on_upgrade_pressed.bind(key, cost))
	inner.add_child(btn)
	grid.add_child(panel)
	if has_node("/root/AudioManager"):
		AudioManager.wire_click_sounds(btn)


# The perks offered to the active character: perks with no effect for the class (`hide_for`) are
# not shown at all rather than sold as dead purchases.
func visible_perks() -> Array:
	var cls := str(SaveManager.get_character_class()) if SaveManager.current_profile_is_valid() else ""
	var out : Array = []
	for entry in perks_def:
		if not (cls in entry.get("hide_for", [])):
			out.append(entry)
	return out


# Perk text for the active character class when the perk works differently per class.
func _perk_desc(data: Dictionary) -> String:
	var cls := str(SaveManager.get_character_class()) if SaveManager.current_profile_is_valid() else ""
	return str(data.get("desc_" + cls, data["desc"]))


func _calculate_cost(lv: int) -> int:
	var base := int(pow(2, lv))
	if has_node("/root/GlobalRunData") and GlobalRunData.difficulty == "easy":
		return maxi(1, int(base * 0.8))   # 20% discount, minimum 1 potion
	return base


# Spends the potions and grants the perk level in one profile write, so a crash between two
# writes can never take the potions without granting the perk.
func _purchase_perk(key: String, cost: int) -> bool:
	if not PlayerWallet.spend_potions(cost, false):
		return false
	var profile = SaveManager.current_profile
	if not profile.has("perks"):
		profile["perks"] = {}
	profile["perks"][key] = int(profile["perks"].get(key, 0)) + 1
	SaveManager.save_profile()
	return true


func _on_upgrade_pressed(key: String, cost: int) -> void:
	if _purchase_perk(key, cost):
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


# Back to the card just bought. If it is now out of reach (disabled), fall to the next card that can
# still be bought, else the main action, so the gamepad never loses its place.
func _refocus_perk_btn(key: String) -> void:
	var btn := find_child("UpgradeBtn_" + key, true, false) as Button
	if btn != null and not btn.disabled:
		btn.grab_focus()
		return
	if grid != null:
		for b in grid.find_children("UpgradeBtn_*", "Button", true, false):
			if not (b as Button).disabled:
				(b as Button).grab_focus()
				return
	if _new_run_btn != null:
		_new_run_btn.grab_focus()
