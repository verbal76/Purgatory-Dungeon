# ============================================================
#  FILE: BuffManager.gd
#  PATH: res://autoloads/BuffManager.gd
#  ATTACHED TO: Autoload (BuffManager)
#  USED BY: GameClock.gd, global UI, player
#  DESCRIPTION: Fully self-contained buff pick and tracking system.
#  MOD NOTES: Added _handle_schizophrenia() hook to dynamically
#  attach/detach the auditory hallucination script to the player.
#  Also plays buff_choice_sound via AudioManager.
#  Rarity system: common / rare / legendary, shown as a text tag plus the card edge (PUI.rarity_card).
#  Weighted pick, slot-machine cycling display, slowdown-on-stop.
#
#  SLOT MACHINE CHANGE: Replaced the 2-choice card pick with a single
#  centered selector that cycles through the weighted perk pool like a
#  slot machine. Player presses A to stop; the selector slows down first,
#  then lands on the final perk and awards it.
# ============================================================

extends Node

# ── Signals ────────────────────────────────────────────────

signal buff_chosen(buff: Dictionary)
signal buff_expired(buff: Dictionary)

# ── File paths ─────────────────────────────────────────────

const BUFF_DATA_PATH : String = "res://data/buffs.json"

# ══════════════════════════════════════════════════════════
#  SLOT MACHINE TUNING
#  Adjust these to change the feel of the perk selector.
# ══════════════════════════════════════════════════════════

# How fast the selector cycles during the rolling phase (seconds per step).
# Lower = faster spin. 0.10 is readable but hard to snipe.
const PERK_CYCLE_START_SPEED : float = 0.10

# How fast the selector moves just before it stops (seconds per step).
# Higher = more noticeable slowdown.
const PERK_CYCLE_END_SPEED : float = 0.38

# Total seconds the slowdown phase lasts after A is pressed.
# Short enough not to feel annoying; long enough to feel deliberate.
const PERK_CYCLE_SLOWDOWN_DURATION : float = 1.4

# How long the winning perk is held on screen before the UI closes.
const PERK_CYCLE_VISUAL_HOLD_TIME : float = 0.7

# ── Card / slot UI layout ──────────────────────────────────
# Look comes from the shared design system (PUI): ScreenTitle / CardTitle / body / WarningLabel roles on an
# iron card whose edge carries the rarity (PUI.rarity_card). Only the geometry lives here.

const CARD_WIDTH         : float = 560.0
const CARD_HEIGHT        : float = 320.0
const TRADEOFF_PREFIX    : String = "Tradeoff: "

# ── Card animation ─────────────────────────────────────────

const CARD_ENTRY_DURATION  : float = 0.35
const CARD_ENTRY_OFFSET_Y  : float = 200.0
const CARD_EXIT_DURATION   : float = 0.35

# ── Rarity ─────────────────────────────────────────────────

# Weights: roughly common 10x, rare 4x, legendary 1x
const RARITY_WEIGHTS : Dictionary = { "common": 10, "rare": 4, "legendary": 1 }

# ── Buff HUD ───────────────────────────────────────────────

const HUD_WIDTH             : float = 280.0
const HUD_MARGIN_X          : float = 20.0
const HUD_START_Y           : float = 50.0
const HUD_LINE_SPACING      : float = 12.0
const COUNTDOWN_UPDATE_RATE : float = 0.5

# ── Slot machine states ────────────────────────────────────

enum SlotState { IDLE, ROLLING, SLOWING, AWARDING, DONE }

# ── Runtime state ──────────────────────────────────────────

var _buff_pool    : Array = []
var _active_buffs : Array = []

# Slot machine
var _slot_state   : SlotState = SlotState.IDLE
var _slot_pool    : Array     = []   # weighted entries shuffled
var _slot_index   : int       = 0
var _slot_timer   : float     = 0.0  # accumulator for cycle steps
var _slot_elapsed : float     = 0.0  # time spent in SLOWING state

# Live label/border refs — updated every cycle step
var _slot_name_label     : Label     = null
var _slot_desc_label     : Label     = null
var _slot_rarity_label   : Label     = null
var _slot_tradeoff_label : Label     = null
var _slot_panel          : PanelContainer = null
var _slot_rarity_key     : String    = ""
var _rarity_boxes        : Dictionary = {}   # rarity -> cached StyleBox (swapping them allocates nothing)

# UI containers (needed for entry animation + close)
var _ui_layer  : CanvasLayer = null
var _ui_root   : Control     = null

var _is_picking : bool = false

var _hud_layer         : CanvasLayer   = null
var _hud_container     : VBoxContainer = null
var _hud_dirty         : bool          = true
var _countdown_refresh : float         = 0.0
var _timed_labels      : Array         = []

# ── Lifecycle ──────────────────────────────────────────────

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_buff_data()
	GameClock.buff_pick_triggered.connect(_on_buff_pick_triggered)
	GameClock.day_changed.connect(_on_day_changed)
	_build_buff_hud()

func _load_buff_data() -> void:
	if not FileAccess.file_exists(BUFF_DATA_PATH):
		push_warning("BuffManager: buffs.json not found at %s" % BUFF_DATA_PATH)
		return
	var file   := FileAccess.open(BUFF_DATA_PATH, FileAccess.READ)
	var parsed  = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Array:
		_buff_pool.clear()
		for entry in parsed:
			if entry is Dictionary and entry.has("id"):
				_buff_pool.append(entry)
	else:
		push_warning("BuffManager: buffs.json failed to parse.")

# ══════════════════════════════════════════════════════════════
#  PROCESS
# ══════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	# ── Slot machine tick ──────────────────────────────────────
	if _is_picking:
		match _slot_state:
			SlotState.ROLLING:
				_slot_timer += delta
				if _slot_timer >= PERK_CYCLE_START_SPEED:
					_slot_timer -= PERK_CYCLE_START_SPEED
					_advance_slot()

			SlotState.SLOWING:
				_slot_elapsed += delta
				var t        : float = clampf(_slot_elapsed / PERK_CYCLE_SLOWDOWN_DURATION, 0.0, 1.0)
				var interval : float = lerpf(PERK_CYCLE_START_SPEED, PERK_CYCLE_END_SPEED, t)
				_slot_timer += delta
				if _slot_timer >= interval:
					_slot_timer -= interval
					_advance_slot()
				if _slot_elapsed >= PERK_CYCLE_SLOWDOWN_DURATION:
					_slot_state = SlotState.AWARDING
					_award_slot_perk()

		# Skip timed-buff expiry while the pick is open — same as old system.
		return

	# Timed buffs must not run down while the pause menu (or any other pause) is open.
	if get_tree().paused:
		return

	# ── Timed buff expiry ──────────────────────────────────────
	var any_expired : bool = false
	for i in range(_active_buffs.size() - 1, -1, -1):
		var buff : Dictionary = _active_buffs[i]
		if buff.has("_remaining") and buff.get("_duration_type", "") == "seconds":
			buff["_remaining"] -= delta
			if buff["_remaining"] <= 0.0:
				var expired := buff.duplicate()
				_active_buffs.remove_at(i)
				_modify_stats(expired, false)
				any_expired = true
				emit_signal("buff_expired", expired)

	if any_expired:
		_hud_dirty = true

	_countdown_refresh += delta
	if _countdown_refresh >= COUNTDOWN_UPDATE_RATE:
		_countdown_refresh = 0.0
		_refresh_countdown_text()

	if _hud_dirty:
		_hud_dirty = false
		_rebuild_buff_list()

func _on_day_changed(_day: int) -> void:
	var any_expired : bool = false
	for i in range(_active_buffs.size() - 1, -1, -1):
		var buff : Dictionary = _active_buffs[i]
		if buff.has("_remaining") and buff.get("_duration_type", "") == "days":
			buff["_remaining"] -= 1.0
			if buff["_remaining"] <= 0.0:
				var expired := buff.duplicate()
				_active_buffs.remove_at(i)
				_modify_stats(expired, false)
				any_expired = true
				emit_signal("buff_expired", expired)
	if any_expired:
		_hud_dirty = true

# ══════════════════════════════════════════════════════════════
#  BUFF HUD
# ══════════════════════════════════════════════════════════════

func _build_buff_hud() -> void:
	_hud_layer       = CanvasLayer.new()
	_hud_layer.layer = 5
	# Small persistent HUD text: keeps the HUD roles' own sizes instead of the phone menu minimums.
	_hud_layer.add_to_group("no_mobile_ui")
	add_child(_hud_layer)

	_hud_container = VBoxContainer.new()
	_hud_container.add_theme_constant_override("separation", int(HUD_LINE_SPACING))
	_hud_container.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_hud_container.anchor_left   = 1.0
	_hud_container.anchor_right  = 1.0
	_hud_container.anchor_top    = 0.0
	_hud_container.anchor_bottom = 0.0
	_hud_container.offset_left   = -HUD_WIDTH - HUD_MARGIN_X
	_hud_container.offset_right  = -HUD_MARGIN_X
	_hud_container.offset_top    = HUD_START_Y + 22.0   # clear of the day counter row
	if TouchControls.is_touch_platform():
		# Phones: the top-right belongs to the day counter, the wallet and the pause/map buttons, so the active
		# buffs list under the left vitals cluster instead.
		var o: Vector2 = HudKit.origin(get_viewport())
		_hud_container.anchor_left   = 0.0
		_hud_container.anchor_right  = 0.0
		_hud_container.offset_left   = o.x
		_hud_container.offset_right  = o.x + HUD_WIDTH
		_hud_container.offset_top    = o.y + HudKit.kills_row_top() + float(HudKit.ROW_KILLS_H) + float(PUI.S4)

	PUI.adopt(_hud_container)
	_hud_layer.add_child(_hud_container)
	_hud_layer.visible = false

func _rebuild_buff_list() -> void:
	for child in _hud_container.get_children():
		child.queue_free()
	_timed_labels.clear()

	if _active_buffs.is_empty():
		return

	for buff in _active_buffs:
		if buff.has("_remaining"):
			continue
		var dt : String = buff.get("duration_type", "permanent")
		if dt == "permanent" or dt == "instant":
			_hud_container.add_child(_build_hud_entry(
				buff.get("name", "???"),
				buff.get("description", ""),
				PUI.BONE, null
			))

	for buff in _active_buffs:
		if not buff.has("_remaining"):
			continue
		var is_neg : bool = false
		if buff.has("value"):
			is_neg = float(buff.get("value", 0)) < 0.0
		if buff.get("effect_type") == "schizophrenia":
			is_neg = true
		var color : Color = PUI.BLOOD_BRIGHT if is_neg else PUI.EMBER_BRIGHT
		var box := _build_hud_entry(_format_timed_entry(buff), buff.get("description", ""), color, null)
		_hud_container.add_child(box)
		_timed_labels.append({ "label": box.get_child(0) as Label, "buff": buff })

# One small outlined HUD entry (name in HudLabel, description in CaptionLabel). Colour meaning:
# permanent = bone, timed = ember (active), timed penalty = blood. No plates: the dungeon stays dominant.
func _build_hud_entry(name_text: String, desc_text: String,
		name_color: Color, _unused) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 0)

	var name_lbl := PUI.label(name_text, "HudLabel")
	name_lbl.add_theme_color_override("font_color", name_color)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(name_lbl)

	if desc_text != "":
		var desc_lbl := PUI.label(desc_text, "CaptionLabel")
		desc_lbl.add_theme_constant_override("outline_size", 3)
		desc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		desc_lbl.autowrap_mode        = TextServer.AUTOWRAP_WORD_SMART
		desc_lbl.mouse_filter         = Control.MOUSE_FILTER_IGNORE
		box.add_child(desc_lbl)

	return box

func _refresh_countdown_text() -> void:
	for entry in _timed_labels:
		var lbl : Label = entry["label"]
		if is_instance_valid(lbl):
			lbl.text = _format_timed_entry(entry["buff"])

func _format_timed_entry(buff: Dictionary) -> String:
	var name_str  : String = buff.get("name", "???")
	var remaining : float  = buff.get("_remaining", 0.0)
	var dur_type  : String = buff.get("_duration_type", "")
	if dur_type == "days":
		return "%s — %dd" % [name_str, int(ceil(remaining))]
	var total_sec : int = int(ceil(remaining))
	return "%s — %d:%02d" % [name_str, int(total_sec / 60.0), total_sec % 60]

# ══════════════════════════════════════════════════════════════
#  SLOT MACHINE — TRIGGER
# ══════════════════════════════════════════════════════════════

func _on_buff_pick_triggered() -> void:
	# Block duplicate triggers while already running.
	if _is_picking:
		return

	if _buff_pool.is_empty():
		push_warning("BuffManager: no buffs available. Resuming clock.")
		GameClock.resume()
		return

	_build_slot_pool()

	if _slot_pool.is_empty():
		push_warning("BuffManager: slot pool is empty after build. Resuming clock.")
		GameClock.resume()
		return

	_slot_index   = 0
	_slot_timer   = 0.0
	_slot_elapsed = 0.0
	_slot_state   = SlotState.ROLLING
	_is_picking   = true

	get_tree().paused = true
	_show_slot_ui()


# Build the weighted perk pool the same way the old system did.
# Common entries appear ~10×, rare ~4×, legendary ~1× so rarity
# weighting is naturally reflected in both the visible cycle and
# the final landed result — no separate winner pre-selection needed.
func _build_slot_pool() -> void:
	_slot_pool.clear()
	# Only offer buffs this character can actually use (every stat the buff touches must exist on
	# the player): a Mage is never offered Wrath Expansion, a Barbarian never Lightning Caller, and
	# a buff whose stat exists on no player (an unimplemented one) is never offered at all.
	var player : Node = get_tree().get_first_node_in_group("player")
	var offerable : Array = []
	for buff in _buff_pool:
		if buff_is_applicable(buff, player):
			offerable.append(buff)
	if offerable.is_empty():
		offerable = _buff_pool   # never leave the player without a card
	for buff in offerable:
		var w : int = RARITY_WEIGHTS.get(buff.get("ranking", "common"), 10)
		for _j in w:
			_slot_pool.append(buff)
	_slot_pool.shuffle()

# ══════════════════════════════════════════════════════════════
#  SLOT MACHINE — UI
# ══════════════════════════════════════════════════════════════

func _show_slot_ui() -> void:
	_ui_layer              = CanvasLayer.new()
	_ui_layer.layer        = 10
	_ui_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child(_ui_layer)

	_ui_root              = Control.new()
	_ui_root.process_mode = Node.PROCESS_MODE_ALWAYS
	_ui_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Nothing here takes the tap: the whole screen is the "stop" button (see _unhandled_input).
	_ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	PUI.adopt(_ui_root)   # a CanvasLayer child does not inherit the root theme
	_ui_layer.add_child(_ui_root)

	# A light veil keeps the frozen dungeon behind the card from competing with it.
	_ui_root.add_child(PUI.background("veil"))

	# Header: title + day.
	var header := VBoxContainer.new()
	header.name = "Header"
	header.set_anchors_preset(Control.PRESET_TOP_WIDE)
	header.offset_top = float(PUI.S7)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_theme_constant_override("separation", PUI.S1)
	_ui_root.add_child(header)

	var title := PUI.label("Choose Your Fate", "ScreenTitle")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(title)

	var day_label := PUI.label("Day %d" % GameClock.current_day, "StatLabel")
	day_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	day_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(day_label)

	# Centered card.
	var sw     : float = get_viewport_rect().size.x
	var sh     : float = get_viewport_rect().size.y
	var card_x : float = (sw * 0.5) - (CARD_WIDTH * 0.5)
	var card_y : float = (sh * 0.5) - (CARD_HEIGHT * 0.5)

	_build_slot_card(card_x, card_y)

	# Prompt. Touch: large and ember so "TAP to stop" is unmissable; otherwise a quiet hint with the
	# glyph of the active input scheme.
	var prompt : Label
	if InputManager.is_touch():
		prompt = PUI.label("TAP to stop", "SectionHeading")
		prompt.add_theme_font_size_override("font_size", int(round(PUI.fs("card_title") * 1.15)))
		prompt.add_theme_color_override("font_color", PUI.EMBER_BRIGHT)
	else:
		prompt = PUI.label("Press %s to stop" % InputManager.glyph("ui_accept"), "SecondaryLabel")
	prompt.name = "StopPrompt"
	prompt.add_theme_constant_override("outline_size", 4)
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	prompt.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	prompt.offset_top    = -float(PUI.S7 + PUI.S6)
	prompt.offset_bottom = -float(PUI.S5)
	_ui_root.add_child(prompt)

	_update_slot_display()
	_animate_slot_card_in(card_x, card_y)


func _build_slot_card(x: float, y: float) -> void:
	var buff    : Dictionary = _slot_pool[_slot_index]
	var ranking : String     = buff.get("ranking", "common")

	var panel := PanelContainer.new()
	panel.name                = "SlotPanel"
	panel.mouse_filter        = Control.MOUSE_FILTER_IGNORE
	panel.custom_minimum_size = Vector2(CARD_WIDTH, CARD_HEIGHT)
	panel.size                = Vector2(CARD_WIDTH, CARD_HEIGHT)
	panel.position            = Vector2(x, y + CARD_ENTRY_OFFSET_Y)
	panel.modulate.a          = 0.0
	_slot_panel = panel
	_slot_rarity_key = ""   # forces the rarity material to be applied by _update_slot_display

	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", PUI.S2)

	# Rarity tag (text + colour, never colour alone)
	var rarity_lbl := PUI.label(ranking.capitalize(), "StatLabel")
	rarity_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(rarity_lbl)
	_slot_rarity_label = rarity_lbl

	# Name
	var name_lbl := PUI.label(buff.get("name", "???"), "CardTitle")
	name_lbl.add_theme_font_size_override("font_size", int(round(PUI.fs("card_title") * 1.3)))
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(name_lbl)
	_slot_name_label = name_lbl

	vbox.add_child(PUI.divider())

	# Description takes the spare height so the tradeoff always sits at the foot of the card.
	var desc_lbl := PUI.label(buff.get("description", ""))
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	desc_lbl.size_flags_vertical  = Control.SIZE_EXPAND_FILL
	vbox.add_child(desc_lbl)
	_slot_desc_label = desc_lbl

	# Tradeoff
	var td_lbl := PUI.label("", "WarningLabel")
	var tradeoff = buff.get("tradeoff", null)
	td_lbl.text = (TRADEOFF_PREFIX + tradeoff.get("description", "")) if tradeoff != null else ""
	td_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	td_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	td_lbl.visible = (tradeoff != null)
	vbox.add_child(td_lbl)
	_slot_tradeoff_label = td_lbl

	panel.add_child(vbox)
	_ui_root.add_child(panel)


func _animate_slot_card_in(_card_x: float, card_y: float) -> void:
	if _ui_root == null:
		return
	var panel : Control = _ui_root.get_node_or_null("SlotPanel")
	if panel == null:
		return

	var t := self.create_tween()
	t.set_process_mode(Tween.TWEEN_PROCESS_IDLE)
	t.set_parallel(true)
	t.tween_property(panel, "position:y", card_y, CARD_ENTRY_DURATION).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	t.tween_property(panel, "modulate:a", 1.0, CARD_ENTRY_DURATION * 0.75)

# ══════════════════════════════════════════════════════════════
#  SLOT MACHINE — CYCLING
# ══════════════════════════════════════════════════════════════

func _advance_slot() -> void:
	_slot_index = (_slot_index + 1) % _slot_pool.size()
	_update_slot_display()


# Pushes the current buff's name, description, rarity, and tradeoff
# into the live label refs.  Called every cycle step — no node rebuild.
func _update_slot_display() -> void:
	if _slot_pool.is_empty():
		return
	var buff     : Dictionary = _slot_pool[_slot_index]
	var ranking  : String     = buff.get("ranking", "common")

	if is_instance_valid(_slot_name_label):
		_slot_name_label.text = buff.get("name", "???")

	if is_instance_valid(_slot_rarity_label):
		_slot_rarity_label.text = ranking.capitalize()
		_slot_rarity_label.add_theme_color_override("font_color", PUI.rarity_text(ranking))

	if is_instance_valid(_slot_desc_label):
		_slot_desc_label.text = buff.get("description", "")

	if is_instance_valid(_slot_tradeoff_label):
		var tradeoff = buff.get("tradeoff", null)
		if tradeoff != null:
			_slot_tradeoff_label.text    = TRADEOFF_PREFIX + tradeoff.get("description", "")
			_slot_tradeoff_label.visible = true
		else:
			_slot_tradeoff_label.text    = ""
			_slot_tradeoff_label.visible = false

	# The card's edge (and, for the top tiers, its base glow) carries the rarity. Materials are built once
	# per rarity and only swapped when the rarity actually changes.
	if is_instance_valid(_slot_panel) and ranking != _slot_rarity_key:
		_slot_rarity_key = ranking
		if not _rarity_boxes.has(ranking):
			_rarity_boxes[ranking] = PUI.rarity_card(ranking)
		_slot_panel.add_theme_stylebox_override("panel", _rarity_boxes[ranking])

# ══════════════════════════════════════════════════════════════
#  INPUT — A PRESS TO STOP
# ══════════════════════════════════════════════════════════════

func _unhandled_input(event: InputEvent) -> void:
	if not _is_picking:
		return
	# Only accept input during ROLLING — once slowing starts, lock out further presses.
	if _slot_state != SlotState.ROLLING:
		return
	# Touch: the whole screen is the button (the touch layer is hidden while the game is paused).
	var tapped: bool = event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed
	if tapped or event.is_action_pressed("ui_accept") or event.is_action_pressed("equip"):
		_slot_state   = SlotState.SLOWING
		_slot_elapsed = 0.0
		_slot_timer   = 0.0
		get_viewport().set_input_as_handled()

# ══════════════════════════════════════════════════════════════
#  SLOT MACHINE — AWARD
# ══════════════════════════════════════════════════════════════

func _award_slot_perk() -> void:
	_slot_state = SlotState.DONE
	var buff : Dictionary = _slot_pool[_slot_index]

	if has_node("/root/AudioManager"):
		AudioManager.play_buff_choice()

	_apply_buff(buff)
	emit_signal("buff_chosen", buff)

	# Brief hold so the player can read the winner, then close.
	get_tree().create_timer(PERK_CYCLE_VISUAL_HOLD_TIME).timeout.connect(
		func() -> void:
			_animate_slot_exit(buff),
		CONNECT_ONE_SHOT)


func _animate_slot_exit(buff: Dictionary) -> void:
	if _ui_root == null:
		_finalize_close(buff)
		return

	var t := self.create_tween()
	t.set_process_mode(Tween.TWEEN_PROCESS_IDLE)
	t.tween_property(_ui_root, "modulate:a", 0.0, CARD_EXIT_DURATION).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
	await t.finished

	_finalize_close(buff)


func _finalize_close(_buff: Dictionary) -> void:
	_destroy_ui()
	get_tree().paused = false
	_is_picking = false
	GameClock.resume()

	# Defensive state reset — if the player was mid-attack / mid-kick /
	# mid-slide / mid-block when the tree paused, their `await` loops froze
	# and their state flag may still be stuck. Clear everything so movement
	# input works immediately after the pick closes.
	var player = get_tree().get_first_node_in_group("player")
	if player != null:
		if player.has_method("_on_buff_pick_finished"):
			player._on_buff_pick_finished()
		# Diagnostic — if the theory holds, all four will be false by now.
		# If any print true we know some other path is holding the flag.
		print("BuffPick end — blocking:", player.get("_is_blocking"),
			  " attacking:", player.get("_is_attacking"),
			  " sliding:",  player.get("_is_sliding"),
			  " kicking:",  player.get("_is_kicking"))

	# If the caller chained picks (e.g. chest reward trigger_buff_picks(3)),
	# fire the next one on the following idle frame so UI has time to tear down.
	if _queued_picks > 0:
		_queued_picks -= 1
		call_deferred("_on_buff_pick_triggered")


# Public API — fire `count` consecutive day-change-style buff picks. If a pick
# is already running the new ones are queued onto the tail.
var _queued_picks : int = 0

func trigger_buff_picks(count: int) -> void:
	if count <= 0:
		return
	_queued_picks += count
	if not _is_picking:
		_queued_picks -= 1
		_on_buff_pick_triggered()


func _destroy_ui() -> void:
	if _ui_layer != null:
		_ui_layer.queue_free()
		_ui_layer = null
	_ui_root             = null
	_slot_name_label     = null
	_slot_desc_label     = null
	_slot_rarity_label   = null
	_slot_tradeoff_label = null
	_slot_panel          = null
	_slot_rarity_key     = ""
	_slot_pool.clear()

# ══════════════════════════════════════════════════════════════
#  BUFF APPLICATION  (unchanged from previous version)
# ══════════════════════════════════════════════════════════════

func _apply_buff(buff: Dictionary) -> void:
	var stored := buff.duplicate()

	var duration_type : String = stored.get("duration_type", "permanent")
	var duration      : float  = float(stored.get("duration", 0))
	if duration_type == "days" and duration > 0:
		stored["_remaining"]     = duration
		stored["_duration_type"] = "days"
	elif duration_type == "seconds" and duration > 0:
		stored["_remaining"]     = duration
		stored["_duration_type"] = "seconds"

	_active_buffs.append(stored)

	var effect_type : String = stored.get("effect_type", "")
	if effect_type == "currency":
		PlayerWallet.add_potions(int(stored.get("value", 0)))
	else:
		_modify_stats(stored, true)

	if _hud_layer != null:
		_hud_layer.visible = true
	_hud_dirty = true

func _modify_stats(buff: Dictionary, apply: bool) -> void:
	if buff.has("effects"):
		for effect in buff.get("effects", []):
			_apply_effect_dict(effect, apply)
		return
	_apply_effect_dict(buff, apply)

func _apply_effect_dict(effect: Dictionary, apply: bool) -> void:
	var effect_type : String = effect.get("effect_type", "")

	if effect_type in ["stat_modifier", "on_kill", "max_health"]:
		var stat : String = effect.get("stat", "")
		var val  : float  = float(effect.get("value", 0.0))
		if stat != "":
			_apply_single_stat(stat, val, apply)
	elif effect_type == "schizophrenia":
		_handle_schizophrenia(apply)

	var tradeoff = effect.get("tradeoff", null)
	if tradeoff != null:
		var t_stat : String = tradeoff.get("stat", "")
		var t_val  : float  = float(tradeoff.get("value", 0.0))
		if t_stat != "":
			_apply_single_stat(t_stat, t_val, apply)

# Stats whose buff value is a FRACTION of the stat's base value for this player (0.25 = +25%),
# matching the card text. Every other stat is an absolute amount (+9 attack damage) or already
# a multiplier / fraction by its own definition (attack_speed 1.0, damage_reduction 0.0).
const PERCENT_OF_BASE_STATS : Array[String] = [
	"move_speed", "move_acceleration", "spell_damage", "spell_range", "fireball_speed",
	"shove_force", "kick_force", "block_knockback_force",
	"head_bob_intensity", "react_anim_speed", "footstep_interval_seconds",
]
# The player's value for each percent stat the first time a buff touched it. Percentages stack
# additively on that base (+25% and +25% = +50%) and are removed exactly when a timed buff ends.
var _stat_base       : Dictionary = {}
var _stat_base_owner : int        = 0


func _percent_base(player: Node, stat_name: String) -> float:
	var pid : int = player.get_instance_id()
	if pid != _stat_base_owner:
		_stat_base.clear()
		_stat_base_owner = pid
	if not _stat_base.has(stat_name):
		_stat_base[stat_name] = float(player.get(stat_name))
	return float(_stat_base[stat_name])


# Every stat a buff or curse entry touches (main effect and tradeoff, single or multi-effect).
func buff_stat_names(buff: Dictionary) -> Array[String]:
	var names : Array[String] = []
	var effects : Array = buff.get("effects", [buff]) if buff.has("effects") else [buff]
	for effect in effects:
		if not (effect is Dictionary):
			continue
		if str(effect.get("effect_type", "")) in ["stat_modifier", "on_kill", "max_health"]:
			var st : String = str(effect.get("stat", ""))
			if st != "":
				names.append(st)
		var tradeoff = effect.get("tradeoff", null)
		if tradeoff is Dictionary and str(tradeoff.get("stat", "")) != "":
			names.append(str(tradeoff.get("stat", "")))
	return names


# True when every stat the entry touches exists on `player` (a null player accepts everything).
func buff_is_applicable(buff: Dictionary, player: Node) -> bool:
	if player == null:
		return true
	for st in buff_stat_names(buff):
		if not (st in player):
			return false
	return true


# Modifier curses (data key `requires_any_positive`) only change an opt-in effect, so they are only
# meaningful while the player holds at least one of those stats above zero. Entries without the
# key are always usable.
func buff_prerequisites_met(buff: Dictionary, player: Node) -> bool:
	var needs = buff.get("requires_any_positive", [])
	if not (needs is Array) or needs.is_empty():
		return true
	if player == null:
		return false
	for st in needs:
		if str(st) in player and float(player.get(str(st))) > 0.0:
			return true
	return false


func _apply_single_stat(stat_name: String, value: float, apply: bool) -> void:
	var player = get_tree().get_first_node_in_group("player")
	if player == null or not (stat_name in player):
		push_warning("BuffManager: Player does not have stat: " + stat_name)
		return

	var current_val : float = float(player.get(stat_name))
	var amount      : float = value
	if stat_name in PERCENT_OF_BASE_STATS:
		amount = value * _percent_base(player, stat_name)
	var change      : float = amount if apply else -amount
	player.set(stat_name, current_val + change)

	if stat_name == "max_health":
		if apply and change > 0.0 and player.has_method("receive_heal"):
			player.receive_heal(change)
		elif apply and change < 0.0:
			var hp      : float = float(player.get("_current_health"))
			var new_max : float = float(player.get("max_health"))
			if hp > new_max:
				player.set("_current_health", new_max)
			if player.has_signal("health_changed"):
				player.emit_signal("health_changed", player.get("_current_health"), new_max)
		elif not apply:
			var hp      = player.get("_current_health")
			var new_max = player.get("max_health")
			if hp > new_max:
				player.set("_current_health", new_max)
			if player.has_signal("health_changed"):
				player.emit_signal("health_changed", player.get("_current_health"), new_max)

# ── Custom effect handlers ─────────────────────────────────

# The hallucination node is shared by every source (the timed buff, each schizophrenia trap), so
# it is reference-counted: it stays attached until the LAST source ends. Re-triggering a trap while
# it is active therefore extends the effect instead of the first timer cutting it short.
var _schizo_refs : int = 0
# Bumped by reset(): a trap timer left over from a previous run must not end this run's effect.
var _run_serial  : int = 0

func _handle_schizophrenia(apply: bool) -> void:
	if apply:
		_schizo_refs += 1
	else:
		_schizo_refs = maxi(_schizo_refs - 1, 0)
	var player = get_tree().get_first_node_in_group("player")
	if player == null:
		return
	if _schizo_refs > 0:
		if player.get_node_or_null("SchizophreniaEffect") == null:
			var s = load("res://schizophrenia_audio.gd")
			if s:
				var n = s.new()
				n.name = "SchizophreniaEffect"
				player.add_child(n)
	else:
		var existing = player.get_node_or_null("SchizophreniaEffect")
		if existing != null:
			existing.queue_free()


# Schizophrenia trap: hallucinations for `seconds` of game time (pauses with the game).
func begin_timed_schizophrenia(seconds: float) -> void:
	_handle_schizophrenia(true)
	var serial : int = _run_serial
	get_tree().create_timer(seconds, false).timeout.connect(func() -> void:
		if serial == _run_serial:
			_handle_schizophrenia(false))

# ══════════════════════════════════════════════════════════════
#  HELPERS
# ══════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════
#  PUBLIC API
# ══════════════════════════════════════════════════════════════

func get_active_buffs() -> Array:
	return _active_buffs.duplicate()

func is_picking() -> bool:
	return _is_picking


func reset() -> void:
	_active_buffs.clear()
	_schizo_refs = 0
	_run_serial += 1
	_stat_base.clear()
	_stat_base_owner = 0
	_queued_picks = 0
	if _is_picking:
		get_tree().paused = false
	_is_picking   = false
	_slot_state   = SlotState.IDLE
	_hud_dirty    = true
	_destroy_ui()
	if _hud_layer != null:
		_hud_layer.visible = false

func get_viewport_rect() -> Rect2:
	return get_viewport().get_visible_rect()
