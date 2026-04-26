# ==============================================================================
# File Name: SettingsManager.gd
# Path: res://scripts/SettingsManager.gd
# Autoload Name: SettingsManager
# Description: Stores and applies all gameplay, audio, and video settings.
#              Settings are saved to the player's Documents folder so they
#              persist across reinstalls and are easy to locate and back up.
#                Windows: Documents/PurgetoryDungeon/settings.json
#                macOS:   ~/Documents/PurgetoryDungeon/settings.json
#                Linux:   ~/Documents/PurgetoryDungeon/settings.json
#              This path resolves correctly in the Godot editor and in
#              exported builds — your settings are stored on your own PC
#              when running from the editor as well.
# ==============================================================================
extends Node

const GAME_FOLDER := "PurgetoryDungeon"

# All settings in one dictionary. Keys match slider/control names used by
# the options screen. Defaults are applied on first launch (no file yet).
# WindowMode values: 0=Windowed  1=Maximized  2=Borderless Fullscreen  3=Exclusive Fullscreen
var gameplay_settings : Dictionary = {
	"MasterSlider"  : 100.0,
	"MusicSlider"   : 65.0,
	"SFXSlider"     : 100.0,
	"WindowMode"    : 2,
	"VSync"         : true,
	"HealthSlider"  : 100.0,
	"ShakeSlider"   : 50.0,
	"SpeedSlider"   : 100.0,
	"DamageSlider"  : 100.0,
	"EnemySpeed"    : 100.0,
}

# Computed in _ready() — points to Documents/PurgetoryDungeon/settings.json.
var _settings_path : String = ""


func _ready() -> void:
	_build_settings_path()
	load_settings()
	# Apply all loaded settings immediately so audio/video match on first frame.
	_apply_all()


func _build_settings_path() -> void:
	var docs : String = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	var game_dir : String = docs.path_join(GAME_FOLDER)
	if not DirAccess.dir_exists_absolute(game_dir):
		DirAccess.make_dir_recursive_absolute(game_dir)
	_settings_path = game_dir.path_join("settings.json")
	print("SettingsManager: settings → ", _settings_path)


# ── Load ────────────────────────────────────────────────────────────────────

func load_settings() -> void:
	if not FileAccess.file_exists(_settings_path):
		# First launch — write defaults so the file exists for next time.
		save_settings()
		return

	var file := FileAccess.open(_settings_path, FileAccess.READ)
	if file == null:
		return

	var parsed = JSON.parse_string(file.get_as_text())
	file.close()

	if parsed is Dictionary:
		# Merge over defaults so newly added keys always appear.
		for key in parsed.keys():
			gameplay_settings[key] = parsed[key]


# ── Save ────────────────────────────────────────────────────────────────────

func save_settings() -> void:
	if _settings_path.is_empty():
		return
	var file := FileAccess.open(_settings_path, FileAccess.WRITE)
	if file == null:
		push_warning("SettingsManager: could not write settings to " + _settings_path)
		return
	file.store_string(JSON.stringify(gameplay_settings, "\t"))
	file.close()


# ── Apply a single setting ──────────────────────────────────────────────────

func update_setting(setting_name: String, value: Variant) -> void:
	gameplay_settings[setting_name] = value

	match setting_name:
		"MasterSlider":
			_set_bus_volume("Master", float(value))
		"MusicSlider":
			_set_bus_volume("Music", float(value))
		"SFXSlider":
			_set_bus_volume("SFX", float(value))
		"WindowMode":
			apply_window_mode(int(value))
		"VSync":
			DisplayServer.window_set_vsync_mode(
				DisplayServer.VSYNC_ENABLED if value else DisplayServer.VSYNC_DISABLED)
		_:
			pass   # Gameplay sliders are read directly via get_setting()

	save_settings()


# ── Apply all saved settings (called on startup) ────────────────────────────

func _apply_all() -> void:
	_set_bus_volume("Master", float(gameplay_settings.get("MasterSlider", 100.0)))
	_set_bus_volume("Music",  float(gameplay_settings.get("MusicSlider",  65.0)))
	_set_bus_volume("SFX",    float(gameplay_settings.get("SFXSlider",   100.0)))

	apply_window_mode(int(gameplay_settings.get("WindowMode", 2)))

	var vsync : bool = bool(gameplay_settings.get("VSync", true))
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)

	_apply_custom_controls()


# ── Custom control bindings ─────────────────────────────────────────────────

# Replay any saved custom bindings over the project defaults.
# Only touches the type of binding that was remapped (keyboard vs gamepad)
# so unmodified bindings remain from project.godot.
func _apply_custom_controls() -> void:
	var controls : Dictionary = gameplay_settings.get("controls", {})
	for action in controls.keys():
		if not InputMap.has_action(action):
			continue
		var binding : Dictionary = controls[action]
		var current  : Array     = InputMap.action_get_events(action)
		if binding.has("keyboard"):
			for e in current:
				if e is InputEventKey or e is InputEventMouseButton:
					InputMap.action_erase_event(action, e)
			var new_e := deserialize_event(binding["keyboard"])
			if new_e != null:
				InputMap.action_add_event(action, new_e)
		if binding.has("gamepad"):
			current = InputMap.action_get_events(action)
			for e in current:
				if e is InputEventJoypadButton or e is InputEventJoypadMotion:
					InputMap.action_erase_event(action, e)
			var new_e := deserialize_event(binding["gamepad"])
			if new_e != null:
				InputMap.action_add_event(action, new_e)


func serialize_event(event: InputEvent) -> Dictionary:
	if event is InputEventKey:
		return {"type": "key",
				"keycode": int(event.keycode),
				"physical_keycode": int(event.physical_keycode)}
	if event is InputEventMouseButton:
		return {"type": "mouse_button",
				"button_index": int(event.button_index)}
	if event is InputEventJoypadButton:
		return {"type": "joypad_button",
				"button_index": int(event.button_index)}
	if event is InputEventJoypadMotion:
		return {"type": "joypad_motion",
				"axis": int(event.axis),
				"axis_value": float(event.axis_value)}
	return {}


func deserialize_event(data: Dictionary) -> InputEvent:
	match data.get("type", ""):
		"key":
			var e := InputEventKey.new()
			e.device           = -1
			e.keycode          = data.get("keycode", 0) as Key
			e.physical_keycode = data.get("physical_keycode", 0) as Key
			return e
		"mouse_button":
			var e := InputEventMouseButton.new()
			e.device       = -1
			e.button_index = data.get("button_index", 0) as MouseButton
			return e
		"joypad_button":
			var e := InputEventJoypadButton.new()
			e.device       = -1
			e.button_index = data.get("button_index", 0) as JoyButton
			return e
		"joypad_motion":
			var e := InputEventJoypadMotion.new()
			e.device      = -1
			e.axis        = data.get("axis", 0) as JoyAxis
			e.axis_value  = float(data.get("axis_value", 1.0))
			return e
	return null


# ── Window mode ─────────────────────────────────────────────────────────────
# mode: 0=Windowed  1=Maximized  2=Borderless Fullscreen  3=Exclusive Fullscreen

func apply_window_mode(mode: int) -> void:
	gameplay_settings["WindowMode"] = mode
	var screen_id  := DisplayServer.window_get_current_screen()
	var native_res := DisplayServer.screen_get_size(screen_id)
	match mode:
		0:  # Windowed — 80 % of native, centered
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			var w := Vector2i(int(native_res.x * 0.8), int(native_res.y * 0.8))
			DisplayServer.window_set_size(w)
			DisplayServer.window_set_position((native_res - w) / 2)
		1:  # Maximized window
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
		2:  # Borderless fullscreen (default)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
			DisplayServer.window_set_size(native_res)
		3:  # Exclusive fullscreen
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
			DisplayServer.window_set_size(native_res)
	save_settings()


# ── Helpers ─────────────────────────────────────────────────────────────────

func _set_bus_volume(bus_name: String, linear_value: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		return
	var db : float = linear_to_db(clampf(linear_value / 100.0, 0.0001, 1.0))
	AudioServer.set_bus_volume_db(idx, db)
	AudioServer.set_bus_mute(idx, linear_value <= 0.0)


# Read-only accessor used throughout the codebase.
func get_setting(setting_name: String, default: float = 100.0) -> float:
	return float(gameplay_settings.get(setting_name, default))
