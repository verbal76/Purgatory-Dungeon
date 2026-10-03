# ============================================================
#  FILE:         GameClock.gd
#  PATH:         res://autoloads/GameClock.gd
#  AUTOLOAD AS:  GameClock
#
#  DEPENDENCIES:
#    - None. This is the root timing authority for the run.
#      BuffManager and GlobeManager listen to this one's signals.
#      Register this autoload BEFORE BuffManager and GlobeManager.
#
#  DESCRIPTION:
#    Tracks in-game days across a full run (default 30 days).
#    One real-world minute equals one in-game day by default,
#    giving a roughly 30-minute run at default settings.
#    Emits signals when the day changes, when a buff pick should
#    trigger, and when the run reaches its final day.
#    Pauses itself during buff picks so the player does not lose
#    run time while choosing — BuffManager calls resume() when done.
#    Displays a day counter HUD element on screen.
#    The clock and HUD do NOT start automatically — call start_run()
#    from your main game file after the player spawns.
#    Call hide_hud() on death to clear the day counter off screen.
#
#  WHAT YOU CAN ADJUST:
#    seconds_per_day     — how long one in-game day lasts in real time
#    max_days            — total days before the run ends (default 30)
#    buff_every_n_days   — how often a buff pick fires; set 0 to disable
#    HUD_FONT_SIZE       — size of the day counter text
#    HUD_MARGIN_X        — horizontal offset from the top-right corner
#    HUD_MARGIN_Y        — vertical offset from the top-right corner
#    HUD_TEXT_COLOR       — color of the day counter text
#    HUD_SHADOW_COLOR     — color of the text shadow for readability
#
#  MOD NOTES:
#    Call start_run() to begin the day timer after the player spawns.
#    Call hide_hud() to hide the day counter (e.g. on death).
#    Call advance_day() to manually skip time (useful for debug/cheats).
#    Connect to day_changed(day: int) to react to any day tick.
#    Connect to run_ended to trigger your end-game portal logic.
#    Connect to buff_pick_triggered to add custom buff sources beyond
#    the built-in BuffManager.
# ============================================================

extends Node


# ── Signals ────────────────────────────────────────────────

# Emitted every time the day counter advances.
# Passes the new day number as an integer.
# Spawners, enemy systems, and UI all listen to this.
signal day_changed(day: int)

# Emitted when current_day reaches max_days and the run is over.
# Hook this to your end-game portal scene to offer Legendary Mode
# or a return to the hub menu.
signal run_ended

# Emitted when it is time to show the player a buff pick.
# The clock is paused before this fires.
# BuffManager listens automatically and handles the UI.
# The clock resumes only after the player makes a choice.
signal buff_pick_triggered


# ── Exported settings ──────────────────────────────────────
# These appear in the Inspector if GameClock is ever attached
# to a node directly, and can be overridden in code for testing.

# How many real-world seconds make up one in-game day.
# Default 60 = one minute per day, giving a ~30 minute run.
# Lower this value (e.g. 10) for rapid debug testing.
@export var seconds_per_day   : float = 60.0

# The number of in-game days before the run ends.
# The run_ended signal fires when current_day reaches this value.
# Legendary Mode can extend this beyond 30 when implemented.
@export var max_days          : int   = 30

# A buff pick fires every this many days.
# Example: 2 means picks trigger on days 2, 4, 6, 8, 10, etc.
# Set to 0 to disable buff picks entirely (e.g. for a no-buff mode).
@export var buff_every_n_days : int   = 2


# ── HUD layout settings ───────────────────────────────────
# These control the day counter display in the top-right corner.

# Font size of the day counter label.
const HUD_FONT_SIZE    : int   = 20

# Horizontal margin from the right edge of the screen.
const HUD_MARGIN_X     : float = 20.0

# Vertical margin from the top edge of the screen.
const HUD_MARGIN_Y     : float = 20.0

# Color of the day counter text.
const HUD_TEXT_COLOR   : Color = Color(0.9, 0.85, 0.7)

# Color of the text shadow behind the day counter for readability.
const HUD_SHADOW_COLOR : Color = Color(0.0, 0.0, 0.0, 0.6)


# ── Runtime state ──────────────────────────────────────────
# These are managed internally — read them freely, but do not
# set them directly from outside this script.

# The current in-game day. Starts at 1 when the run begins.
var current_day    : int  = 1

# True while the clock is paused (buff pick open, hub screen, etc.)
var _paused        : bool = false

# True after the player chooses Legendary Mode at the end portal.
# Prevents run_ended from firing again so the run continues indefinitely.
var legendary_mode : bool = false
# max_days as configured in the inspector; enter_legendary_mode() overrides max_days.
var _default_max_days : int = 0
# True once run_ended has fired for the current run. The signal must fire exactly once:
# resume() (buff picks, chest picks) and the still-running Timer both used to re-fire it.
var _run_end_emitted : bool = false

# The internal repeating timer. Built in code — no scene needed.
var _timer      : Timer

# ── HUD references ────────────────────────────────────────
var _hud_layer       : CanvasLayer = null
var _day_label       : Label       = null
var _day_shadow      : Label       = null


# ── Lifecycle ──────────────────────────────────────────────

func _ready() -> void:
	_default_max_days = max_days
	# Build the timer entirely in code so this autoload
	# has no external scene dependency and is fully portable.
	_timer           = Timer.new()
	_timer.wait_time = seconds_per_day  # One tick = one day
	_timer.autostart = false            # Waits until start_run() is called
	_timer.one_shot  = false            # Repeats indefinitely until stopped
	_timer.timeout.connect(_on_tick)
	add_child(_timer)

	# Build the day counter HUD — starts hidden until start_run().
	_build_day_hud()
	_refresh_day_label()


# ── HUD construction ──────────────────────────────────────

# Builds a small day counter in the top-right corner of the screen.
# Fully self-contained — no external scene or font resource needed.
# Starts hidden — made visible by start_run().
func _build_day_hud() -> void:
	_hud_layer       = CanvasLayer.new()
	_hud_layer.layer = 5  # Above the game world, below buff pick UI (layer 10)
	add_child(_hud_layer)

	# Shadow label sits 2 pixels offset behind the main label
	# so the text is readable against any background.
	_day_shadow = Label.new()
	_day_shadow.add_theme_font_size_override("font_size", HUD_FONT_SIZE)
	_day_shadow.add_theme_color_override("font_color", HUD_SHADOW_COLOR)
	_day_shadow.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	# Anchor to the top-right corner of the screen.
	_day_shadow.anchor_left   = 1.0
	_day_shadow.anchor_right  = 1.0
	_day_shadow.anchor_top    = 0.0
	_day_shadow.anchor_bottom = 0.0
	_day_shadow.offset_left   = -200.0 - HUD_MARGIN_X + 2.0
	_day_shadow.offset_right  = -HUD_MARGIN_X + 2.0
	_day_shadow.offset_top    = HUD_MARGIN_Y + 2.0
	_hud_layer.add_child(_day_shadow)

	# Main day counter label.
	_day_label = Label.new()
	_day_label.add_theme_font_size_override("font_size", HUD_FONT_SIZE)
	_day_label.add_theme_color_override("font_color", HUD_TEXT_COLOR)
	_day_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	# Anchor to the top-right corner of the screen.
	_day_label.anchor_left   = 1.0
	_day_label.anchor_right  = 1.0
	_day_label.anchor_top    = 0.0
	_day_label.anchor_bottom = 0.0
	_day_label.offset_left   = -200.0 - HUD_MARGIN_X
	_day_label.offset_right  = -HUD_MARGIN_X
	_day_label.offset_top    = HUD_MARGIN_Y
	_hud_layer.add_child(_day_label)

	# Start hidden — shown when start_run() is called.
	_hud_layer.visible = false


# Updates the day counter label text.
func _refresh_day_label() -> void:
	var text : String
	if legendary_mode:
		text = "Day %d — LEGENDARY" % current_day
	else:
		text = "Day %d / %d" % [current_day, max_days]
	if _day_label != null:
		_day_label.text = text
	if _day_shadow != null:
		_day_shadow.text = text


# ── Internal timer callback ────────────────────────────────

func _on_tick() -> void:
	# Ignore ticks while paused.
	# The timer still runs internally, but we simply skip
	# advancing the day — no time is lost or gained.
	if _paused:
		return

	advance_day()


# ── Public API ─────────────────────────────────────────────

# Advances the day by one and fires the appropriate signals.
# Called automatically each timer tick.
# Can be called manually for debug skipping or cheat keys.
func advance_day() -> void:
	current_day += 1
	_refresh_day_label()
	emit_signal("day_changed", current_day)

	# Check if a buff pick should fire on this day.
	# We pause first so the player does not lose run time
	# while the buff UI is open. BuffManager calls resume()
	# once the player makes their pick.
	# Note: if this is also the final day, run_ended fires
	# inside resume() after the buff pick resolves cleanly.
	if buff_every_n_days > 0 and current_day % buff_every_n_days == 0 \
			and not GlobalRunData.debug_no_buffs:
		pause()
		emit_signal("buff_pick_triggered")
		return

	# Check if the run has reached its end.
	# Legendary mode disables the end trigger — the run continues indefinitely.
	if current_day >= max_days and not legendary_mode:
		pause()
		_emit_run_ended_once()


# Pauses the day timer.
# Called automatically before buff picks and at run end.
# Can also be called externally — e.g. when opening a pause
# menu, entering the hub, or triggering a cutscene.
func pause() -> void:
	_paused = true


# Resumes the day timer after a pause.
# BuffManager calls this automatically after the player picks a buff.
# If the run ended on the same tick as a buff pick triggered,
# run_ended fires here so it is never skipped.
func resume() -> void:
	# Once the run is over the clock must stay stopped: a late buff/chest pick calling
	# resume() used to restart ticking and fire run_ended again (a second portal).
	if _run_end_emitted and not legendary_mode:
		return
	_paused = false

	# Handle the edge case where a buff pick fires on the final day.
	# We deferred run_ended until the pick resolved — fire it now.
	if current_day >= max_days and not legendary_mode:
		_paused = true
		_emit_run_ended_once()


func _emit_run_ended_once() -> void:
	if _run_end_emitted:
		return
	_run_end_emitted = true
	emit_signal("run_ended")


# Starts the clock for a new run. Resets to day 1, shows the HUD,
# and begins ticking. Call this from your main game file after
# the player spawns.
func start_run() -> void:
	# A previous Legendary run must not leak into this one.
	legendary_mode = false
	_run_end_emitted = false
	max_days       = _default_max_days
	current_day    = 1
	_paused        = false
	_refresh_day_label()
	_timer.start()

	# Show the day counter now that the run has started.
	if _hud_layer != null:
		_hud_layer.visible = true


# Enters Legendary Mode — the run continues beyond day 30 indefinitely.
# The day counter switches to "Day X — LEGENDARY" and run_ended never fires again.
func enter_legendary_mode() -> void:
	legendary_mode = true
	max_days       = 99999
	_paused        = false
	# Keep the day's elapsed progress: the Timer never stopped, restarting it threw it away.
	if _timer.is_stopped():
		_timer.start()
	_refresh_day_label()


# Hides the day counter HUD and stops the timer.
# Call this on death or when returning to the menu.
func hide_hud() -> void:
	if _hud_layer != null:
		_hud_layer.visible = false
	_timer.stop()
	_paused = true
