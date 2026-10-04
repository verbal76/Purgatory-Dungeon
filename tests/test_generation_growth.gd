extends Node
## The generator must never leave the player a tiny dungeon. It is random, and a rare run closed
## itself in after a handful of rooms (5 rooms, no enemy spawns). A layout far short of the room
## target is now discarded and generated again; the last attempt is kept whatever its size.
## One case per process (GROWTH_CASE = normal | recover | exhaust).

const MAIN_SCENE := "res://scenes/Purgatory_Dungeon_main_game_file.tscn"
const GEN_SCENE := "res://scenes/dungeon_generation_function.tscn"

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _ready() -> void:
	var which := OS.get_environment("GROWTH_CASE") if OS.get_environment("GROWTH_CASE") != "" else "normal"
	# Dead-end weight / seed per case. "recover": at weight 15 this seed's first layout closes in
	# early and the second reaches the target. "exhaust": dead ends dominate so no attempt can.
	var weight := -1
	var seed_value := 5
	match which:
		"recover":
			weight = 15
			seed_value = 6
		"exhaust":
			weight = 400
			seed_value = 5
	var cfg: Node = (load(MAIN_SCENE) as PackedScene).instantiate()   # only for its exported settings
	var root := Node3D.new()
	add_child(root)
	var gen: Node = (load(GEN_SCENE) as PackedScene).instantiate()
	root.add_child(gen)
	gen.target_piece_count = cfg.target_piece_count
	gen.total_generation_attempts = cfg.total_generation_attempts
	gen.attempts_per_connection = cfg.attempts_per_connection
	gen.weight_4_connection = cfg.weight_4_connection
	gen.weight_3_connection = cfg.weight_3_connection
	gen.weight_2_connection = cfg.weight_2_connection
	gen.weight_1_connection = cfg.weight_1_connection if weight < 0 else weight
	gen.overlap_shrink = cfg.overlap_shrink
	gen.connection_nudge = cfg.connection_nudge
	gen.exclude_keywords = cfg.exclude_keywords.duplicate()
	gen.exploration_padding = cfg.exploration_padding
	gen.enemy_spawn_chance = cfg.enemy_spawn_chance
	gen.setup_generation(root, cfg.starter_module, cfg.branch_modules, cfg.room_connector_module, cfg.end_cap_module)
	seed(seed_value)
	var result: Dictionary = gen.generate_dungeon()
	print("growth case %s (seed %d, dead-end weight %d): %d rooms of %d target, %d modules, %d layout attempts" % [which, seed_value, gen.weight_1_connection, gen.counted_piece_total, gen.target_piece_count, gen.placed_modules.size(), gen.layout_attempts])
	var needed := int(ceil(float(gen.target_piece_count) * gen.minimum_fill_fraction))
	_check(bool(result.get("success", false)), "generation reports success")
	_check(result.get("starter") != null and gen.placed_modules.has(result.get("starter")), "the returned starter belongs to the kept layout")
	match which:
		"normal":
			_check(gen.layout_attempts == 1, "a normal layout is generated once (%d attempts)" % gen.layout_attempts)
			_check(gen.counted_piece_total >= gen.target_piece_count, "the room target is met (%d)" % gen.counted_piece_total)
		"recover":
			_check(gen.layout_attempts >= 2, "an under-filled first layout was discarded and regenerated (%d attempts)" % gen.layout_attempts)
			_check(gen.counted_piece_total >= needed, "the regenerated dungeon is full-size (%d rooms, needed %d)" % [gen.counted_piece_total, needed])
			_check(gen.registered_typed_spawns.size() > 0, "enemy spawn points exist")
			_check(gen.open_connections.size() == 0, "every doorway is closed (%d open)" % gen.open_connections.size())
		"exhaust":
			_check(gen.layout_attempts == gen.max_layout_attempts, "it gives up after max_layout_attempts (%d)" % gen.layout_attempts)
			_check(gen.placed_modules.size() > 0, "the last layout is kept even though it is small")
	# Discarded layouts must not linger in the scene (they would overlap the kept one).
	await get_tree().process_frame
	await get_tree().process_frame
	var stray := 0
	for c in root.get_children():
		if c != gen and not gen.placed_modules.has(c):
			stray += 1
	_check(stray == 0, "no module of a discarded layout is left in the scene (%d stray nodes)" % stray)
	cfg.free()
	print("test_generation_growth (%s): %d checks, %d failures" % [which, _checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
