# ============================================================
#  FILE: audio_manager.gd
#  PATH: res://scripts/audio_manager.gd
#  ATTACHED TO: Autoload (AudioManager)
#  USED BY: brute_player.gd, brute_ai.gd, BuffManager.gd, global UI
#  DESCRIPTION: Global audio controller. Handles fading music 
#  tracks, managing volume buses, and spawning 2D/3D one-shot sounds.
#  MOD NOTES: Added UI sound preloads and global helpers for 
#  potion pickups and buff selections.
# ============================================================

extends Node

const MENU_MUSIC_PATH: String = "res://Music & background images/Ambience Abyss.wav"
const GAMEPLAY_MUSIC_PATH: String = "res://Music & background images/ActionFlick Vol2 Determined Main.wav"

var menu_music: AudioStream = preload("res://Music & background images/Ambience Abyss.wav")
var gameplay_music: AudioStream = preload("res://Music & background images/ActionFlick Vol2 Determined Main.wav")

# UI Sounds
var ui_pickup_sound: AudioStream = preload("res://Music & background images/Sound Effects/pickup.mp3")
var ui_buff_choice_sound: AudioStream = preload("res://Music & background images/Sound Effects/pick buff.mp3")
var ui_click_sound: AudioStream = preload("res://addons/kenney_ui_audio/mouseclick1.wav")

var music_player: AudioStreamPlayer
var fade_tween: Tween

var master_volume_linear: float = 1.0
var music_volume_linear: float = 0.65 
var sfx_volume_linear: float = 1.0

var menu_music_gain_db: float = 8.0
var gameplay_music_gain_db: float = -10.0 

var current_music_kind: String = ""
var allow_music_loop: bool = true

# Object pool for 2D one-shot sound effects.
# Avoids creating and freeing AudioStreamPlayer nodes every call.
const SFX_POOL_SIZE : int = 8
var _sfx_pool : Array[AudioStreamPlayer] = []
var _sfx_pool_index : int = 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	music_player = AudioStreamPlayer.new()
	music_player.name = "MusicPlayer"
	music_player.bus = get_music_bus_name()
	music_player.autoplay = false
	music_player.stream = null
	add_child(music_player)

	music_player.finished.connect(_on_music_player_finished)

	_build_sfx_pool()
	# Sync internal volume state from SettingsManager once all autoloads are ready.
	call_deferred("_sync_from_settings")


func _build_sfx_pool() -> void:
	for i in SFX_POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = get_sfx_bus_name()
		p.autoplay = false
		add_child(p)
		_sfx_pool.append(p)

func play_pickup() -> void:
	play_one_shot(ui_pickup_sound, 0.0, 1.0)

func play_buff_choice() -> void:
	play_one_shot(ui_buff_choice_sound, 0.0, 1.0)

func play_ui_click() -> void:
	play_one_shot(ui_click_sound, 0.0, 1.0)


# Recursively wires every BaseButton descendant of root (Button, OptionButton,
# CheckBox, CheckButton…) to play_ui_click on press.
# Works on code-built UIs where find_children type-filter may miss subclasses.
func wire_click_sounds(root: Node) -> void:
	if root is BaseButton:
		var btn := root as BaseButton
		if not btn.pressed.is_connected(play_ui_click):
			btn.pressed.connect(play_ui_click)
	for child in root.get_children():
		wire_click_sounds(child)


func play_menu_music() -> void:
	if music_player == null:
		return

	if music_player.stream == menu_music and music_player.playing and current_music_kind == "menu":
		return

	_sync_from_settings()
	_stop_fade()
	allow_music_loop = true
	current_music_kind = "menu"

	music_player.bus = get_music_bus_name()
	music_player.stream = menu_music
	music_player.volume_db = get_effective_music_playback_db(menu_music_gain_db)
	music_player.play()

func play_gameplay_music() -> void:
	if music_player == null:
		return

	if music_player.stream == gameplay_music and music_player.playing and current_music_kind == "gameplay":
		return

	_sync_from_settings()
	_stop_fade()
	allow_music_loop = true
	current_music_kind = "gameplay"

	music_player.bus = get_music_bus_name()
	music_player.stream = gameplay_music
	music_player.volume_db = get_effective_music_playback_db(gameplay_music_gain_db)
	music_player.play()

func stop_music() -> void:
	if music_player == null:
		return

	allow_music_loop = false
	current_music_kind = ""
	_stop_fade()
	music_player.stop()

func fade_to_gameplay_music(fade_out_duration: float = 1.0, fade_in_duration: float = 1.0) -> void:
	if music_player == null:
		return

	_stop_fade()
	allow_music_loop = false

	if not music_player.playing:
		play_gameplay_music()
		return

	fade_tween = create_tween()
	fade_tween.tween_property(
		music_player,
		"volume_db",
		-40.0,
		fade_out_duration
	)

	await fade_tween.finished

	if music_player == null:
		return

	music_player.stop()
	music_player.bus = get_music_bus_name()
	music_player.stream = gameplay_music
	music_player.volume_db = -40.0
	current_music_kind = "gameplay"
	allow_music_loop = true
	music_player.play()

	fade_tween = create_tween()
	fade_tween.tween_property(
		music_player,
		"volume_db",
		get_effective_music_playback_db(gameplay_music_gain_db),
		fade_in_duration
	)

func fade_out_music(duration: float = 1.0) -> void:
	if music_player == null or not music_player.playing:
		return

	allow_music_loop = false
	current_music_kind = ""
	_stop_fade()

	fade_tween = create_tween()
	fade_tween.tween_property(
		music_player,
		"volume_db",
		-40.0,
		duration
	)

	await fade_tween.finished

	if music_player != null:
		music_player.stop()

func set_master_volume(linear_value: float) -> void:
	master_volume_linear = clampf(linear_value, 0.0, 1.0)
	_apply_bus_volumes()
	_save_to_settings("MasterSlider", master_volume_linear)

func set_music_volume(linear_value: float) -> void:
	music_volume_linear = clampf(linear_value, 0.0, 1.0)
	_apply_bus_volumes()
	_save_to_settings("MusicSlider", music_volume_linear)

	if music_player != null and music_player.playing:
		if current_music_kind == "menu":
			music_player.volume_db = get_effective_music_playback_db(menu_music_gain_db)
		elif current_music_kind == "gameplay":
			music_player.volume_db = get_effective_music_playback_db(gameplay_music_gain_db)
		else:
			music_player.volume_db = get_effective_music_playback_db(0.0)

func set_sfx_volume(linear_value: float) -> void:
	sfx_volume_linear = clampf(linear_value, 0.0, 1.0)
	_apply_bus_volumes()
	_save_to_settings("SFXSlider", sfx_volume_linear)


# Reads saved volume settings from SettingsManager (0–100 scale) and syncs
# AudioManager's internal 0–1 linear state + bus volumes.  Safe to call any
# time; silently skips if SettingsManager is not loaded.
func _sync_from_settings() -> void:
	if not has_node("/root/SettingsManager"):
		return
	master_volume_linear = clampf(SettingsManager.get_setting("MasterSlider", 100.0) / 100.0, 0.0, 1.0)
	music_volume_linear  = clampf(SettingsManager.get_setting("MusicSlider",   65.0) / 100.0, 0.0, 1.0)
	sfx_volume_linear    = clampf(SettingsManager.get_setting("SFXSlider",    100.0) / 100.0, 0.0, 1.0)
	_apply_bus_volumes()


# Persists a single volume key back to SettingsManager (converts 0–1 → 0–100).
func _save_to_settings(key: String, linear_value: float) -> void:
	if not has_node("/root/SettingsManager"):
		return
	SettingsManager.gameplay_settings[key] = clampf(linear_value * 100.0, 0.0, 100.0)
	SettingsManager.save_settings()

func play_one_shot(stream: AudioStream, volume_db: float = 0.0, pitch_scale: float = 1.0) -> void:
	if stream == null:
		return

	# Grab the next player from the pool. If it's still playing,
	# it gets interrupted — acceptable for rapid-fire SFX.
	var player : AudioStreamPlayer = _sfx_pool[_sfx_pool_index]
	_sfx_pool_index = (_sfx_pool_index + 1) % SFX_POOL_SIZE

	player.bus = get_sfx_bus_name()
	player.stream = stream
	player.volume_db = get_effective_sfx_playback_db(volume_db)
	player.pitch_scale = pitch_scale
	player.play()

func play_3d_one_shot(stream: AudioStream, pos: Vector3, volume_db: float = 0.0, pitch_scale: float = 1.0, max_dist: float = 25.0) -> void:
	if stream == null:
		return

	var player := AudioStreamPlayer3D.new()
	player.bus = get_sfx_bus_name()
	player.stream = stream
	player.volume_db = get_effective_sfx_playback_db(volume_db)
	player.pitch_scale = pitch_scale
	player.max_distance = max_dist
	
	get_tree().current_scene.add_child(player)
	player.global_position = pos
	player.play()
	player.finished.connect(player.queue_free)

func get_music_bus_name() -> String:
	if AudioServer.get_bus_index("Music") != -1:
		return "Music"
	return "Master"

func get_sfx_bus_name() -> String:
	if AudioServer.get_bus_index("SFX") != -1:
		return "SFX"
	return "Master"

func get_effective_music_playback_db(base_gain_db: float = 0.0) -> float:
	if AudioServer.get_bus_index("Music") != -1:
		return base_gain_db
	return _linear_to_db(music_volume_linear) + base_gain_db

func get_effective_sfx_playback_db(base_gain_db: float = 0.0) -> float:
	if AudioServer.get_bus_index("SFX") != -1:
		return base_gain_db
	return _linear_to_db(sfx_volume_linear) + base_gain_db

func _on_music_player_finished() -> void:
	if music_player == null:
		return

	if not allow_music_loop:
		return

	match current_music_kind:
		"menu":
			music_player.bus = get_music_bus_name()
			music_player.stream = menu_music
			music_player.volume_db = get_effective_music_playback_db(menu_music_gain_db)
			music_player.play()

		"gameplay":
			music_player.bus = get_music_bus_name()
			music_player.stream = gameplay_music
			music_player.volume_db = get_effective_music_playback_db(gameplay_music_gain_db)
			music_player.play()

func _apply_bus_volumes() -> void:
	var master_index := AudioServer.get_bus_index("Master")
	if master_index != -1:
		AudioServer.set_bus_volume_db(master_index, _linear_to_db(master_volume_linear))

	var music_index := AudioServer.get_bus_index("Music")
	if music_index != -1:
		AudioServer.set_bus_volume_db(music_index, _linear_to_db(music_volume_linear))

	var sfx_index := AudioServer.get_bus_index("SFX")
	if sfx_index != -1:
		AudioServer.set_bus_volume_db(sfx_index, _linear_to_db(sfx_volume_linear))

func _linear_to_db(value: float) -> float:
	if value <= 0.0001:
		return -80.0
	return linear_to_db(value)

func _stop_fade() -> void:
	if fade_tween != null and fade_tween.is_valid():
		fade_tween.kill()
