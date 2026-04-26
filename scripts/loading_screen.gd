# ============================================================
#  FILE: loading_screen.gd
#  PATH: res://scripts/loading_screen.gd
#  DESCRIPTION: Dynamically generated loading screen. Pauses
#  the SceneTree to allow EnemyManager to instantiate enemies
#  without causing live stutters. Waits for EnemyManager to
#  signal spawn_complete (minimum 3 seconds floor) before
#  fading out. Resumes gameplay music on fade start.
#  Safety maximum of 30 seconds prevents an infinite wait if
#  the enemy manager fails silently.
#
#  MOD NOTES:
#  - SURGICAL FIX: Label centered using PRESET_FULL_RECT +
#    alignment flags instead of PRESET_CENTER (which was off-center).
#  - SURGICAL FIX: Replaced hardcoded 10s timer with 3s minimum
#    floor + EnemyManager spawn_complete signal polling. The
#    screen dismisses as soon as enemies are ready, not sooner.
#  - SURGICAL FIX: Calls AudioManager.play_gameplay_music() on
#    fade start so music resumes after the paused load period.
# ============================================================

extends CanvasLayer

var bg: ColorRect
var label: Label

# Minimum seconds before we even check if spawning is done.
const MIN_DISPLAY_TIME : float = 3.0
# Safety fallback — dismiss after this many seconds regardless.
const MAX_DISPLAY_TIME : float = 30.0

var _elapsed      : float = 0.0
var _spawn_done   : bool  = false   # Set true when enemy_spawner signals complete
var _connected    : bool  = false   # True once we've connected the spawn signal
var is_fading     : bool  = false

var original_volume : float = 0.0
var bus_idx         : int   = 0

var dot_timer : float = 0.0
var dot_count : int   = 0


# _enter_tree runs before _ready and before the first visual frame.
func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 120  # Sit completely above the HUD and death screens

	# Capture and mute the Master audio bus instantly.
	bus_idx         = AudioServer.get_bus_index("Master")
	original_volume = AudioServer.get_bus_volume_db(bus_idx)
	AudioServer.set_bus_volume_db(bus_idx, -80.0)

	# Freeze physics, enemies, and player inputs instantly.
	get_tree().paused = true


func _ready() -> void:
	_build_ui_elements()


func _build_ui_elements() -> void:
	# Background — full screen solid dark rect.
	bg       = ColorRect.new()
	bg.color = Color(0.02, 0.02, 0.02, 1.0)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# Label — SURGICAL FIX: use PRESET_FULL_RECT + alignment flags so
	# the text truly centers in the viewport instead of drifting off-center.
	label = Label.new()
	label.text                  = "LOADING DUNGEON"
	label.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment    = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.add_theme_font_size_override("font_size", 32)
	label.add_theme_color_override("font_color", Color.WHITE)
	add_child(label)


func _process(delta: float) -> void:
	if is_fading:
		return

	_elapsed += delta

	# Animated dots on the loading message.
	dot_timer += delta
	if dot_timer > 0.5:
		dot_timer  = 0.0
		dot_count  = (dot_count + 1) % 4
		var dots   := ""
		for i in range(dot_count):
			dots += " ."
		label.text = "LOADING DUNGEON" + dots

	# Safety maximum — dismiss after 30 seconds regardless.
	if _elapsed >= MAX_DISPLAY_TIME:
		_start_fade_in()
		return

	# Minimum floor — don't dismiss before 3 seconds no matter what.
	if _elapsed < MIN_DISPLAY_TIME:
		return

	# After minimum floor: try to connect to the enemy_spawner signal once.
	if not _connected:
		var spawners : Array = get_tree().get_nodes_in_group("enemy_spawner")
		for spawner in spawners:
			if spawner.has_signal("spawn_complete"):
				spawner.connect("spawn_complete", _on_spawn_complete)
				_connected = true
			# Also handle the case where spawning already finished
			# before we connected (race condition safety).
			if spawner.get("_initial_spawn_done") == true:
				_spawn_done = true

	# Dismiss as soon as spawn is confirmed done.
	if _spawn_done:
		_start_fade_in()


# Called by EnemyManager via the spawn_complete signal.
func _on_spawn_complete() -> void:
	_spawn_done = true


func _start_fade_in() -> void:
	is_fading = true

	# Unpause the game so physics and AI resume.
	get_tree().paused = false

	# SURGICAL FIX: Resume gameplay music which was silenced by the load pause.
	if has_node("/root/AudioManager"):
		AudioManager.play_gameplay_music()

	var tween := create_tween()
	tween.set_parallel(true)

	# Fade visuals out cleanly.
	tween.tween_property(bg,    "modulate:a", 0.0, 1.5)
	tween.tween_property(label, "modulate:a", 0.0, 1.0)

	# Interpolate audio back to standard volume.
	tween.tween_method(_set_vol, -80.0, original_volume, 2.5)

	# Self-destruct when complete.
	tween.chain().tween_callback(queue_free)


func _set_vol(vol: float) -> void:
	AudioServer.set_bus_volume_db(bus_idx, vol)
