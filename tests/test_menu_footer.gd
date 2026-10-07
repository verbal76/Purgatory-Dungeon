extends Node
## Player-facing menu surface after the post-v7.2 round:
##   - no OTA / debug text over a normal menu: no diagnostics overlay node, no performance readout, no label that names an
##     OTA id, channel or "restart to apply" anywhere in the tree
##   - Main menu footer: version text inside the (simulated) safe area with a real margin on wide, tall and notched
##     viewports; an Exit button above it; Exit flushes the profile and settings and quits exactly once; the old Quit
##     button is gone; focus can reach Exit from the button column
##   - Alchemist's Lab: the bottom-left button reads "Main Menu" (no Load Character), pressing it (or Esc) goes to the
##     main menu and leaves every save file byte-identical
## Runs on desktop and as a phone (PURGATORY_FORCE_TOUCH=1). Must run with PURGATORY_SAVE_ROOT set.

const MENU := "res://scenes/MainMenu.tscn"
const ALCHEMIST := "res://scenes/AlchemistStore.tscn"
const BANNED := ["dev-0", "OTA", "channel", "restart to", "(dev", "runtime", "fingerprint", "ready:"]

var _fails := 0
var _checks := 0
var _quit_calls := 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	# The scene changes below replace the current scene: make a throw-away one so this test keeps running.
	await get_tree().process_frame   # the root is still setting up its children in _ready
	var dummy := Node.new()
	dummy.name = "Dummy"
	get_tree().root.add_child(dummy)
	get_tree().current_scene = dummy
	SaveManager.load_slot(0)
	SaveManager.create_initial_identity("FooterTester", "barbarian")
	var win := get_window()
	win.content_scale_size = Vector2i(1280, 720)
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	await _t_no_overlay_in_menu()
	await _t_footer()
	await _t_exit()
	await _t_alchemist()
	print("test_menu_footer: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _frames(n: int = 4) -> void:
	for i in n:
		await get_tree().process_frame


func _menu() -> Control:
	var m: Control = (load(MENU) as PackedScene).instantiate()
	add_child(m)
	await _frames()
	return m


func _all_labels(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is Label:
			out.append(c)
		_all_labels(c, out)


# --- nothing technical over a normal menu ---------------------------------------------------------------------------

func _t_no_overlay_in_menu() -> void:
	var m: Control = await _menu()
	await _frames(20)
	var boot: Node = get_node_or_null("/root/Boot")
	_check(boot != null, "Boot autoload exists")
	if boot != null:
		_check(boot.get("_overlay") == null, "the diagnostics overlay is not even created in a normal menu")
		for c in boot.get_children():
			_check(not (c is CanvasLayer and (c as CanvasLayer).layer >= 120), "no overlay layer under Boot (%s)" % c.name)
		_check(not boot.call("panel_visible"), "no 'Applying update' panel on a normal start")
	var perf: Node = get_node_or_null("/root/PerfOverlay")
	if perf != null:
		_check(not ((perf.get("_label") as Label).visible), "the performance readout is hidden by default")
	_check(not bool(SettingsManager.gameplay_settings.get(PerfOverlay.KEY, false)), "performance readout setting is off by default")
	_check(not SettingsManager.is_developer_mode(), "developer mode is off by default")
	var labels: Array = []
	_all_labels(get_tree().root, labels)
	for l in labels:
		var lbl: Label = l
		if not lbl.is_visible_in_tree():
			continue
		for b in BANNED:
			_check(not lbl.text.contains(b), "no visible label says '%s' (label '%s': %s)" % [b, lbl.name, lbl.text.left(60)])
	# the version text carries only the version
	var v := m.find_child("VersionLabel", true, false) as Label
	_check(v != null and v.text.begins_with("Purgatory Dungeon") and not v.text.contains("restart"), "version label shows the version only (%s)" % (v.text if v != null else "missing"))
	m.queue_free()
	await _frames(2)


# --- footer layout ----------------------------------------------------------------------------------------------------

func _t_footer() -> void:
	var m: Control = await _menu()
	_check(m.find_child("QuitButton", true, false) == null, "the old Quit button is gone")
	var exit := m.find_child("ExitButton", true, false) as Button
	var ver := m.find_child("VersionLabel", true, false) as Label
	_check(exit != null and ver != null, "Exit button and version label exist")
	if exit == null or ver == null:
		m.queue_free()
		return
	_check(exit.text == "Exit", "the button says Exit")
	_check(exit.theme_type_variation == &"NavButton", "Exit uses the menu's nav button style")
	for size in [Vector2i(1280, 720), Vector2i(1600, 720), Vector2i(720, 1280)]:
		get_window().size = size
		await _frames(3)
		var view: Rect2 = get_viewport().get_visible_rect()
		m.layout_footer(Vector4.ZERO)
		await _frames(2)
		_check_footer(exit, ver, view, Vector4.ZERO, "viewport %s" % [view.size])
	# a notched phone: derive virtual-px insets from a physical safe area exactly like the HUD does
	get_window().size = Vector2i(1280, 720)
	await _frames(3)
	var view2: Rect2 = get_viewport().get_visible_rect()
	var screen := Vector2(2400, 1080)
	var safe := Rect2(84, 0, 2160, 1000)   # cut-out on the left, rounded corner / gesture bar on the right and bottom
	var ins: Vector4 = TouchControls.insets_from_safe_area(screen, safe, view2.size)
	_check(ins.x > 0.0 and ins.z > 0.0 and ins.w > 0.0, "the simulated notch yields insets (%s)" % ins)
	m.layout_footer(ins)
	await _frames(2)
	_check_footer(exit, ver, view2, ins, "notched %s" % ins)
	# a hostile notch
	var big := Vector4(120, 60, 140, 90)
	m.layout_footer(big)
	await _frames(2)
	_check_footer(exit, ver, view2, big, "large cut-out")
	# Exit is above the version text, right-aligned with it
	var er := exit.get_global_rect()
	var vr := ver.get_global_rect()
	_check(er.end.y <= vr.position.y + 0.5, "Exit sits above the version text (exit bottom %.0f, version top %.0f)" % [er.end.y, vr.position.y])
	_check(absf(er.end.x - vr.end.x) < 1.5, "Exit and version share the right edge")
	_check(er.size.y >= (60.0 if TouchControls.is_touch_platform() else 48.0), "Exit is a comfortable target (h=%.0f)" % er.size.y)
	# the button column does not collide with the footer
	var col := m.find_child("VBox", true, false) as Control
	if col != null:
		_check(not col.get_global_rect().intersects(er), "the button column and the footer do not overlap")
	# keyboard / controller: the last column button leads to Exit and back
	var last: Button = null
	for nm in ["StartButton", "ProfileButton", "AlchemistButton", "CodexButton", "OptionsButton"]:
		var b := m.find_child(nm, true, false) as Button
		if b != null:
			last = b
	_check(last != null and last.get_node_or_null(last.focus_neighbor_bottom) == exit, "Down from the last menu button reaches Exit")
	_check(exit.get_node_or_null(exit.focus_neighbor_top) == last, "Up from Exit returns to the column")
	_check(exit.focus_mode == Control.FOCUS_ALL, "Exit takes focus")
	exit.grab_focus()
	_check(exit.has_focus(), "Exit can be focused")
	m.queue_free()
	await _frames(2)


func _check_footer(exit: Button, ver: Label, view: Rect2, ins: Vector4, what: String) -> void:
	var safe := Rect2(view.position.x + ins.x, view.position.y + ins.y, view.size.x - ins.x - ins.z, view.size.y - ins.y - ins.w)
	var min_margin: float = 16.0
	for pair in [["version", ver.get_global_rect()], ["exit", exit.get_global_rect()]]:
		var r: Rect2 = pair[1]
		_check(safe.grow(-min_margin).encloses(r), "%s: %s lies inside the safe area with >=%d px margin (%s in %s)" % [what, pair[0], int(min_margin), r, safe])
	_check(view.size.x - ver.get_global_rect().end.x >= min_margin + ins.z - 0.5, "%s: right margin %.0f" % [what, view.size.x - ver.get_global_rect().end.x])
	_check(view.size.y - ver.get_global_rect().end.y >= min_margin + ins.w - 0.5, "%s: bottom margin %.0f" % [what, view.size.y - ver.get_global_rect().end.y])


# --- Exit ------------------------------------------------------------------------------------------------------------

func _t_exit() -> void:
	var m: Control = await _menu()
	m.quit_override = func() -> void: _quit_calls += 1
	var exit := m.find_child("ExitButton", true, false) as Button
	var slot_path: String = SaveManager.get_file_path(0)
	DirAccess.remove_absolute(slot_path)
	SaveManager.current_profile["meta_currency"] = 77
	exit.pressed.emit()
	_check(_quit_calls == 1, "Exit quits")
	exit.pressed.emit()
	_check(_quit_calls == 1, "a second press does not quit twice")
	var on_disk: Variant = JSON.parse_string(FileAccess.get_file_as_string(slot_path))
	_check(on_disk is Dictionary and int((on_disk as Dictionary).get("meta_currency", -1)) == 77, "Exit flushed the profile to disk first")
	var settings_path: String = StoragePaths.root().path_join("settings.json")
	_check(FileAccess.file_exists(settings_path) and JSON.parse_string(FileAccess.get_file_as_string(settings_path)) is Dictionary, "settings are on disk, valid JSON")
	var leftovers: Array = []
	for f in DirAccess.get_files_at(StoragePaths.root()):
		if f.ends_with(".tmp"):
			leftovers.append(f)
	_check(leftovers.is_empty(), "no half-written temp files after Exit (%s)" % [leftovers])
	m.queue_free()
	await _frames(2)


# --- Alchemist's Lab --------------------------------------------------------------------------------------------------

func _snapshot_saves() -> Dictionary:
	var out: Dictionary = {}
	_walk(StoragePaths.root(), out)
	return out


func _walk(dir: String, out: Dictionary) -> void:
	for f in DirAccess.get_files_at(dir):
		out[dir.path_join(f)] = FileAccess.get_file_as_bytes(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_walk(dir.path_join(d), out)


func _t_alchemist() -> void:
	SaveManager.current_profile["meta_currency"] = 5
	SaveManager.save_profile()
	var store: Control = (load(ALCHEMIST) as PackedScene).instantiate()
	add_child(store)
	await _frames(6)
	var btn := store.find_child("MainMenuButton", true, false) as Button
	_check(btn != null, "the bottom-left button is MainMenuButton")
	_check(store.find_child("LoadCharacterButton", true, false) == null, "no LoadCharacterButton any more")
	if btn == null:
		store.queue_free()
		return
	_check(btn.text.to_upper() == "MAIN MENU", "button text is Main Menu (%s)" % btn.text)
	for l in store.find_children("*", "Label", true, false):
		_check(not (l as Label).text.contains("Load Character"), "no 'Load Character' text in the Alchemist's Lab")
	var nav := btn.get_parent()
	_check(nav != null and nav.get_child(0) == btn, "Main Menu stays bottom-left (first in the nav bar)")
	var before: Dictionary = _snapshot_saves()
	_check(not before.is_empty(), "there are save files to compare (%d)" % before.size())
	btn.pressed.emit()
	await _frames(6)
	var scene: Node = get_tree().current_scene
	_check(scene != null and scene.scene_file_path == MENU, "pressing Main Menu changes to the main menu (%s)" % (scene.scene_file_path if scene != null else "none"))
	var after: Dictionary = _snapshot_saves()
	_check(after.keys().size() == before.keys().size(), "no file was created or removed (%d -> %d)" % [before.size(), after.size()])
	var same := true
	for k in before.keys():
		if not after.has(k) or after[k] != before[k]:
			same = false
			printerr("  changed: " + str(k))
	_check(same, "every save/settings file is byte-identical after leaving the lab")
	# Esc / back does the same
	var store2: Control = (load(ALCHEMIST) as PackedScene).instantiate()
	add_child(store2)
	await _frames(4)
	var first_menu: Node = get_tree().current_scene
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	store2._input(esc)
	await _frames(6)
	_check(get_tree().current_scene != null and get_tree().current_scene.scene_file_path == MENU and get_tree().current_scene != first_menu, "Esc in the lab also goes to a fresh main menu")
	var after2: Dictionary = _snapshot_saves()
	var same2 := after2.keys().size() == before.keys().size()
	for k in before.keys():
		if not after2.has(k) or after2[k] != before[k]:
			same2 = false
	_check(same2, "files still byte-identical after the Esc path")
	if is_instance_valid(store2):
		store2.queue_free()
