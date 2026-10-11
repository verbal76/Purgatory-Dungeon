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

	# --- every button has art, in both label sets ---------------------------------------------------------------------------
	var all_tokens: Array = Glyphs.BUTTON_TOKENS.values() + Glyphs.AXIS_TOKENS.values()
	for style in [Glyphs.Style.XBOX, Glyphs.Style.DECK]:
		var missing: Array[String] = []
		for tok: String in all_tokens:
			var tex: Texture2D = Glyphs.texture(tok, style)
			if tex == null or tex.get_width() < 32:
				missing.append(tok)
		_check(missing.is_empty(), "glyph art exists for every button in style %d (missing: %s)" % [style, ", ".join(missing)])
	_check(Glyphs.texture("rb", Glyphs.Style.XBOX) != Glyphs.texture("rb", Glyphs.Style.DECK), "RB and R1 are different pictures")

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
	_check(line.form() == "text" and "Enter" in seen and "Press" in seen and "to stop" in seen, "keyboard: the prompt names the key (%s)" % [seen])

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
	_check(line.form() == "text", "switching back to keyboard swaps the picture for the key name")
	host.queue_free()

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

	print("test_controller_glyphs: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
