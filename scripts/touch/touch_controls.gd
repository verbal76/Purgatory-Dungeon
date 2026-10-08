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
#     right side   empty screen is inert: a finger that is not on a button does nothing
#     lower right  big ATTACK button at the rim  -> attack, ONE attack per touch (see "ATTACK gesture" below). The
#                  same finger is the look control: a finger that starts on ATTACK and drags looks through EXACTLY the
#                  Classic swipe path (finger displacement -> mouse-look motion, see _look), multiplied by a fixed
#                  compact-input gain that stands in for the smaller travel area (compact_gain). A drag NEVER attacks;
#                  a tap or a short rest attacks once; holding never repeats or charges.
#     arc around   slide, kick, block (hold), burst (cooldown ring + potion count): subordinate buttons on a
#     ATTACK       semicircle on its upper/left side, plus the contextual USE one ring further out
#     top right    pause, map (toggle)
#
#   CLASSIC (exactly the original behaviour and layout):
#     left thumb   floating move stick (as above)
#     right side   swipe anywhere free to look  -> yaw, as mouse-look motion (the game has no pitch)
#     lower right  ABXY-style cluster           -> attack (press/hold/release: one press = one attack, holding never charges or repeats), kick, slide, block (hold)
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

# ── Twin-stick ATTACK-drag look ──────────────────────────────────────────────────────────────────────────────────
# The ATTACK finger turns the players through the SAME path as the Classic swipe (_look): every pixel the finger
# moves becomes LOOK_BASE_GAIN x Look Sensitivity mouse pixels, immediately, with no dead zone, curve, smoothing,
# velocity or coasting (the camera moves exactly when and as far as the thumb does, and stops when it stops). The one
# adaptation is the physical one: the ATTACK button is a small travel area, Classic is a whole screen half. The drag is
# therefore multiplied by compact_gain(): (Classic's right-thumb travel) / (the ATTACK diameter), clamped. Look
# Sensitivity (the player's slider) stays the only other factor, so nothing stacks.
const COMPACT_CLASSIC_TRAVEL := 0.5   # Classic's right-thumb sweep, as a fraction of the canvas width (the right half)
const COMPACT_GAIN_MIN := 1.5
const COMPACT_GAIN_MAX := 3.0         # 180 degrees of turn = ~30 mm of thumb travel at 100% sensitivity

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

# ── Twin-stick ATTACK gesture (the ATTACK button is also the look surface, so a touch on it must first be classified) ──
# A finger that goes down on ATTACK is PENDING: nothing is pressed yet. Then exactly one of
#   TAP    lifted again within ATTACK_INTENT_MS without leaving the slop circle  -> ONE attack, at the lift
#   HOLD   still down, still inside the slop circle after ATTACK_INTENT_MS        -> ONE attack, at that moment
#   LOOK   moved farther than the slop radius from the touch-down point
#                                                                                -> ZERO attacks, for the rest of the touch
# LOOK is latched until the finger lifts: coming back over the button does not attack; the next attack needs a new
# touch. A hold does not repeat, auto-fire or charge (nothing in the game charges): the attack is a fixed ATTACK_PULSE_MS press followed by a release that the layer itself guarantees.
# Numbers (reasoned for real Android touch, not for the mouse):
#   ATTACK_SLOP_MM        1.5 mm = ~9.5 dp: Android's own touch slop is 8 dp (ViewConfiguration), a resting thumb rolls and
#                         tremors a few mm-tenths, a deliberate look drag covers it in a few ms. In virtual px via the
#                         panel dpi (Pixel: ~15 px). The camera does not turn while the gesture is undecided; the movement beyond
#                         the circle is then applied in full (see _attack_move), so the slop is the only travel the look needs.
#   ATTACK_INTENT_MS      150: a tap is ~60-150 ms (Android's tap timeout is 100-ish and long-press 400-500), and a
#                         thumb that goes down to look starts moving within ~100 ms; 150 ms separates "put the thumb down
#                         and drag" from "put the thumb down and stay" without making a held attack feel late.
#   ATTACK_PULSE_MS       80: spans at least two 30 Hz physics ticks, so polling gameplay (brute_player) and event gameplay
#                         (mage_player) both see the press.
#   ATTACK_PULSE_MAX_MS   250: hard cap of any scheduled release (fail-safe, see _enforce_inputs).
const ATTACK_INTENT_MS     := 150
const ATTACK_SLOP_MM       := 1.5
const ATTACK_SLOP_MIN_PX   := 8.0
const ATTACK_SLOP_MAX_PX   := 20.0
const ATTACK_PULSE_MS      := 80
const ATTACK_PULSE_MAX_MS  := 250
const ATTACK_WATCH_MIN_MS  := 100    # after our attack release: how long until the engine's own state must agree...
const ATTACK_WATCH_MAX_MS  := 1000   # ...and for how long that is checked

const STICK_AXES: Array[String] = ["move_left", "move_right", "move_forward", "move_back"]

enum Owner { NONE, STICK, LOOK, BUTTON }
enum Gesture { NONE, PENDING, FIRED, LOOK }

var touch_enabled : bool = true
var ui_scale      : float = 1.0
var opacity       : float = 0.7
var look_gain     : float = 1.0
var attack_look_gain : float = 1.0   # compact-input gain of the twin ATTACK drag (compact_gain; set by the layout)
var scheme        : String = DEFAULT_SCHEME
var dpi_override  : float = 0.0                                    # tests: pretend the panel has this dpi
var screen_override : Vector2 = Vector2.ZERO                       # tests: pretend the panel has this many physical px
var layout_override_insets : Vector4 = Vector4(-1, -1, -1, -1)   # tests: (left, top, right, bottom) virtual px
var view_override : Vector2 = Vector2.ZERO                         # tests: pretend the screen is this size

var buttons : Dictionary = {}            # action name -> TouchButton
var stick_zone : Rect2 = Rect2()
var stick_default : Vector2 = Vector2.ZERO
var onboarding : Node = null

var _root : Control = null
var _stick_base : Vector2 = Vector2.ZERO
var _stick_vec  : Vector2 = Vector2.ZERO
var _stick_active : bool = false
var _stick_draw : Control = null
var _atk_index : int = -1                # finger that went down on ATTACK (-1: none)
var _atk_moved : bool = false            # the ATTACK finger turned the camera since the last rendered frame (onboarding clock)
var _atk_gesture : int = Gesture.NONE    # twin ATTACK gesture state (see above)
var _atk_down_ms : int = 0
var _atk_down_pos : Vector2 = Vector2.ZERO   # touch-down point: the slop circle is centred here
var _atk_slop_px : float = ATTACK_SLOP_MAX_PX
var _stale : Array[String] = []          # scratch for _enforce_inputs (reused: no per-frame allocation)
var _attack_release_ms : int = 0         # when we last released attack (for the engine-state watch), 0 = nothing to watch
var attack_pulses : int = 0              # attacks sent through the twin gesture (diagnostics / tests)
var attack_failsafe_releases : int = 0   # times the fail-safe had to force a release (should stay 0)
var now_override_ms : int = -1           # tests: a controllable clock (>= 0), real time otherwise
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
var look_time : float = 0.0              # seconds the ATTACK finger has been turning the camera (onboarding)


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


## Compact-input gain of the twin ATTACK drag: how much further the camera turns per pixel of thumb travel than in Classic,
## to make up for the smaller travel area. = Classic's right-thumb sweep (COMPACT_CLASSIC_TRAVEL x the canvas width) divided
## by the ATTACK diameter, clamped to COMPACT_GAIN_MIN..MAX. 1280x720 canvas, 100% size: 640 / 200 = 3.2 -> 3.0.
static func compact_gain(view_width: float, attack_radius: float) -> float:
	if attack_radius <= 0.0:
		return COMPACT_GAIN_MIN
	return clampf(COMPACT_CLASSIC_TRAVEL * view_width / (2.0 * attack_radius), COMPACT_GAIN_MIN, COMPACT_GAIN_MAX)


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
		"stick_zone": Rect2(0.0, view.y * 0.28, view.x * 0.40, view.y * 0.72),
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
	return {
		"safe": Rect2(l, t, r - l, b - t),
		"buttons": spots,
		"stick_default": stick_def,
		"stick_zone": Rect2(0.0, view.y * 0.28, view.x * 0.40, view.y * 0.72),
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


	var ob_script := load("res://scripts/touch/touch_onboarding.gd")
	if ob_script != null:
		onboarding = ob_script.new()
		onboarding.name = "Onboarding"
		_root.add_child(onboarding)
		onboarding.setup(self)

	get_viewport().size_changed.connect(_relayout)
	visibility_changed.connect(_on_visibility_changed)
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
	# Phone call, Home button, app switcher, screen lock: never leave an input stuck down. Coming BACK also lets go: a finger
	# that lifted while we were away never delivered its release, so whatever it owned is stale by definition.
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT \
			or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_APPLICATION_RESUMED \
			or what == NOTIFICATION_APPLICATION_FOCUS_IN or what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		release_all()


## The whole layer was hidden (a screen that covers the display): its buttons can no longer receive a lift, so let go.
func _on_visibility_changed() -> void:
	if not visible:
		release_all()


## The clock of the gesture logic and the press timers: real milliseconds, or the test clock.
func _now() -> int:
	return now_override_ms if now_override_ms >= 0 else Time.get_ticks_msec()


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
	stick_zone = lay["stick_zone"]
	attack_look_gain = compact_gain(view.x, (buttons["attack"] as TouchButton).radius) if scheme == SCHEME_TWIN and buttons.has("attack") else 1.0
	_root.modulate.a = opacity
	if _stick_draw != null:
		_stick_draw.queue_redraw()


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
	# Deferred releases (very short taps, the attack pulse), the attack gesture clock, then the fail-safe.
	var now: int = _now()
	if not _pending_release.is_empty():
		for action in _pending_release.keys():
			if now >= int(_pending_release[action]):
				_pending_release.erase(action)
				_send(action, false, 0.0)
				_settle_visual(action)
	_attack_gesture_tick(now)
	_enforce_inputs(now)
	if _stick_active and _stick_vec.length() > STICK_DEADZONE:
		move_time += delta
	_poll_settings(delta)
	if _atk_moved:
		_atk_moved = false
		look_time += delta   # the ATTACK finger turned the camera this frame (onboarding)
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


# Burst cooldown ring + potion count from the live player and wallet.
func _refresh_button_status() -> void:
	var b: TouchButton = buttons.get("AOE")
	if b == null:
		return
	var player := get_tree().get_first_node_in_group("player")
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
	var out_of_potions: bool = potions <= 0 and player != null   # the flask is drawn in the disabled look (input unchanged)
	if not is_equal_approx(b.cooldown, cd) or b.badge != badge or b.unavailable != out_of_potions:
		b.cooldown = cd
		b.badge = badge
		b.unavailable = out_of_potions
		b.queue_redraw()


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
	if not touch_enabled or not visible or get_tree().paused:
		# A lift or cancel must still reach us while the layer is off (a finger that lifts during a pause or a buff pick
		# would otherwise stay "down" in _owners); everything else belongs to the menu on top.
		if event is InputEventScreenTouch and not _owners.is_empty():
			var up := event as InputEventScreenTouch
			if not up.pressed or up.canceled:
				_touch_up(up.index, true, up.position)
		return
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed and not st.canceled:
			_touch_down(st.index, st.position)
		else:
			_touch_up(st.index, st.canceled, st.position)   # a lift or an engine cancel: the same clean release (a cancel never attacks)
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
# move stick. Anything else is a swipe-to-look finger in Classic and is IGNORED in twin-stick (no look zone: aiming
# there is done by dragging from ATTACK). A finger that starts on ATTACK in the twin scheme stays a BUTTON finger and
# additionally measures an aim drag from its touch-down point.
func _touch_down(index: int, p: Vector2) -> void:
	if _owners.has(index):
		# A press on a finger index we still think is down: the lift of the old finger never reached us (an index is reused
		# as soon as a finger lifts). The old finger is gone: drop whatever it owned, then handle the new one normally.
		_drop_owner(index)
	var b := _nearest_button(p)
	if b != null:
		# One live finger per HOLD button. A second touch on it means the first finger is gone or was never ours any more
		# (a lost lift would otherwise own the button, and the attack gesture, for ever).
		if b.mode == TouchButton.Mode.HOLD:
			for other in _owners.keys():
				var oo: Dictionary = _owners[other]
				if int(oo["kind"]) == Owner.BUTTON and oo["button"] == b.action:
					_drop_owner(int(other), true)
		_owners[index] = {"kind": Owner.BUTTON, "button": b.action}
		if is_twin() and b.action == "attack":
			_begin_attack_gesture(index, p, b)   # nothing is pressed yet: the gesture decides (tap / hold = one attack, drag = look)
			return
		_button_down(b)
		return
	if stick_zone.has_point(p) and not _stick_active:
		_owners[index] = {"kind": Owner.STICK}
		_stick_active = true
		_stick_base = p
		_stick_vec = Vector2.ZERO
		_stick_draw.queue_redraw()
		return
	if is_twin():
		_owners[index] = {"kind": Owner.NONE}   # empty screen (or a stray extra finger): owned, so it can never become anything later, and does nothing
	else:
		_owners[index] = {"kind": Owner.LOOK}   # Classic: swipe anywhere free to look


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
			_look(rel)   # Classic only: twin-stick never creates a LOOK owner
		Owner.BUTTON:
			if index == _atk_index:
				_attack_move(p, rel)


## A finger lifted (or the engine cancelled it: `canceled`, which can never attack). `up_pos` is where it lifted
## (Vector2.INF when unknown): a lift far from the touch-down point is a look gesture even if its drags were dropped.
func _touch_up(index: int, canceled: bool = false, up_pos: Vector2 = Vector2.INF) -> void:
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
		Owner.BUTTON:
			if index == _atk_index:
				# The twin ATTACK gesture ends here: a tap (still PENDING: never classified as look, not held long enough to
				# have fired) is the one attack; everything else (look, an attack already fired, a cancel) sends none.
				var tap: bool = _atk_gesture == Gesture.PENDING and not canceled
				if tap and up_pos.is_finite() and up_pos.distance_to(_atk_down_pos) > _atk_slop_px:
					tap = false
				_reset_attack_gesture()   # releasing ATTACK ends the drag at once: the turn stops (no coasting)
				if tap:
					_fire_attack_pulse()
				_settle_visual("attack")
				return
			var b: TouchButton = buttons.get(o["button"])
			if b != null:
				_button_up(b)


## A finger index that is no longer valid (its lift was lost, or another finger now sits on its button). Same cleanup as a
## cancelled touch. `takeover`: another finger is taking over the same button right now, so the button itself stays as is.
func _drop_owner(index: int, takeover: bool = false) -> void:
	if not takeover:
		_touch_up(index, true)
		return
	var o: Dictionary = _owners.get(index, {})
	if o.is_empty():
		return
	_owners.erase(index)
	if index == _atk_index:
		_reset_attack_gesture()


# ── Twin ATTACK gesture ────────────────────────────────────────────────────────

func _begin_attack_gesture(index: int, p: Vector2, b: TouchButton) -> void:
	_atk_index = index
	_atk_down_pos = p
	_atk_down_ms = _now()
	_atk_moved = false
	_atk_gesture = Gesture.PENDING
	_atk_slop_px = clampf(ATTACK_SLOP_MM * device_px_per_mm(), ATTACK_SLOP_MIN_PX, ATTACK_SLOP_MAX_PX)
	b.pressed_visual = true   # the touch is registered (the visual does not claim an attack)
	b.queue_redraw()


func _reset_attack_gesture() -> void:
	_atk_index = -1
	_atk_moved = false
	_atk_gesture = Gesture.NONE


## The ATTACK finger moved to `p` by `rel`. Inside the slop circle the gesture is still undecided and the camera stays put (a
## tap's tremor must not turn it). The event that leaves the circle makes the gesture LOOK for good and contributes only the
## part of the movement beyond the circle (nothing jumps, nothing already inside is replayed); from then on every movement goes
## through the Classic path (_look) times the compact gain.
func _attack_move(p: Vector2, rel: Vector2) -> void:
	if _atk_gesture != Gesture.LOOK:
		var off: Vector2 = p - _atk_down_pos
		var dist: float = off.length()
		if dist <= _atk_slop_px:
			return
		_enter_look()
		rel = off / dist * (dist - _atk_slop_px)
	if rel != Vector2.ZERO:
		_atk_moved = true
		_look(rel, attack_look_gain)


func _enter_look() -> void:
	_atk_gesture = Gesture.LOOK   # latched until the finger lifts: back over the button does not attack
	_settle_visual("attack")


## HOLD: a finger still on ATTACK inside the slop circle after ATTACK_INTENT_MS fires its ONE attack now.
func _attack_gesture_tick(now: int) -> void:
	if _atk_gesture == Gesture.PENDING and now - _atk_down_ms >= ATTACK_INTENT_MS:
		_atk_gesture = Gesture.FIRED
		_fire_attack_pulse()


## The single attack of a gesture: a press that this layer releases itself ATTACK_PULSE_MS later (never "held by a finger").
func _fire_attack_pulse() -> void:
	if _held.has("attack"):
		return   # the previous pulse is still in flight (the player's own attack lockout is longer than this anyway)
	_pending_release.erase("attack")
	_send("attack", true, 1.0)
	_pending_release["attack"] = _now() + ATTACK_PULSE_MS
	attack_pulses += 1
	_settle_visual("attack")
	action_performed.emit("attack")


## Button look follows the truth: down while its action is held (or, twin ATTACK, while the finger is on it undecided).
func _settle_visual(action: String) -> void:
	var b: TouchButton = buttons.get(action)
	if b == null or b.mode == TouchButton.Mode.TOGGLE:
		return
	var down: bool = _held.has(action) or (action == "attack" and is_twin() and _atk_gesture == Gesture.PENDING)
	if b.pressed_visual != down:
		b.pressed_visual = down
		b.queue_redraw()


## Is a finger that is still alive responsible for this held action? (Twin ATTACK is never held by a finger: it is a pulse.)
func _has_live_owner(action: String) -> bool:
	if action == "attack" and is_twin():
		return false
	for index in _owners:
		var o: Dictionary = _owners[index]
		if int(o["kind"]) == Owner.BUTTON and o["button"] == action:
			return true
	return false


## FAIL-SAFE, every frame: no input may stay active after the thing that owns it is gone. A held button action must have a live
## finger or a scheduled release (and a scheduled release must not outlive ATTACK_PULSE_MAX_MS); axes need the stick finger;
## and the engine's own attack state must agree with ours shortly after we released it. Whatever violates this is released
## and counted in `attack_failsafe_releases` (the tests prove it stays 0 on every normal path and trips on injected state).
func _enforce_inputs(now: int) -> void:
	if not _held.is_empty():
		for action in _held:   # (no per-frame allocation: stale actions are collected in a reused array and released after the loop)
			var b: TouchButton = buttons.get(action)
			if b == null or b.mode == TouchButton.Mode.TOGGLE:
				continue
			if _pending_release.has(action):
				if now - int(_press_ms.get(action, now)) <= ATTACK_PULSE_MAX_MS:
					continue
				_pending_release.erase(action)
			elif _has_live_owner(action):
				continue
			_stale.append(action)
		for action in _stale:
			attack_failsafe_releases += 1
			_send(action, false, 0.0)
			_settle_visual(action)
		_stale.clear()
		if not _stick_active:
			for axis in STICK_AXES:
				if _held.has(axis):
					attack_failsafe_releases += 1
					_stick_vec = Vector2.ZERO
					_apply_stick()
					break
	if _attack_release_ms > 0:
		var age: int = now - _attack_release_ms
		if age > ATTACK_WATCH_MAX_MS:
			_attack_release_ms = 0
		elif age >= ATTACK_WATCH_MIN_MS and not _held.has("attack") and Input.is_action_pressed("attack"):
			attack_failsafe_releases += 1
			Input.action_release("attack")   # the engine still thinks attack is down although we released it: set it straight


func _button_down(b: TouchButton) -> void:
	_pending_release.erase(b.action)   # a re-press inside the stretch window keeps holding (never released under a live finger)
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
	var since: int = _now() - int(_press_ms.get(b.action, 0))
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


## The Classic look path: finger displacement -> mouse-look motion. The twin ATTACK drag uses it too, with `gain` = its
## compact-input gain (1.0 = Classic).
func _look(rel: Vector2, gain: float = 1.0) -> void:
	look_total += rel.length()
	_emit_mouse_motion(rel * LOOK_BASE_GAIN * look_gain * gain)


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
			_press_ms[action] = _now()
			if action == "attack":
				_attack_release_ms = 0
	else:
		if was == 0.0:
			return
		_held.erase(action)
		if action == "attack":
			_attack_release_ms = _now()
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed and strength > 0.0
	ev.strength = strength if ev.pressed else 0.0
	Input.parse_input_event(ev)


## Releases everything held through the touch layer and forgets all fingers (and any attack gesture in progress: it
## sends no attack). The engine's action state is cleared at once as well as through the buffered release event: a
## release that has to wait for a paused tree or a backgrounded app to be delivered is a release that can be lost.
func release_all() -> void:
	_owners.clear()
	_pending_release.clear()
	_stick_active = false
	_stick_vec = Vector2.ZERO
	_reset_attack_gesture()   # nothing keeps turning or attacking after a background / lock / pause
	for action in _held.keys():
		var ev := InputEventAction.new()
		ev.action = action
		ev.pressed = false
		ev.strength = 0.0
		Input.parse_input_event(ev)
		Input.action_release(action)
		if action == "attack":
			_attack_release_ms = _now()
	_held.clear()
	for action in buttons:
		var b: TouchButton = buttons[action]
		b.pressed_visual = false
		if b.mode == TouchButton.Mode.TOGGLE:
			b.toggled_on = false
		b.queue_redraw()
	if _stick_draw != null:
		_stick_draw.queue_redraw()
	released_all.emit()


# ── Drawing ───────────────────────────────────────────────────────────────────

const STICK_RING_FRAC := 0.10   # stick bezel thickness (fraction of the stick radius)
const STICK_IDLE_ALPHA := 0.62   # resting joystick: faint but always findable (the opacity setting scales it further)


## The floating move stick: a recessed well in a thin aged-brass bezel with a bone thumb (see _draw_one_stick). Cached
## textures only; redrawn when the stick changes, never per frame. Always visible at rest (idle alpha) so the player can
## find it, ember-rimmed while held.
func _draw_stick() -> void:
	_draw_one_stick(_stick_base if _stick_active else stick_default, _stick_vec, STICK_RADIUS * ui_scale, _stick_active)


func _draw_one_stick(base: Vector2, vec: Vector2, radius: float, active: bool) -> void:
	var a: float = 1.0 if active else STICK_IDLE_ALPHA
	var tint := Color(1, 1, 1, a)
	var rw: float = maxf(radius * STICK_RING_FRAC, 3.0)
	var ring: Color = PUI.EMBER_DEEP if active else PUI.EDGE.lerp(PUI.EDGE_BRASS, 0.45)
	var d: CanvasItem = _stick_draw
	d.draw_texture_rect(TouchButton.stick_base_texture(), Rect2(base - Vector2(radius, radius), Vector2(radius, radius) * 2.0), false, tint)
	d.draw_arc(base, radius - rw * 0.5, 0.0, TAU, 56, Color(ring.r, ring.g, ring.b, a), rw, true)
	d.draw_arc(base, radius - rw * 0.5, PI * 1.05, PI * 1.60, 20, Color(ring.lightened(0.3), 0.8 * a), rw * 0.3, true)
	d.draw_arc(base, radius - rw - 1.0, 0.0, TAU, 56, Color(PUI.EDGE_BRASS.lightened(0.25), 0.7 * a), 1.5, true)
	d.draw_arc(base, radius - rw - 5.0, PI * 0.85, PI * 1.95, 24, Color(0, 0, 0, 0.45 * a), 6.0, true)
	# thumb: contact shadow, small bezel, bone face
	var kr: float = radius * 0.42
	var knob: Vector2 = base + vec.limit_length(1.0) * radius
	var kw: float = maxf(kr * 0.20, 2.5)
	d.draw_circle(knob + Vector2(0.0, kr * 0.12), kr * 1.06, Color(0, 0, 0, 0.35 * a))
	d.draw_arc(knob, kr - kw * 0.5, 0.0, TAU, 40, Color(ring.r, ring.g, ring.b, a), kw, true)
	var ir: float = kr - kw
	d.draw_texture_rect(TouchButton.stick_knob_texture(), Rect2(knob - Vector2(ir, ir), Vector2(ir, ir) * 2.0), false, tint)
	var hl: Color = PUI.EMBER_BRIGHT if active else PUI.EDGE_BRASS.lightened(0.25)
	d.draw_arc(knob, ir, 0.0, TAU, 40, Color(hl.r, hl.g, hl.b, 0.8 * a), 1.5, true)
