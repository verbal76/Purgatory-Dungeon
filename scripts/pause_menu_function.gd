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

	_hook_controls()
	_build_display_mode_options()
	_build_resolution_options()
	_initialize_pause_menu_values()
	_apply_panel_style()
	_inject_options_button()
	_set_pause_menu_visible(false)
	_wire_button_clicks()


func _wire_button_clicks() -> void:
	if has_node("/root/AudioManager"):
		AudioManager.wire_click_sounds(self)


# ── Visual style ───────────────────────────────────────────────────────────────
func _apply_panel_style() -> void:
	# Title
	var title := find_child("PauseTitle", true, false) as Label
	if title != null:
		title.add_theme_color_override("font_color", Color(0.80, 0.18, 0.18, 1.0))
		title.add_theme_font_size_override("font_size", 30)

	# Red separator line under the title
	_inject_title_separator()

	# Style all existing buttons
	_style_all_buttons()

	# Wire percentage text onto the volume slider labels
	_wire_volume_labels()


func _make_btn_stylebox(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.set_corner_radius_all(5)
	s.content_margin_left   = 12.0
	s.content_margin_right  = 12.0
	s.content_margin_top    = 8.0
	s.content_margin_bottom = 8.0
	return s


func _style_button(btn: Button) -> void:
	btn.add_theme_font_size_override("font_size", 16)
	btn.add_theme_color_override("font_color",          Color(0.92, 0.88, 0.88))
	btn.add_theme_color_override("font_hover_color",    Color(1.00, 1.00, 1.00))
	btn.add_theme_color_override("font_pressed_color",  Color(1.00, 0.75, 0.75))
	btn.add_theme_color_override("font_focus_color",    Color(1.00, 1.00, 1.00))
	btn.add_theme_stylebox_override("normal",
		_make_btn_stylebox(Color(0.12, 0.07, 0.10), Color(0.48, 0.10, 0.10)))
	btn.add_theme_stylebox_override("hover",
		_make_btn_stylebox(Color(0.20, 0.08, 0.13), Color(0.72, 0.20, 0.18)))
	btn.add_theme_stylebox_override("pressed",
		_make_btn_stylebox(Color(0.08, 0.04, 0.07), Color(0.85, 0.28, 0.20)))
	btn.add_theme_stylebox_override("focus",
		_make_btn_stylebox(Color(0.16, 0.07, 0.11), Color(0.85, 0.28, 0.20)))


func _style_all_buttons() -> void:
	for btn in find_children("*", "Button", true):
		_style_button(btn as Button)


func _inject_title_separator() -> void:
	var vbox := find_child("PauseVBox", true, false) as VBoxContainer
	if vbox == null or vbox.find_child("TitleSep", false, false) != null:
		return
	var sep := HSeparator.new()
	sep.name = "TitleSep"
	var sep_style := StyleBoxFlat.new()
	sep_style.bg_color = Color(0.55, 0.10, 0.10, 0.85)
	sep_style.set_content_margin_all(0.0)
	sep.add_theme_stylebox_override("separator", sep_style)
	sep.add_theme_constant_override("separation", 2)
	vbox.add_child(sep)
	vbox.move_child(sep, 1)   # Right after the title


func _wire_volume_labels() -> void:
	_wire_slider_label(master_volume_slider, "Master Volume")
	_wire_slider_label(music_volume_slider,  "Music Volume")
	_wire_slider_label(sfx_volume_slider,    "SFX Volume")


# Finds the Label inside the slider's parent VBoxContainer and rewrites it to
# show the current percentage.  Reconnects value_changed so it stays in sync.
func _wire_slider_label(slider: HSlider, title: String) -> void:
	if slider == null:
		return
	var row := slider.get_parent()
	if row == null:
		return
	for child in row.get_children():
		if not (child is Label):
			continue
		var lbl := child as Label
		lbl.add_theme_color_override("font_color", Color(0.72, 0.60, 0.60))
		lbl.add_theme_font_size_override("font_size", 15)
		# Update text now
		lbl.text = "%s   %d%%" % [title, int(slider.value * 100.0)]
		# Reconnect — disconnect any existing lambda first so we don't stack duplicates
		for c in slider.value_changed.get_connections():
			if c.get("callable", Callable()).get_object() == null:
				slider.value_changed.disconnect(c.callable)
		slider.value_changed.connect(
			func(v: float): lbl.text = "%s   %d%%" % [title, int(v * 100.0)])
		break


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

	var options_btn := Button.new()
	options_btn.name = "OptionsButton"
	options_btn.text = "Options"
	options_btn.custom_minimum_size = Vector2(0, 44)
	_style_button(options_btn)
	options_btn.pressed.connect(_on_options_button_pressed)

	# Insert before ExitToMainMenuButton
	var exit_idx : int = -1
	if exit_to_main_menu_button != null:
		exit_idx = exit_to_main_menu_button.get_index()

	vbox.add_child(options_btn)
	if exit_idx >= 0:
		vbox.move_child(options_btn, exit_idx)


func _on_options_button_pressed() -> void:
	# Tell the options screen to return here (dungeon) when Back is pressed.
	# We use the static var on options_screen so no scene reference is needed.
	if ResourceLoader.exists(OPTIONS_SCENE):
		var OptionsScreen = load("res://scripts/options_screen.gd")
		if OptionsScreen:
			OptionsScreen._return_scene = DUNGEON_SCENE

	_set_pause_menu_visible(false)
	get_tree().paused = false
	get_tree().change_scene_to_file(OPTIONS_SCENE)


func open_menu() -> void:
	if _is_open:
		return

	_initialize_pause_menu_values()
	get_tree().paused = true
	_set_pause_menu_visible(true)


func close_menu() -> void:
	if not _is_open:
		return

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
