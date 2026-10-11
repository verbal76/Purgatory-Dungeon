# ==============================================================================
# File Name: camera_fx.gd
# Path: res://scripts/camera_fx.gd
#
# Description:
#   One node per player ("CameraFx", added by CharacterBase) that owns the camera feel:
#     * RENDER-RATE SMOOTHING. Physics runs at 30 Hz, so the body (and the camera on it) used to move in 30 Hz steps. The
#       camera arm is offset every rendered frame by -(1 - fraction) x the last tick's movement (and the head-bob's), which
#       is the interpolated position without touching the body, the physics or the look yaw (that stays immediate).
#     * TRAUMA SHAKE (squared, noise driven) as camera roll + a small sideways offset, scaled by the Screen Shake setting.
#     * FOV PUNCH, PITCH KICK and a landing DIP (critically damped, back to rest).
#     * HIT-STOP: briefly freezes animation speed on the attacker and the target (never Engine.time_scale: that would also
#       slow audio, physics and the awaiting timers).
#     * SCREEN FLASHES on its own CanvasLayer: a radial damage vignette scaled by the hit, a low-health pulse, heal / block /
#       acid tints. One textured quad; no 3D transparency in front of the camera.
#   All motion effects honour Juice.motion_scale() (0 = off). Nothing allocates per frame.
# ==============================================================================
extends Node

const Juice := preload("res://scripts/juice.gd")

const TRAUMA_DECAY := 1.7        # per second
const SHAKE_ROLL_DEG := 1.3      # at trauma 1.0, scale 1
const SHAKE_SIDE_M := 0.05
const FOV_MAX_PUNCH := 8.0       # degrees: a hard cap on a phone
const SMOOTH_TELEPORT_M := 1.5   # a bigger step than this is a teleport: no smoothing
const LOW_HEALTH_FRACTION := 0.30

var player: CharacterBody3D = null
var camera: Camera3D = null
var arm: Node3D = null
var anim_player: AnimationPlayer = null

var trauma: float = 0.0
var _fov_base: float = 75.0
var _fov_off: float = 0.0
var _pitch_kick: float = 0.0     # radians
var _dip: float = 0.0            # metres (positive = camera down)
var _dip_vel: float = 0.0
var _arm_base: Vector3 = Vector3.ZERO
var _noise: FastNoiseLite = null
var _t: float = 0.0
var _smooth_on: bool = true

# smoothing state
var _p_prev: Vector3 = Vector3.ZERO
var _p_curr: Vector3 = Vector3.ZERO
var _by_prev: float = 0.0
var _by_curr: float = 0.0
var _have_prev: bool = false

# death camera
var _dead: bool = false
var _death_t: float = 0.0
var _death_drop: float = 0.0
const DEATH_SECONDS := 1.3
const DEATH_ROLL_DEG := 24.0
const DEATH_DROP_M := 0.55
const DEATH_FOV_DEG := -6.0

# screen layer
var _layer: CanvasLayer = null
var _vignette: TextureRect = null
var _flash_color: Color = Color(0.85, 0.05, 0.05)
var _flash_alpha: float = 0.0
var _low_health: bool = false
var _low_t: float = 0.0
var _health_frac: float = 1.0

# hit-stop
var _stop_until_ms: int = 0
var _stopped: Array = []          # [[AnimationPlayer, restore_scale], ...]
const STOP_SCALE := 0.04

static var _vignette_tex: Texture2D = null


func setup(p_player: CharacterBody3D, p_camera: Camera3D, p_arm: Node3D, p_anim: AnimationPlayer) -> void:
	player = p_player
	camera = p_camera
	arm = p_arm
	anim_player = p_anim
	if camera != null:
		_fov_base = camera.fov
	if arm != null:
		_arm_base = arm.position
	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 1.0
	_noise.seed = randi()
	_build_layer()
	set_process(true)
	set_physics_process(true)


func _build_layer() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "CameraFxLayer"
	_layer.layer = 9   # above the HUD, below the damage fan (25), menus and the loading screen
	add_child(_layer)
	_vignette = TextureRect.new()
	_vignette.name = "Vignette"
	_vignette.texture = _vignette_texture()
	_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vignette.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_vignette.stretch_mode = TextureRect.STRETCH_SCALE
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette.modulate = Color(1, 1, 1, 0)
	_vignette.visible = false
	_layer.add_child(_vignette)


## A radial falloff with a clear centre: the screen edges tint, the middle (where the fight is) stays readable.
static func _vignette_texture() -> Texture2D:
	if _vignette_tex != null:
		return _vignette_tex
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0))
	g.set_color(1, Color(1, 1, 1, 1))
	g.set_offset(0, 0.42)
	g.set_offset(1, 1.0)
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.08, 1.08)
	t.width = 128
	t.height = 128
	_vignette_tex = t
	return t


# ── public API ──────────────────────────────────────────────────────────────────

func add_trauma(amount: float) -> void:
	var s := Juice.motion_scale()
	if s <= 0.0:
		return
	trauma = minf(trauma + amount, 1.0)


func punch_fov(degrees: float) -> void:
	var s := Juice.motion_scale()
	if s <= 0.0:
		return
	_fov_off = minf(maxf(_fov_off, degrees * s), FOV_MAX_PUNCH)


func kick_pitch(degrees: float) -> void:
	var s := Juice.motion_scale()
	if s <= 0.0:
		return
	_pitch_kick = maxf(_pitch_kick, deg_to_rad(degrees) * s)


## The camera drops by `metres` and springs back (landing, heavy impact).
func dip(metres: float) -> void:
	var s := Juice.motion_scale()
	if s <= 0.0:
		return
	_dip = maxf(_dip, metres * s)


## Freeze the attacker's (and optionally the target's) animation for `seconds`.
func hit_stop(seconds: float, target: Node = null) -> void:
	var s := Juice.motion_scale()
	if s <= 0.0 or seconds <= 0.0:
		return
	var now := Time.get_ticks_msec()
	var until := now + int(seconds * 1000.0 * minf(s, 1.5))
	if now < _stop_until_ms:
		_stop_until_ms = maxi(_stop_until_ms, until)
		return
	_stop_until_ms = until
	_stopped.clear()
	_freeze(anim_player)
	if target != null and "anim_player" in target:
		_freeze(target.get("anim_player") as AnimationPlayer)


func _freeze(ap: AnimationPlayer) -> void:
	if ap == null or not is_instance_valid(ap):
		return
	if ap.speed_scale <= STOP_SCALE + 0.001:
		return
	_stopped.append([ap, ap.speed_scale])
	ap.speed_scale = STOP_SCALE


func _release_stop() -> void:
	for e in _stopped:
		var ap: AnimationPlayer = e[0]
		# only if nobody else changed the speed meanwhile (an attack start sets its own)
		if is_instance_valid(ap) and absf(ap.speed_scale - STOP_SCALE) < 0.001:
			ap.speed_scale = float(e[1])
	_stopped.clear()


## A screen-edge tint of `alpha` (0..1) in `color` that fades out; keeps the larger of overlapping flashes.
func flash_screen(color: Color, alpha: float) -> void:
	_flash_color = color if alpha >= _flash_alpha else _flash_color
	_flash_alpha = maxf(_flash_alpha, clampf(alpha, 0.0, 0.85))


## Damage taken: the vignette strength follows the size of the hit (a 1 HP tick is a whisper, a 40 HP hit is not).
func on_damage(amount: float, max_health: float, from_acid: bool = false) -> void:
	var frac := clampf(amount / maxf(max_health, 1.0), 0.0, 1.0)
	var a := 0.16 + frac * 1.1
	flash_screen(Color(0.1, 0.75, 0.2) if from_acid else Color(0.85, 0.05, 0.05), minf(a, 0.65))
	var s := Juice.motion_scale()
	if s > 0.0 and not from_acid:
		add_trauma(0.30 + frac * 1.6)
		kick_pitch(0.8 + frac * 3.0)
	if has_node("/root/AudioManager"):
		get_node("/root/AudioManager").hit_muffle(0.35 + frac * 1.5)
		get_node("/root/AudioManager").haptic(int(clampf(18.0 + frac * 160.0, 18.0, 90.0)))


func on_health_changed(current: float, maximum: float) -> void:
	_health_frac = clampf(current / maxf(maximum, 1.0), 0.0, 1.0)
	var low := _health_frac <= LOW_HEALTH_FRACTION and current > 0.0
	if low != _low_health:
		_low_health = low
		if has_node("/root/AudioManager"):
			get_node("/root/AudioManager").set_low_health(low)
		if not low:
			_low_t = 0.0


func on_heal() -> void:
	flash_screen(Color(0.2, 0.9, 0.35), 0.32)


## The player died: the camera sinks, rolls onto its side and the view narrows a little (reduced motion: only the dark edge).
func on_death() -> void:
	_dead = true
	_death_t = 0.0
	trauma = 0.0
	flash_screen(Color(0.6, 0.02, 0.02), 0.6)
	if _low_health:
		_low_health = false
		if has_node("/root/AudioManager"):
			get_node("/root/AudioManager").set_low_health(false)


# ── per-frame ───────────────────────────────────────────────────────────────────

func _physics_process(_delta: float) -> void:
	if player == null:
		return
	var p := player.global_position
	if not _have_prev or p.distance_to(_p_curr) > SMOOTH_TELEPORT_M:
		_p_prev = p
		_p_curr = p
		_have_prev = true
	else:
		_p_prev = _p_curr
		_p_curr = p
	if camera != null:
		_by_prev = _by_curr
		_by_curr = camera.position.y


func _process(delta: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	_t += delta
	var s := Juice.motion_scale()

	# hit-stop release
	if not _stopped.is_empty() and Time.get_ticks_msec() >= _stop_until_ms:
		_release_stop()

	# trauma shake + kicks + springs
	trauma = maxf(trauma - TRAUMA_DECAY * delta, 0.0)
	_fov_off = lerpf(_fov_off, 0.0, 1.0 - exp(-delta * 11.0))
	_pitch_kick = lerpf(_pitch_kick, 0.0, 1.0 - exp(-delta * 14.0))
	# landing dip: damped spring back to 0
	_dip_vel += (-_dip * 160.0 - _dip_vel * 17.0) * delta
	_dip += _dip_vel * delta
	if absf(_dip) < 0.0003 and absf(_dip_vel) < 0.003:
		_dip = 0.0
		_dip_vel = 0.0

	if camera != null:
		var shake: float = trauma * trauma * s
		var roll: float = 0.0
		var side: float = 0.0
		if shake > 0.0005:
			roll = deg_to_rad(SHAKE_ROLL_DEG) * shake * _noise.get_noise_2d(_t * 24.0, 0.0)
			side = SHAKE_SIDE_M * shake * _noise.get_noise_2d(0.0, _t * 24.0)
		var fov_extra: float = 0.0
		if _dead and s > 0.0:
			_death_t += delta
			var k: float = 1.0 - pow(1.0 - clampf(_death_t / DEATH_SECONDS, 0.0, 1.0), 3.0)   # ease-out: falls fast, settles slowly
			roll += deg_to_rad(DEATH_ROLL_DEG) * k
			fov_extra = DEATH_FOV_DEG * k
			_death_drop = DEATH_DROP_M * k
		camera.rotation = Vector3(_pitch_kick, 0.0, roll)
		camera.position.x = side
		camera.fov = _fov_base + _fov_off + fov_extra

	_smooth_camera()
	_update_screen(delta)


# Render-rate interpolation of the body's last physics step (and the head-bob), applied as an offset on the arm.
func _smooth_camera() -> void:
	if arm == null or not _smooth_on:
		return
	var f: float = Engine.get_physics_interpolation_fraction()
	var off := Vector3.ZERO
	if _have_prev:
		var step: Vector3 = _p_curr - _p_prev
		off = -(1.0 - f) * step
		off = player.global_transform.basis.inverse() * off
		var dby: float = _by_curr - _by_prev
		if absf(dby) < 0.3:   # (the bob moves a few cm; a jump in the camera's local y is something else)
			off += arm.transform.basis * Vector3(0.0, -(1.0 - f) * dby, 0.0)
	off.y -= _dip + _death_drop
	arm.position = _arm_base + off


func _update_screen(delta: float) -> void:
	if _vignette == null:
		return
	_flash_alpha = maxf(_flash_alpha - delta * 1.35, 0.0)
	var low_a: float = 0.0
	if _low_health:
		_low_t += delta
		var pulse := 0.5 + 0.5 * sin(_low_t * TAU * 1.1)
		low_a = (0.14 + 0.10 * pulse) * (1.0 - _health_frac / LOW_HEALTH_FRACTION * 0.5)
	var a: float = maxf(_flash_alpha, low_a)
	if a <= 0.004:
		if _vignette.visible:
			_vignette.visible = false
		return
	_vignette.visible = true
	var col := _flash_color if _flash_alpha >= low_a else Color(0.8, 0.04, 0.04)
	_vignette.modulate = Color(col.r, col.g, col.b, a)


func _exit_tree() -> void:
	_release_stop()
	if _low_health and has_node("/root/AudioManager"):
		get_node("/root/AudioManager").set_low_health(false)
