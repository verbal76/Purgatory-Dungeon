extends Node
## Steam Deck / Steam Machine: on-screen glyphs must match the input in use. Covers the glyph set, the action -> button mapping read from the
## InputMap, the Xbox / Steam Deck label sets, the prompt widget (art on a controller, key name on keyboard, never both) and Options.

const Glyphs := preload("res://scripts/controller_glyphs.gd")
const GlyphPromptScript := preload("res://scripts/glyph_prompt.gd")

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _labels_text(root: Node, out: Array, only_visible: bool = true) -> void:
	for c in root.get_children():
		if c is Label and (not only_visible or (c as Label).is_visible_in_tree()):
			out.append((c as Label).text)
		_labels_text(c, out, only_visible)


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return

	# --- the action -> button mapping is the game's real default bindings -------------------------------------------------
	var expect := {"equip": "a", "ui_accept": "a", "jump": "b", "attack": "rt", "kick": "rb", "AOE": "lb", "block": "dpad_down",
			"ui_menu": "menu", "toggle_walk": "l3", "minimap": "lt"}
	for action in expect:
		_check(Glyphs.token_for_action(action) == expect[action], "%s is bound to controller button '%s' (got '%s')" % [action, expect[action], Glyphs.token_for_action(action)])
	_check(Glyphs.token_for_action("move_forward") == "" and Glyphs.token_for_action("no_such_action") == "", "a stick direction / unknown action has no button glyph")

	# --- label sets ---------------------------------------------------------------------------------------------------------
	_check(Glyphs.style_for_joy_name("Steam Deck Controller") == Glyphs.Style.DECK, "a Steam Deck controller gets the Deck labels")
	_check(Glyphs.style_for_joy_name("Steam Controller") == Glyphs.Style.DECK, "a Steam Controller gets the Deck labels")
	_check(Glyphs.style_for_joy_name("Xbox Series X Controller") == Glyphs.Style.XBOX, "an Xbox pad gets the Xbox labels")
	_check(Glyphs.text("rb", Glyphs.Style.XBOX) == "RB" and Glyphs.text("rb", Glyphs.Style.DECK) == "R1", "RB is R1 on a Deck")
	_check(Glyphs.text("rt", Glyphs.Style.XBOX) == "RT" and Glyphs.text("rt", Glyphs.Style.DECK) == "R2", "RT is R2 on a Deck")

	# --- every button has art, in every pad family -----------------------------------------------------------------------------
	var all_tokens: Array = Glyphs.BUTTON_TOKENS.values() + Glyphs.AXIS_TOKENS.values()
	for style in [Glyphs.Style.XBOX, Glyphs.Style.DECK, Glyphs.Style.PLAYSTATION, Glyphs.Style.SWITCH]:
		var missing: Array[String] = []
		for tok: String in all_tokens:
			var tex: Texture2D = Glyphs.texture(tok, style)
			if tex == null or tex.get_width() < 32:
				missing.append(tok)
		_check(missing.is_empty(), "glyph art exists for every button in style %d (missing: %s)" % [style, ", ".join(missing)])
	_check(Glyphs.texture("rb", Glyphs.Style.XBOX) != Glyphs.texture("rb", Glyphs.Style.DECK), "RB and R1 are different pictures")
	_check(Glyphs.texture("a", Glyphs.Style.XBOX) != Glyphs.texture("a", Glyphs.Style.PLAYSTATION) and Glyphs.texture("a", Glyphs.Style.PLAYSTATION) != Glyphs.texture("a", Glyphs.Style.SWITCH),
			"the south button is a different picture on Xbox, PlayStation and Switch")
	_check(Glyphs.texture("a", Glyphs.Style.DECK) == Glyphs.texture("a", Glyphs.Style.XBOX), "a Deck's face buttons are the Xbox layout")

	# --- pad families from the reported name, and each family's own words ---------------------------------------------------------
	_check(Glyphs.style_for_joy_name("PS5 Controller") == Glyphs.Style.PLAYSTATION and Glyphs.style_for_joy_name("DualSense Wireless Controller") == Glyphs.Style.PLAYSTATION
			and Glyphs.style_for_joy_name("PS4 Controller") == Glyphs.Style.PLAYSTATION, "a DualSense / DualShock is a PlayStation pad")
	_check(Glyphs.style_for_joy_name("Nintendo Switch Pro Controller") == Glyphs.Style.SWITCH and Glyphs.style_for_joy_name("Joy-Con (L)") == Glyphs.Style.SWITCH, "a Switch pad is a Switch pad")
	_check(Glyphs.style_for_joy_name("XInput Gamepad") == Glyphs.Style.XBOX, "an unknown pad is drawn Xbox style")
	_check(Glyphs.text("a", Glyphs.Style.PLAYSTATION) == "Cross" and Glyphs.text("b", Glyphs.Style.PLAYSTATION) == "Circle" and Glyphs.text("rt", Glyphs.Style.PLAYSTATION) == "R2",
			"PlayStation words: south is Cross, east is Circle, RT is R2")
	_check(Glyphs.text("a", Glyphs.Style.SWITCH) == "B" and Glyphs.text("b", Glyphs.Style.SWITCH) == "A" and Glyphs.text("rt", Glyphs.Style.SWITCH) == "ZR",
			"Switch words: south is B, east is A, RT is ZR")

	# --- keyboard / mouse key caps ------------------------------------------------------------------------------------------------
	var key_expect := {"equip": "e", "ui_accept": "enter", "jump": "space", "attack": "mouse_left", "block": "mouse_right", "kick": "f", "AOE": "q", "toggle_walk": "shift",
			"minimap": "tab", "ui_menu": "esc", "restart": "x"}
	for action in key_expect:
		_check(Glyphs.key_name(action) == key_expect[action] and Glyphs.key_texture(action) != null, "key cap for %s is '%s' (got '%s')" % [action, key_expect[action], Glyphs.key_name(action)])

	# --- the glyph library: provenance and integrity ---------------------------------------------------------------------------------
	var lib := JSON.new()
	_check(lib.parse(FileAccess.get_file_as_string("res://assets/ui/glyphs/LIBRARY.json")) == OK, "LIBRARY.json parses")
	var files: Dictionary = lib.data.get("files", {}) if lib.data is Dictionary else {}
	_check(String(lib.data.get("source_archive_sha256", "")).length() == 64 and files.size() >= 100, "LIBRARY.json records the source archive and %d files" % files.size())
	var bad_files: Array[String] = []
	for rel in files:
		if FileAccess.get_sha256("res://assets/ui/glyphs/" + rel) != String(files[rel]["sha256"]):
			bad_files.append(rel)
	_check(bad_files.is_empty(), "every library glyph is byte-identical to the imported source (changed or missing: %s)" % ", ".join(bad_files.slice(0, 5)))
	var notice := FileAccess.get_file_as_string("res://assets/ui/glyphs/NOTICE.md")
	_check(notice.contains("CC0 1.0 Universal") and notice.contains("JulioCacko") and notice.contains("sha256"), "NOTICE.md carries the license evidence and the author")

	# --- the prompt widget --------------------------------------------------------------------------------------------------
	InputManager._set_controller_style(Glyphs.Style.XBOX)
	InputManager._set_scheme(InputManager.Scheme.KEYBOARD)
	var host := Control.new()
	add_child(host)
	var line: HBoxContainer = GlyphPromptScript.new()
	line.setup("Press %g to stop", "ui_accept", "SecondaryLabel", 34.0)
	host.add_child(line)
	await get_tree().process_frame
	var seen: Array = []
	_labels_text(line, seen)
	_check(line.form() == "icon" and line._icon.texture == Glyphs.key_texture("ui_accept") and "Press" in seen and "to stop" in seen and not ("Enter" in seen),
			"keyboard: the prompt shows the Enter key cap (%s)" % [seen])

	InputManager._set_scheme(InputManager.Scheme.GAMEPAD)
	await get_tree().process_frame
	seen.clear()
	_labels_text(line, seen)
	_check(line.form() == "icon", "controller: the prompt shows the button art")
	_check(not ("Enter" in seen) and not ("E" in seen), "controller: no keyboard key name is visible (%s)" % [seen])
	var icon: TextureRect = line._icon
	_check(icon.texture == Glyphs.texture("a", Glyphs.Style.XBOX), "controller: the picture is the A button")

	line.action = "kick"
	InputManager._set_controller_style(Glyphs.Style.DECK)   # signals a style change: the line follows
	await get_tree().process_frame
	_check(icon.texture == Glyphs.texture("rb", Glyphs.Style.DECK), "a Steam Deck pad swaps the picture to its own labels (R1)")
	line.action = "equip"
	InputManager._set_controller_style(Glyphs.Style.XBOX)
	await get_tree().process_frame
	_check(icon.texture == Glyphs.texture("a", Glyphs.Style.XBOX), "back to Xbox labels")

	InputManager._set_scheme(InputManager.Scheme.KEYBOARD)
	await get_tree().process_frame
	_check(line.form() == "icon" and icon.texture == Glyphs.key_texture("equip") and icon.texture != Glyphs.texture("a", Glyphs.Style.XBOX), "switching back to keyboard swaps the button for the E key cap")

	# Touch: a phone has no button to press, so the prompt names the on-screen control (no controller art, no key).
	line.action = "equip"
	line.bracket_keys = true
	InputManager._set_scheme(InputManager.Scheme.TOUCH)
	await get_tree().process_frame
	seen.clear()
	_labels_text(line, seen)
	_check(line.form() == "text" and "USE" in seen and not ("[USE]" in seen) and not ("E" in seen), "touch: the prompt names the on-screen control (%s)" % [seen])
	InputManager._set_scheme(InputManager.Scheme.KEYBOARD)
	host.queue_free()

	# --- the player can fix the pad family in Options > Controls ------------------------------------------------------------------
	InputManager._set_controller_style(Glyphs.Style.XBOX)
	InputManager.set_prompt_override(2)   # PlayStation
	_check(InputManager.controller_style == Glyphs.Style.PLAYSTATION, "override: PlayStation prompts while an Xbox pad is detected")
	InputManager._set_controller_style(Glyphs.Style.SWITCH)   # a different pad is touched: the override still wins
	_check(InputManager.controller_style == Glyphs.Style.PLAYSTATION, "override: a pad change does not undo it")
	InputManager.set_prompt_override(0)
	_check(InputManager.controller_style == Glyphs.Style.SWITCH, "override: Automatic follows the pad in use again (%d)" % InputManager.controller_style)
	_check(int(SettingsManager.get_setting(InputManager.OVERRIDE_KEY, -1.0)) == 0, "override: the choice is saved with the settings")
	InputManager._set_controller_style(Glyphs.Style.XBOX)

	# --- glyph() text follows the InputMap and the pad in use ---------------------------------------------------------------
	InputManager._set_scheme(InputManager.Scheme.GAMEPAD)
	InputManager._set_controller_style(Glyphs.Style.DECK)
	_check(InputManager.glyph("kick") == "R1" and InputManager.glyph("attack") == "R2" and InputManager.glyph("ui_menu") == "Menu", "text glyphs use the Deck labels (%s %s %s)" % [InputManager.glyph("kick"), InputManager.glyph("attack"), InputManager.glyph("ui_menu")])

	# --- Options: a controller player is shown controller buttons only in the Quick Reference ---------------------------------
	InputManager._set_controller_style(Glyphs.Style.XBOX)
	for scheme in [InputManager.Scheme.GAMEPAD, InputManager.Scheme.KEYBOARD]:
		InputManager._set_scheme(scheme)
		var opts := (load("res://scenes/OptionsScreen.tscn") as PackedScene).instantiate()
		add_child(opts)
		for i in 8:
			await get_tree().process_frame
		var texts: Array = []
		_labels_text(opts, texts, false)   # the Controls tab may not be the one showing
		if scheme == InputManager.Scheme.GAMEPAD:
			# (the Remap Bindings editor below the reference keeps its keyboard column: it is where a key is rebound)
			_check(not ("W A S D" in texts) and not ("LMB" in texts) and texts.count("Keyboard / Mouse") == 1, "controller: Options' Quick Reference has no keyboard / mouse column (%d headers)" % texts.count("Keyboard / Mouse"))
			_check("Right Stick" in texts and "RT" in texts and "RB" in texts and "Left Stick" in texts, "controller: Options' Quick Reference lists the real controller buttons")
		else:
			_check("W A S D" in texts and "LMB" in texts and texts.count("Keyboard / Mouse") == 2, "keyboard: Options' Quick Reference lists keys and buttons")
		opts.queue_free()
		await get_tree().process_frame

	# --- bindings are named in the pad's own words, not engine indices -----------------------------------------------------------
	var jb := InputEventJoypadButton.new()
	jb.button_index = JOY_BUTTON_A
	_check(Glyphs.joy_event_text(jb, Glyphs.Style.XBOX) == "A", "binding label: button 0 is A")
	jb.button_index = JOY_BUTTON_RIGHT_SHOULDER
	_check(Glyphs.joy_event_text(jb, Glyphs.Style.XBOX) == "RB" and Glyphs.joy_event_text(jb, Glyphs.Style.DECK) == "R1", "binding label: right shoulder is RB / R1")
	var jm := InputEventJoypadMotion.new()
	jm.axis = JOY_AXIS_LEFT_Y
	jm.axis_value = -1.0
	_check(Glyphs.joy_event_text(jm, Glyphs.Style.XBOX) == "Left Stick Up", "binding label: left stick up (%s)" % Glyphs.joy_event_text(jm, Glyphs.Style.XBOX))
	jm.axis = JOY_AXIS_RIGHT_X
	jm.axis_value = 1.0
	_check(Glyphs.joy_event_text(jm, Glyphs.Style.XBOX) == "Right Stick Right", "binding label: right stick right")
	jm.axis = JOY_AXIS_TRIGGER_RIGHT
	_check(Glyphs.joy_event_text(jm, Glyphs.Style.DECK) == "R2", "binding label: right trigger is R2 on a Deck")

	# --- Options > Controls > Controller Prompts ---------------------------------------------------------------------------------------
	var opts3 := (load("res://scenes/OptionsScreen.tscn") as PackedScene).instantiate()
	add_child(opts3)
	for i in 8:
		await get_tree().process_frame
	var pr_row: OptionButton = opts3.find_child("ControllerPrompts", true, false) as OptionButton
	_check(pr_row != null and pr_row.item_count == 5 and pr_row.selected == 0, "Options > Controls has the Controller Prompts row, Automatic by default")
	if pr_row != null:
		pr_row.select(3)
		pr_row.item_selected.emit(3)
		_check(InputManager.prompt_override == 3 and InputManager.controller_style == Glyphs.Style.SWITCH, "choosing Nintendo Switch in Options applies at once")
		InputManager.set_prompt_override(0)
	opts3.queue_free()

	# --- a pending remap cancels itself (a controller player has no Escape) --------------------------------------------------------
	InputManager._set_scheme(InputManager.Scheme.GAMEPAD)
	var opts2 := (load("res://scenes/OptionsScreen.tscn") as PackedScene).instantiate()
	add_child(opts2)
	for i in 8:
		await get_tree().process_frame
	opts2.listen_timeout = 0.3
	var jump_before: String = opts2._get_gp_label("jump")
	_check(jump_before == "B", "Options shows the jump binding as B (%s)" % jump_before)
	var tbtn := Button.new()
	opts2.add_child(tbtn)
	opts2._start_listen("jump", "gamepad", tbtn)
	_check(opts2._listening_action == "jump" and tbtn.text == "Press a button...", "a remap waits for a button")
	await get_tree().create_timer(0.8).timeout
	_check(opts2._listening_action == "" and tbtn.text == "B", "an unanswered remap cancels itself and leaves the binding alone (%s)" % tbtn.text)
	_check(Glyphs.token_for_action("jump") == "b", "the binding was not changed")
	opts2.queue_free()
	InputManager._set_scheme(InputManager.Scheme.KEYBOARD)

	# --- a controller player is not told to "click" ---------------------------------------------------------------------------------
	const MenuKitScript := preload("res://scripts/ui/menu_kit.gd")
	InputManager._set_scheme(InputManager.Scheme.KEYBOARD)
	_check(MenuKitScript._select_verb() == "click", "keyboard / mouse: 'click' (%s)" % MenuKitScript._select_verb())
	InputManager._set_controller_style(Glyphs.Style.DECK)
	InputManager._set_scheme(InputManager.Scheme.GAMEPAD)
	_check(MenuKitScript._select_verb() == "press A", "controller: 'press A' (%s)" % MenuKitScript._select_verb())
	InputManager._set_scheme(InputManager.Scheme.KEYBOARD)

	print("test_controller_glyphs: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
