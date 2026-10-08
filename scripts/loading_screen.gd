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

var bg: Control          # PUI void background (near-black + faint warm vignette)
var label: Label         # "Loading the dungeon" (display face)
var _dots: Label         # animated dots in their own fixed-width slot so the title never shifts
var _content: Control    # title block, faded together with the background

# Minimum seconds before we even check if spawning is done (a floor so the screen never flashes; it used to be
# 3 s, which kept a fast device waiting on an already finished dungeon).
const MIN_DISPLAY_TIME : float = 1.2
# Rendered frames with the whole neighbourhood in place before the fade starts: the first draws of its meshes,
# lights and materials happen behind the screen instead of under the player's first steps.
const SETTLE_FRAMES : int = 3
# Safety fallback — dismiss after this many seconds regardless.
const MAX_DISPLAY_TIME : float = 30.0

var _elapsed      : float = 0.0
var _spawn_done   : bool  = false   # Set true when enemy_spawner signals complete
var _connected    : bool  = false   # True once we've connected the spawn signal
var is_fading     : bool  = false
var _gen_node     : Node  = null    # the dungeon's main node (group "dungeon_generator"), once found
var _settle       : int   = 0
var _world_hidden : bool  = false   # the root viewport's 3D rendering is off (see _enter_tree)

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

	# Nothing of the 3D world is visible behind this screen while the dungeon is being built, so it is not rendered:
	# the layout used to be drawn (hundreds of draw calls, growing every slice) under an opaque overlay on every
	# loading frame. It is switched back on (_show_world) once the neighbourhood is complete, a few frames before
	# the fade, so the first draws of its meshes, lights and materials still happen behind the screen.
	get_tree().root.disable_3d = true
	_world_hidden = true


func _ready() -> void:
	_build_ui_elements()


func _build_ui_elements() -> void:
	# Background - the design system's near-black "void" with a faint warm vignette.
	# Controls under a CanvasLayer do not inherit the root window's theme, so hand it over explicitly.
	bg = PUI.background("void")
	bg.theme = PUI.theme()
	bg.mouse_filter = Control.MOUSE_FILTER_STOP   # nothing behind a loading screen may be clicked
	add_child(bg)

	# Title block, truly centred: a brass hairline under the display-face title. The dots sit in a reserved slot to the
	# right (mirrored by an equal spacer on the left) so the changing dots never move the title.
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.theme = PUI.theme()
	add_child(center)
	_content = center

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", PUI.S3)
	center.add_child(column)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	column.add_child(row)
	var left_pad := Control.new()
	left_pad.custom_minimum_size.x = 64.0
	row.add_child(left_pad)
	label = PUI.label("Loading the dungeon", "ScreenTitle")
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(label)
	_dots = PUI.label("", "ScreenTitle")
	_dots.custom_minimum_size.x = 64.0
	row.add_child(_dots)

	var rule := PUI.divider()
	column.add_child(rule)


func _process(delta: float) -> void:
	if is_fading:
		return

	_elapsed += delta

	# Animated dots on the loading message.
	dot_timer += delta
	if dot_timer > 0.5:
		dot_timer  = 0.0
		dot_count  = (dot_count + 1) % 4
		_dots.text = ".".repeat(dot_count)

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

	# Dismiss as soon as spawn is confirmed done AND the dungeon reports the player's neighbourhood complete
	# (props, chests, orbs around the spawn), then a few settle frames.
	if _spawn_done and _entry_ready():
		if _world_hidden:
			_show_world()   # settle frames count from the first frame that renders the world
		else:
			_settle += 1
			if _settle >= SETTLE_FRAMES:
				_start_fade_in()


func _show_world() -> void:
	if _world_hidden and is_inside_tree():
		get_tree().root.disable_3d = false
	_world_hidden = false


# True when there is no staged dungeon to wait for (menus, tests) or it reports entry_is_ready.
func _entry_ready() -> bool:
	if _gen_node == null or not is_instance_valid(_gen_node):
		var nodes : Array[Node] = get_tree().get_nodes_in_group("dungeon_generator")
		_gen_node = nodes[0] if not nodes.is_empty() else null
	if _gen_node == null or not ("entry_is_ready" in _gen_node):
		return true
	return bool(_gen_node.entry_is_ready)


# Called by EnemyManager via the spawn_complete signal.
func _on_spawn_complete() -> void:
	_spawn_done = true


func _start_fade_in() -> void:
	is_fading = true
	_show_world()

	# Unpause the game so physics and AI resume.
	get_tree().paused = false

	# SURGICAL FIX: Resume gameplay music which was silenced by the load pause.
	if has_node("/root/AudioManager"):
		AudioManager.play_gameplay_music()

	var tween := create_tween()
	tween.set_parallel(true)

	# Fade visuals out cleanly.
	tween.tween_property(bg,       "modulate:a", 0.0, 1.5)
	tween.tween_property(_content, "modulate:a", 0.0, 1.0)

	# Interpolate audio back to standard volume.
	tween.tween_method(_set_vol, -80.0, original_volume, 2.5)

	# Self-destruct when complete.
	tween.chain().tween_callback(queue_free)


func _set_vol(vol: float) -> void:
	AudioServer.set_bus_volume_db(bus_idx, vol)


# If this screen is freed before its fade finishes (scene change, death, quit to menu)
# the tween dies with it and Master would stay at -80 dB: the whole game silent until
# a slider is touched. Always put the Master bus back where the settings say it belongs.
func _exit_tree() -> void:
	if _world_hidden:
		# Freed before it ever showed the world (scene change, quit): rendering must come back.
		get_tree().root.disable_3d = false
		_world_hidden = false
	if bus_idx < 0:
		return
	var target : float = original_volume
	if has_node("/root/AudioManager") and "master_volume_linear" in AudioManager:
		target = AudioManager._linear_to_db(AudioManager.master_volume_linear)
	AudioServer.set_bus_volume_db(bus_idx, target)
