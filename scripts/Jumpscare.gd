# ============================================================
#  FILE: jumpscare.gd
#  PATH: res://scripts/jumpscare.gd
#  DESCRIPTION: Full-screen jump scare overlay. Instantiated at
#               runtime by TrapManager when a jumpscare trap fires.
#               Not placed in any scene — created entirely in code.
#
#  SEQUENCE:
#    1. Scream fires immediately at +8 dB through Master bus.
#    2. SCREAM_DELAY seconds later the face slams in.
#    3. Face zooms from oversized → normal with bounce, while the
#       whole overlay shakes for SHAKE_COUNT ticks.
#    4. After DISPLAY_DURATION the overlay fades out while zooming
#       back down slightly, then frees itself.
#
#  SETUP: Assign the scary face image and scream sound in the
#         Inspector on Purgatory_Dungeon_main_game_file.tscn.
#         Those are passed here via setup() before _ready() runs.
# ============================================================

extends CanvasLayer

const SCREAM_DELAY      : float = 0.5    # Scream fires this many seconds before the image
const DISPLAY_DURATION  : float = 0.7    # Seconds face is fully visible
const FADE_IN_DURATION  : float = 0.04   # Nearly instant slam-in
const FADE_OUT_DURATION : float = 0.6    # Slower fade/zoom out
const ZOOM_START_SCALE  : float = 1.35   # Face starts this big, then slams to 1.0
const ZOOM_IN_TIME      : float = 0.14   # Seconds to slam from big to normal
const ZOOM_OUT_SCALE    : float = 0.82   # Face shrinks to this while fading out
const SHAKE_COUNT       : int   = 10     # Number of shake ticks
const SHAKE_STRENGTH    : float = 18.0   # Peak offset in pixels
const SCREAM_VOLUME_DB  : float = 8.0    # Volume boost on top of Master bus

var _texture : Texture2D   = null
var _sound   : AudioStream = null


# Called by TrapManager BEFORE add_child so resources are ready when _ready() fires.
func setup(texture: Texture2D, sound: AudioStream) -> void:
	_texture = texture
	_sound   = sound


func _ready() -> void:
	layer        = 200
	process_mode = Node.PROCESS_MODE_ALWAYS

	# ── Root control — owns modulate and scale for the whole overlay ───────────
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.modulate.a = 0.0   # Invisible until scream has built up
	add_child(root)

	# ── Black background ───────────────────────────────────────────────────────
	var bg        := ColorRect.new()
	bg.color       = Color(0.0, 0.0, 0.0, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg)

	# ── Scary face ─────────────────────────────────────────────────────────────
	if _texture != null:
		var tex_rect         := TextureRect.new()
		tex_rect.texture      = _texture
		tex_rect.expand_mode  = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(tex_rect)

	# ── Scream — fires IMMEDIATELY, before the image appears ──────────────────
	if _sound != null:
		var audio_player        := AudioStreamPlayer.new()
		audio_player.stream      = _sound
		audio_player.bus         = "Master"
		audio_player.volume_db   = SCREAM_VOLUME_DB
		root.add_child(audio_player)
		audio_player.play()

	# ── Wait one frame so root.size is valid, then set scale pivot to centre ──
	await get_tree().process_frame
	root.pivot_offset = root.size * 0.5

	# ── Wait for the scream to build before the image hits ────────────────────
	await get_tree().create_timer(SCREAM_DELAY).timeout

	# ── SLAM IN — face starts oversized then bounces to 1.0 ──────────────────
	root.scale = Vector2(ZOOM_START_SCALE, ZOOM_START_SCALE)

	var slam := create_tween().set_parallel(true)
	slam.tween_property(root, "modulate:a", 1.0, FADE_IN_DURATION)
	slam.tween_property(root, "scale",
		Vector2.ONE, ZOOM_IN_TIME).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)

	# ── Screen shake runs alongside the slam ──────────────────────────────────
	_do_shake(root)

	# ── Hold for DISPLAY_DURATION then fade + zoom out ────────────────────────
	await get_tree().create_timer(DISPLAY_DURATION).timeout

	var fade := create_tween().set_parallel(true)
	fade.tween_property(root, "modulate:a", 0.0,
		FADE_OUT_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	fade.tween_property(root, "scale",
		Vector2(ZOOM_OUT_SCALE, ZOOM_OUT_SCALE), FADE_OUT_DURATION)

	get_tree().create_timer(FADE_OUT_DURATION + 0.05).timeout.connect(queue_free)


# Shakes node.position with decaying random offsets, then returns to zero.
func _do_shake(node: Control) -> void:
	var shake_tween := create_tween()
	var strength    : float = SHAKE_STRENGTH
	for i in range(SHAKE_COUNT):
		var dir := Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)).normalized() * strength
		strength *= 0.82
		shake_tween.tween_property(node, "position", dir, 0.035)
	shake_tween.tween_property(node, "position", Vector2.ZERO, 0.07)
