extends Node
## The Repulse button's cooldown presentation (dark radial sweep + remaining whole seconds in the centre) against the REAL
## player's authoritative `_repulse_cooldown`, for the real Barbarian and Mage (REPULSE_CLASS), and the guarantee that Kick has
## no cooldown presentation at all. Presentation only: nothing here (or in the layer) writes the cooldown.
## Needs PURGATORY_FORCE_TOUCH=1 (run_tests.sh sets it).

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
		await get_tree().process_frame


func _ready() -> void:
	if OS.get_environment("PURGATORY_FORCE_TOUCH") != "1":
		printerr("FAIL: run with PURGATORY_FORCE_TOUCH=1")
		get_tree().quit(2)
		return
	var cls: String = OS.get_environment("REPULSE_CLASS")
	if cls == "":
		cls = "barbarian"
	GlobalRunData.character_class = cls
	var main: Node = (load("res://scenes/Purgatory_Dungeon_main_game_file.tscn") as PackedScene).instantiate()
	add_child(main)
	await _frames(150)
	var tcs := get_tree().get_nodes_in_group(TouchControls.GROUP)
	var tc: TouchControls = tcs[0]
	var player: Node = get_tree().get_first_node_in_group("player")
	var waited := 0
	while (get_tree().paused or not player.is_on_floor()) and waited < 3000:
		await get_tree().physics_frame
		waited += 1
	tc.view_override = Vector2(1602, 720)
	tc.layout_override_insets = Vector4.ZERO
	tc.dpi_override = 480.0
	tc.screen_override = Vector2(2992, 1344)
	tc._relayout()
	await _frames(40)   # the layer finds the player
	var rep: TouchButton = tc.buttons["jump"]
	var kick: TouchButton = tc.buttons["kick"]
	var total: float = BruteCharacter.REPULSE_COOLDOWN
	var c0: Vector2 = rep.center
	var r0: float = rep.radius
	var kc0: Vector2 = kick.center
	var kr0: float = kick.radius
	_check(is_equal_approx(total, 3.0), "[%s] the Repulse cooldown itself is unchanged (%.1f s)" % [cls, total])
	_check(rep.icon_kind == "repulse" and kick.icon_kind == "kick", "[%s] the buttons use the Repulse and Kick icons" % cls)

	# ready
	_check(float(player.get("_repulse_cooldown")) <= 0.0 and rep.cooldown == 0.0 and rep.cooldown_text == "" and rep.art_state() == "default", "[%s] ready: no sweep, no number, normal icon" % cls)

	# use it for real: the authoritative cooldown starts and the button follows it
	Input.action_press("jump")
	await _frames(2)
	Input.action_release("jump")
	await _frames(2)
	var cd: float = float(player.get("_repulse_cooldown"))
	_check(cd > 2.0 and cd <= total, "[%s] a real use starts the real cooldown (%.2f s)" % [cls, cd])
	_check(rep.cooldown_text == str(ceili(cd)) and absf(rep.cooldown - cd / total) < 0.05, "[%s] immediately after use: sweep %.2f and number '%s' agree with the cooldown %.2f" % [cls, rep.cooldown, rep.cooldown_text, cd])
	_check(rep.art_state() == "default", "[%s] the coloured icon stays under the sweep (not swapped for the grey cooldown art)" % cls)

	# it follows the real countdown over real time
	await get_tree().create_timer(1.2).timeout
	await _frames(2)
	cd = float(player.get("_repulse_cooldown"))
	_check(cd > 0.0 and cd < total - 1.0, "[%s] real time has run the cooldown down (%.2f s)" % [cls, cd])
	_check(rep.cooldown_text == str(ceili(cd)) and absf(rep.cooldown - cd / total) < 0.05, "[%s] about a second in: sweep %.2f and number '%s' still agree with %.2f" % [cls, rep.cooldown, rep.cooldown_text, cd])

	# representative values, driven through the authoritative variable the HUD only reads
	# (values sit away from whole seconds: a 30 Hz physics tick may land between the HUD frame and this read)
	var cases: Array = [[2.9, "3"], [2.5, "3"], [1.9, "2"], [1.5, "2"], [0.9, "1"], [0.5, "1"], [0.3, "1"]]
	for cs in cases:
		player.set("_repulse_cooldown", float(cs[0]))
		await get_tree().process_frame
		await get_tree().process_frame
		var live: float = float(player.get("_repulse_cooldown"))
		_check(rep.cooldown_text == str(ceili(live)) and absf(rep.cooldown - live / total) < 0.04, "[%s] cooldown %.2f s: number '%s', sweep %.2f" % [cls, live, rep.cooldown_text, rep.cooldown])
	# ready again
	player.set("_repulse_cooldown", 0.0)
	await _frames(2)
	_check(rep.cooldown == 0.0 and rep.cooldown_text == "" and rep.art_state() == "default", "[%s] ready again: the sweep and the number are gone and the icon is normal" % cls)
	# a repeated use resets the visual
	await _frames(6)
	Input.action_press("jump")
	await _frames(2)
	Input.action_release("jump")
	await _frames(2)
	cd = float(player.get("_repulse_cooldown"))
	_check(cd > 2.0 and rep.cooldown_text == "3" and rep.cooldown > 0.85, "[%s] a second use restarts the visual at the full cooldown (number '%s', sweep %.2f)" % [cls, rep.cooldown_text, rep.cooldown])
	# the sweep and number follow a hand-set refill exactly (no stale value kept)
	player.set("_repulse_cooldown", 0.0)
	await _frames(2)
	_check(rep.cooldown_text == "" and rep.cooldown == 0.0, "[%s] and clears cleanly once more" % cls)

	# touch target and button geometry never change with the cooldown; Kick never gets a cooldown presentation
	player.set("_repulse_cooldown", 2.0)
	await _frames(2)
	_check(rep.center == c0 and is_equal_approx(rep.radius, r0) and rep.hit(c0) and rep.hit(c0 + Vector2(r0 * 1.2, 0)) and not rep.hit(c0 + Vector2(r0 * 1.5, 0)), "[%s] the Repulse touch target is unchanged while cooling down" % cls)
	Input.action_press("kick")
	await _frames(3)
	Input.action_release("kick")
	await _frames(3)
	_check(kick.cooldown == 0.0 and kick.cooldown_text == "" and kick.art_state() != "cooldown" and kick.center == kc0 and is_equal_approx(kick.radius, kr0), "[%s] Kick has no cooldown sweep, number or state, and its touch target is unchanged" % cls)
	player.set("_repulse_cooldown", 0.0)
	await _frames(2)
	var src: String = FileAccess.get_file_as_string("res://scripts/touch/touch_controls.gd")
	_check(not src.contains("_repulse_cooldown =") and not src.contains("_repulse_cooldown -=") and not src.contains("set(\"_repulse_cooldown\""), "the touch layer only reads the Repulse cooldown, it never writes it")
	_check(src.find("buttons.get(\"jump\")") > 0 and src.find("buttons.get(\"kick\")") < 0, "only the jump (Repulse) button is wired to a cooldown readout; Kick is not")

	print("test_repulse_hud (%s): %d checks, %d failures" % [cls, _checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
