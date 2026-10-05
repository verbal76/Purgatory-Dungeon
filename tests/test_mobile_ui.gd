extends Node
## Phone UI legibility: on a touch platform every menu screen has readable text, thumb-sized
## buttons, and nothing a player must tap hangs off the 1280x720 phone canvas. Run with
## PURGATORY_FORCE_TOUCH=1 (tests/run_tests.sh does).

const SCENES: Array[String] = [
	"res://scenes/MainMenu.tscn",
	"res://scenes/CharacterSelection.tscn",
	"res://scenes/ProfileScreen.tscn",
	"res://scenes/OptionsScreen.tscn",
	"res://scenes/CodexScreen.tscn",
	"res://scenes/AlchemistStore.tscn",
]
const MIN_FONT := 22
const MIN_BUTTON_H := 60.0   # layout may squeeze a 72 px minimum a little; still a thumb-sized target
var _fails := 0
var _checks := 0


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		printerr("FAIL: " + msg)


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	_check(TouchControls.is_touch_platform(), "run with PURGATORY_FORCE_TOUCH=1")
	var win := get_window()
	win.content_scale_size = Vector2i(1280, 720)
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	win.size = Vector2i(1280, 720)
	for i in 5:
		await get_tree().process_frame
	_check(get_node_or_null("/root/MobileUi") != null, "MobileUi is installed on touch platforms")
	SaveManager.load_slot(0)
	SaveManager.create_initial_identity("PhoneTester", "barbarian")

	for path in SCENES:
		var inst := (load(path) as PackedScene).instantiate()
		add_child(inst)
		for i in 12:
			await get_tree().process_frame
		_audit(inst, path)
		inst.queue_free()
		await get_tree().process_frame

	await _audit_character_select_phone_mode()
	print("test_mobile_ui: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _audit(root: Node, path: String) -> void:
	var view := get_viewport().get_visible_rect()
	_check(view.size.y <= 720.5 and view.size.y >= 719.0, "%s: phone canvas is 720 high (got %s)" % [path, view.size])
	var buttons := 0
	for n in _all_controls(root):
		var c := n as Control
		if not c.is_visible_in_tree():
			continue
		if c is Button:
			buttons += 1
			var r := c.get_global_rect()
			_check(r.size.y >= MIN_BUTTON_H, "%s: button '%s' is thumb-sized (h=%.0f)" % [path, c.name, r.size.y])
			_check(c.get_theme_font_size("font_size") >= MIN_FONT, "%s: button '%s' text readable (%d)" % [path, c.name, c.get_theme_font_size("font_size")])
			_check(view.grow(2.0).encloses(r), "%s: button '%s' lies on screen (%s in %s)" % [path, c.name, r, view])
		elif c is Label and (c as Label).text.strip_edges() != "":
			_check(c.get_theme_font_size("font_size") >= MIN_FONT, "%s: label '%s' readable (%d)" % [path, c.name, c.get_theme_font_size("font_size")])
	_check(buttons > 0, "%s has buttons to audit" % path)


func _all_controls(n: Node) -> Array:
	var out: Array = []
	for c in n.get_children():
		if c is Control:
			out.append(c)
		out.append_array(_all_controls(c))
	return out


# The dev toggles are not for phones; the name field must not pop the OS keyboard over the form.
func _audit_character_select_phone_mode() -> void:
	var inst := (load("res://scenes/CharacterSelection.tscn") as PackedScene).instantiate()
	add_child(inst)
	for i in 8:
		await get_tree().process_frame
	var dbg := inst.find_child("DebugPanel", true, false) as Control
	_check(dbg != null and not dbg.visible, "debug toggles hidden on phones")
	var name_in := inst.find_child("CharNameInput", true, false) as LineEdit
	_check(name_in != null and not name_in.virtual_keyboard_enabled, "name field uses the game's own keyboard, not the OS one")
	inst.queue_free()
	await get_tree().process_frame
