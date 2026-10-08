extends Node
## Not a pass/fail test. Boots the main game scene and prints headless CPU-side
## numbers (script/physics time per frame, node/object/memory counts, enemy count).
## Run: PURGATORY_SAVE_ROOT=/tmp/x godot --headless --path . res://tests/perf_probe.tscn

func _ready() -> void:
	GlobalRunData.character_class = "barbarian"
	var t0 := Time.get_ticks_msec()
	var main: Node = (load("res://scenes/Purgatory_Dungeon_main_game_file.tscn") as PackedScene).instantiate()
	add_child(main)
	var gen = main.get_node("DungeonGenerationFunction")
	while gen.placed_modules.size() == 0:
		await get_tree().physics_frame
	print("PERF boot->generated: %d ms, modules=%d" % [Time.get_ticks_msec() - t0, gen.placed_modules.size()])
	for i in 4:
		await get_tree().physics_frame
	for i in 450:   # warm-up: staggered prop/chest/enemy spawning settles
		await get_tree().physics_frame
	var proc_list: Array[float] = []
	var phys_list: Array[float] = []
	var samples := 0
	var proc := 0.0
	var phys := 0.0
	var worst_phys := 0.0
	var worst_proc := 0.0
	for f in 1200:
		await get_tree().physics_frame
		if f % 10 == 0:
			var p: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
			var q: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			proc += p
			phys += q
			worst_proc = maxf(worst_proc, p)
			worst_phys = maxf(worst_phys, q)
			samples += 1
			proc_list.append(p)
			phys_list.append(q)
	print("PERF over %d samples: process avg %.3f ms (worst %.3f), physics_process avg %.3f ms (worst %.3f)" % [samples, proc / samples, worst_proc, phys / samples, worst_phys])
	proc_list.sort()
	phys_list.sort()
	print("PERF steady-state median: process %.3f ms, physics_process %.3f ms (p95 %.3f / %.3f)" % [proc_list[samples / 2], phys_list[samples / 2], proc_list[int(samples * 0.95)], phys_list[int(samples * 0.95)]])
	var enemies := 0
	for e in get_tree().get_nodes_in_group("enemy"):
		if e.visible:
			enemies += 1
	print("PERF live enemies=%d nodes=%d objects=%d static_mem=%.1f MB orphan_nodes=%d" % [enemies, get_tree().get_node_count(), Performance.get_monitor(Performance.OBJECT_COUNT), Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)])
	get_tree().quit(0)
