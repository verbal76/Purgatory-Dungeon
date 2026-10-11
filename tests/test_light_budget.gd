extends Node
## Protects the render-cost wins of the torch light budget (scripts/torch_light_budget.gd), the
## batched torch flames and the Hardcore dimming hand-over. Deterministic, headless, no renderer.
##
## Part 1 (synthetic grid of 300+ torches, fast): the active-light cap, nearest-first selection,
##   hysteresis (no flip-flop on a jittering camera), fade (no popping), energy ownership
##   (global energy, flicker factor, death), the shared budget with dynamic lights, and no
##   allocation growth across thousands of updates.
## Part 2 (TorchDimmingManager + budget): dimming reaches the right energy, flicker dips and
##   recovers, dead torches go out, all through the budget.
## Part 3 (one real generated dungeon, one seed per process like the other generation tests):
##   the cap holds while the camera visits many places, a flame exists for EVERY torch (batched,
##   far fewer nodes than torches), no per-torch FlameMesh nodes, light-per-mesh and node ceilings.
## LIGHT_TEST_SEED=n overrides the part-3 seed.

const GEN_SCENE := "res://scenes/dungeon_generation_function.tscn"
const MAIN_SCENE := "res://scenes/Purgatory_Dungeon_main_game_file.tscn"
const BUDGET_SCRIPT := "res://scripts/torch_light_budget.gd"
const DIMMING_SCRIPT := "res://scripts/torch_dimming_manager.gd"
const TUNING_SCRIPT := "res://scripts/dungeon_render_tuning.gd"

# Documented ceilings for the real dungeon (target 110 rooms, ~310-340 modules, ~740 torches).
# Measured on seeds 1/7/42: see the printed metrics. The old per-torch FlameMesh design had
# ~740 flame MeshInstance3D nodes (4224 triangles each); now they are <= 120 batch nodes.
const MAX_FLAME_BATCH_NODES := 120
const MAX_FLAME_TRIANGLES_PER_INSTANCE := 200
const MAX_ENABLED_TORCH_LIGHTS := 16
const MAX_LIGHTS_PER_MESH := 16

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


# ── helpers ──────────────────────────────────────────────────────────────────

func _make_budget(parent: Node) -> Node:
	var b := Node.new()
	b.name = "TorchLightBudget"
	b.set_script(load(BUDGET_SCRIPT))
	parent.add_child(b)
	return b


func _make_torches(parent: Node, positions: Array[Vector3], energy: float = 3.0) -> Array[Node3D]:
	var out: Array[Node3D] = []
	for p in positions:
		var t := Node3D.new()
		t.name = "Torch"
		var l := OmniLight3D.new()
		l.name = "OmniLight3D"
		l.light_energy = energy
		l.omni_range = 7.7
		t.add_child(l)
		parent.add_child(t)
		t.global_position = p
		out.append(t)
	return out


func _grid_positions(nx: int, nz: int, spacing: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for x in nx:
		for z in nz:
			out.append(Vector3(x * spacing, 3.0, z * spacing))
	return out


func _light_of(t: Node3D) -> OmniLight3D:
	return t.get_node("OmniLight3D") as OmniLight3D


func _on_count(torches: Array[Node3D]) -> int:
	var c := 0
	for t in torches:
		if _light_of(t).visible:
			c += 1
	return c


func _on_set(torches: Array[Node3D]) -> Dictionary:
	var d := {}
	for i in torches.size():
		if _light_of(torches[i]).visible:
			d[i] = true
	return d


func _nearest(torches: Array[Node3D], p: Vector3, k: int) -> Array:
	var idx: Array = range(torches.size())
	idx.sort_custom(func(a, b): return torches[a].global_position.distance_squared_to(p) < torches[b].global_position.distance_squared_to(p))
	return idx.slice(0, k)


func _flush(budget: Node, seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		budget._process(0.05)
		t += 0.05


# ── part 1: synthetic ────────────────────────────────────────────────────────

func _part1() -> void:
	var root := Node3D.new()
	add_child(root)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	var torches := _make_torches(root, _grid_positions(20, 20, 6.0))   # 400 torches over 114 m
	var budget := _make_budget(root)
	cam.global_position = Vector3(60.0, 1.6, 60.0)
	budget.boot(torches)

	# -- the cap, and nearest-first selection
	var cap: int = budget.MAX_TORCH_LIGHTS
	_check(budget.torch_count() == 400, "budget registered all 400 torches (%d)" % budget.torch_count())
	_check(_on_count(torches) == cap, "boot switches on exactly the cap (%d of %d)" % [_on_count(torches), cap])
	var want := _nearest(torches, cam.global_position, cap)
	var on := _on_set(torches)
	var missing := 0
	for i in want:
		if not on.has(i):
			missing += 1
	_check(missing == 0, "the lights that are on are the %d nearest to the camera (%d missing)" % [cap, missing])
	for t in torches:
		var l := _light_of(t)
		if l.visible:
			_check(is_equal_approx(l.light_energy, 3.0), "an on light has its full energy after the instant boot refresh")
			break

	# -- cap holds while the camera moves around (instant refresh at each place)
	var worst := 0
	for p in [Vector3(5, 1.6, 5), Vector3(110, 1.6, 7), Vector3(57, 1.6, 113), Vector3(300, 1.6, 300), Vector3(60, 1.6, 61)]:
		cam.global_position = p
		budget.refresh(true)
		# the SELECTION never exceeds the cap; for the 0.3 s fade the lights that lose their slot are
		# still (dimming) on, so at most cap + the number that changed are visible
		_check(budget.wanted_torch_lights() <= cap, "selected torches <= cap right after a move (%d)" % budget.wanted_torch_lights())
		_check(_on_count(torches) <= 2 * cap, "transient crossfade <= 2 x cap (%d)" % _on_count(torches))
		_flush(budget, 0.6)
		worst = maxi(worst, _on_count(torches))
	_check(worst <= cap, "once faded, never more than the cap on while the camera moves (worst %d)" % worst)
	cam.global_position = Vector3(300, 1.6, 300)   # far outside the grid: nothing within 45 m
	budget.refresh(true)
	_flush(budget, 0.6)
	_check(_on_count(torches) == 0, "no torch light is on when none is within the selection radius (%d)" % _on_count(torches))

	root.free()   # sub-scenes are independent: one budget (and its dynamic-light bookkeeping) at a time

	# -- hysteresis: a camera jittering around the point where two torches tie does not flip them
	var hroot := Node3D.new()
	add_child(hroot)
	var hcam := Camera3D.new()
	hroot.add_child(hcam)
	hcam.current = true
	var line: Array[Vector3] = []
	for i in 40:
		line.append(Vector3(i * 3.0, 3.0, 0.0))
	var ltorches := _make_torches(hroot, line)
	var hb := _make_budget(hroot)
	hcam.global_position = Vector3(0.0, 1.6, 0.0)
	hb.boot(ltorches)
	# walk to the spot where strict nearest-16 flips between torch 0 and torch 16, then jitter
	var flips := 0
	hcam.global_position = Vector3(24.0, 1.6, 0.0)   # 16 nearest: torches 1..15 plus one of the two at +-24 m
	hb.refresh(true)
	_flush(hb, 0.6)
	var prev := _on_set(ltorches)
	for n in 40:
		hcam.global_position.x = 24.0 + (0.4 if n % 2 == 0 else -0.4)
		hb.refresh(false)
		_flush(hb, 0.4)
		var now := _on_set(ltorches)
		if now.keys() != prev.keys():
			flips += 1
		prev = now
	_check(flips == 0, "a camera jittering +-0.4 m around a tie does not flip any light (%d flips)" % flips)
	# and a real move still changes the selection
	hcam.global_position = Vector3(100.0, 1.6, 0.0)
	hb.refresh(true)
	_flush(hb, 0.6)
	_check(_on_count(ltorches) <= cap and _on_count(ltorches) > 0, "a real move re-selects (on=%d)" % _on_count(ltorches))
	hroot.free()

	# -- fade: nothing pops
	var froot := Node3D.new()
	add_child(froot)
	var fcam := Camera3D.new()
	froot.add_child(fcam)
	fcam.current = true
	var ftorches := _make_torches(froot, _grid_positions(10, 10, 6.0))
	var fb := _make_budget(froot)
	fcam.global_position = Vector3(0.0, 1.6, 0.0)
	fb.boot(ftorches)
	var before := _on_set(ftorches)
	fcam.global_position = Vector3(54.0, 1.6, 54.0)   # opposite corner: a whole new set
	fb.refresh(false)
	var max_step := 0.0
	var energies: Dictionary = {}
	for i in ftorches.size():
		energies[i] = _light_of(ftorches[i]).light_energy if _light_of(ftorches[i]).visible else 0.0
	var steps := 0
	var all_before_visible_first := true
	for n in 12:
		fb._process(0.05)
		steps += 1
		for i in ftorches.size():
			var l := _light_of(ftorches[i])
			var e: float = l.light_energy if l.visible else 0.0
			max_step = maxf(max_step, absf(e - float(energies[i])))
			energies[i] = e
		if n == 0:
			for i in before:
				if not _light_of(ftorches[i]).visible:
					all_before_visible_first = false
	_check(max_step <= 3.0 * 0.05 / fb.FADE_TIME + 0.01, "no light jumps more than one fade step per frame (max step %.3f)" % max_step)
	_check(all_before_visible_first, "lights that lose their slot are still on after the first frame (they fade, not vanish)")
	_check(_on_count(ftorches) <= cap, "after the fade only the cap is on (%d)" % _on_count(ftorches))
	var after := _on_set(ftorches)
	var overlap := 0
	for i in before:
		if after.has(i):
			overlap += 1
	_check(overlap == 0, "the old and the new sets are disjoint here (%d common): the test really exercised both fades" % overlap)
	froot.free()

	# -- energy ownership
	var eroot := Node3D.new()
	add_child(eroot)
	var ecam := Camera3D.new()
	eroot.add_child(ecam)
	ecam.current = true
	var etorches := _make_torches(eroot, _grid_positions(8, 8, 5.0))
	var eb := _make_budget(eroot)
	ecam.global_position = Vector3(15.0, 1.6, 15.0)
	eb.boot(etorches)
	eb.set_global_energy(5.0)
	_flush(eb, 0.5)
	var any_on: OmniLight3D = null
	for t in etorches:
		if _light_of(t).visible:
			any_on = _light_of(t)
			break
	_check(any_on != null and is_equal_approx(any_on.light_energy, 5.0), "global energy 5.0 reaches the lights that are on (%s)" % str(any_on.light_energy if any_on != null else -1))
	eb.set_global_energy(1.0)
	_flush(eb, 0.1)
	_check(is_equal_approx(any_on.light_energy, 1.0), "global energy 1.0 reaches them next frame")
	eb.set_light_factor(any_on, 0.5)
	_flush(eb, 0.1)
	_check(is_equal_approx(any_on.light_energy, 0.5), "a flicker factor 0.5 halves that light only")
	var other: OmniLight3D = null
	for t in etorches:
		if _light_of(t).visible and _light_of(t) != any_on:
			other = _light_of(t)
			break
	_check(other != null and is_equal_approx(other.light_energy, 1.0), "other lights are unaffected by one light's factor")
	eb.set_light_factor(any_on, 1.0)
	var killed_count_before := _on_count(etorches)
	eb.kill_light(any_on)
	eb.refresh(false)
	_flush(eb, 0.6)
	_check(not any_on.visible, "a killed torch goes out and stays out")
	_check(_on_count(etorches) == killed_count_before, "its slot is taken by the next nearest torch (%d vs %d)" % [_on_count(etorches), killed_count_before])
	eb.set_global_energy(-1.0)
	_flush(eb, 0.1)
	_check(is_equal_approx(other.light_energy, 3.0), "negative global energy gives each light its own energy back")
	eroot.free()

	# -- one budget for torches + dynamic lights
	var droot := Node3D.new()
	add_child(droot)
	var dcam := Camera3D.new()
	droot.add_child(dcam)
	dcam.current = true
	var dtorches := _make_torches(droot, _grid_positions(10, 10, 4.0))
	var db := _make_budget(droot)
	dcam.global_position = Vector3(18.0, 1.6, 18.0)
	db.boot(dtorches)
	_check(_on_count(dtorches) == cap and db.torch_allowance() == cap, "no dynamic lights: torches get the cap (%d)" % _on_count(dtorches))
	var dyn: Array[OmniLight3D] = []
	for i in 12:
		var l := OmniLight3D.new()   # added after boot: picked up through node_added
		droot.add_child(l)
		l.global_position = Vector3(18.0 + i * 0.5, 1.0, 18.0)
		dyn.append(l)
	db.refresh(true)
	_flush(db, 0.6)
	var total_on: int = _on_count(dtorches) + int(db.dynamic_lights_near())
	_check(db.dynamic_lights_near() == 12, "12 nearby dynamic lights are counted (%d)" % db.dynamic_lights_near())
	_check(total_on <= db.TOTAL_LIGHT_BUDGET, "torches + dynamic lights stay within the single budget (%d <= %d)" % [total_on, db.TOTAL_LIGHT_BUDGET])
	_check(_on_count(dtorches) == db.TOTAL_LIGHT_BUDGET - 12, "torches yield exactly the slots the dynamic lights use (%d)" % _on_count(dtorches))
	for i in 12:
		dyn.append(OmniLight3D.new())
		droot.add_child(dyn[dyn.size() - 1])
		dyn[dyn.size() - 1].global_position = Vector3(18.0, 1.0, 18.0)
	db.refresh(true)
	_flush(db, 0.6)
	_check(_on_count(dtorches) == db.MIN_TORCH_LIGHTS, "torches never drop below the minimum (%d)" % _on_count(dtorches))
	for l in dyn:
		_check(l.visible, "the budget never switches a dynamic light (their scripts own them)")
		break
	dyn[0].visible = false
	db.refresh(true)
	_check(db.dynamic_lights_near() == 23, "a dynamic light its script hides is not counted (%d)" % db.dynamic_lights_near())
	droot.free()

	# -- no allocation growth across thousands of updates
	var aroot := Node3D.new()
	add_child(aroot)
	var acam := Camera3D.new()
	aroot.add_child(acam)
	acam.current = true
	var atorches := _make_torches(aroot, _grid_positions(20, 20, 6.0))
	var ab := _make_budget(aroot)
	acam.global_position = Vector3(40.0, 1.6, 40.0)
	ab.boot(atorches)
	for n in 300:   # warm up (first-use allocations, dictionary growth)
		acam.global_position = Vector3(40.0 + (n % 50), 1.6, 40.0 + (n % 37))
		ab.refresh(false)
		ab._process(0.016)
	var objs0 := Performance.get_monitor(Performance.OBJECT_COUNT)
	var mem0 := Performance.get_monitor(Performance.MEMORY_STATIC)
	var sel_size0: int = ab._sel_idx.size()
	var act_cap0: int = ab._active.size()
	var t0 := Time.get_ticks_usec()
	for n in 6000:
		acam.global_position = Vector3(20.0 + (n % 90), 1.6, 20.0 + ((n * 7) % 80))
		ab.refresh(false)
		ab._process(0.016)
	var per_update_us := float(Time.get_ticks_usec() - t0) / 6000.0
	var objs1 := Performance.get_monitor(Performance.OBJECT_COUNT)
	var mem1 := Performance.get_monitor(Performance.MEMORY_STATIC)
	_check(objs1 == objs0, "no objects created by 6000 updates (%d -> %d)" % [objs0, objs1])
	_check(mem1 - mem0 < 262144.0, "static memory does not grow with updates (%+.0f bytes over 6000 updates)" % (mem1 - mem0))
	_check(ab._sel_idx.size() == sel_size0 and ab._active.size() == act_cap0, "scratch buffers keep their fixed size")
	print("  metric budget update+frame step: %.1f us per update (400 torches, desktop CPU)" % per_update_us)
	aroot.free()
	await get_tree().process_frame


# ── part 2: dimming manager through the budget ───────────────────────────────

func _part2() -> void:
	var root := Node3D.new()
	add_child(root)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	var torches := _make_torches(root, _grid_positions(6, 6, 5.0))
	var budget := _make_budget(root)
	var dim := Node.new()
	dim.name = "TorchDimmingManager"
	dim.set_script(load(DIMMING_SCRIPT))
	root.add_child(dim)
	dim.torch_flicker_chance = 1.0   # every torch flickers
	dim.torch_die_chance = 0.0
	cam.global_position = Vector3(12.0, 1.6, 12.0)
	budget.boot(torches)
	dim.boot(torches, null)
	dim.set_process(false)   # the test drives _process by hand
	_check(dim._budget == budget, "the dimming manager found the sibling budget")

	dim._process(0.05)   # t ~ 0: starting energy
	_flush(budget, 0.5)
	var lit: Array[OmniLight3D] = []
	for t in torches:
		if _light_of(t).visible:
			lit.append(_light_of(t))
	_check(lit.size() == budget.MAX_TORCH_LIGHTS, "dimming run: the cap is on (%d)" % lit.size())
	var e0: float = lit[0].light_energy
	_check(e0 <= dim.starting_light_value + 0.001 and e0 > dim.starting_light_value * 0.4, "day-1 energy is the starting value times a flicker factor (%.2f)" % e0)
	# half way: global energy is the midpoint
	dim._elapsed = dim.dimming_duration * 0.5
	for light in lit:
		budget.set_light_factor(light, 1.0)
	for fs in dim._flicker_states:
		fs["burst_timer"] = 0.0
		fs["idle_timer"] = 1e9
	dim._process(0.05)
	_flush(budget, 0.1)
	var mid: float = lerpf(dim.starting_light_value, dim.ending_light_value, 0.5 + 0.05 / dim.dimming_duration)
	_check(absf(lit[0].light_energy - mid) < 0.02, "half way the lights are at the mid energy (%.3f vs %.3f)" % [lit[0].light_energy, mid])
	# a flicker burst dips only the bursting torches and recovers
	var fs0: Dictionary = {}
	for fs in dim._flicker_states:
		if (fs["light"] as OmniLight3D).visible:
			fs0 = fs
			break
	_check(not fs0.is_empty(), "a flickering torch is among the lights that are on")
	var flick_light: OmniLight3D = fs0["light"] as OmniLight3D
	fs0["idle_timer"] = 0.0
	dim._process(0.05)   # starts a burst
	dim._process(0.05)   # first dip
	_flush(budget, 0.1)
	_check(flick_light.visible and flick_light.light_energy < mid * 0.9, "a flicker burst dips the torch (%.2f < %.2f)" % [flick_light.light_energy, mid * 0.9])
	fs0["burst_timer"] = 0.01
	dim._process(0.05)   # burst ends
	_flush(budget, 0.1)
	_check(absf(flick_light.light_energy - lerpf(dim.starting_light_value, dim.ending_light_value, dim._elapsed / dim.dimming_duration)) < 0.05, "after the burst the torch is back at the global energy")
	# the end of the run: ending energy
	dim._elapsed = dim.dimming_duration
	for fs in dim._flicker_states:
		fs["burst_timer"] = 0.0
		fs["idle_timer"] = 1e9
	dim._process(0.05)
	_flush(budget, 0.1)
	var any_on: OmniLight3D = null
	for t in torches:
		if _light_of(t).visible:
			any_on = _light_of(t)
			break
	_check(any_on != null and absf(any_on.light_energy - dim.ending_light_value) < 0.02, "day 30: lights are at the ending energy (%.2f)" % (any_on.light_energy if any_on != null else -1.0))
	# deaths: every torch dies -> every light goes out through the budget
	dim._early_die_queue.clear()
	for light in budget._lights:
		dim._early_die_queue.append({"light": light, "die_at": 0.0})
	dim._process(0.05)
	budget.refresh(false)
	_flush(budget, 0.6)
	_check(_on_count(torches) == 0, "dead torches are out (%d still on)" % _on_count(torches))
	root.free()
	await get_tree().process_frame


# ── part 3: one real dungeon ─────────────────────────────────────────────────

func _build_dungeon(seed_value: int, cfg: Node) -> Dictionary:
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
	gen.weight_1_connection = cfg.weight_1_connection
	gen.overlap_shrink = cfg.overlap_shrink
	gen.connection_nudge = cfg.connection_nudge
	gen.exclude_keywords = cfg.exclude_keywords.duplicate()
	gen.exploration_padding = cfg.exploration_padding
	gen.enemy_spawn_chance = cfg.enemy_spawn_chance
	gen.setup_generation(root, cfg.starter_module, cfg.branch_modules, cfg.room_connector_module, cfg.end_cap_module)
	seed(seed_value)
	var result: Dictionary = gen.generate_dungeon()
	return {"root": root, "gen": gen, "result": result}


func _overlap_count(lights: Array, a: AABB) -> int:
	var c := 0
	for lr in lights:
		var q: Vector3 = (lr[0] as Vector3).clamp(a.position, a.end)
		if (lr[0] as Vector3).distance_squared_to(q) <= float(lr[1]) * float(lr[1]):
			c += 1
	return c


func _enabled_torch_lights(gen: Node) -> int:
	var c := 0
	for t in gen.registered_torches:
		if is_instance_valid(t) and _light_of(t).visible:
			c += 1
	return c


func _part3() -> void:
	var cfg: Node = (load(MAIN_SCENE) as PackedScene).instantiate()   # exported generator settings only
	var seed_value := 7
	var env := OS.get_environment("LIGHT_TEST_SEED")
	if env != "":
		seed_value = int(env)
	var built := _build_dungeon(seed_value, cfg)
	var gen: Node = built["gen"]
	var root: Node3D = built["root"]
	for i in 4:
		await get_tree().physics_frame
	var tag := "seed %d: " % seed_value
	_check(bool(built["result"].get("success", false)), tag + "generation succeeds")
	var torches: Array = gen.registered_torches
	_check(torches.size() > 300, tag + "dungeon has torches (%d)" % torches.size())

	await _part4(gen, root, tag)

	# flames: one per torch, batched, never one node per torch
	var old_style := 0
	for n in root.find_children("FlameMesh", "MeshInstance3D", true, false):
		old_style += 1
	_check(old_style == 0, tag + "no per-torch FlameMesh MeshInstance3D nodes (%d)" % old_style)
	var batch_nodes := 0
	var instances := 0
	var tris_per_instance := 0
	for b in gen.torch_flame_batches:
		if b is MultiMeshInstance3D and is_instance_valid(b):
			batch_nodes += 1
			var mm: MultiMesh = (b as MultiMeshInstance3D).multimesh
			instances += mm.instance_count
			if tris_per_instance == 0 and mm.mesh is SphereMesh:
				# a UV sphere is radial_segments x rings quads (the poles degenerate to ~half): upper bound
				tris_per_instance = (mm.mesh as SphereMesh).radial_segments * (mm.mesh as SphereMesh).rings * 2
			_check((b as MultiMeshInstance3D).layers == 2, tag + "flame batch stays on layer 2 (minimap camera excludes it)")
	_check(instances == torches.size(), tag + "a flame instance for every torch (%d flames, %d torches)" % [instances, torches.size()])
	_check(gen.torch_flame_positions.size() == torches.size(), tag + "flame positions recorded for every torch")
	_check(batch_nodes > 0 and batch_nodes <= MAX_FLAME_BATCH_NODES, tag + "flames are %d batch nodes (ceiling %d), not %d nodes" % [batch_nodes, MAX_FLAME_BATCH_NODES, torches.size()])
	_check(tris_per_instance > 0 and tris_per_instance <= MAX_FLAME_TRIANGLES_PER_INSTANCE, tag + "flame mesh is low-poly (%d triangles, ceiling %d; the default sphere was 4224)" % [tris_per_instance, MAX_FLAME_TRIANGLES_PER_INSTANCE])
	var mat_ids := {}
	for b in gen.torch_flame_batches:
		mat_ids[(b as MultiMeshInstance3D).multimesh.mesh.get_rid()] = true
	_check(mat_ids.size() == 1, tag + "all flames share one mesh resource")

	# the budget over the real dungeon
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	var budget := _make_budget(root)
	var spots: Array[Vector3] = []
	var step: int = maxi(gen.placed_modules.size() / 12, 1)
	for i in range(0, gen.placed_modules.size(), step):
		var m: Node3D = gen.placed_modules[i]
		if is_instance_valid(m):
			spots.append(gen.get_module_aabb(m).get_center() + Vector3(0, 0.0, 0))
	cam.global_position = spots[0] if not spots.is_empty() else Vector3.ZERO
	budget.boot(torches)
	_check(budget.torch_count() == torches.size(), tag + "budget registered every torch (%d)" % budget.torch_count())
	var worst_on := 0
	var worst_total := 0
	var p95_worst := 0
	var max_worst := 0
	var mean_acc := 0.0
	var mean_all_acc := 0.0
	var not_better := 0
	var meshes_all: Array = root.find_children("*", "MeshInstance3D", true, false)
	for spot in spots:
		cam.global_position = spot
		budget.refresh(true)
		_flush(budget, 0.5)
		var on := _enabled_torch_lights(gen)
		worst_on = maxi(worst_on, on)
		# every enabled OmniLight3D of the whole level (torches + anything else in the tree)
		var all_on := 0
		for l in root.find_children("*", "OmniLight3D", true, false):
			if (l as Node3D).is_visible_in_tree() and (l as Light3D).light_energy > 0.0:
				all_on += 1
		worst_total = maxi(worst_total, all_on)
		# lights per mesh (meshes within 30 m of the camera): enabled torch lights whose range reaches
		# the mesh AABB, compared with what every torch light inside the 40 m distance fade would give
		var on_lights: Array = []
		var all_lights: Array = []
		for t in torches:
			var l := _light_of(t)
			if l.global_position.distance_to(spot) <= 40.0:
				all_lights.append([l.global_position, l.omni_range])
			if l.visible:
				on_lights.append([l.global_position, l.omni_range])
		var counts: Array[int] = []
		var counts_all: Array[int] = []
		for mi in meshes_all:
			if not is_instance_valid(mi) or (mi as MeshInstance3D).mesh == null:
				continue
			var a: AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
			if a.get_center().distance_to(spot) > 30.0:
				continue
			counts.append(_overlap_count(on_lights, a))
			counts_all.append(_overlap_count(all_lights, a))
		counts.sort()
		counts_all.sort()
		if not counts.is_empty():
			var p95: int = counts[int(counts.size() * 0.95)]
			var p95_all: int = counts_all[int(counts_all.size() * 0.95)]
			p95_worst = maxi(p95_worst, p95)
			max_worst = maxi(max_worst, counts[counts.size() - 1])
			var s1 := 0
			var s2 := 0
			for c in counts:
				s1 += c
			for c in counts_all:
				s2 += c
			mean_acc += float(s1) / counts.size()
			mean_all_acc += float(s2) / counts_all.size()
			if s1 > s2 or p95 > p95_all:
				not_better += 1
	print("  metric %storches=%d flame_batches=%d (%d tris each) enabled torch lights worst=%d, all enabled omni lights worst=%d, lights/mesh with budget: p95 worst=%d max=%d mean=%.2f (all torches within 40 m: mean=%.2f) over %d viewpoints" % [
		tag, torches.size(), batch_nodes, tris_per_instance, worst_on, worst_total, p95_worst, max_worst, mean_acc / maxf(spots.size(), 1), mean_all_acc / maxf(spots.size(), 1), spots.size()])
	_check(worst_on <= MAX_ENABLED_TORCH_LIGHTS, tag + "enabled torch lights stay <= %d at every viewpoint (worst %d)" % [MAX_ENABLED_TORCH_LIGHTS, worst_on])
	_check(worst_total <= budget.TOTAL_LIGHT_BUDGET, tag + "ALL enabled omni lights stay within the single budget (%d <= %d)" % [worst_total, budget.TOTAL_LIGHT_BUDGET])
	_check(not_better == 0, tag + "the budget never gives meshes more lights than 'every torch within 40 m' would (%d viewpoints worse)" % not_better)
	_check(max_worst <= MAX_LIGHTS_PER_MESH, tag + "lights per mesh <= %d (worst %d)" % [MAX_LIGHTS_PER_MESH, max_worst])
	# flames and light count are independent: every flame is still there with the lights off
	_check(gen.torch_flame_count == torches.size(), tag + "flames untouched by the light budget")
	# total light nodes did not change (hidden, not freed): the budget only toggles
	var omni_nodes := root.find_children("*", "OmniLight3D", true, false).size()
	_check(omni_nodes >= torches.size(), tag + "every torch keeps its OmniLight3D node (hidden, not freed)")
	cfg.free()
	root.queue_free()
	await get_tree().process_frame


# ── part 4: module materials go back to the opaque pass ─────────────────────

func _part4(gen: Node, root: Node3D, tag: String) -> void:
	var tuning = load(TUNING_SCRIPT)
	# the safety net: every module albedo texture the tuning may touch is fully opaque on disk
	var dir := DirAccess.open("res://dungeon modules")
	var opaque_checked := 0
	for f in dir.get_files():
		if f.ends_with(tuning.TEXTURE_SUFFIX):
			var img := Image.load_from_file(ProjectSettings.globalize_path("res://dungeon modules/" + f))
			_check(img != null and img.detect_alpha() == Image.ALPHA_NONE, tag + "module texture %s is fully opaque (the tuning relies on it)" % f)
			opaque_checked += 1
	_check(opaque_checked >= 10, tag + "checked the module colormap textures (%d)" % opaque_checked)
	# before: the glTF import leaves every module surface in the depth-pre-pass alpha mode
	var before_alpha := 0
	var before_total := 0
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null or not _is_in_module(m, gen):
			continue
		for i in m.mesh.get_surface_count():
			var mat := m.get_active_material(i)
			if mat is BaseMaterial3D:
				before_total += 1
				if (mat as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
					before_alpha += 1
	var stats: Dictionary = tuning.apply_to_modules(gen.placed_modules)
	var after_alpha := 0
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null or not _is_in_module(m, gen):
			continue
		for i in m.mesh.get_surface_count():
			var mat := m.get_active_material(i)
			if mat is BaseMaterial3D and (mat as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED and tuning.is_tunable(mat):
				after_alpha += 1
			if mat is BaseMaterial3D and (mat as BaseMaterial3D).transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
				_check((mat as BaseMaterial3D).albedo_color.a >= 0.999, tag + "no translucent material was made opaque")
	print("  metric %smodule surfaces=%d with alpha pass before=%d ; tuning: %s ; still tunable after=%d" % [tag, before_total, before_alpha, str(stats), after_alpha])
	_check(int(stats["switched"]) > 0 and int(stats["scenes"]) > 0, tag + "the tuning switched module materials (%s)" % str(stats))
	_check(after_alpha == 0, tag + "no module surface is left in the alpha pass (%d)" % after_alpha)
	var again: Dictionary = tuning.apply_to_modules(gen.placed_modules)
	_check(int(again["switched"]) == 0, tag + "applying twice changes nothing")
	# a translucent / non-module material is never touched
	var other := StandardMaterial3D.new()
	other.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_check(not tuning.is_tunable(other), tag + "unrelated translucent materials are left alone")


func _is_in_module(n: Node, gen: Node) -> bool:
	var cur: Node = n
	while cur != null:
		if gen.placed_modules.has(cur):
			return true
		cur = cur.get_parent()
	return false


func _ready() -> void:
	await _part1()
	await _part2()
	await _part3()
	print("test_light_budget: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
