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
#   Layout (landscape, virtual 1280x720-ish canvas):
#     left thumb   floating move stick          -> move_left/right/forward/back (analog strength)
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
const DEFAULT_OPACITY := 70.0
const DEFAULT_SCALE   := 100.0
const DEFAULT_LOOK    := 100.0

const LOOK_BASE_GAIN  := 1.4     # virtual px of swipe -> "mouse pixels" for the players' mouse-look
const STICK_RADIUS    := 100.0
const STICK_DEADZONE  := 0.16
const MIN_PRESS_MS    := 70      # a press shorter than this is stretched so polling code sees it
const MARGIN_X        := 36.0    # keep clear of rounded corners / gesture edges
const MARGIN_Y        := 28.0

enum Owner { NONE, STICK, LOOK, BUTTON }

var touch_enabled : bool = true
var ui_scale      : float = 1.0
var opacity       : float = 0.7
var look_gain     : float = 1.0
var layout_override_insets : Vector4 = Vector4(-1, -1, -1, -1)   # tests: (left, top, right, bottom) virtual px
var view_override : Vector2 = Vector2.ZERO                         # tests: pretend the screen is this size

var buttons : Dictionary = {}            # action name -> TouchButton
var stick_zone : Rect2 = Rect2()
var look_zone  : Rect2 = Rect2()
var stick_default : Vector2 = Vector2.ZERO
var onboarding : Node = null

var _root : Control = null
var _stick_base : Vector2 = Vector2.ZERO
var _stick_vec  : Vector2 = Vector2.ZERO
var _stick_active : bool = false
var _stick_draw : Control = null
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


## Button centres/radii and touch zones for a view size, safe insets (l,t,r,b) and UI scale.
static func compute_layout(view: Vector2, insets: Vector4, s: float) -> Dictionary:
	var l: float = insets.x + MARGIN_X
	var t: float = insets.y + MARGIN_Y
	var r: float = view.x - insets.z - MARGIN_X
	var b: float = view.y - insets.w - MARGIN_Y
	var cluster := Vector2(r - 184.0 * s, b - 176.0 * s)
	var out := {
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
		"look_zone": Rect2(view.x * 0.40, 0.0, view.x * 0.60, view.y),
	}
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


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 80
	process_mode = Node.PROCESS_MODE_ALWAYS   # must notice pause / focus loss to release inputs
	add_to_group(GROUP)
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
	_relayout()


func _exit_tree() -> void:
	release_all()


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
	var lay: Dictionary = compute_layout(view, insets, ui_scale)
	for action in lay["buttons"]:
		var spec: Array = lay["buttons"][action]
		if buttons.has(action):
			(buttons[action] as TouchButton).place(spec[0], spec[1])
	stick_default = lay["stick_default"]
	stick_zone = lay["stick_zone"]
	look_zone = lay["look_zone"]
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
	_settings_poll += delta
	if _settings_poll >= 0.5:
		_settings_poll = 0.0
		var o := opacity
		var sc := ui_scale
		_apply_settings()
		if not is_equal_approx(o, opacity) or not is_equal_approx(sc, ui_scale) \
				or view_size() != _last_view:
			_relayout()
	_status_poll += delta
	if _status_poll >= 0.1:
		_status_poll = 0.0
		_refresh_button_status()


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
	if not is_equal_approx(b.cooldown, cd) or b.badge != badge:
		b.cooldown = cd
		b.badge = badge
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


func _touch_down(index: int, p: Vector2) -> void:
	if _owners.has(index):
		return
	var b := _nearest_button(p)
	if b != null:
		_owners[index] = {"kind": Owner.BUTTON, "button": b.action}
		_button_down(b)
		return
	if stick_zone.has_point(p) and not _stick_active:
		_owners[index] = {"kind": Owner.STICK}
		_stick_active = true
		_stick_base = p
		_stick_vec = Vector2.ZERO
		_stick_draw.queue_redraw()
		return
	_owners[index] = {"kind": Owner.LOOK}


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
			_look(rel)


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
		Owner.BUTTON:
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
	var ev := InputEventMouseMotion.new()
	ev.device = 0   # a real-mouse-like event; touch-emulated mouse motion (device -1) is ignored by the players
	ev.relative = rel * LOOK_BASE_GAIN * look_gain
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
	released_all.emit()


# ── Drawing ───────────────────────────────────────────────────────────────────

func _draw_stick() -> void:
	var radius: float = STICK_RADIUS * ui_scale
	var base: Vector2 = _stick_base if _stick_active else stick_default
	var a: float = 1.0 if _stick_active else 0.45
	_stick_draw.draw_circle(base, radius, Color(TouchIcons.INK.r, TouchIcons.INK.g, TouchIcons.INK.b, 0.45 * a))
	_stick_draw.draw_arc(base, radius, 0.0, TAU, 56, Color(TouchIcons.BONE.r, TouchIcons.BONE.g, TouchIcons.BONE.b, 0.55 * a), 3.0, true)
	var knob: Vector2 = base + _stick_vec * radius
	_stick_draw.draw_circle(knob, radius * 0.42, Color(TouchIcons.INK.r, TouchIcons.INK.g, TouchIcons.INK.b, 0.80 * a))
	_stick_draw.draw_arc(knob, radius * 0.42, 0.0, TAU, 40, TouchIcons.EMBER if _stick_active else Color(TouchIcons.BONE.r, TouchIcons.BONE.g, TouchIcons.BONE.b, 0.6), 3.0, true)
