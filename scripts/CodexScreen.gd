# ==============================================================================
#  FILE:        CodexScreen.gd
#  PATH:        res://scripts/CodexScreen.gd
#  ATTACHED TO: res://scenes/CodexScreen.tscn
#
#  DEPENDENCIES: CodexManager (autoload), PUI (docs/UI_DESIGN_SYSTEM.md)
#
#  DESCRIPTION:
#    Displays the lore codex - lore entries that unlock one at a time as the player completes runs
#    (death or day-30 finish). Entries come from res://data/codex_lore.txt via CodexManager. The
#    screen rebuilds its entry list every time it opens, so it always reflects the current
#    completion count and lore file contents.
#
#    Layout (built in code, no .tscn dependency): the void background, one parchment page held to a
#    readable column (max ~900 px) with the title in the display face over a brass rule, a progress
#    line + meter, a scrolling list of unlocked entries ("Entry N" + text), the next entry shown
#    sealed, and an iron Back button beneath the page. Escape / ui_cancel fires Back.
#
#  MOD NOTES:
#    - To add lore entries, append lines to res://data/codex_lore.txt.
#    - The screen always reads live data - no restart required after editing the lore file.
#    - Wording of the progress/empty lines is unchanged by the visual pass.
# ==============================================================================
extends Control

# -- Navigation -----------------------------------------------------------------
@export var main_menu_scene : String = "res://scenes/MainMenu.tscn"

# -- Layout ---------------------------------------------------------------------
const MAX_PAGE_WIDTH : float = 960.0   # page incl. its padding: ~900 px of readable text

# -- Built node references - cached in _ready() ---------------------------------
var _margin         : MarginContainer = null
var _back_btn       : Button          = null
var _scroll         : ScrollContainer = null
var _entry_list     : VBoxContainer   = null
var _progress_label : Label           = null
var _meter          : ProgressBar     = null


# ══════════════════════════════════════════════════════════════════════════════
#  BOOT
# ══════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	# The dungeon captures the mouse; make sure menus are clickable after leaving it.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Clear any stale children from the .tscn (placeholder nodes).
	for child in get_children():
		remove_child(child)
		child.queue_free()

	_build_ui()
	_populate_entries()
	resized.connect(_apply_margins)
	_apply_margins()

	# Give focus to the back button so gamepad works immediately.
	if _back_btn != null:
		_back_btn.call_deferred("grab_focus")
	if has_node("/root/AudioManager"):
		AudioManager.wire_click_sounds(self)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_go_back()


# Phone-safe margins on touch; on wide windows the page is a centred column, never edge to edge.
func _apply_margins() -> void:
	if _margin == null:
		return
	var touch: bool = TouchControls.is_touch_platform()
	var side: float = float(PUI.S6 + PUI.S2) if touch else float(PUI.SCREEN_MARGIN)
	side = maxf(side, (size.x - MAX_PAGE_WIDTH) * 0.5)
	var vert: float = float(PUI.S3) if touch else float(PUI.S5)
	_margin.add_theme_constant_override("margin_left", int(side))
	_margin.add_theme_constant_override("margin_right", int(side))
	_margin.add_theme_constant_override("margin_top", int(vert))
	_margin.add_theme_constant_override("margin_bottom", int(vert))


# ══════════════════════════════════════════════════════════════════════════════
#  UI CONSTRUCTION
# ══════════════════════════════════════════════════════════════════════════════

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(PUI.background("void"))

	var touch: bool = TouchControls.is_touch_platform()
	_margin = MarginContainer.new()
	_margin.name = "Margin"
	_margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", PUI.S3 if touch else PUI.S4)
	_margin.add_child(column)

	# The page.
	var page := PUI.paper_panel(Vector2(PUI.S6 + PUI.S2, PUI.S5 if touch else PUI.S5 + PUI.S1))
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(page)

	var page_v := VBoxContainer.new()
	page_v.add_theme_constant_override("separation", PUI.S2 if touch else PUI.S3)
	page.add_child(page_v)

	var title := PUI.label("Codex", "ParchmentTitle")
	title.name = "Title"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	page_v.add_child(title)
	page_v.add_child(PUI.divider())

	_progress_label = PUI.label("", "ParchmentBody")
	_progress_label.name = "ProgressLabel"
	_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_progress_label.add_theme_color_override("font_color", PUI.INK_DIM)
	page_v.add_child(_progress_label)

	_meter = ProgressBar.new()
	_meter.name = "ProgressMeter"
	_meter.show_percentage = false
	_meter.custom_minimum_size = Vector2(0, 10)
	_meter.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	page_v.add_child(_meter)

	# Scrollable entry area (drag-scrolls on touch: nothing inside it blocks the pointer).
	_scroll = ScrollContainer.new()
	_scroll.name = "EntryScroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	page_v.add_child(_scroll)

	_entry_list = VBoxContainer.new()
	_entry_list.name = "EntryList"
	_entry_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_entry_list.add_theme_constant_override("separation", PUI.S3)
	_scroll.add_child(_entry_list)

	# Back: an iron NavButton under the page (it stays iron on paper).
	_back_btn = PUI.button("Back", "nav")
	_back_btn.name = "BackButton"
	_back_btn.custom_minimum_size = Vector2(280, PUI.BUTTON_H)
	_back_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_back_btn.pressed.connect(_go_back)
	PUI.button_chevron(_back_btn, "chevron_left")
	column.add_child(_back_btn)


# ══════════════════════════════════════════════════════════════════════════════
#  ENTRY POPULATION - reads live from CodexManager
# ══════════════════════════════════════════════════════════════════════════════

# Clears and rebuilds the entry list from the current CodexManager state.
func _populate_entries() -> void:
	for child in _entry_list.get_children():
		_entry_list.remove_child(child)
		child.queue_free()

	# Guard: CodexManager must be present.
	if not has_node("/root/CodexManager"):
		push_warning("CodexScreen: CodexManager autoload not found.")
		_meter.visible = false
		_show_empty_state("CodexManager not loaded.")
		return

	var unlocked : Array[String] = CodexManager.get_unlocked_entries()
	var total    : int           = CodexManager.get_total_lore_count()
	var count    : int           = unlocked.size()

	# -- Progress line + meter ----------------------------------------------------
	_meter.visible = total > 0
	_meter.max_value = maxf(1.0, float(total))
	_meter.value = float(count)
	if total > 0:
		if CodexManager.is_codex_complete():
			_progress_label.text = "Codex complete — all %d entries revealed." % total
			_progress_label.add_theme_color_override("font_color", PUI.color("INK"))
		else:
			_progress_label.text = "%d / %d entr%s revealed" % [
				count, total, "y" if count == 1 else "ies"]
			_progress_label.add_theme_color_override("font_color", PUI.INK_DIM)
	else:
		_progress_label.text = "No lore file found."
		_progress_label.add_theme_color_override("font_color", PUI.INK_DIM)

	# -- Zero entries - placeholder prompt ----------------------------------------
	if count == 0:
		_show_empty_state("Complete your first run to reveal the first entry.")
		return

	# -- Each unlocked entry -------------------------------------------------------
	for i in range(count):
		_add_entry(i + 1, unlocked[i])   # 1-indexed for display
		if i < count - 1:
			_add_rule()

	# -- What is still sealed ------------------------------------------------------
	if count < total:
		_add_rule()
		_add_sealed(count + 1, total - count)
	elif CodexManager.is_codex_complete():
		_add_rule()
		var done := PUI.label("The codex is complete.", "ParchmentHeading")
		done.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_entry_list.add_child(done)


# A faint brass rule between entries.
func _add_rule() -> void:
	var rule := PUI.divider()
	rule.modulate = Color(1, 1, 1, 0.45)
	_entry_list.add_child(rule)


# Adds a single lore entry: "Entry N" (display face) over its text.
func _add_entry(number: int, text: String) -> void:
	var box := VBoxContainer.new()
	box.name = "Entry_%d" % number
	box.add_theme_constant_override("separation", PUI.S1)
	_entry_list.add_child(box)

	var head := PUI.label("Entry %d" % number, "ParchmentCardTitle")
	box.add_child(head)

	var body := PUI.label(text, "ParchmentBody")
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(body)


# The next entry, sealed: a dim slip with an hourglass, plus how many more lie beyond it.
func _add_sealed(next_number: int, remaining: int) -> void:
	var slip := PanelContainer.new()
	slip.name = "SealedEntry"
	slip.mouse_filter = Control.MOUSE_FILTER_PASS
	var sb: StyleBoxTexture = PUI.paper_slip("dim")
	sb.content_margin_left = PUI.S4
	sb.content_margin_right = PUI.S4
	sb.content_margin_top = PUI.S3
	sb.content_margin_bottom = PUI.S3
	slip.add_theme_stylebox_override("panel", sb)
	_entry_list.add_child(slip)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", PUI.S4)
	slip.add_child(row)
	var icon := PUIIcon.make("hourglass", 36.0, PUI.INK_DIM)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(icon)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(col)
	var head := PUI.label("Entry %d — sealed" % next_number, "ParchmentCardTitle")
	head.add_theme_color_override("font_color", PUI.ink_muted())
	col.add_child(head)
	var more := "Complete a run to reveal it." if remaining <= 1 else \
		"Complete a run to reveal it. %d entries remain sealed." % remaining
	var body := PUI.label(more, "ParchmentBody")
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_color_override("font_color", PUI.INK_DIM)
	col.add_child(body)


# A deliberate empty state: an iron medallion with an hourglass over the message.
func _show_empty_state(message: String) -> void:
	var box := VBoxContainer.new()
	box.name = "EmptyState"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", PUI.S4)
	_entry_list.add_child(box)
	_entry_list.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var medal := PanelContainer.new()
	medal.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var sb: StyleBoxTexture = PUI.box(PUI.IRON, PUI.EDGE_BRASS, PUI.IRON.darkened(0.12), 0.08, 0.32, 0.016)
	sb.content_margin_left = PUI.S5
	sb.content_margin_right = PUI.S5
	sb.content_margin_top = PUI.S5
	sb.content_margin_bottom = PUI.S5
	medal.add_theme_stylebox_override("panel", sb)
	medal.add_child(PUIIcon.make("hourglass", 72.0))
	box.add_child(medal)

	var lbl := PUI.label(message, "ParchmentCardTitle")
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(lbl)


# ══════════════════════════════════════════════════════════════════════════════
#  NAVIGATION
# ══════════════════════════════════════════════════════════════════════════════

func _go_back() -> void:
	get_tree().change_scene_to_file(main_menu_scene)
