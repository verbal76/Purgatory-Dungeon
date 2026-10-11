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

const MENU_MUSIC_PATH: String = "res://Music & background images/Ambience Abyss.ogg"
const GAMEPLAY_MUSIC_PATH: String = "res://Music & background images/ActionFlick Vol2 Determined Main.ogg"

# Ogg Vorbis (about 2 MB for both, was 39 MB of PCM that sat in memory for the whole session). Looped by the stream itself.
var menu_music: AudioStream = _looped(preload("res://Music & background images/Ambience Abyss.ogg"))
var gameplay_music: AudioStream = _looped(preload("res://Music & background images/ActionFlick Vol2 Determined Main.ogg"))

# UI Sounds
var ui_pickup_sound: AudioStream = preload("res://Music & background images/Sound Effects/pickup.mp3")
var ui_buff_choice_sound: AudioStream = preload("res://Music & background images/Sound Effects/pick buff.mp3")
var ui_click_sound: AudioStream = preload("res://addons/kenney_ui_audio/mouseclick1.wav")
var ui_hover_sound: AudioStream = preload("res://addons/kenney_ui_audio/rollover1.wav")

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

static func _looped(stream: AudioStream) -> AudioStream:
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	return stream


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
	_build_3d_pool()
	_build_juice()
	# Sync internal volume state from SettingsManager once all autoloads are ready.
	call_deferred("_sync_from_settings")


func _build_sfx_pool() -> void:
	for i in SFX_POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = get_sfx_bus_name()
		p.autoplay = false
		add_child(p)
		_sfx_pool.append(p)
		_slot_priority.append(0)
		_slot_started_ms.append(0)

func play_pickup() -> void:
	play_one_shot(ui_pickup_sound, 0.0, 1.0)

func play_buff_choice() -> void:
	play_one_shot(ui_buff_choice_sound, 0.0, 1.0)

func play_ui_click() -> void:
	play_one_shot(ui_click_sound, -2.0, randf_range(0.96, 1.06), 2, 25)


## Hover / focus tick for menu buttons (the Kenney rollover clip, quiet).
func play_ui_hover() -> void:
	play_one_shot(ui_hover_sound, -12.0, randf_range(0.95, 1.08), 0, 40)


# Recursively wires every BaseButton descendant of root (Button, OptionButton,
# CheckBox, CheckButton…) to play_ui_click on press.
# Works on code-built UIs where find_children type-filter may miss subclasses.
func wire_click_sounds(root: Node) -> void:
	if root is BaseButton:
		var btn := root as BaseButton
		if not btn.pressed.is_connected(play_ui_click):
			btn.pressed.connect(play_ui_click)
		_wire_button_feel(btn)
	for child in root.get_children():
		wire_click_sounds(child)


# Hover / focus / press feel for every wired menu button: a soft tick and a small swell on hover (not on touch screens, where there is
# no hover), a quick squash while pressed. Buttons stay where the layout puts them: only their scale changes, around their centre.
const BTN_HOVER_SCALE : float = 1.035
const BTN_PRESS_SCALE : float = 0.965


func _wire_button_feel(btn: BaseButton) -> void:
	if btn.has_meta("feel_wired"):
		return
	btn.set_meta("feel_wired", true)
	btn.mouse_entered.connect(_on_button_hover.bind(btn))
	btn.mouse_exited.connect(_btn_scale.bind(btn, 1.0, 0.1))
	btn.focus_entered.connect(_on_button_focus.bind(btn))
	btn.focus_exited.connect(_btn_scale.bind(btn, 1.0, 0.1))
	btn.button_down.connect(_btn_scale.bind(btn, BTN_PRESS_SCALE, 0.05))
	btn.button_up.connect(_on_button_up.bind(btn))


func _on_button_hover(btn: BaseButton) -> void:
	if btn.disabled or _is_touch_screen():
		return
	play_ui_hover()
	_btn_scale(btn, BTN_HOVER_SCALE, 0.08)


func _on_button_focus(btn: BaseButton) -> void:
	if btn.disabled:
		return
	if not _is_touch_screen():
		play_ui_hover()
	_btn_scale(btn, BTN_HOVER_SCALE, 0.08)


func _on_button_up(btn: BaseButton) -> void:
	_btn_scale(btn, BTN_HOVER_SCALE if btn.is_hovered() and not _is_touch_screen() else 1.0, 0.08)


func _is_touch_screen() -> bool:
	return TouchControls.is_touch_platform()


func _btn_scale(btn: BaseButton, target: float, seconds: float) -> void:
	if not is_instance_valid(btn) or not btn.is_inside_tree():
		return
	btn.pivot_offset = btn.size * 0.5
	if btn.has_meta("feel_tween"):
		var old: Tween = btn.get_meta("feel_tween") as Tween
		if old != null and old.is_valid():
			old.kill()
	var tw: Tween = btn.create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)   # menus run while the tree is paused
	tw.tween_property(btn, "scale", Vector2.ONE * target, seconds).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	btn.set_meta("feel_tween", tw)


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
	stop_ambience()

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
	start_ambience()

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

# Pool-slot bookkeeping: which sound each slot is playing, how important it is and when it started, so a new sound takes a FREE
# slot first and only steals the least important / oldest one when all are busy (a swing + hit + grunt in one frame no longer
# cut each other off), and a per-stream minimum gap stops a kill burst from stacking one clip into mush.
const DEFAULT_MIN_GAP_MS : int = 35
var _slot_priority : PackedInt32Array = PackedInt32Array()
var _slot_started_ms : PackedInt64Array = PackedInt64Array()
var _last_play_ms : Dictionary = {}   # stream instance id -> msec of its last start


func _gap_ok(stream: AudioStream, min_gap_ms: int) -> bool:
	var now: int = Time.get_ticks_msec()
	var key: int = stream.get_instance_id()
	if now - int(_last_play_ms.get(key, -100000)) < min_gap_ms:
		return false
	_last_play_ms[key] = now
	return true


func _pick_slot(priority: int, busy_of: Callable, count: int) -> int:
	var oldest: int = -1
	var oldest_ms: int = 0x7FFFFFFFFFFF
	for i in count:
		if not bool(busy_of.call(i)):
			return i
		if _slot_priority[i] <= priority and _slot_started_ms[i] < oldest_ms:
			oldest_ms = _slot_started_ms[i]
			oldest = i
	return oldest   # -1: everything playing is more important than this sound: drop it


## priority: 0 = ambient detail, 1 = normal gameplay, 2 = player-critical / UI (never stolen by lower ones).
func play_one_shot(stream: AudioStream, volume_db: float = 0.0, pitch_scale: float = 1.0, priority: int = 1, min_gap_ms: int = DEFAULT_MIN_GAP_MS) -> void:
	if stream == null or not _gap_ok(stream, min_gap_ms):
		return
	var idx: int = _pick_slot(priority, func(i: int) -> bool: return _sfx_pool[i].playing, SFX_POOL_SIZE)
	if idx < 0:
		return
	var player : AudioStreamPlayer = _sfx_pool[idx]
	_slot_priority[idx] = priority
	_slot_started_ms[idx] = Time.get_ticks_msec()
	player.bus = get_sfx_bus_name()
	player.stream = stream
	player.volume_db = get_effective_sfx_playback_db(volume_db)
	player.pitch_scale = pitch_scale
	player.play()


# Fixed pool of positional voices (created once): the old version allocated and freed an AudioStreamPlayer3D on every hit.
const SFX3D_POOL_SIZE : int = 8
var _sfx3d_pool : Array[AudioStreamPlayer3D] = []
var _slot3d_priority : PackedInt32Array = PackedInt32Array()
var _slot3d_started_ms : PackedInt64Array = PackedInt64Array()


func _build_3d_pool() -> void:
	for i in SFX3D_POOL_SIZE:
		var p := AudioStreamPlayer3D.new()
		p.bus = get_sfx_bus_name()
		p.autoplay = false
		add_child(p)
		_sfx3d_pool.append(p)
		_slot3d_priority.append(0)
		_slot3d_started_ms.append(0)


func play_3d_one_shot(stream: AudioStream, pos: Vector3, volume_db: float = 0.0, pitch_scale: float = 1.0, max_dist: float = 25.0, priority: int = 1) -> void:
	if stream == null or not _gap_ok(stream, 0 if priority >= 2 else 20):
		return
	var best: int = -1
	var oldest_ms: int = 0x7FFFFFFFFFFF
	for i in SFX3D_POOL_SIZE:
		if not _sfx3d_pool[i].playing:
			best = i
			break
		if _slot3d_priority[i] <= priority and _slot3d_started_ms[i] < oldest_ms:
			oldest_ms = _slot3d_started_ms[i]
			best = i
	if best < 0:
		return
	var player : AudioStreamPlayer3D = _sfx3d_pool[best]
	_slot3d_priority[best] = priority
	_slot3d_started_ms[best] = Time.get_ticks_msec()
	player.bus = get_sfx_bus_name()
	player.stream = stream
	player.volume_db = get_effective_sfx_playback_db(volume_db)
	player.pitch_scale = pitch_scale
	player.max_distance = max_dist
	player.global_position = pos
	player.play()


## One of `streams` (never the same one twice in a row), with a random pitch in [pitch_lo, pitch_hi] and +-`vol_jitter_db`.
func play_varied(streams: Array, volume_db: float = 0.0, pitch_lo: float = 0.94, pitch_hi: float = 1.06, vol_jitter_db: float = 1.0, priority: int = 1) -> void:
	if streams.is_empty():
		return
	var idx: int = randi() % streams.size()
	if streams.size() > 1 and idx == _last_varied.get(streams.hash(), -1):
		idx = (idx + 1 + randi() % (streams.size() - 1)) % streams.size()
	_last_varied[streams.hash()] = idx
	play_one_shot(streams[idx] as AudioStream, volume_db + randf_range(-vol_jitter_db, vol_jitter_db), randf_range(pitch_lo, pitch_hi), priority)

var _last_varied : Dictionary = {}


## Positional version of play_varied.
func play_varied_3d(streams: Array, pos: Vector3, volume_db: float = 0.0, pitch_lo: float = 0.94, pitch_hi: float = 1.06, max_dist: float = 25.0, priority: int = 1) -> void:
	if streams.is_empty():
		return
	var idx: int = randi() % streams.size()
	if streams.size() > 1 and idx == _last_varied.get(streams.hash() + 1, -1):
		idx = (idx + 1 + randi() % (streams.size() - 1)) % streams.size()
	_last_varied[streams.hash() + 1] = idx
	play_3d_one_shot(streams[idx] as AudioStream, pos, volume_db, randf_range(pitch_lo, pitch_hi), max_dist, priority)


# ── The game-feel sound set (tools/make_juice_audio.py): loaded once, by name ──────────────────────────────────────────
const JUICE_DIR : String = "res://Music & background images/Sound Effects/juice/"
const JUICE_NAMES : Array[String] = [
	"footstep_1", "footstep_2", "footstep_3", "footstep_4", "swing_whoosh", "impact_thud", "landing_thud", "heartbeat", "tick",
	"ready_ding", "unlock_chime", "heal_chime", "pop_soft", "coin", "key_jingle", "trap_click", "day_bell", "door_slam", "explosion",
	"fireball_cast", "fireball_impact", "aggro_rumble", "death_sting", "victory_sting", "legend_sting", "torch_crackle", "cave_bed", "drip"]
const JUICE_LOOPS : Array[String] = ["heartbeat", "torch_crackle", "cave_bed"]
var _juice : Dictionary = {}


func _build_juice() -> void:
	for nm in JUICE_NAMES:
		var path: String = JUICE_DIR + nm + ".wav"
		if ResourceLoader.exists(path):
			var st := load(path) as AudioStream
			if st is AudioStreamWAV and nm in JUICE_LOOPS:
				var w := st as AudioStreamWAV
				w.loop_mode = AudioStreamWAV.LOOP_FORWARD
				w.loop_begin = 0
				w.loop_end = w.data.size() / 2   # 16-bit mono: samples
			_juice[nm] = st
	_footsteps = [_juice.get("footstep_1"), _juice.get("footstep_2"), _juice.get("footstep_3"), _juice.get("footstep_4")]
	_footsteps = _footsteps.filter(func(x): return x != null)
	_build_filters()
	_build_ambience()


func sfx(nm: String) -> AudioStream:
	return _juice.get(nm) as AudioStream


## Play a named game-feel sound (2D). Unknown names are ignored.
func play_sfx(nm: String, volume_db: float = 0.0, pitch_lo: float = 1.0, pitch_hi: float = 1.0, priority: int = 1) -> void:
	var st: AudioStream = sfx(nm)
	if st != null:
		play_one_shot(st, volume_db, randf_range(pitch_lo, pitch_hi), priority)


func play_sfx_3d(nm: String, pos: Vector3, volume_db: float = 0.0, pitch_lo: float = 1.0, pitch_hi: float = 1.0, max_dist: float = 25.0, priority: int = 1) -> void:
	var st: AudioStream = sfx(nm)
	if st != null:
		play_3d_one_shot(st, pos, volume_db, randf_range(pitch_lo, pitch_hi), max_dist, priority)


var _footsteps : Array = []


func footstep_stream() -> AudioStream:
	if _footsteps.is_empty():
		return null
	return _footsteps[randi() % _footsteps.size()] as AudioStream


## A step of the player / any walker: alternates the four variants, never twice in a row, slight pitch and volume jitter.
func play_footstep(volume_db: float = -6.0, pos: Variant = null) -> void:
	if _footsteps.is_empty():
		return
	play_varied(_footsteps, volume_db, 0.92, 1.08, 1.5, 1)


# ── Bus filters (added at run time: bus layouts load before an OTA pack can replace them) ─────────────────────────────
const FILTER_OPEN_HZ : float = 20500.0
var _music_lp : AudioEffectLowPassFilter = null
var _sfx_lp : AudioEffectLowPassFilter = null
var _filter_tween : Tween = null
var _paused_muffle : bool = false
var _low_health : bool = false
var _hit_muffle : float = 0.0   # 0..1, decays


func _build_filters() -> void:
	var mi: int = AudioServer.get_bus_index("Music")
	if mi != -1 and _music_lp == null:
		_music_lp = AudioEffectLowPassFilter.new()
		_music_lp.cutoff_hz = FILTER_OPEN_HZ
		AudioServer.add_bus_effect(mi, _music_lp)
	var si: int = AudioServer.get_bus_index("SFX")
	if si != -1 and _sfx_lp == null:
		_sfx_lp = AudioEffectLowPassFilter.new()
		_sfx_lp.cutoff_hz = FILTER_OPEN_HZ
		AudioServer.add_bus_effect(si, _sfx_lp)


func _target_music_cutoff() -> float:
	var hz: float = FILTER_OPEN_HZ
	if _paused_muffle:
		hz = 700.0
	elif _low_health:
		hz = 2600.0
	return hz


func _apply_filters(duration: float = 0.25) -> void:
	if _music_lp == null:
		return
	if _filter_tween != null and _filter_tween.is_valid():
		_filter_tween.kill()
	_filter_tween = create_tween()
	_filter_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_filter_tween.tween_property(_music_lp, "cutoff_hz", _target_music_cutoff(), duration)
	if _sfx_lp != null:
		_filter_tween.parallel().tween_property(_sfx_lp, "cutoff_hz", 3200.0 if _paused_muffle else FILTER_OPEN_HZ, duration)


## The pause menu / buff pick muffles the world a little (music a lot) and releases it on resume.
func set_pause_muffle(on: bool) -> void:
	if _paused_muffle == on:
		return
	_paused_muffle = on
	_apply_filters(0.18 if on else 0.3)


## Below about a third of health: the music dulls and a heartbeat plays; both leave when health recovers or the run ends.
func set_low_health(on: bool) -> void:
	if _low_health == on:
		return
	_low_health = on
	_apply_filters(0.5)
	if _heartbeat_player != null:
		if on:
			_heartbeat_player.stream = sfx("heartbeat")
			_heartbeat_player.volume_db = get_effective_sfx_playback_db(-4.0)
			if not _heartbeat_player.playing:
				_heartbeat_player.play()
		else:
			_heartbeat_player.stop()


## A hit dips the music for a moment (the SFX stay clear). strength 0..1.
func hit_muffle(strength: float = 0.6) -> void:
	if _music_lp == null or _paused_muffle:
		return
	if _filter_tween != null and _filter_tween.is_valid():
		_filter_tween.kill()
	_filter_tween = create_tween()
	_filter_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_filter_tween.tween_property(_music_lp, "cutoff_hz", lerpf(FILTER_OPEN_HZ, 1400.0, clampf(strength, 0.0, 1.0)), 0.04)
	_filter_tween.tween_property(_music_lp, "cutoff_hz", _target_music_cutoff(), 0.45)


# ── Ambience: a dim cave bed, torch crackle and the odd drip while a run is on (players created once) ──────────────────
var _ambience_player : AudioStreamPlayer = null
var _crackle_player : AudioStreamPlayer = null
var _heartbeat_player : AudioStreamPlayer = null
var _drip_timer : Timer = null


func _build_ambience() -> void:
	_ambience_player = AudioStreamPlayer.new()
	_ambience_player.bus = get_sfx_bus_name()
	_ambience_player.volume_db = -26.0
	add_child(_ambience_player)
	_crackle_player = AudioStreamPlayer.new()
	_crackle_player.bus = get_sfx_bus_name()
	_crackle_player.volume_db = -32.0
	add_child(_crackle_player)
	_heartbeat_player = AudioStreamPlayer.new()
	_heartbeat_player.bus = get_sfx_bus_name()
	add_child(_heartbeat_player)
	_drip_timer = Timer.new()
	_drip_timer.one_shot = true
	_drip_timer.process_mode = Node.PROCESS_MODE_PAUSABLE
	_drip_timer.timeout.connect(_on_drip)
	add_child(_drip_timer)


func start_ambience() -> void:
	if _ambience_player == null or sfx("cave_bed") == null:
		return
	_ambience_player.stream = sfx("cave_bed")
	_crackle_player.stream = sfx("torch_crackle")
	if not _ambience_player.playing:
		_ambience_player.play()
	if not _crackle_player.playing:
		_crackle_player.play()
	_drip_timer.start(randf_range(5.0, 12.0))


func stop_ambience() -> void:
	if _ambience_player == null:
		return
	_ambience_player.stop()
	_crackle_player.stop()
	_drip_timer.stop()
	set_low_health(false)


func _on_drip() -> void:
	play_sfx("drip", -20.0, 0.8, 1.2, 0)
	_drip_timer.start(randf_range(6.0, 18.0))


# ── Haptics (mobile only; Options > Vibration 0 turns it off) ───────────────────────────────────────────────────────
func haptic(duration_ms: int, amplitude: float = -1.0) -> void:
	if not (OS.has_feature("mobile") or OS.get_environment("PURGATORY_FORCE_TOUCH") == "1"):
		return
	var level: float = 0.6
	if has_node("/root/SettingsManager"):
		level = clampf(float(SettingsManager.get_setting("Vibration", 60.0)) / 100.0, 0.0, 1.0)
	if level <= 0.0:
		return
	if OS.has_feature("mobile"):
		Input.vibrate_handheld(int(round(float(duration_ms) * (0.5 + level))), amplitude if amplitude >= 0.0 else clampf(level, 0.1, 1.0))


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
