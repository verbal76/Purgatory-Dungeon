# Dev utility (not shipped): renders the touch layer over a stand-in dungeon backdrop so the controls can be
# judged and screenshotted without the (slow in software GL) game scene. Used with tools/ui_shot.gd:
#   PURGATORY_SAVE_ROOT=/tmp/x PURGATORY_FORCE_TOUCH=1 xvfb-run -a -s "-screen 0 1496x672x24" godot \
#     --rendering-driver opengl3 --resolution 1496x672 --path . --script tools/ui_shot.gd -- \
#     res://tools/touch_preview.tscn /tmp/touch.png 40
# Env: TOUCH_SCHEME=twin|classic (default twin), TOUCH_LOOK=active (twin: the right look stick held out),
#      TOUCH_ATTACK_DRAG=1 (twin: a finger on ATTACK dragged out to aim), TOUCH_DPI (default 480: the Pixel panel,
#      for the mm minimums),
#      TOUCH_OPACITY (percent, default 70), TOUCH_SCALE (percent, default 100), TOUCH_STICK=idle|active|none,
#      TOUCH_PRESSED="attack,block" (buttons drawn pressed), TOUCH_HINT=<onboarding step>, TOUCH_BRIGHT=1 (light wall),
#      TOUCH_COOLDOWN (0..1, default 0.45), TOUCH_BADGE (default "3"), TOUCH_CHARGE (0..1, default none),
#      TOUCH_DISABLED=AOE (drawn in the disabled look), TOUCH_MAP_ON=1 (map toggled on), TOUCH_DUMP=1 (print every button centre/radius, for before/after comparison).
extends Control

var _tc: TouchControls = null
var _bright: bool = false
var _rng := RandomNumberGenerator.new()
var _cooldown: float = 0.45
var _badge: String = "3"
var _charge: float = -1.0


func _ready() -> void:
	_bright = OS.get_environment("TOUCH_BRIGHT") == "1"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var op: String = OS.get_environment("TOUCH_OPACITY")
	var sc: String = OS.get_environment("TOUCH_SCALE")
	SettingsManager.gameplay_settings[TouchControls.KEY_OPACITY] = float(op) if op != "" else 70.0
	SettingsManager.gameplay_settings[TouchControls.KEY_SCALE] = float(sc) if sc != "" else 100.0
	# Mark the first-run hints done so only the requested one shows.
	SettingsManager.gameplay_settings[TouchOnboarding.SETTINGS_KEY] = {"move": true, "look": true, "look_stick": true, "attack": true, "aim": true, "use": true, "block": true, "burst": true}
	var scheme: String = OS.get_environment("TOUCH_SCHEME")
	SettingsManager.gameplay_settings[TouchControls.KEY_SCHEME] = scheme if scheme != "" else "twin"
	_tc = TouchControls.new()
	_tc.layout_override_insets = Vector4(0, 0, 0, 0)
	var dpi: String = OS.get_environment("TOUCH_DPI")
	_tc.dpi_override = float(dpi) if dpi != "" else 480.0
	add_child(_tc)
	await get_tree().process_frame
	await get_tree().process_frame
	_tc.set_use_context(true, "OPEN")
	var cd: String = OS.get_environment("TOUCH_COOLDOWN")
	_cooldown = float(cd) if cd != "" else 0.45
	_badge = OS.get_environment("TOUCH_BADGE") if OS.get_environment("TOUCH_BADGE") != "" else "3"
	var ch: String = OS.get_environment("TOUCH_CHARGE")
	if ch != "":
		_charge = float(ch)
	for a in OS.get_environment("TOUCH_PRESSED").split(",", false):
		if _tc.buttons.has(a):
			(_tc.buttons[a] as TouchButton).pressed_visual = true
			(_tc.buttons[a] as TouchButton).queue_redraw()
	if OS.get_environment("TOUCH_MAP_ON") == "1":
		(_tc.buttons["minimap"] as TouchButton).toggled_on = true
		(_tc.buttons["minimap"] as TouchButton).queue_redraw()
	var stick: String = OS.get_environment("TOUCH_STICK")
	if stick == "active":
		var p: Vector2 = _tc.stick_default + Vector2(10, 0)
		_tc._touch_down(7, p)
		_tc._touch_move(7, p + Vector2(58, -36), Vector2.ZERO)
	if OS.get_environment("TOUCH_LOOK") == "active" and _tc.is_twin():
		var lp: Vector2 = _tc.look_default + Vector2(10, 0)
		_tc._touch_down(8, lp)
		_tc._touch_move(8, lp + Vector2(60, -34), Vector2.ZERO)
	if OS.get_environment("TOUCH_ATTACK_DRAG") == "1" and _tc.is_twin():
		var ab: TouchButton = _tc.buttons["attack"]
		_tc._touch_down(9, ab.center + Vector2(12, 10))
		_tc._touch_move(9, ab.center + Vector2(12, 10) + Vector2(-70, -48), Vector2.ZERO)
	var hint: String = OS.get_environment("TOUCH_HINT")
	if hint != "":
		_tc.onboarding._activate(hint)
		_tc.onboarding._poll = 1.0
	if OS.get_environment("TOUCH_DUMP") == "1":
		print("VIEW ", _tc.view_size(), " scheme ", _tc.scheme, " ppmm ", _tc.device_px_per_mm(), " stick_default ", _tc.stick_default, " look_default ", _tc.look_default)
		for a in _tc.buttons:
			var b: TouchButton = _tc.buttons[a]
			print("BTN ", a, " c=", b.center, " r=", b.radius, " pos=", b.position, " size=", b.size, " vis=", b.visible)
	queue_redraw()


func _process(_delta: float) -> void:
	# TouchControls polls the (absent) player every 0.1 s and would reset these demo values.
	if _tc == null or not _tc.buttons.has("AOE"):
		return
	var aoe: TouchButton = _tc.buttons["AOE"]
	var dis: bool = OS.get_environment("TOUCH_DISABLED") == "AOE"
	if aoe.cooldown != _cooldown or aoe.badge != _badge or aoe.unavailable != dis:
		aoe.cooldown = _cooldown
		aoe.badge = _badge
		aoe.unavailable = dis
		aoe.queue_redraw()
	if _charge >= 0.0 and "charge" in _tc.buttons["attack"] and _tc.buttons["attack"].get("charge") != _charge:
		_tc.buttons["attack"].set("charge", _charge)
		_tc.buttons["attack"].queue_redraw()


func _draw() -> void:
	# A stand-in for the dungeon: mortar-dark stone blocks lit by a warm torch at the upper left.
	var s: Vector2 = get_viewport_rect().size
	_rng.seed = 11
	draw_rect(Rect2(Vector2.ZERO, s), Color("120e0c"))
	var bh: float = 64.0
	var y: float = 0.0
	var row: int = 0
	while y < s.y:
		var x: float = -float(row % 2) * 60.0
		while x < s.x:
			var w: float = 120.0 + _rng.randf() * 40.0
			var tone: float = 0.10 + _rng.randf() * 0.07
			if _bright:
				tone += 0.30
			var warm: float = clampf(1.0 - Vector2(x, y).distance_to(Vector2(120, 60)) / 900.0, 0.0, 1.0)
			var col := Color(tone + warm * 0.12, tone * 0.88 + warm * 0.05, tone * 0.74)
			draw_rect(Rect2(x + 2, y + 2, w - 4, bh - 4), col)
			x += w
		y += bh
		row += 1
	# floor-ish darkening toward the bottom
	for i in 12:
		var f: float = float(i) / 12.0
		draw_rect(Rect2(0, s.y * (0.55 + 0.45 * f), s.x, s.y * 0.45 / 12.0 + 1.0), Color(0, 0, 0, 0.05))
