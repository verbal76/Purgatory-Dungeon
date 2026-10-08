extends CanvasLayer

const DungeonEntry = preload("res://scripts/dungeon_entry.gd")   # threaded dungeon load (no global class name)
# ══════════════════════════════════════════════════════════════
#  FILE:         you_died_screen.gd
#  PATH:         res://scripts/you_died_screen.gd
#
#  DESCRIPTION:
#    Fades in a black overlay with centered "YOU DIED" text,
#    then pulses the text like a heartbeat. A prompt appears
#    telling the player to press the menu button to return
#    to the main menu.
#    On exit, clears the day counter and buff HUD so they
#    don't persist into the menu screen.
#    Uses _input instead of _unhandled_input so this screen
#    captures the menu button press before brute_player's
#    pause handler can intercept it.
#
#  WHAT YOU CAN ADJUST:
#    FADE_DURATION       — how long the initial fade-in takes
#    PULSE_SPEED         — how fast the heartbeat pulse cycles
#    PULSE_MIN_ALPHA     — dimmest the text gets during a pulse
#    PULSE_MAX_ALPHA     — brightest the text gets during a pulse
#    PROMPT_FADE_DELAY   — seconds after fade-in before the prompt appears
#    PROMPT_FADE_TIME    — how long the prompt takes to fade in
#    MENU_SCENE          — scene to load when the player presses menu
#
#  SURGICAL CHANGES:
#    - Shop label: removed "✕ / " prefix — now reads "Press <glyph> to visit..."
#    - Added _restart_label: "Press X to start a new run".
#    - KEY_X moved from shop handler to quick-restart handler.
#    - JOY_BUTTON_X added so controller X/Square button also triggers restart.
#    - NOTE: _can_exit gates all input. It becomes true only after the prompts
#      have fully faded in (~4 seconds after death). Pressing X before the
#      prompts appear will do nothing — this is intentional.
#    - _do_quick_restart() increments run_count, randomises seed, resets
#      run-scoped autoloads, and loads the dungeon directly — bypasses
#      character selection so speedrunners never touch a menu.
#    - SURGICAL FIX: Hides the minimap compass label (GameplayCompassLabel)
#      so it doesn't bleed through onto the death screen.
#    - SURGICAL ADD: CodexManager.increment_completions() called once in
#      _ready() alongside death_count. This fires on every run end (death)
#      globally across all characters and drives the Codex lore drip system.
#      When a day-30 completion screen is added in future, call
#      CodexManager.increment_completions() there too.
# ══════════════════════════════════════════════════════════════

# ── Timing ─────────────────────────────────────────────────────
const FADE_DURATION    : float = 1.5
const PULSE_SPEED      : float = 2.0
const PULSE_MIN_ALPHA  : float = 0.3
const PULSE_MAX_ALPHA  : float = 1.0
const PROMPT_FADE_DELAY : float = 1.5
const PROMPT_FADE_TIME  : float = 1.0

# ── Scene ──────────────────────────────────────────────────────
const MENU_SCENE          : String = "res://scenes/CharacterSelection.tscn"
const ALCHEMIST_SCENE     : String = "res://scenes/AlchemistStore.tscn"
const QUICK_RESTART_SCENE : String = "res://scenes/Purgatory_Dungeon_main_game_file.tscn"

# ── Runtime state ──────────────────────────────────────────────
var _overlay         : ColorRect = null
var _label           : Label     = null
var _prompt_label    : Label     = null
var _shop_label      : Label     = null
var _restart_label   : Label     = null
var _prompts         : VBoxContainer = null
var _touch_row       : HBoxContainer = null
var _timer           : float     = 0.0
var _phase           : int       = 0
var _prompt_timer    : float     = 0.0
var _can_exit        : bool      = false
var _exiting         : bool      = false

# Cached reference to the compass label so we can restore it if needed.
var _hidden_compass  : CanvasItem = null


func _ready() -> void:
	if not SaveManager.current_profile.is_empty():
		SaveManager.current_profile["death_count"] = \
			int(SaveManager.current_profile.get("death_count", 0)) + 1
		var kills_this_run : int = CharacterBase.GLOBAL_KILL_COUNT
		SaveManager.current_profile["kill_count"] = \
			int(SaveManager.current_profile.get("kill_count", 0)) + kills_this_run
		# Award 1 potion per 50 kills earned this run.
		var potions_earned : int = kills_this_run / 50
		if potions_earned > 0:
			SaveManager.current_profile["meta_currency"] = \
				int(SaveManager.current_profile.get("meta_currency", 0)) + potions_earned
		CharacterBase.GLOBAL_KILL_COUNT = 0
		SaveManager.save_profile()

	# SURGICAL ADD: Increment the global codex completion counter.
	# This fires once per death, across all characters, and drives the
	# lore drip system in CodexScreen. If CodexManager is not loaded
	# (e.g. autoload was accidentally removed) we skip silently.
	if has_node("/root/CodexManager"):
		CodexManager.increment_completions()

	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS

	# SURGICAL FIX: The minimap compass label (GameplayCompassLabel) sits on a
	# persistent CanvasLayer and bleeds through onto this screen. Hide it here
	# so the heading indicator doesn't show over "YOU DIED".
	var compass := get_tree().root.find_child("GameplayCompassLabel", true, false)
	if compass is CanvasItem:
		_hidden_compass = compass as CanvasItem
		_hidden_compass.visible = false

	# ── Black overlay ──────────────────────────────────────────
	_overlay       = ColorRect.new()
	_overlay.color = Color(PUI.VOID, 0.0)
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)

	# ── "YOU DIED" label ───────────────────────────────────────
	# Display face (Cinzel Black, the GameTitle role) in blood-bright; fade and heartbeat animate the
	# label's modulate alpha (no theme overrides per frame).
	_label      = PUI.label("YOU DIED", "GameTitle")
	_label.add_theme_font_size_override("font_size", int(round(PUI.fs("game_title") * 1.5)))
	_label.add_theme_color_override("font_color", PUI.BLOOD_BRIGHT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.offset_bottom = -float(PUI.S7 + PUI.S4)   # title sits a little above centre
	_label.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_label.modulate.a    = 0.0
	PUI.adopt(_label)   # a CanvasLayer child does not inherit the root theme
	add_child(_label)

	# ── Key prompts (desktop / controller): quiet hierarchy, glyphs from InputManager ─────────
	_prompts = VBoxContainer.new()
	_prompts.name = "KeyPrompts"
	_prompts.set_anchors_preset(Control.PRESET_FULL_RECT)
	_prompts.anchor_top = 0.5
	_prompts.offset_top = float(PUI.S7 + PUI.S2)   # first line starts a clear gap below the title
	_prompts.alignment  = BoxContainer.ALIGNMENT_BEGIN
	_prompts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompts.add_theme_constant_override("separation", PUI.S2)
	_prompts.modulate.a = 0.0
	PUI.adopt(_prompts)
	add_child(_prompts)

	_prompt_label = _prompt_line("Press %s to view character stats" % InputManager.glyph("ui_menu"), "MetaLabel")
	_shop_label = _prompt_line("Press %s to visit the Alchemist's Lab" % InputManager.glyph("ui_accept"), "SecondaryLabel")
	_restart_label = _prompt_line("Press %s to start a new run" % InputManager.glyph("restart"), "SecondaryLabel")

	if TouchControls.is_touch_platform():
		_build_touch_buttons()


func _prompt_line(text: String, variation: String) -> Label:
	var l := PUI.label(text, variation)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompts.add_child(l)
	return l


# Phones have no keys: the three exits are buttons that appear with the key prompts (which they replace).
func _build_touch_buttons() -> void:
	get_tree().call_group(TouchControls.GROUP, "set_enabled", false)
	_prompts.hide()
	_touch_row = HBoxContainer.new()
	_touch_row.name = "TouchExits"
	_touch_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_touch_row.add_theme_constant_override("separation", PUI.S5)
	_touch_row.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_touch_row.offset_top = -170.0
	_touch_row.offset_bottom = -64.0
	_touch_row.modulate.a = 0.0
	PUI.adopt(_touch_row)
	add_child(_touch_row)
	# Same button family as every menu; starting over is the one primary action.
	for spec in [["Main Menu", "menu", "secondary"], ["Alchemist's Lab", "shop", "secondary"], ["New Run", "restart", "primary"]]:
		var b := PUI.button(spec[0], spec[2])
		b.name = "Exit_" + spec[1]
		b.custom_minimum_size = Vector2(300, 88)
		b.pressed.connect(_on_touch_exit.bind(spec[1]))
		_touch_row.add_child(b)


func _on_touch_exit(which: String) -> void:
	if not _can_exit or _exiting:
		return
	match which:
		"menu": _leave_to(MENU_SCENE)
		"shop": _leave_to(ALCHEMIST_SCENE)
		"restart":
			_exiting = true
			_do_quick_restart()


func _process(delta: float) -> void:
	_timer += delta

	if _phase == 0:
		var pct : float = clampf(_timer / FADE_DURATION, 0.0, 1.0)
		_overlay.color.a = pct
		_label.modulate.a = pct

		if _timer >= FADE_DURATION:
			_phase        = 1
			_timer        = 0.0
			_prompt_timer = 0.0

	elif _phase == 1:
		var pulse_raw : float = (sin(_timer * PULSE_SPEED * TAU) + 1.0) * 0.5
		var alpha     : float = lerp(PULSE_MIN_ALPHA, PULSE_MAX_ALPHA, pulse_raw)
		_label.modulate.a = alpha

		_prompt_timer += delta
		if _prompt_timer >= PROMPT_FADE_DELAY:
			var prompt_pct : float = clampf(
				(_prompt_timer - PROMPT_FADE_DELAY) / PROMPT_FADE_TIME, 0.0, 1.0
			)
			_prompts.modulate.a = prompt_pct
			if _touch_row != null:
				_touch_row.modulate.a = prompt_pct

			if prompt_pct >= 1.0:
				_can_exit = true


func _input(event: InputEvent) -> void:
	if not _can_exit or _exiting:
		return

	# ── ☰ / B / Escape — return to menu ───────────────────────
	var is_menu_press : bool = false
	if event.is_action_pressed("ui_menu"):
		is_menu_press = true
	elif event.is_action_pressed("ui_cancel"):
		is_menu_press = true
	elif event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			is_menu_press = true

	if is_menu_press:
		get_viewport().set_input_as_handled()
		_leave_to(MENU_SCENE)
		return

	# ── A/Cross — Alchemist store ──────────────────────────────
	if event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		_leave_to(ALCHEMIST_SCENE)
		return

	# ── X key / X button — quick restart ──────────────────────
	var is_restart_press : bool = false
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_X:
			is_restart_press = true
	elif event is InputEventJoypadButton and event.pressed:
		if event.button_index == JOY_BUTTON_X:
			is_restart_press = true

	if is_restart_press:
		_exiting = true
		_do_quick_restart()


func _leave_to(scene: String) -> void:
	_exiting = true
	get_tree().paused = false
	GameClock.hide_hud()
	BuffManager.reset()
	GlobeManager.reset()
	PlayerWallet.hide_hud()
	get_tree().change_scene_to_file(scene)
	queue_free()


func _do_quick_restart() -> void:
	get_viewport().set_input_as_handled()
	get_tree().paused = false

	if not SaveManager.current_profile.is_empty():
		SaveManager.current_profile["run_count"] = \
			int(SaveManager.current_profile.get("run_count", 0)) + 1
		RunLifecycle.grant_starter_potion()
		SaveManager.save_profile()

	RunLifecycle.sync_run_data_from_profile()
	var run_data := get_node_or_null("/root/GlobalRunData")
	if run_data != null:
		run_data.seed_hash = 0

	RunLifecycle.end_run_cleanup()

	DungeonEntry.start(get_tree(), QUICK_RESTART_SCENE)
	queue_free()
