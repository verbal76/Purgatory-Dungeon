extends CanvasLayer

@export var main_menu_scene_path : String = "res://scenes/MainMenu.tscn"

const OPTIONS_SCENE  : String = "res://scenes/OptionsScreen.tscn"
const DUNGEON_SCENE  : String = "res://scenes/Purgatory_Dungeon_main_game_file.tscn"


@onready var pause_shade: ColorRect = $PauseShade
@onready var pause_menu: Control = $PauseMenu

@onready var master_volume_slider: HSlider = $PauseMenu/PausePanel/PauseMargin/PauseVBox/MasterVolumeRow/MasterVolumeSlider
@onready var music_volume_slider: HSlider = $PauseMenu/PausePanel/PauseMargin/PauseVBox/MusicVolumeRow/MusicVolumeSlider
@onready var sfx_volume_slider: HSlider = $PauseMenu/PausePanel/PauseMargin/PauseVBox/SfxVolumeRow/SfxVolumeSlider

@onready var display_mode_option: OptionButton = $PauseMenu/PausePanel/PauseMargin/PauseVBox/DisplayModeRow/DisplayModeOption
@onready var resolution_option: OptionButton = $PauseMenu/PausePanel/PauseMargin/PauseVBox/ResolutionRow/ResolutionOption

@onready var resume_button: Button = $PauseMenu/PausePanel/PauseMargin/PauseVBox/ResumeButton
@onready var exit_to_main_menu_button: Button = $PauseMenu/PausePanel/PauseMargin/PauseVBox/ExitToMainMenuButton

const DISPLAY_MODE_FULLSCREEN: int = 0
const DISPLAY_MODE_WINDOWED: int = 1

var _is_open: bool = false
var _suppress_ui_callbacks: bool = false
var _resolution_list: Array[Vector2i] = []
var _pending_windowed_resolution: Vector2i = Vector2i(1280, 720)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("pause_menu")   # the Android lifecycle handler opens it when the app is backgrounded

	# The menu hangs off a CanvasLayer, which does not pass the root window's theme down: apply the shared one.
	if pause_menu != null:
		pause_menu.theme = PUI.theme()
	if pause_shade != null:
		pause_shade.theme = PUI.theme()

	_hook_controls()
	_build_display_mode_options()
	_build_resolution_options()
	_initialize_pause_menu_values()
	_apply_panel_style()
	_inject_options_button()
	if TouchControls.is_touch_platform():
		_fit_for_phone()
	_set_pause_menu_visible(false)
	_wire_button_clicks()


# Phones: Resume / Options / Exit as big buttons. Volume lives in Options (Sound), and fullscreen /
# window size mean nothing on a phone, so those rows would only crowd the 720-high canvas.
func _fit_for_phone() -> void:
	for row_name in ["MasterVolumeRow", "MusicVolumeRow", "SfxVolumeRow", "DisplayModeRow", "ResolutionRow", "ButtonSpacer"]:
		var row := find_child(row_name, true, false) as Control
		if row != null:
			row.hide()
	# The desktop panel is wider; on a phone it is a compact column. Its height is whatever the three
	# buttons need (the panel is a container), centred on the canvas.
	var panel := find_child("PausePanel", true, false) as Control
	if panel != null:
		panel.offset_left = -300.0
		panel.offset_right = 300.0
		panel.offset_top = -1.0
		panel.offset_bottom = 1.0


func _wire_button_clicks() -> void:
	if has_node("/root/AudioManager"):
		AudioManager.wire_click_sounds(self)


# ── Visual style ───────────────────────────────────────────────────────────────
# Everything comes from the shared theme: the panel is the brand surface, the title is a ScreenTitle,
# Resume is the primary action, Exit to Main Menu carries the danger edge (it abandons the run).
func _apply_panel_style() -> void:
	# veil over the paused dungeon: a light darkening + vignette (the shade node itself stays a ColorRect)
	if pause_shade != null and pause_shade.find_child("UiBackground", false, false) == null:
		pause_shade.add_child(PUI.background("veil"))

	var title := find_child("PauseTitle", true, false) as Label
	if title != null:
		title.theme_type_variation = &"ScreenTitle"

	_inject_title_separator()

	if resume_button != null:
		PUI.style_button(resume_button, "primary")
	if exit_to_main_menu_button != null:
		PUI.style_button(exit_to_main_menu_button, "danger")

	# the rows share the Options screen's components (label left, control right, HudValue read-out)
	for row_name in ["MasterVolumeRow", "MusicVolumeRow", "SfxVolumeRow", "DisplayModeRow", "ResolutionRow"]:
		var row := find_child(row_name, true, false) as Control
		if row != null:
			# slider rows are a touch shorter than option rows so the desktop panel fits a 1280x720 window
			row.custom_minimum_size.y = SettingsRows.SLIDER_H + PUI.S1 if row_name.contains("Volume") else SettingsRows.ROW_H
			for child in row.get_children():
				if child is Label:
					(child as Label).theme_type_variation = &"ShortLabel"   # same Cinzel setting names as Options
					(child as Label).custom_minimum_size.x = SettingsRows.LABEL_W - 50.0
					(child as Label).vertical_alignment = VERTICAL_ALIGNMENT_CENTER
				elif child is HSlider:
					SettingsRows.prepare_slider(child as HSlider)
				elif child is OptionButton:
					(child as OptionButton).size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_wire_volume_labels()


func _inject_title_separator() -> void:
	var vbox := find_child("PauseVBox", true, false) as VBoxContainer
	if vbox == null or vbox.find_child("TitleSep", false, false) != null:
		return
	var sep := SettingsRows.brass_line()
	sep.name = "TitleSep"
	vbox.add_child(sep)
	vbox.move_child(sep, 1)   # Right after the title


func _wire_volume_labels() -> void:
	_wire_slider_label(master_volume_slider)
	_wire_slider_label(music_volume_slider)
	_wire_slider_label(sfx_volume_slider)


# Adds the numeric read-out (HudValue, like Options) to the right of the slider and keeps it in sync.
func _wire_slider_label(slider: HSlider) -> void:
	if slider == null:
		return
	var row := slider.get_parent()
	if row == null or row.find_child("ValueLabel", false, false) != null:
		return
	var vl := SettingsRows.value_label()
	vl.name = "ValueLabel"
	row.add_child(vl)
	vl.text = "%d%%" % int(round(slider.value * 100.0))
	slider.value_changed.connect(func(v: float) -> void: vl.text = "%d%%" % int(round(v * 100.0)))


# ── Options button injection ───────────────────────────────────────────────────
# Adds an "Options" button between Resume and Exit to Main Menu.
# When pressed: saves paused state, sets return path, navigates to options.
func _inject_options_button() -> void:
	var vbox := find_child("PauseVBox", true, false) as VBoxContainer
	if vbox == null:
		return

	# Don't add twice
	if vbox.find_child("OptionsButton", false, false) != null:
		return

	var options_btn := PUI.button("Options")
	options_btn.name = "OptionsButton"
	options_btn.pressed.connect(_on_options_button_pressed)

	# Insert before ExitToMainMenuButton
	var exit_idx : int = -1
	if exit_to_main_menu_button != null:
		exit_idx = exit_to_main_menu_button.get_index()

	vbox.add_child(options_btn)
	if exit_idx >= 0:
		vbox.move_child(options_btn, exit_idx)


# Options opens as an overlay on top of the paused run. It must NOT change scene:
# change_scene_to_file() frees the whole dungeon, and returning would reload a fresh one,
# silently abandoning the run (world, enemies, clock, player position).
var _options_layer : CanvasLayer = null

func _on_options_button_pressed() -> void:
	if _options_layer != null or not ResourceLoader.exists(OPTIONS_SCENE):
		return
	var options_scene : PackedScene = load(OPTIONS_SCENE)
	var options : Control = options_scene.instantiate() as Control
	if options == null:
		return
	options.set("embedded", true)
	options.process_mode = Node.PROCESS_MODE_ALWAYS
	options.connect("closed", _on_options_closed)
	_options_layer = CanvasLayer.new()
	_options_layer.name = "OptionsOverlay"
	_options_layer.layer = 128
	_options_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_options_layer)
	_options_layer.add_child(options)
	if pause_menu != null:
		pause_menu.visible = false


func _on_options_closed() -> void:
	if _options_layer != null:
		_options_layer.queue_free()
		_options_layer = null
	if pause_menu != null and _is_open:
		pause_menu.visible = true
		if resume_button != null:
			resume_button.grab_focus()
	_initialize_pause_menu_values()   # reflect any audio/display changes made in Options


func open_menu() -> void:
	if _is_open:
		return
	# A buff pick is modal. Opening the pause menu over it let a second Escape "resume"
	# the tree while the pick UI was still up, so the world ran behind it.
	if has_node("/root/BuffManager") and BuffManager.is_picking():
		return

	_initialize_pause_menu_values()
	get_tree().paused = true
	_set_pause_menu_visible(true)


func close_menu() -> void:
	if not _is_open:
		return
	if _options_layer != null:   # never leave the Options overlay behind a resumed game
		_options_layer.queue_free()
		_options_layer = null

	_set_pause_menu_visible(false)
	get_tree().paused = false

	# SURGICAL FIX: Explicitly restart gameplay music after unpausing.
	# The audio server bus manipulation done by the loading screen can leave
	# AudioStreamPlayer in a stopped state after tree pause/resume cycles.
	# play_gameplay_music() has an idempotency guard — it does nothing if
	# music is already playing, and restarts it cleanly if it stopped.
	if has_node("/root/AudioManager"):
		AudioManager.play_gameplay_music()


func is_menu_open() -> bool:
	return _is_open


func _hook_controls() -> void:
	if resume_button != null and not resume_button.pressed.is_connected(_on_resume_button_pressed):
		resume_button.pressed.connect(_on_resume_button_pressed)

	if exit_to_main_menu_button != null and not exit_to_main_menu_button.pressed.is_connected(_on_exit_to_main_menu_button_pressed):
		exit_to_main_menu_button.pressed.connect(_on_exit_to_main_menu_button_pressed)

	if master_volume_slider != null and not master_volume_slider.value_changed.is_connected(_on_master_volume_slider_changed):
		master_volume_slider.value_changed.connect(_on_master_volume_slider_changed)

	if music_volume_slider != null and not music_volume_slider.value_changed.is_connected(_on_music_volume_slider_changed):
		music_volume_slider.value_changed.connect(_on_music_volume_slider_changed)

	if sfx_volume_slider != null and not sfx_volume_slider.value_changed.is_connected(_on_sfx_volume_slider_changed):
		sfx_volume_slider.value_changed.connect(_on_sfx_volume_slider_changed)

	if display_mode_option != null and not display_mode_option.item_selected.is_connected(_on_display_mode_option_selected):
		display_mode_option.item_selected.connect(_on_display_mode_option_selected)

	if resolution_option != null and not resolution_option.item_selected.is_connected(_on_resolution_option_selected):
		resolution_option.item_selected.connect(_on_resolution_option_selected)


func _build_display_mode_options() -> void:
	if display_mode_option == null:
		return

	display_mode_option.clear()
	display_mode_option.add_item("Fullscreen", DISPLAY_MODE_FULLSCREEN)
	display_mode_option.add_item("Windowed", DISPLAY_MODE_WINDOWED)


func _build_resolution_options() -> void:
	if resolution_option == null:
		return

	resolution_option.clear()
	_resolution_list.clear()

	var desktop_size: Vector2i = DisplayServer.screen_get_size()
	var current_window_size: Vector2i = DisplayServer.window_get_size()

	var candidates: Array[Vector2i] = [
		Vector2i(1280, 720),
		Vector2i(1366, 768),
		Vector2i(1600, 900),
		Vector2i(1920, 1080),
		Vector2i(2560, 1440),
		Vector2i(3840, 2160)
	]

	candidates.append(desktop_size)
	candidates.append(current_window_size)

	var seen: Dictionary = {}

	for size in candidates:
		if size.x < 800 or size.y < 600:
			continue

		if size.x > desktop_size.x or size.y > desktop_size.y:
			continue

		var key: String = str(size.x) + "x" + str(size.y)
		if seen.has(key):
			continue

		seen[key] = true
		_resolution_list.append(size)

	_resolution_list.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x == b.x:
			return a.y < b.y
		return a.x < b.x
	)

	for i in range(_resolution_list.size()):
		var size: Vector2i = _resolution_list[i]
		var label: String = str(size.x) + " x " + str(size.y)

		if size == desktop_size:
			label += "  (Desktop)"

		resolution_option.add_item(label, i)


func _initialize_pause_menu_values() -> void:
	_suppress_ui_callbacks = true

	# Read from SettingsManager (0–100 scale) and convert to the slider's 0–1 range.
	# This keeps the pause menu in sync with the options screen even when the player
	# changes volume there and comes back to the dungeon.
	if has_node("/root/SettingsManager"):
		if master_volume_slider != null:
			master_volume_slider.value = SettingsManager.get_setting("MasterSlider", 100.0) / 100.0
		if music_volume_slider != null:
			music_volume_slider.value = SettingsManager.get_setting("MusicSlider", 65.0) / 100.0
		if sfx_volume_slider != null:
			sfx_volume_slider.value = SettingsManager.get_setting("SFXSlider", 100.0) / 100.0

	var current_mode: int = _get_current_display_mode_value()
	if display_mode_option != null:
		var mode_index: int = _find_display_mode_index(current_mode)
		if mode_index >= 0:
			display_mode_option.select(mode_index)

	var current_window_size: Vector2i = DisplayServer.window_get_size()
	if _get_current_display_mode_value() == DISPLAY_MODE_WINDOWED:
		_pending_windowed_resolution = current_window_size

	_select_best_resolution_item(current_window_size)

	_suppress_ui_callbacks = false


func _set_pause_menu_visible(visible_value: bool) -> void:
	_is_open = visible_value

	if pause_shade != null:
		pause_shade.visible = visible_value

	if pause_menu != null:
		pause_menu.visible = visible_value

	if visible_value:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if resume_button != null:
			resume_button.grab_focus()
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _get_current_display_mode_value() -> int:
	var mode: int = DisplayServer.window_get_mode()

	if mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
		return DISPLAY_MODE_FULLSCREEN

	return DISPLAY_MODE_WINDOWED


func _find_display_mode_index(mode_value: int) -> int:
	if display_mode_option == null:
		return -1

	for i in range(display_mode_option.item_count):
		if display_mode_option.get_item_id(i) == mode_value:
			return i

	return -1


func _select_best_resolution_item(target_size: Vector2i) -> void:
	if resolution_option == null or _resolution_list.is_empty():
		return

	var best_index: int = 0
	var best_score: int = 2147483647

	for i in range(_resolution_list.size()):
		var size: Vector2i = _resolution_list[i]
		var score: int = abs(size.x - target_size.x) + abs(size.y - target_size.y)

		if score < best_score:
			best_score = score
			best_index = i

	resolution_option.select(best_index)


func _get_selected_resolution() -> Vector2i:
	if resolution_option == null or _resolution_list.is_empty():
		return _pending_windowed_resolution

	var selected_index: int = resolution_option.selected
	if selected_index < 0 or selected_index >= _resolution_list.size():
		return _pending_windowed_resolution

	return _resolution_list[selected_index]


func _apply_display_mode(mode_value: int) -> void:
	match mode_value:
		DISPLAY_MODE_FULLSCREEN:
			var desktop_size: Vector2i = DisplayServer.screen_get_size()
			DisplayServer.window_set_size(desktop_size)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)

		DISPLAY_MODE_WINDOWED:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_size(_pending_windowed_resolution)
			_center_window(_pending_windowed_resolution)


func _apply_resolution(window_size: Vector2i) -> void:
	_pending_windowed_resolution = window_size

	if _get_current_display_mode_value() == DISPLAY_MODE_WINDOWED:
		DisplayServer.window_set_size(window_size)
		_center_window(window_size)


func _center_window(window_size: Vector2i) -> void:
	var screen_size: Vector2i = DisplayServer.screen_get_size()
	var pos_x: int = int((screen_size.x - window_size.x) / 2.0)
	var pos_y: int = int((screen_size.y - window_size.y) / 2.0)
	DisplayServer.window_set_position(Vector2i(pos_x, pos_y))


func _on_resume_button_pressed() -> void:
	close_menu()


func _on_exit_to_main_menu_button_pressed() -> void:
	_set_pause_menu_visible(false)
	get_tree().paused = false
	# Leaving the run: stop the day clock/buffs/globes so a buff pick or day HUD cannot
	# appear over the main menu a minute later.
	RunLifecycle.end_run_cleanup()

	if has_node("/root/AudioManager"):
		AudioManager.play_menu_music()

	if main_menu_scene_path == "":
		push_warning("Main menu scene path is empty. Could not return to main menu.")
		return

	get_tree().change_scene_to_file(main_menu_scene_path)


func _on_master_volume_slider_changed(value: float) -> void:
	if _suppress_ui_callbacks:
		return

	if has_node("/root/AudioManager"):
		AudioManager.set_master_volume(value)


func _on_music_volume_slider_changed(value: float) -> void:
	if _suppress_ui_callbacks:
		return

	if has_node("/root/AudioManager"):
		AudioManager.set_music_volume(value)


func _on_sfx_volume_slider_changed(value: float) -> void:
	if _suppress_ui_callbacks:
		return

	if has_node("/root/AudioManager"):
		AudioManager.set_sfx_volume(value)


func _on_display_mode_option_selected(index: int) -> void:
	if _suppress_ui_callbacks:
		return

	if display_mode_option == null:
		return

	var mode_value: int = display_mode_option.get_item_id(index)
	_apply_display_mode(mode_value)


func _on_resolution_option_selected(index: int) -> void:
	if _suppress_ui_callbacks:
		return

	if index < 0 or index >= _resolution_list.size():
		return

	_apply_resolution(_resolution_list[index])
