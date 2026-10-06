# ==============================================================================
# File Name: touch_onboarding.gd
# Path: res://scripts/touch/touch_onboarding.gd
#
# Description:
#   Contextual, one-at-a-time control hints. Nothing is shown up front: each hint appears when
#   the control first becomes relevant, waits for the player to actually DO the thing, then fades
#   and is remembered (SettingsManager.gameplay_settings["touch_tutorial"]) so it never nags again.
#
#   The hints teach the ACTIVE control scheme (TouchControls.scheme):
#
#     move       -> at the start: "drag to move" until the stick has been used
#     look       -> classic: "swipe to look" until the player has swiped
#     aim        -> twin-stick, right after move: "drag from Attack to look and aim" (highlights ATTACK) until the
#                   ATTACK drag has been held out for AIM_DONE_SECONDS. (Older installs may carry a completed
#                   "look_stick" flag from the removed right stick: it is simply never read again.)
#     attack     -> when the first enemy is near: highlights ATTACK until pressed
#     use        -> when something usable is in range (chest): highlights USE until pressed
#     block      -> after the first hit taken (and attack learned): highlights BLOCK
#     burst      -> when an enemy is close and a potion is held: highlights BURST
#
#   A hint that is shown MAX_SHOWS times without being completed is retired too.
# ==============================================================================
class_name TouchOnboarding
extends Control

const STEPS : Array[String] = ["move", "look", "attack", "use", "block", "burst"]   # classic order
const STEPS_TWIN : Array[String] = ["move", "aim", "attack", "use", "block", "burst"]
const SETTINGS_KEY := "touch_tutorial"
const SHOWS_KEY := "touch_tutorial_shown"
const MAX_SHOWS := 3
const HINT_SECONDS := 9.0
const LOOK_DONE_PX := 350.0
const MOVE_DONE_SECONDS := 0.8
const AIM_DONE_SECONDS := 0.8

const TEXT := {
	"move": "Drag here to move",
	"look": "Swipe on this side to look around",
	"attack": "Tap to attack - hold to charge",
	"use": "Tap to use",
	"block": "Hold to block",
	"burst": "Burst costs a potion",
}
# Twin-stick wording (same steps where the control is the same).
const TEXT_TWIN := {
	"move": "Drag the left side to move",
	"attack": "Tap to attack - drag the button to look",
	"aim": "Drag from Attack to look and aim",
	"use": "Tap to use",
	"block": "Hold to block",
	"burst": "Burst costs a potion",
}

var active : String = ""
var _tc : Node = null
var _label : Label = null
var _poll : float = 0.0
var _shown_for : float = 0.0
var _fade : float = 0.0
var _last_health : float = -1.0
var _took_damage : bool = false


func setup(tc: Node) -> void:
	_tc = tc
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_label = Label.new()
	# Brand typography: body role, bone text on a tiny dark iron plate (the plate is the Label's own
	# "normal" stylebox, so the label's rect - which placement keeps clear of every button - includes it).
	PUI.apply_role(_label, "body", PUI.BONE_BRIGHT)
	_label.add_theme_font_override("font", PUI.font("body_semi"))
	_label.add_theme_constant_override("outline_size", 3)
	_label.add_theme_color_override("font_outline_color", Color(0.03, 0.02, 0.02, 0.9))
	var plate := PUI.box(Color(0.07, 0.055, 0.045, 0.88), PUI.EDGE_BRASS.darkened(0.3), Color(0.05, 0.04, 0.035, 0.9), 0.05, 0.25, 0.02, Color(0, 0, 0, 0), 8)
	plate.content_margin_left = PUI.S4
	plate.content_margin_right = PUI.S4
	plate.content_margin_top = PUI.S2
	plate.content_margin_bottom = PUI.S2
	_label.add_theme_stylebox_override("normal", plate)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF   # hints are short; the plate hugs the text
	_label.modulate.a = 0.0
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)
	if _tc.has_signal("action_performed"):
		_tc.action_performed.connect(_on_action)


# ── State ─────────────────────────────────────────────────────────────────────

func _done_map() -> Dictionary:
	if not has_node("/root/SettingsManager"):
		return {}
	var m = SettingsManager.gameplay_settings.get(SETTINGS_KEY, {})
	return m if m is Dictionary else {}


func is_done(step: String) -> bool:
	return bool(_done_map().get(step, false))


func _mark_done(step: String) -> void:
	if not has_node("/root/SettingsManager"):
		return
	var m: Dictionary = _done_map()
	if m.get(step, false):
		return
	m[step] = true
	SettingsManager.gameplay_settings[SETTINGS_KEY] = m
	SettingsManager.save_settings()


func _count_show(step: String) -> void:
	if not has_node("/root/SettingsManager"):
		return
	var m = SettingsManager.gameplay_settings.get(SHOWS_KEY, {})
	if not (m is Dictionary):
		m = {}
	m[step] = int(m.get(step, 0)) + 1
	SettingsManager.gameplay_settings[SHOWS_KEY] = m
	if int(m[step]) >= MAX_SHOWS and not is_done(step):
		_mark_done(step)   # retired: shown enough times, stop nagging
	else:
		SettingsManager.save_settings()


func _shows(step: String) -> int:
	if not has_node("/root/SettingsManager"):
		return 0
	var m = SettingsManager.gameplay_settings.get(SHOWS_KEY, {})
	return int(m.get(step, 0)) if m is Dictionary else 0


# ── Completion ────────────────────────────────────────────────────────────────

## The hint text for a step under the active scheme.
func text_for(step: String) -> String:
	if _twin():
		return TEXT_TWIN.get(step, TEXT.get(step, ""))
	return TEXT.get(step, "")


func _twin() -> bool:
	return _tc != null and _tc.has_method("is_twin") and _tc.is_twin()


## The player switched scheme: drop the hint that taught the old one; the right one is chosen next poll.
func on_scheme_changed() -> void:
	_deactivate()
	_poll = 1.0


func _on_action(action: String) -> void:
	var step: String = ""
	match action:
		"attack": step = "attack"
		"equip": step = "use"
		"block": step = "block"
		"AOE": step = "burst"
	if step != "" and not is_done(step):
		_mark_done(step)
		if active == step:
			_deactivate()


func _process(delta: float) -> void:
	if _label == null or get_tree().paused:
		return
	_poll += delta
	# Movement and look are detected from the layer's own counters.
	if active == "move" and float(_tc.get("move_time")) >= MOVE_DONE_SECONDS:
		_mark_done("move")
		_deactivate()
	elif active == "look" and float(_tc.get("look_total")) >= LOOK_DONE_PX:
		_mark_done("look")
		_deactivate()
	elif active == "aim" and float(_tc.get("look_time")) >= AIM_DONE_SECONDS:
		_mark_done("aim")
		_deactivate()
	if active != "":
		_shown_for += delta
		if _shown_for >= HINT_SECONDS:
			_deactivate()   # hint timed out; it will come back next launch until MAX_SHOWS
		_fade = minf(_fade + delta * 3.0, 1.0)
	else:
		_fade = maxf(_fade - delta * 3.0, 0.0)
	_label.modulate.a = _fade
	if _poll < 0.4:
		return
	_poll = 0.0
	_watch_damage()
	if active == "":
		_choose_next()
	_position_label()


func _watch_damage() -> void:
	var p := get_tree().get_first_node_in_group("player")
	if p == null or not ("_current_health" in p):
		return
	var raw: Variant = p.get("_current_health")
	if not (raw is float or raw is int):   # null while the player is still initialising
		return
	var h: float = float(raw)
	if _last_health >= 0.0 and h < _last_health - 0.5:
		_took_damage = true
	_last_health = h


func _enemy_within(dist: float) -> bool:
	var p := get_tree().get_first_node_in_group("player") as Node3D
	if p == null:
		return false
	for e in get_tree().get_nodes_in_group("enemy"):
		if e is Node3D and is_instance_valid(e) and e.get("_is_dead") != true:
			if (e as Node3D).global_position.distance_to(p.global_position) <= dist:
				return true
	return false


func _choose_next() -> void:
	var next: String = ""
	var twin: bool = _twin()
	if not is_done("move"):
		next = "move"
	elif twin and not is_done("aim"):
		next = "aim"
	elif not twin and not is_done("look"):
		next = "look"
	elif not is_done("attack") and _enemy_within(22.0):
		next = "attack"
	elif not is_done("use") and int(_tc.get("_use_context")) > 0:
		next = "use"
	elif not is_done("block") and is_done("attack") and _took_damage:
		next = "block"
	elif not is_done("burst") and is_done("attack") and _enemy_within(9.0) and _potions() > 0:
		next = "burst"
	if next != "":
		_activate(next)


func _potions() -> int:
	if has_node("/root/SaveManager") and not SaveManager.current_profile.is_empty():
		return int(SaveManager.current_profile.get("meta_currency", 0))
	return 0


func _activate(step: String) -> void:
	active = step
	_shown_for = 0.0
	_label.text = text_for(step)
	_label.reset_size()   # shrink the plate to the new text
	_count_show(step)
	_set_highlight(step, true)


func _deactivate() -> void:
	if active == "":
		return
	_set_highlight(active, false)
	active = ""


func _set_highlight(step: String, on: bool) -> void:
	var action: String = ""
	match step:
		"attack", "aim": action = "attack"
		"use": action = "equip"
		"block": action = "block"
		"burst": action = "AOE"
	if action != "" and _tc.buttons.has(action):
		var b: TouchButton = _tc.buttons[action]
		b.highlighted = on
		b.queue_redraw()
	# Redraw highlighted buttons each frame while a pulse is showing.
	set_process(true)


func _position_label() -> void:
	if active == "" or _label == null:
		return
	var view: Vector2 = _tc.view_size()
	var lo := Vector2(8, 8)
	var hi: Vector2 = view - _label.size - Vector2(8, 8)
	var half: Vector2 = _label.size * 0.5
	var spots: Array[Vector2] = []
	match active:
		"move":
			spots.append(_tc.stick_default + Vector2(0.0, -150.0))
		"look":
			# below the wallet list (top right), clear of USE when it is showing
			spots.append(Vector2(view.x * 0.70, view.y * 0.40))
			spots.append(Vector2(view.x * 0.55, view.y * 0.40))
			spots.append(Vector2(view.x * 0.55, view.y * 0.30))
			spots.append(Vector2(view.x * 0.45, view.y * 0.40))
		_:
			# Above the whole action cluster, so the hint never sits on a button the player must press; if the
			# first spot would touch any control (map button, arc) try the ones further left.
			var top: float = view.y
			var left: float = view.x
			for action in ["attack", "kick", "jump", "block", "AOE", "equip"]:
				var b: TouchButton = _tc.buttons.get(action)
				if b != null and b.visible:
					top = minf(top, b.center.y - b.radius)
					left = minf(left, b.center.x - b.radius)
			var ref: TouchButton = _tc.buttons.get("attack")
			var cx: float = _tc.view_size().x * 0.8
			if ref != null:
				cx = ref.center.x - 140.0
			var y: float = top - 24.0 - half.y
			spots.append(Vector2(cx, y))
			for f in [0.62, 0.5, 0.38]:
				spots.append(Vector2(view.x * f, y))
			spots.append(Vector2(left - 24.0 - half.x, view.y * 0.45))
	var chosen: Vector2 = (spots[0] - half).clamp(lo, hi)
	for at in spots:
		var cand: Vector2 = (at - half).clamp(lo, hi)
		if not _hits_control(Rect2(cand, _label.size)):
			chosen = cand
			break
	_label.position = chosen


## True when the rect touches any visible button (with a small margin).
func _hits_control(rect: Rect2) -> bool:
	var r := rect.grow(6.0)
	for action in _tc.buttons:
		var b: TouchButton = _tc.buttons[action]
		if b.visible and r.intersects(Rect2(b.center - Vector2(b.radius, b.radius), Vector2(b.radius, b.radius) * 2.0)):
			return true
	return false
