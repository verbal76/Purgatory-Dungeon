extends Node
## Steam Deck / Steam Machine: every menu screen must be usable with a controller alone. For each screen: a control has focus once it is
## up, and every visible, enabled, focusable control can be reached from it by D-pad / stick focus moves (no mouse needed).

const SCENES: Array[String] = [
	"res://scenes/MainMenu.tscn",
	"res://scenes/ProfileScreen.tscn",
	"res://scenes/CharacterSelection.tscn",
	"res://scenes/OptionsScreen.tscn",
	"res://scenes/CodexScreen.tscn",
	"res://scenes/AlchemistStore.tscn",
]

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _interactive(c: Control) -> bool:
	if not c.is_visible_in_tree() or c.focus_mode == Control.FOCUS_NONE:
		return false
	if c is BaseButton:
		return not (c as BaseButton).disabled
	if c is Range:
		return (c as Range).editable
	return c is LineEdit or c is TextEdit or c is ItemList or c is Tree


func _collect(root: Node, out: Array[Control]) -> void:
	for ch in root.get_children():
		if ch is Control and _interactive(ch):
			out.append(ch)
		_collect(ch, out)


func _title(c: Control) -> String:
	var t: String = c.name
	if c is Button:
		t += " '" + (c as Button).text + "'"
	return t


## Controls reachable from `start` by focus moves in the four directions (a flood fill over find_valid_focus_neighbor).
func _reachable(start: Control) -> Dictionary:
	var seen: Dictionary = {start: true}
	var queue: Array[Control] = [start]
	while not queue.is_empty():
		var cur: Control = queue.pop_front()
		for side in [SIDE_TOP, SIDE_BOTTOM, SIDE_LEFT, SIDE_RIGHT]:
			var nxt: Control = cur.find_valid_focus_neighbor(side)
			if nxt != null and not seen.has(nxt):
				seen[nxt] = true
				queue.append(nxt)
		var nxt2: Control = cur.find_next_valid_focus()   # the Tab chain too
		if nxt2 != null and not seen.has(nxt2):
			seen[nxt2] = true
			queue.append(nxt2)
	return seen


# Character selection at the Deck's 1280 px: its three columns must not push the form off the screen (the dev toggles column yields).
func _check_fits_deck(sel: Node) -> void:
	var columns: Control = sel.find_child("CenterContent", true, false)
	var margin: MarginContainer = sel.find_child("Margin", true, false)
	var panel: Control = sel.find_child("DebugPanel", true, false)
	var m: float = float(margin.get_theme_constant("margin_left") + margin.get_theme_constant("margin_right"))
	sel._fit_debug_panel(1280.0)
	_check(columns.get_combined_minimum_size().x + m <= 1280.0, "character select fits a 1280 px screen (needs %d)" % int(columns.get_combined_minimum_size().x + m))
	_check(panel == null or not panel.visible, "the developer toggles column yields on a 1280 px screen")
	sel._fit_debug_panel(2400.0)
	_check(panel == null or panel.visible, "the developer toggles column is still shown on a wide desktop window")
	sel._fit_debug_panel(1280.0)


# Every Options tab: the tab bar takes focus, left / right changes tab, and each tab's controls can be reached from it.
func _check_options_tabs(opts: Node) -> void:
	var tc: TabContainer = opts.find_child("TabContainer", true, false)
	var bar: TabBar = tc.get_tab_bar()
	bar.grab_focus()
	for i in tc.get_tab_count():
		tc.current_tab = i
		for f in 4:
			await get_tree().process_frame
		var all: Array[Control] = []
		_collect(tc.get_tab_control(i), all)
		var reach: Dictionary = _reachable(bar)
		var unreachable: Array[String] = []
		for c in all:
			if not reach.has(c):
				unreachable.append(_title(c))
		_check(unreachable.is_empty(), "Options tab %d '%s': every control is reachable from the tab bar (%d of %d not: %s)" % [i, tc.get_tab_title(i), unreachable.size(), all.size(), ", ".join(unreachable.slice(0, 8))])
	# left / right on the tab bar changes the tab
	tc.current_tab = 0
	bar.grab_focus()
	var ev := InputEventAction.new()
	ev.action = "ui_right"
	ev.pressed = true
	Input.parse_input_event(ev)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(tc.current_tab == 1, "Options: right on the focused tab bar moves to the next tab (tab %d)" % tc.current_tab)
	var rel := InputEventAction.new()
	rel.action = "ui_right"
	Input.parse_input_event(rel)


# The win screen: once its fade is done a button has focus and both choices can be reached.
func _check_run_end() -> void:
	var screen := CanvasLayer.new()
	screen.set_script(load("res://scripts/run_end_screen.gd"))
	add_child(screen)
	screen.setup(null)
	var waited := 0.0
	var focus: Control = null
	while waited < 6.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
		focus = get_viewport().gui_get_focus_owner()
		if focus is Button and screen.is_ancestor_of(focus):
			break
	_check(focus is Button and screen.is_ancestor_of(focus), "win screen: a choice has focus once the fade is done (%s)" % (focus.name if focus != null else "none"))
	var all: Array[Control] = []
	_collect(screen, all)
	var reach: Dictionary = _reachable(focus) if focus != null else {}
	var lost: Array[String] = []
	for c in all:
		if not reach.has(c):
			lost.append(_title(c))
	_check(all.size() >= 2 and lost.is_empty(), "win screen: both choices are reachable by controller (%d found, not reachable: %s)" % [all.size(), ", ".join(lost)])
	screen.queue_free()


# The on-screen keyboard (character name): type, delete, accept and cancel with controller actions only.
func _check_keyboard() -> void:
	var kb: Control = (load("res://scenes/VirtualKeyboard.tscn") as PackedScene).instantiate()
	add_child(kb)
	for i in 6:
		await get_tree().process_frame
	var submitted: Array = []
	var cancelled: Array = []
	kb.submitted.connect(func(t: String) -> void: submitted.append(t))
	kb.cancelled.connect(func() -> void: cancelled.append(true))
	kb.open_with_text("")
	for i in 6:
		await get_tree().process_frame
	var focus: Control = get_viewport().gui_get_focus_owner()
	_check(focus is Button and kb.is_ancestor_of(focus), "keyboard: opens with a key focused (%s)" % (focus.name if focus != null else "none"))
	var keys: Array[Control] = []
	_collect(kb, keys)
	var reach: Dictionary = _reachable(focus) if focus != null else {}
	var lost: Array[String] = []
	for k in keys:
		if not reach.has(k):
			lost.append(_title(k))
	_check(lost.is_empty(), "keyboard: every key is reachable by D-pad (%d of %d not: %s)" % [lost.size(), keys.size(), ", ".join(lost.slice(0, 6))])
	kb._on_key_pressed("A")
	kb._on_key_pressed("B")
	_check(kb.get_text() == "AB", "keyboard: pressing keys types (%s)" % kb.get_text())
	var bs := InputEventAction.new()
	bs.action = "ui_text_backspace"
	bs.pressed = true
	kb._unhandled_input(bs)
	_check(kb.get_text() == "A", "keyboard: the X button (ui_text_backspace) deletes (%s)" % kb.get_text())
	var cancel := InputEventAction.new()
	cancel.action = "ui_cancel"
	cancel.pressed = true
	kb._unhandled_input(cancel)
	_check(cancelled.size() == 1 and not kb.visible, "keyboard: B (ui_cancel) closes it")
	kb.queue_free()


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	SaveManager.load_slot(0)
	SaveManager.create_initial_identity("NavTester", "mage")
	SaveManager.load_slot(1)
	SaveManager.create_initial_identity("NavBarb", "barbarian")
	InputManager._set_scheme(InputManager.Scheme.GAMEPAD)
	for path in SCENES:
		var name_: String = path.get_file().get_basename()
		var inst: Node = (load(path) as PackedScene).instantiate()
		add_child(inst)
		for i in 12:
			await get_tree().process_frame
		var focused: Control = get_viewport().gui_get_focus_owner()
		_check(focused != null and focused.is_visible_in_tree(), "%s: a control has focus when the screen opens (%s)" % [name_, focused.name if focused != null else "none"])
		var all: Array[Control] = []
		_collect(inst, all)
		_check(not all.is_empty(), "%s: has interactive controls" % name_)
		if focused != null:
			var reach: Dictionary = _reachable(focused)
			var unreachable: Array[String] = []
			for c in all:
				if not reach.has(c):
					unreachable.append(_title(c))
			_check(unreachable.is_empty(), "%s: every control is reachable by controller focus moves (%d of %d not: %s)" % [name_, unreachable.size(), all.size(), ", ".join(unreachable.slice(0, 8))])
		if name_ == "OptionsScreen":
			await _check_options_tabs(inst)
		if name_ == "CharacterSelection":
			_check_fits_deck(inst)
		inst.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame
	await _check_keyboard()
	await _check_run_end()
	print("test_controller_nav: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
