extends Node
## Data-driven audit of every buff and globe curse against the real player (BUFF_CLASS =
## barbarian | mage): the stats exist, each effect changes the player by the amount its card
## says, removing it restores the player exactly, and the pick pool only offers usable buffs.

const BRUTE_SCENE := "res://characters/brute/scenes/brute_player.tscn"
const MAGE_SCENE := "res://characters/Lutsch Mage/scenes/Mage player.tscn"
# Buffs/curses whose stat no player implements yet. They are held out of the pick pool until the
# owner decides to build or remove them (jump has no jump mechanic; torches only dim on hardcore).
const KNOWN_UNIMPLEMENTED: Array[String] = ["jump_master", "torchbearer", "dimming_legend", "flickering_torment", "eternal_night"]
# Curses that adjust an opt-in effect (sparks, on-kill) and so only bite while the matching buff is held.
const OPT_IN_CURSES: Array[String] = ["dimmed_sparks", "blind_rage", "shattered_spark", "weakened_flame", "blood_thirst"]

var _fails: int = 0
var _checks: int = 0


class FakeProp extends Node3D:
	var kicks: int = 0
	func apply_kick(_dir: Vector3, _force: float) -> void:
		kicks += 1


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _entries(path: String) -> Array:
	var out: Array = []
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	for e in parsed:
		if e is Dictionary and e.has("id"):
			out.append(e)
	return out


func _effects(entry: Dictionary) -> Array:
	return entry.get("effects", [entry]) if entry.has("effects") else [entry]


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	var cls := OS.get_environment("BUFF_CLASS")
	if cls == "":
		cls = "barbarian"
	GlobalRunData.character_class = cls
	var main: Node = (load("res://scenes/Purgatory_Dungeon_main_game_file.tscn") as PackedScene).instantiate()
	add_child(main)
	await _frames(120)
	var player: Node = main.get_node("Player") if cls == "barbarian" else get_tree().get_first_node_in_group("player")
	_check(player != null and player.is_in_group("player"), "found the %s player" % cls)
	if player == null:
		get_tree().quit(1)
		return

	# The other class, only to know which stats exist anywhere.
	var other_scene: PackedScene = load(MAGE_SCENE if cls == "barbarian" else BRUTE_SCENE)
	var other: Node = other_scene.instantiate()

	var buffs: Array = _entries("res://data/buffs.json")
	var curses: Array = _entries("res://data/globe_effects.json")
	_check(buffs.size() >= 50, "loaded the buff data (%d entries)" % buffs.size())

	# --- Every stat exists on some class (or the buff is a listed unimplemented one) -------------
	for entry in buffs + curses:
		var id := str(entry.get("id"))
		var known_dead := id in KNOWN_UNIMPLEMENTED
		var on_some_class := true
		for st in BuffManager.buff_stat_names(entry):
			if not (st in player) and not (st in other):
				on_some_class = false
		_check(on_some_class != known_dead, "%s: %s" % [id, "listed as unimplemented but all its stats exist" if known_dead else "has a stat that no player implements (add it, remove the buff, or list it in KNOWN_UNIMPLEMENTED)"])
	other.free()

	# --- Apply / verify magnitude / remove, for every buff the player can use -------------------
	var applied := 0
	for entry in buffs + curses:
		if not BuffManager.buff_is_applicable(entry, player):
			continue
		var id2 := str(entry.get("id"))
		var before := {}
		for st in BuffManager.buff_stat_names(entry):
			before[st] = float(player.get(st))
		BuffManager._modify_stats(entry, true)
		for effect in _effects(entry):
			if str(effect.get("effect_type", "")) not in ["stat_modifier", "on_kill", "max_health"]:
				continue
			var st: String = str(effect.get("stat", ""))
			var value := float(effect.get("value", 0.0))
			var base: float = float(BuffManager._stat_base.get(st, before[st]))
			var expect: float = value * base if st in BuffManager.PERCENT_OF_BASE_STATS else value
			# Tradeoffs on the same stat are folded into `before`, so only check isolated deltas.
			var same_stat_tradeoff: bool = effect.get("tradeoff") is Dictionary and str(effect["tradeoff"].get("stat", "")) == st
			if not same_stat_tradeoff and st != "max_health":
				var got: float = float(player.get(st)) - float(before[st])
				var total_expect: float = expect
				# Several effects of one entry may touch the same stat.
				for e2 in _effects(entry):
					if e2 != effect and str(e2.get("stat", "")) == st:
						total_expect += float(e2.get("value", 0.0)) * (base if st in BuffManager.PERCENT_OF_BASE_STATS else 1.0)
				_check(absf(got - total_expect) < 0.001, "%s: %s changes by %.3f (card says %.3f)" % [id2, st, got, total_expect])
			if st in BuffManager.PERCENT_OF_BASE_STATS:
				_check(absf(base) > 0.0001, "%s: percent stat %s has a non-zero base (%.3f), so the buff can do something" % [id2, st, base])
		BuffManager._modify_stats(entry, false)
		for st in before.keys():
			if st == "max_health":
				continue
			_check(absf(float(player.get(st)) - float(before[st])) < 0.0001, "%s: removing it restores %s exactly" % [id2, st])
		applied += 1
	_check(applied >= 35, "exercised %d buffs and curses on the %s" % [applied, cls])

	# --- Card text and data agree for every percent stat -----------------------------------------
	var pct := RegEx.new()
	pct.compile("(\\d+(?:\\.\\d+)?)%")
	for entry in buffs + curses:
		var texts: Array = []   # [stat, value, text]
		if not entry.has("effects"):
			texts.append([str(entry.get("stat", "")), float(entry.get("value", 0.0)), str(entry.get("description", ""))])
			var td = entry.get("tradeoff")
			if td is Dictionary:
				texts.append([str(td.get("stat", "")), float(td.get("value", 0.0)), str(td.get("description", ""))])
		for t in texts:
			if t[0] in BuffManager.PERCENT_OF_BASE_STATS:
				var m := pct.search(t[2])
				if m != null:
					_check(absf(absf(t[1]) * 100.0 - float(m.get_string(1))) < 0.5, "%s: card says %s%% but %s is %.2f" % [entry["id"], m.get_string(1), t[0], t[1]])

	# --- Specific behaviours ---------------------------------------------------------------------
	var blood: Dictionary = {}
	for e in buffs:
		if e["id"] == "blood_rush":
			blood = e
	var ms0: float = float(player.get("move_speed"))
	BuffManager._modify_stats(blood, true)
	_check(absf(float(player.get("move_speed")) / ms0 - 1.25) < 0.001, "Blood Rush is +25%% movement speed (%.2f -> %.2f)" % [ms0, float(player.get("move_speed"))])
	BuffManager._modify_stats(blood, false)

	# Adrenaline Spike: only below 30% health.
	var adr: Dictionary = {}
	var shadow: Dictionary = {}
	for e in buffs:
		if e["id"] == "adrenaline_spike":
			adr = e
		if e["id"] == "shadow_dancer":
			shadow = e
	BuffManager._modify_stats(adr, true)
	player.set("_current_health", float(player.get("max_health")))
	_check(player.get_low_health_attack_bonus() == 0.0, "Adrenaline Spike gives nothing at full health")
	player.set("_current_health", float(player.get("max_health")) * 0.2)
	_check(is_equal_approx(player.get_low_health_attack_bonus(), 12.0), "Adrenaline Spike gives +12 attack damage below 30%% health")
	BuffManager._modify_stats(adr, false)
	player.set("_current_health", float(player.get("max_health")))

	# Shadow Dancer: haste only after a kill, for 5 s.
	BuffManager._modify_stats(shadow, true)
	_check(is_equal_approx(player.kill_haste_multiplier(), 1.0), "Shadow Dancer gives no haste before a kill")
	player._on_kill_haste_trigger()
	_check(is_equal_approx(player.kill_haste_multiplier(), 1.18), "Shadow Dancer: +18%% movement speed after a kill (%.2f)" % player.kill_haste_multiplier())
	player._tick_kill_haste(4.9)
	_check(player.kill_haste_multiplier() > 1.0, "Shadow Dancer haste lasts about 5 s")
	player._tick_kill_haste(0.2)
	_check(is_equal_approx(player.kill_haste_multiplier(), 1.0), "Shadow Dancer haste ends after 5 s")
	BuffManager._modify_stats(shadow, false)

	# Negative damage reduction (Pain Mirror, Void Embrace) means MORE damage taken.
	var hp_full: float = float(player.get("max_health"))
	player.set("_current_health", hp_full)
	player.set("damage_reduction", -0.25)
	player.take_damage(10.0)
	_check(absf((hp_full - float(player.get("_current_health"))) - 12.5) < 0.01, "a -25%% damage-reduction curse makes a 10 hit deal 12.5 (took %.2f)" % (hp_full - float(player.get("_current_health"))))
	player.set("damage_reduction", 0.0)
	player.set("_current_health", hp_full)

	# Both classes carry the enemy-strength modifiers (Horde Caller / Slow the Horde / Enemy Weaken).
	_check("enemy_speed_modifier" in player and "enemy_damage_modifier" in player, "the %s carries enemy_speed_modifier and enemy_damage_modifier" % cls)

	# --- Pick pool only offers usable buffs -------------------------------------------------------
	BuffManager._build_slot_pool()
	var offered_ids := {}
	for e in BuffManager._slot_pool:
		offered_ids[e["id"]] = true
		_check(BuffManager.buff_is_applicable(e, player), "pool: %s is usable by the %s" % [e["id"], cls])
	_check(offered_ids.size() >= 25, "pool offers a healthy variety (%d distinct buffs)" % offered_ids.size())
	for id3 in KNOWN_UNIMPLEMENTED:
		_check(not offered_ids.has(id3), "pool never offers the unimplemented %s" % id3)
	if cls == "mage":
		_check(not offered_ids.has("aoe_radius_boost") and not offered_ids.has("mighty_kick"), "the Mage is not offered Barbarian-only buffs")
	else:
		_check(not offered_ids.has("lightning_caller") and not offered_ids.has("spell_surge"), "the Barbarian is not offered Mage-only buffs")
	BuffManager.reset()

	# --- Trap statuses: tracked timers, tunable acid -----------------------------------------------
	player.apply_status("drunk", 0)
	player.apply_status("reversed_controls", 0)
	_check(is_equal_approx(player._status_drunk_timer, 30.0) and is_equal_approx(player._status_controls_timer, 30.0), "the %s tracks drunk / reversed-controls timers (30 s)" % cls)
	await _frames(30)   # about one second of physics ticks
	var drunk_left: float = player._status_drunk_timer
	_check(drunk_left < 29.5 and drunk_left > 28.0, "the drunk timer counts down with the game (%.2f s left after ~1 s)" % drunk_left)
	player.apply_status("drunk", 0)
	_check(is_equal_approx(player._status_drunk_timer, 30.0), "re-applying drunk refreshes it to the full 30 s")
	player._status_drunk = false
	player._status_reversed_controls = false
	player.apply_status("acid_pool", 8, 2.5)
	_check(is_equal_approx(player._status_acid_dps, 2.5) and is_equal_approx(player._status_acid_timer, 8.0), "acid uses the trap's damage per second and duration (%.1f dps, %.1f s)" % [player._status_acid_dps, player._status_acid_timer])
	player.apply_status("acid_pool", 0)
	_check(is_equal_approx(player._status_acid_dps, 1.0) and is_equal_approx(player._status_acid_timer, 15.0), "acid defaults to 1.0 dps for 15 s")
	player._status_acid = false

	# --- Slide knockback kicks each prop once per slide (Barbarian) ------------------------------------
	if cls == "barbarian":
		var props: Array = []
		for i in 3:
			var prop := FakeProp.new()
			prop.add_to_group("kickable_prop")
			add_child(prop)
			prop.global_position = player.global_position + Vector3(0.5 * i, 0, 0.5)
			props.append(prop)
		player._slide_kicked_props.clear()
		for tick in 6:
			player._check_slide_knockback()
		var kicks: Array = props.map(func(p): return p.kicks)
		_check(kicks == [1, 1, 1], "every prop in range is kicked exactly once across a slide's ticks %s" % [kicks])
		player._slide_kicked_props.clear()
		player._check_slide_knockback()
		_check(props.all(func(p): return p.kicks == 2), "the next slide kicks them again")
		for prop in props:
			prop.queue_free()

	print("test_buffs (%s): %d checks, %d failures" % [cls, _checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
