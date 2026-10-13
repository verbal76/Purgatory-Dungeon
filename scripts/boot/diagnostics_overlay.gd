# ==============================================================================
# File Name: diagnostics_overlay.gd
# Path: res://scripts/boot/diagnostics_overlay.gd
#
# Description:
#   NATIVE LAYER (docs/OTA.md section 10). Diagnostics and OTA recovery screen, built entirely in
#   code with engine controls so it works even when the game layer (scenes, theme, UI scripts)
#   from an OTA is broken. No game-layer dependencies. Shows what Boot.diagnostics_text() returns
#   (never a secret) and offers Check / Download / Activate on restart / Roll back / Boot baseline
#   (Re-enable OTA) / Copy diagnostics / Close. Buttons are thumb-sized on touch devices.
# ==============================================================================
extends CanvasLayer

var boot   # the Boot autoload node

var _panel: PanelContainer
var _text: Label
var _status: Label
var _toast: Label
var _buttons: Dictionary = {}
var _toast_t := 0.0
var _touch := false


func _ready() -> void:
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS
	_touch = OS.has_feature("mobile") or DisplayServer.is_touchscreen_available()
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.offset_left = 24
	_panel.offset_top = 24
	_panel.offset_right = -24
	_panel.offset_bottom = -24
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.035, 0.035, 0.97)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(18)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)
	var v: VBoxContainer = VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	_panel.add_child(v)
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_text = Label.new()
	_text.add_theme_font_size_override("font_size", 19)
	_text.add_theme_color_override("font_color", Color(0.9, 0.88, 0.84))
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_text)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 19)
	_status.add_theme_color_override("font_color", Color(1.0, 0.86, 0.55))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_status)
	var grid: GridContainer = GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	v.add_child(grid)
	var defs: Array = []
	if boot.ota_enabled:
		defs = [["check", "Check for update"], ["download", "Download update"], ["activate", "Activate on restart"],
				["rollback", "Roll back"], ["baseline", "Boot baseline"], ["copy", "Copy diagnostics"],
				["quit", "Close app"], ["close", "Close"]]
	else:
		defs = [["copy", "Copy diagnostics"], ["close", "Close"]]
	for d in defs:
		var b: Button = Button.new()
		b.text = d[1]
		b.custom_minimum_size = Vector2(240, 76 if _touch else 48)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 20)
		b.pressed.connect(_on_button.bind(d[0]))
		grid.add_child(b)
		_buttons[d[0]] = b
	_toast = Label.new()
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.offset_top = 16
	_toast.add_theme_font_size_override("font_size", 22)
	_toast.add_theme_color_override("font_color", Color(0.95, 0.95, 0.9))
	_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_toast.add_theme_constant_override("outline_size", 8)
	_toast.visible = false
	add_child(_toast)
	_panel.visible = false
	set_process(false)


func open() -> void:
	_panel.visible = true
	refresh()


func close() -> void:
	_panel.visible = false


func is_open() -> bool:
	return _panel != null and _panel.visible


func refresh() -> void:
	_text.text = boot.diagnostics_text()
	if boot.ota_enabled:
		(_buttons["baseline"] as Button).text = "Re-enable OTA" if bool(boot.core.state["disabled"]) else "Boot baseline"
		var busy: bool = boot.updater.busy
		(_buttons["check"] as Button).disabled = busy
		# Download: an update the last check found, or (after a failed download) try again.
		(_buttons["download"] as Button).disabled = busy or not (boot.updater.has_available() or boot.updater.status == "failed")
		(_buttons["activate"] as Button).disabled = boot.core.slot("ready").is_empty()
		(_buttons["rollback"] as Button).disabled = boot.core.slot("current").is_empty() and boot.core.slot("pending").is_empty()


func toast(msg: String) -> void:
	_toast.text = msg
	_toast.visible = true
	_toast_t = 6.0
	set_process(true)


func _process(dt: float) -> void:
	_toast_t -= dt
	if _toast_t <= 0.0:
		_toast.visible = false
		set_process(false)


func _say(msg: String) -> void:
	_status.text = msg
	refresh()


func _on_button(id: String) -> void:
	match id:
		"close":
			close()
		"copy":
			DisplayServer.clipboard_set(boot.diagnostics_text())
			_say("Diagnostics copied to the clipboard.")
		"quit":
			boot.get_tree().quit()
		"check":
			_say("Checking the %s channel..." % boot.core.channel)
			var r: String = await boot.updater.check(false)
			_say(("Update available: %s. Press Download update." % boot.updater.remote.get("ota_id", "?")) if r == "available" else r)
		"download":
			_say("Downloading...")
			var r: String = await boot.updater.download_available()
			if r.begins_with("nothing to download"):
				r = await boot.updater.check(true)
			_say(r)
		"activate":
			var r: String = boot.core.activate_ready()
			boot.status_changed.emit()
			_say(r if r != "" else "Will run on next start. Close and reopen the app.")
		"rollback":
			var r: String = boot.core.rollback()
			boot.status_changed.emit()
			_say(r if r != "" else "Rolled back: close and reopen the app to run it.")
		"baseline":
			boot.core.set_disabled(not bool(boot.core.state["disabled"]))
			boot.status_changed.emit()
			_say("Next start runs the embedded baseline." if bool(boot.core.state["disabled"]) else "OTA re-enabled for the next start.")
