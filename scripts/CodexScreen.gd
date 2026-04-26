# ==============================================================================
#  FILE:        CodexScreen.gd
#  PATH:        res://scripts/CodexScreen.gd
#  ATTACHED TO: res://scenes/CodexScreen.tscn  (or the codex tab node)
#
#  DEPENDENCIES: CodexManager (autoload)
#
#  DESCRIPTION:
#    Displays the lore codex — a collection of lore entries that unlock
#    one at a time as the player completes runs (death or day-30 finish).
#    Entries are read from res://data/codex_lore.txt via CodexManager.
#    The screen rebuilds its entry list every time it opens so it always
#    reflects the current completion count and lore file contents.
#
#    UI layout (built entirely in code — no .tscn dependency):
#      • Dark background + centered parchment panel
#      • Title: "CODEX"
#      • Progress line: "3 / 47 entries revealed"
#      • Scrollable list of unlocked lore entries, numbered
#      • Locked placeholder shown if zero entries revealed
#      • Back button; L1/R1 cycle tabs if inside a TabContainer
#      • Escape / ui_cancel fires Back
#
#  ADJUSTABLE SETTINGS:
#    main_menu_scene   — scene to return to when Back is pressed
#    PARCHMENT_PATH    — texture used for the background panel
#    ENTRY_FONT_SIZE   — font size for individual lore lines
#    TITLE_FONT_SIZE   — font size for the "CODEX" heading
#
#  MOD NOTES:
#    • To add lore entries, append lines to res://data/codex_lore.txt.
#    • The screen always reads live data — no restart required after
#      editing the lore file.
#    • Styling constants (COL_*) match the rest of the game's UI palette.
# ==============================================================================
extends Control

# ── Navigation ─────────────────────────────────────────────────────────────────
@export var main_menu_scene : String = "res://scenes/MainMenu.tscn"

# ── Asset paths ────────────────────────────────────────────────────────────────
const PARCHMENT_PATH   : String = "res://Music & background images/parchment.jpeg"

# ── Font sizes ─────────────────────────────────────────────────────────────────
const TITLE_FONT_SIZE  : int = 30
const PROGRESS_FONT_SIZE : int = 14
const ENTRY_FONT_SIZE  : int = 15
const EMPTY_FONT_SIZE  : int = 15

# ── Colour palette — matches AlchemistStore / OptionsScreen ───────────────────
const COL_BG          := Color(0.07, 0.07, 0.09, 0.98)
const COL_TITLE       := Color(0.85, 0.70, 0.40, 1.0)   # Warm gold
const COL_PROGRESS    := Color(0.55, 0.50, 0.40, 1.0)   # Muted parchment
const COL_ENTRY_NUM   := Color(0.70, 0.55, 0.25, 1.0)   # Entry number accent
const COL_ENTRY_TEXT  := Color(0.18, 0.12, 0.06, 1.0)   # Dark ink on parchment
const COL_EMPTY       := Color(0.50, 0.42, 0.30, 0.75)  # Greyed placeholder
const COL_COMPLETE    := Color(0.40, 0.72, 0.45, 1.0)   # Green completion badge
const COL_SEPARATOR   := Color(0.60, 0.48, 0.28, 0.40)  # Faint divider line

# ── Built node references — cached in _ready() ────────────────────────────────
var _back_btn       : Button          = null
var _scroll         : ScrollContainer = null
var _entry_list     : VBoxContainer   = null
var _progress_label : Label           = null


# ══════════════════════════════════════════════════════════════════════════════
#  BOOT
# ══════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	# Clear any stale children from the .tscn (placeholder nodes).
	for child in get_children():
		remove_child(child)
		child.queue_free()

	_build_ui()
	_populate_entries()

	# Give focus to the back button so gamepad works immediately.
	if _back_btn != null:
		_back_btn.call_deferred("grab_focus")


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_go_back()


# ══════════════════════════════════════════════════════════════════════════════
#  UI CONSTRUCTION — built entirely in code
# ══════════════════════════════════════════════════════════════════════════════

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	# Dark full-screen background.
	var bg := ColorRect.new()
	bg.color = COL_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# Centred parchment panel — same approach as AlchemistStore.
	var panel := Panel.new()
	panel.anchor_left   = 0.10
	panel.anchor_top    = 0.04
	panel.anchor_right  = 0.90
	panel.anchor_bottom = 0.96
	panel.offset_left   = 0.0
	panel.offset_top    = 0.0
	panel.offset_right  = 0.0
	panel.offset_bottom = 0.0
	add_child(panel)

	# Parchment texture as panel stylebox.
	var parchment_tex : Texture2D = load(PARCHMENT_PATH) if \
		ResourceLoader.exists(PARCHMENT_PATH) else null
	var sb : StyleBox = StyleBoxTexture.new() if parchment_tex != null else StyleBoxFlat.new()
	if sb is StyleBoxTexture:
		(sb as StyleBoxTexture).texture = parchment_tex
	else:
		(sb as StyleBoxFlat).bg_color = Color(0.88, 0.80, 0.62, 1.0)
	panel.add_theme_stylebox_override("panel", sb)

	# Outer margin container inside the panel.
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left",   28)
	margin.add_theme_constant_override("margin_right",  28)
	margin.add_theme_constant_override("margin_top",    20)
	margin.add_theme_constant_override("margin_bottom", 20)
	panel.add_child(margin)

	# Root vertical layout.
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	# ── Title ────────────────────────────────────────────────────────────────
	var title := Label.new()
	title.text = "CODEX"
	title.add_theme_font_size_override("font_size", TITLE_FONT_SIZE)
	title.add_theme_color_override("font_color", COL_TITLE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# Title underline.
	var underline := ColorRect.new()
	underline.color                = COL_TITLE
	underline.custom_minimum_size  = Vector2(0, 1)
	underline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(underline)

	# ── Progress label (populated in _populate_entries) ───────────────────────
	_progress_label = Label.new()
	_progress_label.add_theme_font_size_override("font_size", PROGRESS_FONT_SIZE)
	_progress_label.add_theme_color_override("font_color", COL_PROGRESS)
	_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_progress_label)

	# ── Scrollable entry area ─────────────────────────────────────────────────
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical           = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode        = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode          = ScrollContainer.SCROLL_MODE_AUTO
	vbox.add_child(_scroll)

	_entry_list = VBoxContainer.new()
	_entry_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_entry_list.add_theme_constant_override("separation", 6)
	_scroll.add_child(_entry_list)

	# ── Spacer before back button ─────────────────────────────────────────────
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	vbox.add_child(spacer)

	# ── Back button ───────────────────────────────────────────────────────────
	_back_btn = Button.new()
	_back_btn.text = "← Back"
	_back_btn.custom_minimum_size = Vector2(160, 40)
	_back_btn.add_theme_font_size_override("font_size", 15)
	_back_btn.pressed.connect(_go_back)
	var btn_wrap := CenterContainer.new()
	btn_wrap.add_child(_back_btn)
	vbox.add_child(btn_wrap)


# ══════════════════════════════════════════════════════════════════════════════
#  ENTRY POPULATION — reads live from CodexManager
# ══════════════════════════════════════════════════════════════════════════════

# Clears and rebuilds the entry list from the current CodexManager state.
# Called once in _ready(). If you want the screen to refresh while open
# (e.g. after a background run ends), call this again.
func _populate_entries() -> void:
	# Clear existing entries.
	for child in _entry_list.get_children():
		_entry_list.remove_child(child)
		child.queue_free()

	# Guard: CodexManager must be present.
	if not has_node("/root/CodexManager"):
		push_warning("CodexScreen: CodexManager autoload not found.")
		_show_empty_state("CodexManager not loaded.")
		return

	var unlocked : Array[String] = CodexManager.get_unlocked_entries()
	var total    : int           = CodexManager.get_total_lore_count()
	var count    : int           = unlocked.size()

	# ── Progress line ─────────────────────────────────────────────────────────
	if total > 0:
		if CodexManager.is_codex_complete():
			_progress_label.text = "Codex complete — all %d entries revealed." % total
			_progress_label.add_theme_color_override("font_color", COL_COMPLETE)
		else:
			_progress_label.text = "%d / %d entr%s revealed" % [
				count, total, "y" if count == 1 else "ies"]
			_progress_label.add_theme_color_override("font_color", COL_PROGRESS)
	else:
		_progress_label.text = "No lore file found."
		_progress_label.add_theme_color_override("font_color", COL_PROGRESS)

	# ── Zero entries — placeholder prompt ────────────────────────────────────
	if count == 0:
		_show_empty_state("Complete your first run to reveal the first entry.")
		return

	# ── Render each unlocked entry ────────────────────────────────────────────
	for i in range(count):
		_add_entry(i + 1, unlocked[i])   # 1-indexed for display

		# Faint separator between entries (skip after the last one).
		if i < count - 1:
			var sep := ColorRect.new()
			sep.color                = COL_SEPARATOR
			sep.custom_minimum_size  = Vector2(0, 1)
			sep.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_entry_list.add_child(sep)

	# ── "Codex Complete" badge at the bottom ──────────────────────────────────
	if CodexManager.is_codex_complete():
		var complete_lbl := Label.new()
		complete_lbl.text = "✦ The codex is complete. ✦"
		complete_lbl.add_theme_font_size_override("font_size", PROGRESS_FONT_SIZE)
		complete_lbl.add_theme_color_override("font_color", COL_COMPLETE)
		complete_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_entry_list.add_child(complete_lbl)


# Adds a single numbered lore entry row to the list.
func _add_entry(number: int, text: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_entry_list.add_child(row)

	# Entry number — right-aligned in a fixed-width column.
	var num_lbl := Label.new()
	num_lbl.text                  = "%d." % number
	num_lbl.custom_minimum_size.x = 32.0
	num_lbl.add_theme_font_size_override("font_size", ENTRY_FONT_SIZE)
	num_lbl.add_theme_color_override("font_color", COL_ENTRY_NUM)
	num_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_RIGHT
	num_lbl.vertical_alignment    = VERTICAL_ALIGNMENT_TOP
	row.add_child(num_lbl)

	# Entry text — wraps across multiple lines if needed.
	var text_lbl := Label.new()
	text_lbl.text                   = text
	text_lbl.add_theme_font_size_override("font_size", ENTRY_FONT_SIZE)
	text_lbl.add_theme_color_override("font_color", COL_ENTRY_TEXT)
	text_lbl.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	text_lbl.autowrap_mode          = TextServer.AUTOWRAP_WORD_SMART
	text_lbl.vertical_alignment     = VERTICAL_ALIGNMENT_TOP
	row.add_child(text_lbl)


# Displays a centred italic placeholder message when nothing is unlocked yet.
func _show_empty_state(message: String) -> void:
	var lbl := Label.new()
	lbl.text                    = message
	lbl.add_theme_font_size_override("font_size", EMPTY_FONT_SIZE)
	lbl.add_theme_color_override("font_color", COL_EMPTY)
	lbl.horizontal_alignment    = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment      = VERTICAL_ALIGNMENT_CENTER
	lbl.size_flags_horizontal   = Control.SIZE_EXPAND_FILL
	lbl.size_flags_vertical     = Control.SIZE_EXPAND_FILL
	lbl.autowrap_mode           = TextServer.AUTOWRAP_WORD_SMART
	_entry_list.add_child(lbl)


# ══════════════════════════════════════════════════════════════════════════════
#  NAVIGATION
# ══════════════════════════════════════════════════════════════════════════════

func _go_back() -> void:
	get_tree().change_scene_to_file(main_menu_scene)
