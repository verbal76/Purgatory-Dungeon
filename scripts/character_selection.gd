# ==============================================================================
# File Name: character_selection.gd
# Path: res://scripts/character_selection.gd
# Description: Handles name entry, seeds, starter potions, and class selection.
#              Phase 4 Implementation: Separates New Character vs Existing Character modes.
# Adjustable Settings: None
# Mod Notes: Identity is locked upon first save. GlobalRunData acts as a transport.
# ==============================================================================
extends Control

@export var main_menu_scene: String = "res://scenes/MainMenu.tscn" # Path to the main menu
@export var gameplay_scene: String = "res://scenes/Purgatory_Dungeon_main_game_file.tscn" # Path to the actual game

# Node Variables
var back_btn: Button
var load_char_btn: Button
var start_btn: Button
var random_seed_btn: Button
var seed_input: LineEdit
var char_name_input: LineEdit
var char_name_label: Label
var stats_label: Label 
var custom_keyboard: Control

# Class selection
var barbarian_btn: Button
var mage_btn: Button
var selected_class: String = "barbarian"

# Difficulty selection (new characters only; locked at creation like class)
var selected_difficulty: String = "medium"
var _easy_btn     : Button = null
var _medium_btn   : Button = null
var _hardcore_btn : Button = null

# UI Helpers (Created in code)
var _warning_label: Label = null
var _slot_indicator: Label = null

# Debug panel nodes
var _debug_panel        : PanelContainer = null
var _btn_brutes         : Button = null
var _btn_mages          : Button = null
var _btn_health_orbs    : Button = null
var _btn_demonic_orbs   : Button = null
var _btn_buffs          : Button = null
var _btn_traps          : Button = null

func _ready() -> void:
	# The dungeon captures the mouse; make sure menus are clickable after leaving it.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Bind all UI nodes to variables
	_bind_nodes()
	# Connect button presses and UI events
	_connect_signals()
	# Debug spawn/system toggles — must come before class picker so it lands above it
	_build_debug_panel()
	if TouchControls.is_touch_platform():
		# Phones: the dev toggles do not fit and are not for players; the on-screen keyboard below is
		# this game's own (the OS keyboard would cover the form in landscape).
		if _debug_panel:
			_debug_panel.hide()
		if char_name_input:
			char_name_input.virtual_keyboard_enabled = false
	# Create or find the class selection buttons
	_build_class_picker()
	# Create or find the difficulty selection buttons
	_build_difficulty_picker()
	# Set up the label showing the active slot
	_setup_slot_indicator()

	# Hide the LoadCharacterButton — removed from the flow
	if load_char_btn:
		load_char_btn.hide()

	# Seed UI removed — all runs auto-generate a fresh seed
	if random_seed_btn:
		random_seed_btn.hide()
	if seed_input:
		seed_input.hide()
	var seed_label := find_child("SeedLabel", true, false)
	if seed_label:
		seed_label.hide()

	# Determine mode and configure UI accordingly
	if SaveManager.current_profile_is_valid():
		# EXISTING CHARACTER — show locked identity, hide editable fields
		_display_loaded_profile()
	else:
		# NEW CHARACTER — show editable fields
		if char_name_input:
			char_name_input.show()

	# GAMEPAD: Focus the back button for immediate controller navigation
	if back_btn:
		back_btn.call_deferred("grab_focus")

	_wire_button_clicks()

func _wire_button_clicks() -> void:
	if has_node("/root/AudioManager"):
		AudioManager.wire_click_sounds(self)

func _bind_nodes() -> void:
	# Recursively search the scene tree for the required UI elements
	back_btn = find_child("BackButton", true, false)
	load_char_btn = find_child("LoadCharacterButton", true, false)
	start_btn = find_child("StartRunButton", true, false)
	random_seed_btn = find_child("RandomSeedButton", true, false)
	seed_input = find_child("SeedInput", true, false)
	char_name_input = find_child("CharNameInput", true, false)
	char_name_label = find_child("CharName", true, false)
	stats_label = find_child("CharImagePlaceholder", true, false)
	custom_keyboard = find_child("VirtualKeyboard", true, false)

func _setup_slot_indicator() -> void:
	# Generates a label at the top of the screen to indicate the active save slot
	_slot_indicator = Label.new()
	_slot_indicator.name = "SlotIndicator"
	_slot_indicator.add_theme_font_size_override("font_size", 18)
	_slot_indicator.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_slot_indicator.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_slot_indicator)
	# Move to top of the scene
	move_child(_slot_indicator, 0)

	var slot_num: String = str(SaveManager.active_slot_index + 1)
	if not SaveManager.current_profile_is_valid():
		_slot_indicator.text = "Creating Character in Slot " + slot_num
	else:
		_slot_indicator.text = "Slot " + slot_num + ": " + SaveManager.get_character_name()

func _display_loaded_profile() -> void:
	# Updates the UI for an existing character (read-only mode).
	# If stats have changed since last visit, numbers roll up with click sounds.
	var profile = SaveManager.current_profile

	# Show locked name
	if char_name_label:
		char_name_label.text = SaveManager.get_character_name()
		char_name_label.show()

	# Hide name input — name is locked
	if char_name_input:
		char_name_input.hide()

	if stats_label:
		stats_label.add_theme_font_size_override("font_size", 16)

	# Generate FRESH seed — never show the old one
	_generate_random_seed()

	# ── Current values ────────────────────────────────────────────────────────
	var runs         : int        = int(profile.get("run_count",    0))
	var deaths       : int        = int(profile.get("death_count",  0))
	var potions      : int        = int(profile.get("meta_currency", 0))
	var kills        : int        = int(profile.get("kill_count",   0))
	var perk_levels  : Dictionary = profile.get("perks", {})

	# Friendly display names matching AlchemistStore perk definitions.
	var perk_names : Dictionary = {
		"magnitude":   "Magnitude",   "persistence": "Persistence",
		"vitality":    "Vitality",    "adrenaline":  "Adrenaline",
		"ferocity":    "Ferocity",    "scavenge":    "Scavenge",
		"greed":       "Greed",       "swiftness":   "Swiftness",
		"health_regen": "Regeneration", "cyclone":   "Cyclone",
		"trap_sense":  "Trap Sense"
	}

	# ── Snapshot — what was shown last visit ──────────────────────────────────
	var snapshot    : Dictionary = profile.get("_display_snapshot", {})
	var snap_kills  : int        = int(snapshot.get("kills", kills))
	var snap_perks  : Dictionary = snapshot.get("perks",  perk_levels.duplicate())

	# Identify new perks (level 0→N) and leveled-up perks (level N→M where M>N)
	var new_perk_keys    : Array = []
	var leveled_perk_keys : Array = []
	for key in perk_levels.keys():
		var cur_lv  : int = int(perk_levels.get(key, 0))
		var snap_lv : int = int(snap_perks.get(key, 0))
		if cur_lv > 0 and snap_lv == 0:
			new_perk_keys.append(key)
		elif cur_lv > snap_lv and snap_lv > 0:
			leveled_perk_keys.append(key)

	var kills_delta : int = kills - snap_kills

	# ── No delta — show static stats and save snapshot ────────────────────────
	if kills_delta <= 0 and new_perk_keys.is_empty() and leveled_perk_keys.is_empty():
		_set_stats_text(kills, runs, deaths, potions, perk_levels, perk_names)
		_save_display_snapshot(kills, perk_levels)
		SaveManager.save_profile()
		return

	# ── Has delta — animate rollup ────────────────────────────────────────────
	# Start with snapshot values; new perks hidden until their reveal step.
	var anim_perks : Dictionary = snap_perks.duplicate()
	for key in new_perk_keys:
		anim_perks.erase(key)

	_set_stats_text(snap_kills, runs, deaths, potions, anim_perks, perk_names)

	# 1. Roll kills up to current value
	if kills_delta > 0:
		var step      : int = maxi(1, int(ceil(float(kills_delta) / 60.0)))
		var displayed : int = snap_kills
		var click_acc : int = 0
		while displayed < kills:
			displayed  = mini(displayed + step, kills)
			click_acc += 1
			if click_acc >= 3:
				click_acc = 0
				if has_node("/root/AudioManager"):
					AudioManager.play_pickup()
			_set_stats_text(displayed, runs, deaths, potions, anim_perks, perk_names)
			await get_tree().create_timer(0.05).timeout
			if not is_inside_tree():
				return
		if has_node("/root/AudioManager"):
			AudioManager.play_buff_choice()

	# 2. Roll up levels for existing perks that leveled up
	for key in leveled_perk_keys:
		var from_lv : int = int(snap_perks.get(key, 1))
		var to_lv   : int = int(perk_levels.get(key, 1))
		var lv      : int = from_lv
		while lv < to_lv:
			lv += 1
			anim_perks[key] = lv
			if has_node("/root/AudioManager"):
				AudioManager.play_pickup()
			_set_stats_text(kills, runs, deaths, potions, anim_perks, perk_names)
			await get_tree().create_timer(0.15).timeout
			if not is_inside_tree():
				return
		if has_node("/root/AudioManager"):
			AudioManager.play_buff_choice()

	# 3. Reveal new perks one by one with a pop, then roll their level
	for key in new_perk_keys:
		await get_tree().create_timer(0.35).timeout
		if not is_inside_tree():
			return
		anim_perks[key] = 1
		if has_node("/root/AudioManager"):
			AudioManager.play_buff_choice()
		_set_stats_text(kills, runs, deaths, potions, anim_perks, perk_names)
		# Roll up if level > 1
		var target_lv : int = int(perk_levels.get(key, 1))
		var lv        : int = 1
		while lv < target_lv:
			lv += 1
			anim_perks[key] = lv
			if has_node("/root/AudioManager"):
				AudioManager.play_pickup()
			_set_stats_text(kills, runs, deaths, potions, anim_perks, perk_names)
			await get_tree().create_timer(0.15).timeout
			if not is_inside_tree():
				return

	# Save snapshot after the full animation so incomplete views re-animate next visit.
	# Also persist to disk so the delta resets correctly on the next scene load.
	_save_display_snapshot(kills, perk_levels)
	SaveManager.save_profile()


func _set_stats_text(kills: int, runs: int, deaths: int, potions: int,
		perk_levels: Dictionary, perk_names: Dictionary) -> void:
	if stats_label == null:
		return
	var locked_class       : String = SaveManager.get_character_class().capitalize()
	var locked_difficulty  : String = SaveManager.get_character_difficulty().capitalize()
	var abandoned          : int    = maxi(runs - deaths, 0)
	var text : String = "Class: %s  |  Difficulty: %s\nRuns: %d  |  Deaths: %d  |  Abandoned: %d\nKills: %d  |  Potions: %d" % [
		locked_class, locked_difficulty, runs, deaths, abandoned, kills, potions
	]
	var has_perks : bool = false
	for key in perk_names.keys():
		var lv : int = int(perk_levels.get(key, 0))
		if lv > 0:
			if not has_perks:
				text += "\n── Perks ──"
				has_perks = true
			text += "\n%s Level %d" % [perk_names[key], lv]
	stats_label.text = text


func _save_display_snapshot(kills: int, perk_levels: Dictionary) -> void:
	if SaveManager.current_profile.is_empty():
		return
	SaveManager.current_profile["_display_snapshot"] = {
		"kills": kills,
		"perks": perk_levels.duplicate()
	}
	SaveManager.save_profile()

func _connect_signals() -> void:
	# Navigation Buttons — guarded so a missing scene node gives a warning
	# instead of a crash. Node names must match the CharacterSelection scene.
	if back_btn:
		back_btn.pressed.connect(func(): get_tree().change_scene_to_file(main_menu_scene))
	else:
		push_warning("CharacterSelection: BackButton node not found in scene.")

	# LoadCharacterButton is hidden/removed — do NOT connect it

	if start_btn:
		start_btn.pressed.connect(_on_start_run)
	else:
		push_warning("CharacterSelection: StartRunButton node not found in scene.")

	# RandomSeedButton removed — seed UI is hidden; do not connect it
	
	# Virtual Keyboard Connections
	if custom_keyboard:
		custom_keyboard.submitted.connect(_on_keyboard_submitted)
		
		# Your VirtualKeyboard uses 'cancelled' (two L's)
		if custom_keyboard.has_signal("cancelled"):
			custom_keyboard.cancelled.connect(_on_keyboard_close_request)
		elif custom_keyboard.has_signal("canceled"):
			custom_keyboard.canceled.connect(_on_keyboard_close_request)

	# Click/Accept logic for inputs (prevents focus-traps)
	if char_name_input:
		char_name_input.gui_input.connect(_on_input_clicked.bind(char_name_input))
	if seed_input:
		seed_input.gui_input.connect(_on_input_clicked.bind(seed_input))

func _show_name_warning() -> void:
	# Displays a temporary warning if the user tries to start a new character without a name
	if _warning_label == null:
		_warning_label = Label.new()
		_warning_label.name = "NameWarningLabel"
		_warning_label.text = "Enter a name first!"
		_warning_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2))
		_warning_label.add_theme_font_size_override("font_size", 18)
		_warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		# Insert near the name input — find its parent and add after it
		if char_name_input and char_name_input.get_parent():
			var parent = char_name_input.get_parent()
			var idx = char_name_input.get_index() + 1
			parent.add_child(_warning_label)
			parent.move_child(_warning_label, idx)
		else:
			add_child(_warning_label)
	_warning_label.show()
	# Auto-hide after 3 seconds
	get_tree().create_timer(3.0).timeout.connect(func():
		if _warning_label: _warning_label.hide()
	)

func _on_input_clicked(event: InputEvent, input_node: LineEdit) -> void:
	# Only open keyboard if user actually CLICKS or presses ACCEPT (Enter/A-Button)
	if (event is InputEventMouseButton and event.pressed) or event.is_action_pressed("ui_accept"):
		if custom_keyboard:
			custom_keyboard.open_with_text(input_node.text)
			input_node.set_meta("editing", true)
			# Release LineEdit focus so gamepad can interact with the keyboard keys
			input_node.release_focus()

func _on_keyboard_submitted(text: String) -> void:
	# Handles the text returned from the virtual keyboard
	var target = _find_editing_node()
	if target:
		target.text = text
	_on_keyboard_close_request()

func _on_keyboard_close_request() -> void:
	# Force hide the keyboard
	if custom_keyboard:
		custom_keyboard.hide()
	
	# Clean up metadata tracking
	if char_name_input: char_name_input.remove_meta("editing")
	if seed_input: seed_input.remove_meta("editing")
	
	# AGGRESSIVE RESET: Give focus back to the UI. 
	if start_btn:
		start_btn.call_deferred("grab_focus")
	else:
		back_btn.call_deferred("grab_focus")

func _find_editing_node() -> LineEdit:
	# Locates which input field is currently active
	if char_name_input and char_name_input.has_meta("editing"): return char_name_input
	if seed_input and seed_input.has_meta("editing"): return seed_input
	return null

func _generate_random_seed() -> void:
	# Fills the seed input with a randomized string
	if seed_input: 
		seed_input.text = "RANDOM_" + str(randi() % 99999)

# ══════════════════════════════════════════════════════════════
#  DEBUG PANEL  (dev-only — remove before shipping)
# ══════════════════════════════════════════════════════════════

func _build_debug_panel() -> void:
	_debug_panel = PanelContainer.new()
	_debug_panel.name = "DebugPanel"

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)

	var header := Label.new()
	header.text = "[ DEBUG ]"
	header.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	header.add_theme_font_size_override("font_size", 14)
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(header)

	_btn_brutes       = _make_debug_toggle("Brutes",       GlobalRunData.debug_no_brutes)
	_btn_mages        = _make_debug_toggle("Mages",        GlobalRunData.debug_no_mages)
	_btn_health_orbs  = _make_debug_toggle("Health Orbs",  GlobalRunData.debug_no_health_orbs)
	_btn_demonic_orbs = _make_debug_toggle("Demonic Orbs", GlobalRunData.debug_no_demonic_orbs)
	_btn_buffs        = _make_debug_toggle("Buff Roulette", GlobalRunData.debug_no_buffs)
	_btn_traps        = _make_debug_toggle("Traps",        GlobalRunData.debug_no_traps)

	vbox.add_child(_btn_brutes)
	vbox.add_child(_btn_mages)
	vbox.add_child(_btn_health_orbs)
	vbox.add_child(_btn_demonic_orbs)
	vbox.add_child(_btn_buffs)
	vbox.add_child(_btn_traps)

	_debug_panel.add_child(vbox)

	_btn_brutes.pressed.connect(func():
		GlobalRunData.debug_no_brutes = not GlobalRunData.debug_no_brutes
		_refresh_debug_toggle(_btn_brutes, "Brutes", GlobalRunData.debug_no_brutes)
	)
	_btn_mages.pressed.connect(func():
		GlobalRunData.debug_no_mages = not GlobalRunData.debug_no_mages
		_refresh_debug_toggle(_btn_mages, "Mages", GlobalRunData.debug_no_mages)
	)
	_btn_health_orbs.pressed.connect(func():
		GlobalRunData.debug_no_health_orbs = not GlobalRunData.debug_no_health_orbs
		_refresh_debug_toggle(_btn_health_orbs, "Health Orbs", GlobalRunData.debug_no_health_orbs)
	)
	_btn_demonic_orbs.pressed.connect(func():
		GlobalRunData.debug_no_demonic_orbs = not GlobalRunData.debug_no_demonic_orbs
		_refresh_debug_toggle(_btn_demonic_orbs, "Demonic Orbs", GlobalRunData.debug_no_demonic_orbs)
	)
	_btn_buffs.pressed.connect(func():
		GlobalRunData.debug_no_buffs = not GlobalRunData.debug_no_buffs
		_refresh_debug_toggle(_btn_buffs, "Buff Roulette", GlobalRunData.debug_no_buffs)
	)
	_btn_traps.pressed.connect(func():
		GlobalRunData.debug_no_traps = not GlobalRunData.debug_no_traps
		_refresh_debug_toggle(_btn_traps, "Traps", GlobalRunData.debug_no_traps)
	)

	if start_btn and start_btn.get_parent():
		var parent := start_btn.get_parent()
		var idx    := start_btn.get_index()
		parent.add_child(_debug_panel)
		parent.move_child(_debug_panel, idx)
	else:
		add_child(_debug_panel)


func _make_debug_toggle(label: String, currently_disabled: bool) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(200, 36)
	_refresh_debug_toggle(btn, label, currently_disabled)
	return btn


func _refresh_debug_toggle(btn: Button, label: String, is_disabled: bool) -> void:
	if is_disabled:
		btn.text = label + "  ✕  OFF"
		btn.modulate = Color(1.0, 0.35, 0.35)
	else:
		btn.text = label + "  ✓  ON"
		btn.modulate = Color(0.35, 1.0, 0.45)


# ══════════════════════════════════════════════════════════════
#  CLASS PICKER
# ══════════════════════════════════════════════════════════════

func _build_class_picker() -> void:
	# Look for existing buttons first (if you add them in the editor)
	barbarian_btn = find_child("BarbarianButton", true, false) as Button
	mage_btn = find_child("MageButton", true, false) as Button

	# If not placed in the editor, build them in code
	if barbarian_btn == null or mage_btn == null:
		var container := HBoxContainer.new()
		container.name = "ClassPicker"
		container.alignment = BoxContainer.ALIGNMENT_CENTER
		container.add_theme_constant_override("separation", 20)

		barbarian_btn = Button.new()
		barbarian_btn.name = "BarbarianButton"
		barbarian_btn.text = "BARBARIAN"
		barbarian_btn.custom_minimum_size = Vector2(160, 50)
		container.add_child(barbarian_btn)

		mage_btn = Button.new()
		mage_btn.name = "MageButton"
		mage_btn.text = "MAGE"
		mage_btn.custom_minimum_size = Vector2(160, 50)
		container.add_child(mage_btn)

		# Insert above the start button
		if start_btn and start_btn.get_parent():
			var parent := start_btn.get_parent()
			var idx := start_btn.get_index()
			parent.add_child(container)
			parent.move_child(container, idx)
		else:
			add_child(container)

	barbarian_btn.pressed.connect(func(): _select_class("barbarian"))
	mage_btn.pressed.connect(func(): _select_class("mage"))

	# Set default selection
	_select_class("barbarian")

	# NEW: After building, check if this is an existing character.
	# If so, hide the picker entirely — class is locked.
	if SaveManager.current_profile_is_valid():
		if barbarian_btn:
			barbarian_btn.hide()
		if mage_btn:
			mage_btn.hide()
		# Also hide the container if it was built in code
		var picker_container = find_child("ClassPicker", true, false)
		if picker_container:
			picker_container.hide()
		# Set selected_class from save file (not UI) for safety
		selected_class = SaveManager.get_character_class()
	else:
		# New character — show picker, default to barbarian
		_select_class("barbarian")

func _select_class(class_name_str: String) -> void:
	# Updates the visual state of the class selection buttons
	selected_class = class_name_str

	# Visual feedback
	if barbarian_btn and mage_btn:
		if class_name_str == "barbarian":
			barbarian_btn.modulate = Color(1.0, 0.85, 0.4)
			mage_btn.modulate = Color(0.5, 0.5, 0.5)
		else:
			barbarian_btn.modulate = Color(0.5, 0.5, 0.5)
			mage_btn.modulate = Color(0.6, 0.4, 1.0)

# ══════════════════════════════════════════════════════════════
#  DIFFICULTY PICKER
# ══════════════════════════════════════════════════════════════

func _build_difficulty_picker() -> void:
	# Look for existing buttons first (placed in editor)
	_easy_btn     = find_child("EasyButton",     true, false) as Button
	_medium_btn   = find_child("MediumButton",   true, false) as Button
	_hardcore_btn = find_child("HardcoreButton", true, false) as Button

	# Build in code if not in scene
	if _easy_btn == null or _medium_btn == null or _hardcore_btn == null:
		var container := HBoxContainer.new()
		container.name = "DifficultyPicker"
		container.alignment = BoxContainer.ALIGNMENT_CENTER
		container.add_theme_constant_override("separation", 16)

		_easy_btn = Button.new()
		_easy_btn.name = "EasyButton"
		_easy_btn.text = "EASY"
		_easy_btn.custom_minimum_size = Vector2(120, 44)
		container.add_child(_easy_btn)

		_medium_btn = Button.new()
		_medium_btn.name = "MediumButton"
		_medium_btn.text = "MEDIUM"
		_medium_btn.custom_minimum_size = Vector2(120, 44)
		container.add_child(_medium_btn)

		_hardcore_btn = Button.new()
		_hardcore_btn.name = "HardcoreButton"
		_hardcore_btn.text = "HARDCORE"
		_hardcore_btn.custom_minimum_size = Vector2(120, 44)
		container.add_child(_hardcore_btn)

		# Insert above the start button (below the class picker)
		if start_btn and start_btn.get_parent():
			var parent := start_btn.get_parent()
			var idx    := start_btn.get_index()
			parent.add_child(container)
			parent.move_child(container, idx)
		else:
			add_child(container)

	_easy_btn.pressed.connect(func(): _select_difficulty("easy"))
	_medium_btn.pressed.connect(func(): _select_difficulty("medium"))
	_hardcore_btn.pressed.connect(func(): _select_difficulty("hardcore"))

	# Existing character — hide picker, read locked difficulty from save
	if SaveManager.current_profile_is_valid():
		_easy_btn.hide()
		_medium_btn.hide()
		_hardcore_btn.hide()
		var picker_container := find_child("DifficultyPicker", true, false)
		if picker_container:
			picker_container.hide()
		selected_difficulty = SaveManager.get_character_difficulty()
	else:
		# New character — show picker, default to medium
		_select_difficulty("medium")


func _select_difficulty(d: String) -> void:
	selected_difficulty = d

	if _easy_btn == null or _medium_btn == null or _hardcore_btn == null:
		return

	# Tint: Easy = green, Medium = white, Hardcore = red
	_easy_btn.modulate     = Color(0.4, 1.0, 0.4)   if d == "easy"     else Color(0.5, 0.5, 0.5)
	_medium_btn.modulate   = Color(1.0, 1.0, 1.0)   if d == "medium"   else Color(0.5, 0.5, 0.5)
	_hardcore_btn.modulate = Color(1.0, 0.35, 0.35) if d == "hardcore" else Color(0.5, 0.5, 0.5)


# ══════════════════════════════════════════════════════════════
#  START RUN
# ══════════════════════════════════════════════════════════════

func _on_start_run() -> void:
	var is_new := not SaveManager.current_profile_is_valid()

	if is_new:
		# ── NEW CHARACTER FLOW ──────────────────────────────

		# Step 1: Validate name
		var raw_name: String = char_name_input.text if char_name_input else ""
		var clean_name: String = raw_name.strip_edges()

		if clean_name == "":
			# Show warning to player — name is required
			_show_name_warning()
			return  # STOP. Do not proceed. Do not save. Do not grant potion.

		# Step 2: Create initial identity (atomic: name + class + difficulty + initialized=true)
		var identity_saved: bool = SaveManager.create_initial_identity(
				clean_name, selected_class, selected_difficulty)
		if not identity_saved:
			push_error("Failed to create initial identity.")
			return  # STOP.

		# Step 3: Auto-generate and commit seed — seed UI is hidden, always auto
		var final_seed: String = SaveManager.build_unique_random_seed_text()
		SaveManager.commit_run_seed(final_seed, final_seed.hash())

		# Step 4: Populate GlobalRunData FROM THE SAVED PROFILE (not from UI)
		GlobalRunData.character_name  = SaveManager.get_character_name()
		GlobalRunData.character_class = SaveManager.get_character_class()
		GlobalRunData.difficulty      = SaveManager.get_character_difficulty()
		GlobalRunData.seed_text       = final_seed
		GlobalRunData.seed_hash       = final_seed.hash()

		# Step 5: Grant starter potion AFTER identity is locked
		RunLifecycle.grant_starter_potion()
		SaveManager.save_profile()

	else:
		# ── EXISTING CHARACTER FLOW ─────────────────────────

		# Step 1: Read locked identity FROM SAVE FILE. Never from UI.
		var locked_name  : String = SaveManager.get_character_name()
		var locked_class : String = SaveManager.get_character_class()

		# Step 2: Auto-generate and commit seed — seed UI is hidden, always auto
		var final_seed: String = SaveManager.build_unique_random_seed_text()
		SaveManager.commit_run_seed(final_seed, final_seed.hash())

		# Step 3: Populate GlobalRunData from PROFILE
		GlobalRunData.character_name  = locked_name
		GlobalRunData.character_class = locked_class
		GlobalRunData.difficulty      = SaveManager.get_character_difficulty()
		GlobalRunData.seed_text       = final_seed
		GlobalRunData.seed_hash       = final_seed.hash()

		# Step 4: Grant starter potion
		RunLifecycle.grant_starter_potion()
		SaveManager.save_profile()

	# ── COMMON (both paths) ─────────────────────────────
	# Reset all run-only autoloads so nothing carries over.
	BuffManager.reset()
	GlobeManager.reset()
	GameClock.hide_hud()
	PlayerWallet.refresh_hud()

	# Transition to gameplay
	get_tree().change_scene_to_file(gameplay_scene)
