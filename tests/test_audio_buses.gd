extends Node
## Audio bus layout + volume plumbing + loading-screen mute restore.

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	await get_tree().process_frame
	await get_tree().process_frame
	var master := AudioServer.get_bus_index("Master")
	var music := AudioServer.get_bus_index("Music")
	var sfx := AudioServer.get_bus_index("SFX")
	_check(master == 0, "Master bus exists")
	_check(music != -1 and sfx != -1, "Music and SFX buses exist")
	_check(AudioServer.get_bus_send(music) == &"Master" and AudioServer.get_bus_send(sfx) == &"Master", "Music/SFX send to Master")
	_check(AudioManager.get_music_bus_name() == "Music" and AudioManager.get_sfx_bus_name() == "SFX", "AudioManager routes to the real buses")
	_check(AudioManager.music_player.bus == &"Music", "music player is on the Music bus")
	var sfx_on_bus := 0
	for p in AudioManager._sfx_pool:
		if p.bus == &"SFX":
			sfx_on_bus += 1
	_check(sfx_on_bus == AudioManager.SFX_POOL_SIZE, "all %d pooled SFX players are on the SFX bus" % AudioManager.SFX_POOL_SIZE)

	# Sliders reach the buses, and the per-player fallback gain is not double-applied.
	AudioManager.set_music_volume(0.5)
	AudioManager.set_sfx_volume(0.25)
	AudioManager.set_master_volume(0.8)
	_check(is_equal_approx(AudioServer.get_bus_volume_db(music), linear_to_db(0.5)), "music slider sets the Music bus (%.2f dB)" % AudioServer.get_bus_volume_db(music))
	_check(is_equal_approx(AudioServer.get_bus_volume_db(sfx), linear_to_db(0.25)), "sfx slider sets the SFX bus")
	_check(is_equal_approx(AudioServer.get_bus_volume_db(master), linear_to_db(0.8)), "master slider sets the Master bus")
	_check(is_equal_approx(AudioManager.get_effective_music_playback_db(-3.0), -3.0), "no double attenuation on the music player")
	_check(is_equal_approx(AudioManager.get_effective_sfx_playback_db(-3.0), -3.0), "no double attenuation on SFX")

	# Settings -> buses (what the Options screen uses).
	SettingsManager.update_setting("MusicSlider", 40.0)
	_check(is_equal_approx(AudioServer.get_bus_volume_db(music), linear_to_db(0.4)), "SettingsManager music slider reaches the Music bus")
	SettingsManager.update_setting("SFXSlider", 0.0)
	_check(AudioServer.is_bus_mute(sfx), "SFX slider at 0 mutes the SFX bus")
	SettingsManager.update_setting("SFXSlider", 100.0)
	_check(not AudioServer.is_bus_mute(sfx), "SFX unmutes when raised")

	# Loading screen freed mid-fade must not leave the game silent.
	var before := AudioServer.get_bus_volume_db(master)
	var ls := CanvasLayer.new()
	ls.set_script(load("res://scripts/loading_screen.gd"))
	add_child(ls)
	_check(AudioServer.get_bus_volume_db(master) <= -79.0, "loading screen mutes Master while loading")
	await get_tree().process_frame
	ls.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(absf(AudioServer.get_bus_volume_db(master) - before) < 0.01, "Master restored when the loading screen is freed early (%.2f vs %.2f)" % [AudioServer.get_bus_volume_db(master), before])
	get_tree().paused = false

	print("test_audio_buses: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
