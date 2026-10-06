extends Node
## Starting a run no longer freezes the screen while the dungeon scene loads: DungeonEntry.start() loads it on
## worker threads under the loading screen and switches when it is ready. Proves: the overlay appears at once and
## the main loop keeps running during the load (no multi-hundred-ms frame), the dungeon scene is entered, the
## overlay removes itself once the dungeon's own loading screen is up, and a second start() is ignored.

const DungeonEntry = preload("res://scripts/dungeon_entry.gd")
const MAIN_SCENE := "res://scenes/Purgatory_Dungeon_main_game_file.tscn"

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _ready() -> void:
	# The scene change frees current_scene: park a dummy as the current scene and live under the root.
	var dummy := Node.new()
	dummy.name = "DummyScene"
	get_tree().root.add_child.call_deferred(dummy)
	_start.call_deferred(dummy)


func _start(dummy: Node) -> void:
	get_tree().current_scene = dummy
	reparent(get_tree().root)
	_run()


func _run() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	GlobalRunData.character_class = "barbarian"
	GlobalRunData.seed_hash = 7
	var tree := get_tree()
	DungeonEntry.start(tree, MAIN_SCENE)
	DungeonEntry.start(tree, MAIN_SCENE)   # ignored: one entry at a time
	var overlays := 0
	for c in tree.root.get_children():
		if c.name == "DungeonEntryOverlay":
			overlays += 1
	_check(overlays == 1, "exactly one entry overlay while loading (%d)" % overlays)

	var last := Time.get_ticks_usec()
	var worst := 0.0
	var frames := 0
	var entered := false
	var t_start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t_start < 60000:
		await tree.process_frame
		var now := Time.get_ticks_usec()
		var dt := float(now - last) / 1000.0
		last = now
		if tree.get_nodes_in_group("dungeon_generator").is_empty():
			frames += 1
			worst = maxf(worst, dt)
		else:
			entered = true
			break
	_check(entered, "the dungeon scene is entered (%d frames of loading, %.1f s)" % [frames, float(Time.get_ticks_msec() - t_start) / 1000.0])
	_check(frames > 3, "the main loop kept running while the scene loaded (%d frames)" % frames)
	# The dungeon's own _ready runs synchronously for ~60 ms in the frame that enters it: that frame is excluded
	# above; every frame before it must be short (the old blocking change_scene_to_file froze for seconds).
	_check(worst < 400.0, "no long frame while the scene loads (worst %.1f ms)" % worst)

	var gone := false
	for i in 30:
		await tree.process_frame
		if not tree.root.has_node("DungeonEntryOverlay"):
			gone = true
			break
	_check(gone, "the overlay removes itself once the dungeon's loading screen is up")
	var main: Node = tree.get_first_node_in_group("dungeon_generator")
	var loading: Node = null
	if main != null:
		var p := main.get_node_or_null("Player")
		if p != null:
			for c in p.get_children():
				if c is CanvasLayer and c.get_script() != null and String(c.get_script().resource_path).ends_with("loading_screen.gd"):
					loading = c
	_check(loading != null, "the dungeon's own loading screen is present after the hand-over from the overlay")

	print("test_dungeon_entry: %d checks, %d failures" % [_checks, _fails])
	tree.quit(1 if _fails > 0 else 0)
