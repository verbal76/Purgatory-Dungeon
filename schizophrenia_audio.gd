# ============================================================
#  FILE: schizophrenia_audio.gd
#  PATH: res://scripts/schizophrenia_audio.gd
#  ATTACHED TO: Dynamically added to Player by BuffManager
#  USED BY: BuffManager.gd
#  DESCRIPTION: Spawns overlapping 3D audio players around the 
#  player at random intervals, pitches, and volumes. Fades them 
#  in and out to simulate auditory hallucinations. Hardcoded to 
#  load the specific provided Demonic Whisper sound files.
# ============================================================

extends Node3D

var spooky_sounds: Array[AudioStream] = []
var spawn_timer: Timer

func _ready() -> void:
	spooky_sounds.append(preload("res://Music & background images/Sound Effects/Lost Child 001.wav"))
	spooky_sounds.append(preload("res://Music & background images/Sound Effects/Deadly Whispers 003.wav"))
	spooky_sounds.append(preload("res://Music & background images/Sound Effects/Apparition 003.wav"))
	spooky_sounds.append(preload("res://Music & background images/Sound Effects/Ghost Maiden Laughter 003.wav"))
	spooky_sounds.append(preload("res://Music & background images/Sound Effects/Evil Spirits 003.wav"))
	
	spawn_timer = Timer.new()
	spawn_timer.wait_time = 0.5 
	spawn_timer.timeout.connect(_on_spawn_timer_timeout)
	add_child(spawn_timer)
	spawn_timer.start()

func _on_spawn_timer_timeout() -> void:
	spawn_timer.wait_time = randf_range(0.5, 2.5)
	
	if spooky_sounds.is_empty():
		return
		
	var stream = spooky_sounds.pick_random()
	var player = AudioStreamPlayer3D.new()
	player.stream = stream
	
	if AudioServer.get_bus_index("SFX") != -1:
		player.bus = "SFX" 
	
	var angle = randf() * TAU
	var distance = randf_range(2.0, 6.0)
	
	player.position = Vector3(cos(angle) * distance, randf_range(-1.5, 2.5), sin(angle) * distance)
	player.pitch_scale = randf_range(0.75, 1.2)
	player.volume_db = -50.0

	var peak_volume_db = randf_range(-4.0, 8.0)
	
	add_child(player)
	player.play()
	
	var duration = stream.get_length()
	if duration <= 0.0:
		duration = 3.0 
		
	var tween = create_tween()
	tween.tween_property(player, "volume_db", peak_volume_db, duration * 0.3)
	tween.tween_property(player, "volume_db", -50.0, duration * 0.3).set_delay(duration * 0.4)
	
	player.finished.connect(player.queue_free)
