extends CanvasLayer
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
#    - Shop label: removed "✕ / " prefix — now reads "Press A to visit..."
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
	_overlay.color = Color(0.0, 0.0, 0.0, 0.0)
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_overlay)

	# ── "YOU DIED" label ───────────────────────────────────────
	_label      = Label.new()
	_label.text = "YOU DIED"
	_label.add_theme_font_size_override("font_size", 72)
	_label.add_theme_color_override("font_color", Color(0.85, 0.1, 0.1, 0.0))
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_label)

	# ── Menu prompt ────────────────────────────────────────────
	_prompt_label      = Label.new()
	_prompt_label.text = "Press ☰ to view character stats"
	_prompt_label.add_theme_font_size_override("font_size", 22)
	_prompt_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, 0.0))
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_prompt_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_prompt_label.offset_top = 100.0
	add_child(_prompt_label)

	# ── Alchemist shortcut — A/Cross only ──────────────────────
	_shop_label = Label.new()
	_shop_label.text = "Press A to visit the Alchemist's Lab"
	_shop_label.add_theme_font_size_override("font_size", 20)
	_shop_label.add_theme_color_override("font_color", Color(0.4, 0.85, 1.0, 0.0))
	_shop_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_shop_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_shop_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shop_label.offset_top = 155.0
	add_child(_shop_label)

	# ── Quick restart — keyboard X or controller X/Square ──────
	_restart_label = Label.new()
	_restart_label.text = "Press X to start a new run"
	_restart_label.add_theme_font_size_override("font_size", 20)
	_restart_label.add_theme_color_override("font_color", Color(0.4, 0.85, 1.0, 0.0))
	_restart_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_restart_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_restart_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_restart_label.offset_top = 210.0
	add_child(_restart_label)


func _process(delta: float) -> void:
	_timer += delta

	if _phase == 0:
		var pct : float = clampf(_timer / FADE_DURATION, 0.0, 1.0)
		_overlay.color.a = pct
		_label.add_theme_color_override("font_color", Color(0.85, 0.1, 0.1, pct))

		if _timer >= FADE_DURATION:
			_phase        = 1
			_timer        = 0.0
			_prompt_timer = 0.0

	elif _phase == 1:
		var pulse_raw : float = (sin(_timer * PULSE_SPEED * TAU) + 1.0) * 0.5
		var alpha     : float = lerp(PULSE_MIN_ALPHA, PULSE_MAX_ALPHA, pulse_raw)
		_label.add_theme_color_override("font_color", Color(0.85, 0.1, 0.1, alpha))

		_prompt_timer += delta
		if _prompt_timer >= PROMPT_FADE_DELAY:
			var prompt_pct : float = clampf(
				(_prompt_timer - PROMPT_FADE_DELAY) / PROMPT_FADE_TIME, 0.0, 1.0
			)
			_prompt_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, prompt_pct))
			if _shop_label    != null:
				_shop_label.add_theme_color_override("font_color", Color(0.4, 0.85, 1.0, prompt_pct))
			if _restart_label != null:
				_restart_label.add_theme_color_override("font_color", Color(0.4, 0.85, 1.0, prompt_pct))

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
		_exiting = true
		get_viewport().set_input_as_handled()
		get_tree().paused = false
		GameClock.hide_hud()
		BuffManager.reset()
		GlobeManager.reset()
		PlayerWallet.hide_hud()
		get_tree().change_scene_to_file(MENU_SCENE)
		queue_free()
		return

	# ── A/Cross — Alchemist store ──────────────────────────────
	if event.is_action_pressed("ui_accept"):
		_exiting = true
		get_viewport().set_input_as_handled()
		get_tree().paused = false
		GameClock.hide_hud()
		BuffManager.reset()
		GlobeManager.reset()
		PlayerWallet.hide_hud()
		get_tree().change_scene_to_file(ALCHEMIST_SCENE)
		queue_free()
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

	get_tree().change_scene_to_file(QUICK_RESTART_SCENE)
	queue_free()
