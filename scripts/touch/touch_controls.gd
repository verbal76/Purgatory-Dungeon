# ==============================================================================
# File Name: touch_controls.gd
# Path: res://scripts/touch/touch_controls.gd
#
# Description:
#   The touch layer. It turns fingers into the SAME semantic input actions the keyboard and
#   gamepad already produce (InputEventAction through Input.parse_input_event), so the gameplay
#   code has no separate mobile path:
#
#     keyboard / gamepad / touch  ->  semantic actions  ->  gameplay
#
#   Two selectable control schemes (Options > Gameplay > Touch Controls, setting "TouchScheme"):
#
#   TWIN-STICK (default), landscape, virtual 1280x720-ish canvas:
#     left thumb   floating move stick           -> move_left/right/forward/back (analog strength)
#     right side   floating LOOK stick           -> continuous turn RATE (deflection = speed), fed to the
#                  players as mouse-look motion once per physics frame (they need no change)
#     lower right  big ATTACK button at the rim  -> attack (hold = charge, release = fire). A finger that
#                  starts on ATTACK and drags becomes a look stick measured from the touch-down point, so
#                  the player turns while attacking without lifting; the drag never releases/re-presses it.
#     arc around   slide, kick, block (hold), burst (cooldown ring + potion count): subordinate buttons on a
#     ATTACK       semicircle on its upper/left side, plus the contextual USE one ring further out
#     top right    pause, map (toggle)
#
#   CLASSIC (exactly the original behaviour and layout):
#     left thumb   floating move stick (as above)
#     right side   swipe anywhere free to look  -> yaw, as mouse-look motion (the game has no pitch)
#     lower right  ABXY-style cluster           -> attack (hold = charge), kick, slide, block (hold)
#                  burst (potion blast, with cooldown + potion count), contextual USE
#     top right    pause, map (toggle)
#
#   Several fingers work at once (move + look + action). Anything that needs the player's full
#   attention (pause menu, buff pick) hides the layer and releases every held action.
# ==============================================================================
class_name TouchControls
extends CanvasLayer

signal action_performed(action: String)
signal released_all

const GROUP := "touch_controls"

# Settings keys (SettingsManager.gameplay_settings, percent values).
const KEY_OPACITY := "TouchOpacity"
const KEY_SCALE   := "TouchScale"
const KEY_LOOK    := "TouchLookSens"
const KEY_SCHEME  := "TouchScheme"
const DEFAULT_OPACITY := 70.0
const DEFAULT_SCALE   := 100.0
const DEFAULT_LOOK    := 100.0
const SCHEME_TWIN     := "twin"
const SCHEME_CLASSIC  := "classic"
const DEFAULT_SCHEME  := SCHEME_TWIN    # existing installs with no saved key get twin-stick

const LOOK_BASE_GAIN  := 1.4     # virtual px of swipe -> "mouse pixels" for the players' mouse-look
const STICK_RADIUS    := 100.0
const STICK_DEADZONE  := 0.16
const MIN_PRESS_MS    := 70      # a press shorter than this is stretched so polling code sees it
const MARGIN_X        := 36.0    # keep clear of rounded corners / gesture edges
const MARGIN_Y        := 28.0

# ── Twin-stick look stick (all numbers in virtual px at 100% size unless stated) ─────────────────────────
# Response: offset from the stick base / its radius = deflection d in 0..1. Inside LOOK_DEADZONE nothing
# turns; outside it x = (d - dz) / (1 - dz) is stretched over 0..1 and shaped by x^LOOK_CURVE_EXP, so a
# small push is a slow, precise aim and a full push is the maximum turn rate. Rates are physical
# (radians per second at 100% Look Sensitivity) so they do not depend on the frame time.
const LOOK_STICK_RADIUS := 90.0   # thumb travel for full deflection (the base follows the thumb past it)
const LOOK_DEADZONE     := 0.12
const LOOK_CURVE_EXP    := 1.7    # >1: fine control near the centre, fast turn at the rim
const LOOK_MAX_YAW_RATE := 4.2    # rad/s at full deflection and 100% sensitivity (~240 deg/s)
const LOOK_PITCH_RATIO  := 0.55   # pitch rate / yaw rate (the players have no pitch today and ignore it)
const LOOK_MAX_STEP     := 0.1    # s: a hitch never turns the camera more than this much in one step
# The players turn by `relative.x * mouse_sensitivity` (0.0025 rad per mouse px); the rate is expressed in
# that unit so the same input path as the classic swipe is used.
const LOOK_RAD_PER_MOUSE_PX := 0.0025

# ── Twin-stick layout (virtual px at 100% size, before the shrink for short screens) ────────────────────
const TWIN_ATTACK_R   := 100.0    # ATTACK radius: 200 px diameter (~19.8 mm at 480 dpi on a 720 px canvas)
const TWIN_SUB_R      := 56.0     # slide / kick / block / burst radius (112 px, ~11 mm)
const TWIN_USE_R      := 60.0     # contextual USE radius
const TWIN_ATTACK_IN_X := 30.0    # ATTACK rim distance from the safe-area right edge
const TWIN_ATTACK_IN_Y := 14.0    # ... and from the bottom edge (the right thumb's natural rest)
const TWIN_ARC_R      := 178.0    # distance ATTACK centre -> subordinate centres
const TWIN_ARC_GAP    := 8.0      # minimum clear px between neighbouring subordinate rims
const TWIN_ARC_START  := 165.0    # degrees, screen space (0 = right, 90 = down): slide, lower left of ATTACK
const TWIN_ARC_STEP   := 40.0     # degrees between neighbours: slide 165, kick 205, block 245, burst 285
const TWIN_USE_ANGLE  := 225.0    # USE sits on a second ring, between kick and block
const TWIN_USE_GAP    := 14.0
const TWIN_REF_H      := 720.0    # canvas height the numbers above were drawn for
const TWIN_MIN_SHRINK := 0.8      # shorter canvases shrink the cluster at most this much
# Physical minimums (diameter in mm). px per mm = dpi / 25.4 * (virtual height / screen height).
const ATTACK_MIN_MM   := 16.0
const SUB_MIN_MM      := 9.0
const FALLBACK_DPI    := 480.0    # Pixel-class panel when the OS reports nothing
const FALLBACK_SCREEN_H := 1344.0 # Pixel 10 Pro XL panel height, used only when no screen size is known

enum Owner { NONE, STICK, LOOK, BUTTON }

var touch_enabled : bool = true
var ui_scale      : float = 1.0
var opacity       : float = 0.7
var look_gain     : float = 1.0
var scheme        : String = DEFAULT_SCHEME
var dpi_override  : float = 0.0                                    # tests: pretend the panel has this dpi
var screen_override : Vector2 = Vector2.ZERO                       # tests: pretend the panel has this many physical px
var layout_override_insets : Vector4 = Vector4(-1, -1, -1, -1)   # tests: (left, top, right, bottom) virtual px
var view_override : Vector2 = Vector2.ZERO                         # tests: pretend the screen is this size

var buttons : Dictionary = {}            # action name -> TouchButton
var stick_zone : Rect2 = Rect2()
var look_zone  : Rect2 = Rect2()
var stick_default : Vector2 = Vector2.ZERO
var look_default  : Vector2 = Vector2.ZERO   # idle marker of the look stick (twin scheme)
var onboarding : Node = null

var _root : Control = null
var _stick_base : Vector2 = Vector2.ZERO
var _stick_vec  : Vector2 = Vector2.ZERO
var _stick_active : bool = false
var _stick_draw : Control = null
var _overlay_draw : Control = null       # above the buttons: the drag ring of an ATTACK drag
var _look_base : Vector2 = Vector2.ZERO  # twin: look stick base (follows the thumb past the radius)
var _look_vec  : Vector2 = Vector2.ZERO  # offset / radius, length up to 1
var _look_index : int = -1               # finger driving the look stick (-1: none)
var _atk_index : int = -1                # finger that went down on ATTACK (-1: none)
var _atk_origin : Vector2 = Vector2.ZERO # where that finger touched down (the drag is measured from here)
var _atk_vec : Vector2 = Vector2.ZERO
var _atk_aimed : bool = false            # the ATTACK finger has dragged out of the dead zone at least once
var _look_cmd : Vector2 = Vector2.ZERO   # combined, curved look command (length <= 1), applied each physics frame
var _owners : Dictionary = {}            # finger index -> {"kind": Owner, "button": String}
var _held : Dictionary = {}              # action -> strength currently pressed through us
var _press_ms : Dictionary = {}          # action -> time pressed (for MIN_PRESS_MS)
var _pending_release : Dictionary = {}   # action -> time to release
var _use_context : int = 0
var _use_label : String = ""
var _settings_poll : float = 0.0
var _status_poll : float = 0.0
var _last_view : Vector2 = Vector2.ZERO
var look_total : float = 0.0             # cumulative virtual px swiped (onboarding)
var move_time : float = 0.0              # seconds the stick has been held out (onboarding)
var look_time : float = 0.0              # seconds the look stick / attack drag has been held out (onboarding)


## True on phones (and when forced for desktop testing with PURGATORY_FORCE_TOUCH=1).
static func is_touch_platform() -> bool:
	if OS.get_environment("PURGATORY_FORCE_TOUCH") == "1":
		return true
	return OS.has_feature("android") or OS.has_feature("ios")


## Adds the layer to `parent` when this platform needs it. Returns it (or null).
static func install(parent: Node) -> TouchControls:
	if not is_touch_platform():
		return null
	var existing := parent.get_tree().get_first_node_in_group(GROUP)
	if existing != null:
		return existing as TouchControls
	var tc := TouchControls.new()
	parent.add_child(tc)
	return tc


# ── Layout (pure function: unit-testable) ─────────────────────────────────────

## Safe-area insets in virtual px from the physical safe area. screen/safe are physical px.
static func insets_from_safe_area(screen: Vector2, safe: Rect2, view: Vector2) -> Vector4:
	if screen.x <= 0.0 or screen.y <= 0.0 or safe.size.x <= 0.0 or safe.size.y <= 0.0:
		return Vector4.ZERO
	var f := Vector2(view.x / screen.x, view.y / screen.y)
	return Vector4(
		maxf(safe.position.x, 0.0) * f.x,
		maxf(safe.position.y, 0.0) * f.y,
		maxf(screen.x - (safe.position.x + safe.size.x), 0.0) * f.x,
		maxf(screen.y - (safe.position.y + safe.size.y), 0.0) * f.y)


## "classic" or "twin" from any stored value (anything unknown, including a missing key, is twin-stick).
static func scheme_from(v: Variant) -> String:
	return SCHEME_CLASSIC if str(v).strip_edges().to_lower() == SCHEME_CLASSIC else SCHEME_TWIN


## Virtual px per millimetre: the panel's dpi, scaled by how much the canvas is shrunk to fit the screen
## (virtual height / screen height). dpi <= 0 means unknown -> a Pixel-class 480 dpi panel.
static func px_per_mm(view: Vector2, screen: Vector2, dpi: float) -> float:
	var d: float = dpi if dpi > 0.0 else FALLBACK_DPI
	var sh: float = screen.y if screen.y > 0.0 else FALLBACK_SCREEN_H
	return d / 25.4 * (view.y / sh)


## Look-stick response for a stick offset (offset / radius, any length): dead zone, then x^LOOK_CURVE_EXP
## over the remaining travel. Returns a vector in the same direction with length 0..1 (1 = full rate).
static func look_response(v: Vector2) -> Vector2:
	var mag: float = v.length()
	if mag <= LOOK_DEADZONE:
		return Vector2.ZERO
	var x: float = (minf(mag, 1.0) - LOOK_DEADZONE) / (1.0 - LOOK_DEADZONE)
	return v / mag * pow(x, LOOK_CURVE_EXP)


## Turn rates (yaw, pitch) in rad/s for a look command (output of look_response) at a sensitivity factor.
static func look_rates(cmd: Vector2, sensitivity: float) -> Vector2:
	return Vector2(cmd.x * LOOK_MAX_YAW_RATE, cmd.y * LOOK_MAX_YAW_RATE * LOOK_PITCH_RATIO) * sensitivity


## Button centres/radii and touch zones for a view size, safe insets (l,t,r,b) and UI scale.
## `p_scheme` picks the layout (the classic one is the original, untouched); `ppmm` is virtual px per mm
## (<= 0: derive it from the 480 dpi Pixel fallback) and only the twin layout uses it, for its minimum sizes.
static func compute_layout(view: Vector2, insets: Vector4, s: float, p_scheme: String = SCHEME_CLASSIC, ppmm: float = 0.0) -> Dictionary:
	var l: float = insets.x + MARGIN_X
	var t: float = insets.y + MARGIN_Y
	var r: float = view.x - insets.z - MARGIN_X
	var b: float = view.y - insets.w - MARGIN_Y
	var out: Dictionary
	if p_scheme == SCHEME_TWIN:
		var mm: float = ppmm if ppmm > 0.0 else px_per_mm(view, Vector2(0.0, FALLBACK_SCREEN_H), FALLBACK_DPI)
		out = _layout_twin(view, l, t, r, b, s, mm)
	else:
		out = _layout_classic(view, l, t, r, b, s)
	# Large UI scales must never push a button off the usable area: clamp every centre inside it.
	var safe: Rect2 = out["safe"]
	for name in out["buttons"]:
		var spec: Array = out["buttons"][name]
		var rad: float = spec[1]
		var c: Vector2 = spec[0]
		c.x = clampf(c.x, safe.position.x + rad, maxf(safe.end.x - rad, safe.position.x + rad))
		c.y = clampf(c.y, safe.position.y + rad, maxf(safe.end.y - rad, safe.position.y + rad))
		out["buttons"][name] = [c, rad]
	return out


static func _layout_classic(view: Vector2, l: float, t: float, r: float, b: float, s: float) -> Dictionary:
	var cluster := Vector2(r - 184.0 * s, b - 176.0 * s)
	return {
		"safe": Rect2(l, t, r - l, b - t),
		"buttons": {
			"attack": [cluster + Vector2(0.0, 92.0) * s, 84.0 * s],
			"kick":   [cluster + Vector2(122.0, 0.0) * s, 62.0 * s],
			"jump":   [cluster + Vector2(-122.0, -4.0) * s, 62.0 * s],   # "Slide (Evade)"
			"block":  [cluster + Vector2(0.0, -98.0) * s, 62.0 * s],
			"AOE":    [cluster + Vector2(-252.0, 62.0) * s, 58.0 * s],
			"equip":  [cluster + Vector2(-172.0, -228.0) * s, 74.0 * s],
			"ui_menu": [Vector2(r - 40.0 * s, t + 112.0 * s), 38.0 * s],
			"minimap": [Vector2(r - 40.0 * s, t + 112.0 * s + 100.0 * s), 38.0 * s],
		},
		"stick_default": Vector2(l + 168.0 * s, b - 150.0 * s),
		"look_default": Vector2(view.x * 0.70, view.y * 0.50),
		"stick_zone": Rect2(0.0, view.y * 0.28, view.x * 0.40, view.y * 0.72),
		"look_zone": Rect2(view.x * 0.40, 0.0, view.x * 0.60, view.y),
	}


## Twin-stick layout. ATTACK sits at the lower-right rim; slide, kick, block and burst are spaced
## TWIN_ARC_STEP degrees apart on a semicircle of radius TWIN_ARC_R around it (upper/left side, so the right
## thumb hops to them without crossing the move stick); USE sits on a second ring. Sizes are floored by the
## physical minimums (ATTACK_MIN_MM / SUB_MIN_MM) and the arc radius grows when needed so that neither ATTACK
## and the arc nor neighbouring arc buttons can overlap.
static func _layout_twin(view: Vector2, l: float, t: float, r: float, b: float, s: float, ppmm: float) -> Dictionary:
	var k: float = s * clampf(view.y / TWIN_REF_H, TWIN_MIN_SHRINK, 1.0)
	var ra: float = maxf(TWIN_ATTACK_R * k, ATTACK_MIN_MM * 0.5 * ppmm)
	var rs: float = maxf(TWIN_SUB_R * k, SUB_MIN_MM * 0.5 * ppmm)
	var ru: float = maxf(TWIN_USE_R * k, SUB_MIN_MM * 0.5 * ppmm)
	var c := Vector2(r - ra - TWIN_ATTACK_IN_X * k, b - ra - TWIN_ATTACK_IN_Y * k)
	var chord_r: float = (2.0 * rs + TWIN_ARC_GAP * k) / (2.0 * sin(deg_to_rad(TWIN_ARC_STEP) * 0.5))
	var arc: float = maxf(maxf(TWIN_ARC_R * k, ra + rs + TWIN_ARC_GAP * k), chord_r)
	var spots: Dictionary = {}
	var order: Array[String] = ["jump", "kick", "block", "AOE"]
	for i in order.size():
		var a: float = deg_to_rad(TWIN_ARC_START + TWIN_ARC_STEP * float(i))
		spots[order[i]] = [c + Vector2(cos(a), sin(a)) * arc, rs]
	var ua: float = deg_to_rad(TWIN_USE_ANGLE)
	var ur: float = arc + rs + ru + TWIN_USE_GAP * k
	spots["equip"] = [c + Vector2(cos(ua), sin(ua)) * ur, ru]
	spots["attack"] = [c, ra]
	spots["ui_menu"] = [Vector2(r - 40.0 * s, t + 112.0 * s), 38.0 * s]
	spots["minimap"] = [Vector2(r - 40.0 * s, t + 112.0 * s + 100.0 * s), 38.0 * s]
	var stick_def := Vector2(l + 168.0 * s, b - 150.0 * s)
	# Idle look-stick marker: left of the whole cluster at the move stick's height, never on top of the move marker.
	var lr: float = LOOK_STICK_RADIUS * s
	var cluster_left: float = c.x - ur * absf(cos(ua)) - ru
	var look_x: float = clampf(cluster_left - 24.0 * s - lr, stick_def.x + 2.0 * lr + 16.0 * s, view.x * 0.62)
	return {
		"safe": Rect2(l, t, r - l, b - t),
		"buttons": spots,
		"stick_default": stick_def,
		"look_default": Vector2(look_x, stick_def.y),
		"stick_zone": Rect2(0.0, view.y * 0.28, view.x * 0.40, view.y * 0.72),
		"look_zone": Rect2(view.x * 0.40, 0.0, view.x * 0.60, view.y),
	}


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 80
	process_mode = Node.PROCESS_MODE_ALWAYS   # must notice pause / focus loss to release inputs
	add_to_group(GROUP)
	add_to_group(MobileUi.GROUP_OPT_OUT)
	scheme = _stored_scheme()
	_apply_settings()
	_strip_mouse_bindings()

	_root = Control.new()
	_root.name = "TouchRoot"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_stick_draw = Control.new()
	_stick_draw.name = "StickVisual"
	_stick_draw.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stick_draw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stick_draw.draw.connect(_draw_stick)
	_root.add_child(_stick_draw)

	_make_button("attack", "attack", "", TouchButton.Mode.HOLD)
	_make_button("kick", "kick", "", TouchButton.Mode.HOLD)
	_make_button("jump", "slide", "", TouchButton.Mode.HOLD)
	_make_button("block", "block", "", TouchButton.Mode.HOLD)
	_make_button("AOE", "burst", "", TouchButton.Mode.HOLD)
	_make_button("equip", "use", "USE", TouchButton.Mode.HOLD)
	_make_button("ui_menu", "pause", "", TouchButton.Mode.HOLD)
	_make_button("minimap", "map", "", TouchButton.Mode.TOGGLE)
	buttons["equip"].visible = false

	_overlay_draw = Control.new()
	_overlay_draw.name = "DragRing"
	_overlay_draw.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay_draw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_draw.draw.connect(_draw_overlay)
	_root.add_child(_overlay_draw)

	var ob_script := load("res://scripts/touch/touch_onboarding.gd")
	if ob_script != null:
		onboarding = ob_script.new()
		onboarding.name = "Onboarding"
		_root.add_child(onboarding)
		onboarding.setup(self)

	get_viewport().size_changed.connect(_relayout)
	_relayout()


func _exit_tree() -> void:
	release_all()


## Screens that take over the whole display (death, run end) switch the layer off so its buttons never
## sit over - or swallow taps meant for - their own buttons.
func set_enabled(on: bool) -> void:
	touch_enabled = on
	if not on:
		release_all()
	if _root != null:
		_root.visible = on and not get_tree().paused


func _notification(what: int) -> void:
	# Phone call, Home button, app switcher, screen lock: never leave an input stuck down.
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT \
			or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		release_all()


# A finger also produces emulated mouse clicks, and the keyboard map binds left/right mouse to
# attack and block: without this, tapping ANYWHERE (the stick, the swipe area) would attack. Only
# the touch platforms do this; desktop keeps its mouse bindings.
func _strip_mouse_bindings() -> void:
	for action in ["attack", "block", "kick", "AOE", "jump", "equip", "minimap"]:
		if not InputMap.has_action(action):
			continue
		for e in InputMap.action_get_events(action):
			if e is InputEventMouseButton:
				InputMap.action_erase_event(action, e)


func _make_button(action: String, icon: String, text: String, mode: TouchButton.Mode) -> void:
	var b := TouchButton.new()
	b.name = "Btn_" + action
	b.setup(action, icon, mode)
	b.label = text
	_root.add_child(b)
	buttons[action] = b


func _apply_settings() -> void:
	opacity = clampf(_setting(KEY_OPACITY, DEFAULT_OPACITY) / 100.0, 0.15, 1.0)
	ui_scale = clampf(_setting(KEY_SCALE, DEFAULT_SCALE) / 100.0, 0.6, 1.6)
	look_gain = clampf(_setting(KEY_LOOK, DEFAULT_LOOK) / 100.0, 0.2, 3.0)


func _stored_scheme() -> String:
	if has_node("/root/SettingsManager"):
		return scheme_from(SettingsManager.gameplay_settings.get(KEY_SCHEME, DEFAULT_SCHEME))
	return DEFAULT_SCHEME


func is_twin() -> bool:
	return scheme == SCHEME_TWIN


## Switches the scheme now (Options does it through the setting, which the poll below picks up): every
## finger and held action is let go, the buttons are re-laid out and the hints follow the new scheme.
func set_scheme(p_scheme: String) -> void:
	var want: String = scheme_from(p_scheme)
	if want == scheme:
		return
	release_all()
	scheme = want
	_relayout()
	if onboarding != null and onboarding.has_method("on_scheme_changed"):
		onboarding.on_scheme_changed()


## Virtual px per mm on this device (see px_per_mm).
func device_px_per_mm() -> float:
	var screen: Vector2 = screen_override
	if screen.y <= 0.0 and get_window() != null:
		screen = Vector2(get_window().size)
	if screen.y <= 0.0:
		screen = Vector2(DisplayServer.screen_get_size())
	screen.y = maxf(screen.y, view_size().y)   # a panel is never smaller than the canvas drawn on it (tiny headless windows)
	var dpi: float = dpi_override if dpi_override > 0.0 else float(DisplayServer.screen_get_dpi())
	return px_per_mm(view_size(), screen, dpi)


func _setting(key: String, default_value: float) -> float:
	if has_node("/root/SettingsManager"):
		return SettingsManager.get_setting(key, default_value)
	return default_value


## The size of the screen in virtual pixels (what the layout is computed against).
func view_size() -> Vector2:
	if view_override != Vector2.ZERO:
		return view_override
	return get_viewport().get_visible_rect().size


func _relayout() -> void:
	if _root == null:
		return
	var view: Vector2 = view_size()
	_last_view = view
	var insets: Vector4
	if layout_override_insets.x >= 0.0:
		insets = layout_override_insets
	else:
		insets = insets_from_safe_area(Vector2(DisplayServer.screen_get_size()), Rect2(DisplayServer.get_display_safe_area()), view)
	var lay: Dictionary = compute_layout(view, insets, ui_scale, scheme, device_px_per_mm())
	for action in lay["buttons"]:
		var spec: Array = lay["buttons"][action]
		if buttons.has(action):
			(buttons[action] as TouchButton).place(spec[0], spec[1])
	stick_default = lay["stick_default"]
	look_default = lay["look_default"]
	stick_zone = lay["stick_zone"]
	look_zone = lay["look_zone"]
	_root.modulate.a = opacity
	if _stick_draw != null:
		_stick_draw.queue_redraw()
	if _overlay_draw != null:
		_overlay_draw.queue_redraw()


# ── Per-frame housekeeping ────────────────────────────────────────────────────

func _process(delta: float) -> void:
	var paused: bool = get_tree().paused
	if _root != null:
		_root.visible = touch_enabled and not paused
	if paused:
		if not _held.is_empty() or not _owners.is_empty():
			release_all()
		_poll_settings(delta)   # Options opened from the pause menu: the layer is ready when the game resumes
		return
	# Deferred releases for very short taps.
	if not _pending_release.is_empty():
		var now: int = Time.get_ticks_msec()
		for action in _pending_release.keys():
			if now >= int(_pending_release[action]):
				_pending_release.erase(action)
				_send(action, false, 0.0)
	if _stick_active and _stick_vec.length() > STICK_DEADZONE:
		move_time += delta
	_poll_settings(delta)
	_status_poll += delta
	if _status_poll >= 0.1:
		_status_poll = 0.0
		_refresh_button_status()


# Settings are polled twice a second (opacity, size, sensitivity, scheme): cheap, and no signal plumbing.
func _poll_settings(delta: float) -> void:
	_settings_poll += delta
	if _settings_poll < 0.5:
		return
	_settings_poll = 0.0
	var o := opacity
	var sc := ui_scale
	_apply_settings()
	var scheme_changed: bool = _stored_scheme() != scheme
	if scheme_changed:
		set_scheme(_stored_scheme())   # releases, re-lays out
	elif not is_equal_approx(o, opacity) or not is_equal_approx(sc, ui_scale) or view_size() != _last_view:
		_relayout()


## Twin look stick / ATTACK drag: one look event per physics frame, a turn RATE (not a distance), so the
## result does not depend on the frame time. Fed through the same mouse-motion path the classic swipe uses.
func _physics_process(delta: float) -> void:
	if _look_cmd == Vector2.ZERO or get_tree().paused or not touch_enabled:
		return
	look_step(delta)


## Applies one look step of `delta` seconds from the current look command; returns the mouse-motion px sent.
func look_step(delta: float) -> Vector2:
	if _look_cmd == Vector2.ZERO:
		return Vector2.ZERO
	var dt: float = minf(delta, LOOK_MAX_STEP)
	look_time += dt
	var px: Vector2 = look_rates(_look_cmd, look_gain) / LOOK_RAD_PER_MOUSE_PX * dt
	_emit_mouse_motion(px)
	return px


# Burst cooldown ring + potion count from the live player and wallet.
func _refresh_button_status() -> void:
	var b: TouchButton = buttons.get("AOE")
	if b == null:
		return
	var player := get_tree().get_first_node_in_group("player")
	_refresh_charge(player)
	var cd: float = 0.0
	if player != null:
		var remain: float = 0.0
		var total: float = 2.5
		if "_aoe_cooldown" in player:
			remain = float(player.get("_aoe_cooldown"))
		elif "_dome_cooldown" in player:
			remain = float(player.get("_dome_cooldown"))
		cd = clampf(remain / total, 0.0, 1.0)
	var potions: int = 0
	if has_node("/root/SaveManager") and not SaveManager.current_profile.is_empty():
		potions = int(SaveManager.current_profile.get("meta_currency", 0))
	var badge: String = str(potions)
	if not is_equal_approx(b.cooldown, cd) or b.badge != badge:
		b.cooldown = cd
		b.badge = badge
		b.queue_redraw()


# Hold-to-charge progress of the Rapid Attack (both classes expose it) as an ember ring on ATTACK.
func _refresh_charge(player: Node) -> void:
	var atk: TouchButton = buttons.get("attack")
	if atk == null:
		return
	var ch: float = 0.0
	if player != null and "_rapid_attack_charge" in player:
		ch = clampf(float(player.get("_rapid_attack_charge")), 0.0, 1.0)
	if not is_equal_approx(atk.charge, ch):
		atk.charge = ch
		atk.queue_redraw()


# ── Contextual USE button ─────────────────────────────────────────────────────

## Called (call_group) by things the player can interact with when they come into / out of range.
func set_use_context(active: bool, text: String = "USE") -> void:
	_use_context = maxi(_use_context + (1 if active else -1), 0)
	_use_label = text
	var b: TouchButton = buttons.get("equip")
	if b != null:
		b.visible = _use_context > 0
		b.label = text if text != "" else "USE"
		b.queue_redraw()
	if _use_context == 0 and _held.has("equip"):
		_send("equip", false, 0.0)


# ── Input routing ─────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if not touch_enabled or get_tree().paused:
		return
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_touch_down(st.index, st.position)
		else:
			_touch_up(st.index)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		_touch_move(sd.index, sd.position, sd.relative)
		get_viewport().set_input_as_handled()


func _nearest_button(p: Vector2) -> TouchButton:
	var best: TouchButton = null
	var best_d: float = INF
	for action in buttons:
		var b: TouchButton = buttons[action]
		if b.hit(p):
			var d: float = p.distance_to(b.center) / maxf(b.radius, 1.0)
			if d < best_d:
				best_d = d
				best = b
	return best


# Ownership: every finger is owned by exactly ONE thing from touch-down to touch-up, so fingers never
# cross-talk. Buttons win (a touch on a button is that button); otherwise the left lower zone is the
# move stick and the right zone is the look stick (twin) / a swipe (classic). A finger that starts on ATTACK
# in the twin scheme stays a BUTTON finger and additionally measures a look drag from its touch-down point.
func _touch_down(index: int, p: Vector2) -> void:
	if _owners.has(index):
		return
	var b := _nearest_button(p)
	if b != null:
		_owners[index] = {"kind": Owner.BUTTON, "button": b.action}
		if is_twin() and b.action == "attack" and _atk_index < 0:
			_atk_index = index
			_atk_origin = p
			_atk_vec = Vector2.ZERO
			_atk_aimed = false
		_button_down(b)
		return
	if stick_zone.has_point(p) and not _stick_active:
		_owners[index] = {"kind": Owner.STICK}
		_stick_active = true
		_stick_base = p
		_stick_vec = Vector2.ZERO
		_stick_draw.queue_redraw()
		return
	if not is_twin():
		_owners[index] = {"kind": Owner.LOOK}
		return
	if look_zone.has_point(p) and _look_index < 0:
		_owners[index] = {"kind": Owner.LOOK}
		_look_index = index
		_look_base = p
		_look_vec = Vector2.ZERO
		_update_look_cmd()
		_stick_draw.queue_redraw()
		return
	_owners[index] = {"kind": Owner.NONE}   # a stray extra finger: owned (so it cannot turn into anything later), does nothing


func _touch_move(index: int, p: Vector2, rel: Vector2) -> void:
	var o: Dictionary = _owners.get(index, {})
	if o.is_empty():
		return
	match int(o["kind"]):
		Owner.STICK:
			var delta: Vector2 = p - _stick_base
			var radius: float = STICK_RADIUS * ui_scale
			if delta.length() > radius:
				# Floating stick: the base follows the thumb so it never runs out of travel.
				_stick_base = p - delta.normalized() * radius
				delta = p - _stick_base
			_stick_vec = delta / radius
			_apply_stick()
			_stick_draw.queue_redraw()
		Owner.LOOK:
			if is_twin():
				_look_base = _follow(_look_base, p)
				_look_vec = (p - _look_base) / (LOOK_STICK_RADIUS * ui_scale)
				_update_look_cmd()
				_stick_draw.queue_redraw()
			else:
				_look(rel)
		Owner.BUTTON:
			if index == _atk_index:
				_atk_origin = _follow(_atk_origin, p)
				_atk_vec = (p - _atk_origin) / (LOOK_STICK_RADIUS * ui_scale)
				if not _atk_aimed and _atk_vec.length() > LOOK_DEADZONE:
					_atk_aimed = true
					action_performed.emit("aim")   # the onboarding "drag from Attack to aim" hint completes on this
				_update_look_cmd()
				_overlay_draw.queue_redraw()


## Floating base: stays put while the finger is within the look radius, then trails it at exactly that radius.
func _follow(base: Vector2, p: Vector2) -> Vector2:
	var radius: float = LOOK_STICK_RADIUS * ui_scale
	var d: Vector2 = p - base
	if d.length() > radius:
		return p - d.normalized() * radius
	return base


## Combines the look stick and the ATTACK drag (normally only one is live) into the command applied each
## physics frame: both responses added, limited to full deflection.
func _update_look_cmd() -> void:
	var c: Vector2 = look_response(_look_vec) + look_response(_atk_vec)
	if c.length() > 1.0:
		c = c.normalized()
	_look_cmd = c


func _touch_up(index: int) -> void:
	var o: Dictionary = _owners.get(index, {})
	if o.is_empty():
		return
	_owners.erase(index)
	match int(o["kind"]):
		Owner.STICK:
			_stick_active = false
			_stick_vec = Vector2.ZERO
			_apply_stick()
			_stick_draw.queue_redraw()
		Owner.LOOK:
			if index == _look_index:
				_look_index = -1
				_look_vec = Vector2.ZERO
				_update_look_cmd()
				_stick_draw.queue_redraw()
		Owner.BUTTON:
			if index == _atk_index:
				_atk_index = -1
				_atk_vec = Vector2.ZERO
				_atk_aimed = false
				_update_look_cmd()   # releasing ATTACK ends the drag: the turn stops, the attack releases below
				_overlay_draw.queue_redraw()
			var b: TouchButton = buttons.get(o["button"])
			if b != null:
				_button_up(b)


func _button_down(b: TouchButton) -> void:
	if b.mode == TouchButton.Mode.TOGGLE:
		b.toggled_on = not b.toggled_on
		_send(b.action, b.toggled_on, 1.0)
	else:
		b.pressed_visual = true
		_send(b.action, true, 1.0)
	b.queue_redraw()
	action_performed.emit(b.action)


func _button_up(b: TouchButton) -> void:
	if b.mode == TouchButton.Mode.TOGGLE:
		return
	b.pressed_visual = false
	b.queue_redraw()
	# Polling gameplay code (Input.is_action_just_pressed) needs the press to span a frame.
	var since: int = Time.get_ticks_msec() - int(_press_ms.get(b.action, 0))
	if since < MIN_PRESS_MS:
		_pending_release[b.action] = int(_press_ms.get(b.action, 0)) + MIN_PRESS_MS
	else:
		_send(b.action, false, 0.0)


func _apply_stick() -> void:
	var v: Vector2 = _stick_vec
	var mag: float = v.length()
	if mag < STICK_DEADZONE:
		v = Vector2.ZERO
	else:
		v = v.normalized() * ((mag - STICK_DEADZONE) / (1.0 - STICK_DEADZONE))
	# Each direction is its own analog action (Input.get_axis subtracts the opposite pair).
	_send_axis("move_left", maxf(-v.x, 0.0))
	_send_axis("move_right", maxf(v.x, 0.0))
	_send_axis("move_forward", maxf(-v.y, 0.0))
	_send_axis("move_back", maxf(v.y, 0.0))


func _send_axis(action: String, strength: float) -> void:
	_send(action, strength > 0.0, strength)


func _look(rel: Vector2) -> void:
	look_total += rel.length()
	_emit_mouse_motion(rel * LOOK_BASE_GAIN * look_gain)


## One mouse-look motion event: the single path both schemes use to turn the players.
func _emit_mouse_motion(px: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.device = 0   # a real-mouse-like event; touch-emulated mouse motion (device -1) is ignored by the players
	ev.relative = px
	ev.position = view_size() * 0.5
	Input.parse_input_event(ev)


## Sends one semantic action event (only on change). strength 0 / pressed false releases.
func _send(action: String, pressed: bool, strength: float) -> void:
	var was: float = float(_held.get(action, 0.0))
	if pressed and strength > 0.0:
		if is_equal_approx(was, strength):
			return
		_held[action] = strength
		if was == 0.0:
			_press_ms[action] = Time.get_ticks_msec()
	else:
		if was == 0.0:
			return
		_held.erase(action)
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed and strength > 0.0
	ev.strength = strength if ev.pressed else 0.0
	Input.parse_input_event(ev)


## Releases everything held through the touch layer and forgets all fingers.
func release_all() -> void:
	_owners.clear()
	_pending_release.clear()
	_stick_active = false
	_stick_vec = Vector2.ZERO
	_look_index = -1
	_look_vec = Vector2.ZERO
	_atk_index = -1
	_atk_vec = Vector2.ZERO
	_atk_aimed = false
	_look_cmd = Vector2.ZERO   # nothing keeps turning after a background / lock / pause
	for action in _held.keys():
		var ev := InputEventAction.new()
		ev.action = action
		ev.pressed = false
		ev.strength = 0.0
		Input.parse_input_event(ev)
	_held.clear()
	for action in buttons:
		var b: TouchButton = buttons[action]
		b.pressed_visual = false
		if b.mode == TouchButton.Mode.TOGGLE:
			b.toggled_on = false
		b.queue_redraw()
	if _stick_draw != null:
		_stick_draw.queue_redraw()
	if _overlay_draw != null:
		_overlay_draw.queue_redraw()
	released_all.emit()


# ── Drawing ───────────────────────────────────────────────────────────────────

const STICK_IDLE_ALPHA := 0.62   # resting joystick: faint but always findable (the opacity setting scales it further)


## Floating sticks: a dark radial well with a faint iron rim and a bone/iron thumb. Cached textures only;
## redrawn when a stick changes, never per frame. The look stick (twin scheme) uses the same language as the move
## stick, always visible at rest (idle alpha) so the player can find it, ember-rimmed while held.
func _draw_stick() -> void:
	_draw_one_stick(_stick_base if _stick_active else stick_default, _stick_vec, STICK_RADIUS * ui_scale, _stick_active)
	if is_twin():
		var live: bool = _look_index >= 0
		_draw_one_stick(_look_base if live else look_default, _look_vec, LOOK_STICK_RADIUS * ui_scale, live)


func _draw_one_stick(base: Vector2, vec: Vector2, radius: float, active: bool) -> void:
	var a: float = 1.0 if active else STICK_IDLE_ALPHA
	var tint := Color(1, 1, 1, a)
	_stick_draw.draw_texture_rect(TouchButton.stick_base_texture(), Rect2(base - Vector2(radius, radius), Vector2(radius, radius) * 2.0), false, tint)
	_stick_draw.draw_arc(base, radius - 1.5, 0.0, TAU, 56, Color(PUI.EDGE.lightened(0.2), a), 3.0, true)
	_stick_draw.draw_arc(base, radius - 4.0, PI * 1.08, PI * 1.62, 20, Color(PUI.EDGE_BRASS.r, PUI.EDGE_BRASS.g, PUI.EDGE_BRASS.b, 0.55 * a), 1.5, true)
	var kr: float = radius * 0.42
	var knob: Vector2 = base + vec.limit_length(1.0) * radius
	_stick_draw.draw_texture_rect(TouchButton.stick_knob_texture(), Rect2(knob - Vector2(kr, kr), Vector2(kr, kr) * 2.0), false, tint)
	var ring: Color = PUI.EMBER if active else PUI.EDGE_BRASS
	_stick_draw.draw_arc(knob, kr - 1.5, 0.0, TAU, 40, Color(ring.r, ring.g, ring.b, a), 3.0, true)


## Drag ring of a finger that went down on ATTACK and is aiming: a faint ember ring around the touch-down
## point and a small thumb dot (above the buttons, so ATTACK does not hide it). Nothing while it is not dragging.
func _draw_overlay() -> void:
	if _atk_index < 0 or _atk_vec.length() <= LOOK_DEADZONE * 0.5:
		return
	var radius: float = LOOK_STICK_RADIUS * ui_scale
	var ring := PUI.EMBER
	var dot: Vector2 = _atk_origin + _atk_vec.limit_length(1.0) * radius
	_overlay_draw.draw_arc(_atk_origin, radius, 0.0, TAU, 48, Color(0, 0, 0, 0.35), 5.0, true)
	_overlay_draw.draw_arc(_atk_origin, radius, 0.0, TAU, 48, Color(ring.r, ring.g, ring.b, 0.6), 3.0, true)
	_overlay_draw.draw_line(_atk_origin, dot, Color(ring.r, ring.g, ring.b, 0.5), 3.0, true)
	_overlay_draw.draw_circle(_atk_origin, 5.0 * ui_scale, Color(ring.r, ring.g, ring.b, 0.6))
	_overlay_draw.draw_circle(dot, 13.0 * ui_scale, Color(ring.r, ring.g, ring.b, 0.65))
	_overlay_draw.draw_arc(dot, 13.0 * ui_scale, 0.0, TAU, 20, Color(PUI.EMBER_BRIGHT.r, PUI.EMBER_BRIGHT.g, PUI.EMBER_BRIGHT.b, 0.95), 2.5, true)
