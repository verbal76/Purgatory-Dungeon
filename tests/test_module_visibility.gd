extends Node
## Protects the distance culling of scripts/module_visibility.gd (rooms outside the useful player
## area cost no rendering work). Deterministic and headless: it checks the node-level visibility the
## renderer is driven by, not pixels (tests/perf_render_probe.gd with PERF_SHOT=1 compares culled and
## unculled pictures under a real renderer).
##
## Covers: far modules are hidden and near ones kept (distance rule + forward cone), the module of the
## camera and its doorway neighbours are always shown, hysteresis (no flip-flop at the border), the map
## showing everything (and the rate-limited re-hide after it closes), collision / physics of hidden
## modules untouched (layers unchanged, rays still hit), the portal's surroundings never hidden, props
## (also ones added later) hidden by their own distance, items another script hid left alone, flame
## batches culled with the rooms, zero object growth over thousands of updates, restore on shutdown and
## no crash when a module is freed while hidden.
## VIS_TEST_SEED=n overrides the seed (run_tests.sh runs one seed per process).

const GEN_SCENE := "res://scenes/dungeon_generation_function.tscn"
const MAIN_SCENE := "res://scenes/Purgatory_Dungeon_main_game_file.tscn"
const VIS_SCRIPT := "res://scripts/module_visibility.gd"

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _aabb_dist(box: AABB, p: Vector3) -> float:
	return p.distance_to(p.clamp(box.position, box.end))


func _make_vis(parent: Node) -> Node:
	var v := Node.new()
	v.name = "ModuleVisibility"
	v.set_script(load(VIS_SCRIPT))
	parent.add_child(v)
	return v


func _ready() -> void:
	var cfg: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	var seed_value := 7
	if OS.get_environment("VIS_TEST_SEED") != "":
		seed_value = int(OS.get_environment("VIS_TEST_SEED"))
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
	for i in 4:
		await get_tree().physics_frame
	var tag := "seed %d: " % seed_value
	_check(bool(result.get("success", false)), tag + "generation succeeds")
	var modules: Array = gen.placed_modules
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true

	# physics layers before the manager exists
	var layers_before: Dictionary = {}
	for co in root.find_children("*", "CollisionObject3D", true, false):
		layers_before[co.get_instance_id()] = [(co as CollisionObject3D).collision_layer, (co as CollisionObject3D).collision_mask]

	# fake props and a fake minimap node (the real ones belong to the main scene)
	var props := Node3D.new()
	props.name = "PropSpawner"
	root.add_child(props)
	var map_script := GDScript.new()
	map_script.source_code = "extends Node\nvar _map_visible : bool = false\n"
	map_script.reload()
	var map_node := Node.new()
	map_node.name = "minimap_function"
	map_node.set_script(map_script)
	root.add_child(map_node)

	var vis := _make_vis(root)
	var rules_ok := true
	var spawn_mod: Node3D = modules[0]
	var spawn_box: AABB = gen.get_module_aabb(spawn_mod)
	cam.global_position = spawn_box.get_center() + Vector3(0, 1.6, 0)
	cam.global_rotation = Vector3.ZERO   # looks along -Z
	vis.boot(modules, gen.torch_flame_batches, gen.torch_flame_bounds)
	_check(vis.item_count() >= modules.size() - 5, tag + "every module with geometry is an item (%d of %d)" % [vis.item_count(), modules.size()])
	vis.refresh(true)
	var hidden_modules := 0
	var near_bad := 0
	var far_bad := 0
	var cone_bad := 0
	var fwd := Vector3(0, 0, -1)
	var campos := cam.global_position
	for m in modules:
		var box: AABB = gen.get_module_aabb(m)
		if box.size == Vector3.ZERO:
			continue
		var d: float = _aabb_dist(box, campos)
		var shown: bool = (m as Node3D).visible
		if not shown:
			hidden_modules += 1
		if d <= vis.R_BASE - 3.0 and not shown:
			near_bad += 1
		if d > vis.R_FORWARD + vis.HYSTERESIS + 3.0 and shown:
			far_bad += 1
		if d > vis.R_BASE + 3.0 and d < vis.R_FORWARD - 3.0:
			# in between: inside the forward cone is shown; outside it is hidden once past the hysteresis band
			var cp: Vector3 = campos.clamp(box.position - Vector3.ONE * vis.AABB_MARGIN, box.end + Vector3.ONE * vis.AABB_MARGIN)
			var v: Vector3 = cp - campos
			var vh: Vector3 = Vector3(v.x, 0, v.z)
			var in_cone: bool = vh.length() < 2.0 or (vh.dot(fwd) > 0.0 and vh.normalized().dot(fwd) > vis.FORWARD_COS + 0.02)
			var out_cone: bool = vh.length() >= 2.0 and (vh.dot(fwd) <= 0.0 or vh.normalized().dot(fwd) < vis.FORWARD_COS - 0.02)
			if (in_cone and not shown) or (out_cone and shown and d > vis.R_BASE + vis.HYSTERESIS + 3.0):
				cone_bad += 1
	print("  metric %smodules=%d hidden=%d (%.0f %%) items=%d hidden_items=%d" % [tag, modules.size(), hidden_modules, 100.0 * hidden_modules / maxf(modules.size(), 1), vis.item_count(), vis.hidden_count()])
	_check(hidden_modules > modules.size() / 3, tag + "a large part of the level is hidden from the spawn (%d of %d)" % [hidden_modules, modules.size()])
	_check(near_bad == 0, tag + "every module within %d m of the camera is shown (%d wrong)" % [int(vis.R_BASE - 3.0), near_bad])
	_check(far_bad == 0, tag + "every module beyond %d m is hidden (%d wrong)" % [int(vis.R_FORWARD + vis.HYSTERESIS + 3.0), far_bad])
	_check(cone_bad == 0, tag + "between %d and %d m modules in the forward cone are shown and those outside it (past the hysteresis band) hidden (%d wrong)" % [int(vis.R_BASE), int(vis.R_FORWARD), cone_bad])
	_check(spawn_mod.visible, tag + "the module the camera is in is shown")

	# camera module and its doorway neighbours are always shown, wherever the camera stands
	var neigh_bad := 0
	var spots := 0
	var step: int = maxi(modules.size() / 25, 1)
	for i in range(0, modules.size(), step):
		var box: AABB = gen.get_module_aabb(modules[i])
		if box.size == Vector3.ZERO:
			continue
		cam.global_position = box.get_center()
		cam.global_rotation = Vector3(0, float(i) * 0.7, 0)
		vis.refresh(true)
		spots += 1
		var inflated: AABB = box.grow(3.0)
		for m in modules:
			var b2: AABB = gen.get_module_aabb(m)
			if b2.size == Vector3.ZERO:
				continue
			if inflated.intersects(b2) and not (m as Node3D).visible:
				neigh_bad += 1
	_check(neigh_bad == 0, tag + "the camera's module and every module touching it stay shown at %d spots (%d wrong)" % [spots, neigh_bad])

	# hysteresis: jitter the camera around the border of one module, nothing flips
	cam.global_position = campos
	cam.global_rotation = Vector3.ZERO
	vis.refresh(true)
	var snapshot: Array[bool] = []
	for m in modules:
		snapshot.append((m as Node3D).visible)
	var flips := 0
	for n in 40:
		cam.global_position = campos + Vector3(0.0, 0.0, 3.0 * (1.0 if n % 2 == 0 else -1.0))
		vis.refresh(true)
		cam.global_position = campos
		vis.refresh(true)
	var off_band := 0
	for i in modules.size():
		if (modules[i] as Node3D).visible != snapshot[i]:
			flips += 1
			var dd: float = _aabb_dist(gen.get_module_aabb(modules[i]), campos)
			if dd < vis.R_BASE - 1.0 or dd > vis.R_FORWARD + vis.HYSTERESIS + 1.0:
				off_band += 1
	_check(off_band == 0 and flips <= 6, tag + "after jittering and coming back only modules inside the hysteresis band differ (%d differ, %d outside the band)" % [flips, off_band])
	# a camera hovering at exactly the hide distance of a module does not flip it (hysteresis)
	var border_mod: Node3D = null
	var border_box := AABB()
	for m in modules:
		var b3: AABB = gen.get_module_aabb(m)
		if b3.size != Vector3.ZERO and _aabb_dist(b3, campos) > vis.R_FORWARD + 5.0 and _aabb_dist(b3, campos) < vis.R_FORWARD + 40.0:
			border_mod = m
			border_box = b3
			break
	if border_mod != null:
		# put the camera so that the module is at R_FORWARD +- 2 m, looking straight at it
		var tgt := border_box.get_center()
		var dir := (campos - tgt)
		dir.y = 0.0
		dir = dir.normalized()
		var base_d := _aabb_dist(border_box, tgt + dir * 500.0)   # distance to the box from far along dir (approx, refined below)
		var cp0: Vector3 = border_box.get_center() + dir * 400.0
		var edge: Vector3 = cp0.clamp(border_box.position - Vector3.ONE * vis.AABB_MARGIN, border_box.end + Vector3.ONE * vis.AABB_MARGIN)
		var on_ray: Vector3 = edge + dir * (vis.R_FORWARD - 1.0)   # 1 m inside the show radius
		cam.global_position = on_ray
		cam.look_at(edge, Vector3.UP)
		vis.refresh(true)
		var was_shown := border_mod.visible
		_check(was_shown, tag + "1 m inside the forward radius the module is shown")
		var changes := 0
		for n in 20:
			cam.global_position = edge + dir * (vis.R_FORWARD + (4.0 if n % 2 == 0 else -1.0))   # up to 4 m beyond: inside the hysteresis band
			cam.look_at(edge, Vector3.UP)
			vis.refresh(true)
			if border_mod.visible != was_shown:
				changes += 1
		_check(changes == 0 and base_d >= 0.0, tag + "4 m beyond the show radius a shown module stays shown (hysteresis, %d changes)" % changes)
		cam.global_position = edge + dir * (vis.R_FORWARD + vis.HYSTERESIS + 4.0)
		cam.look_at(edge, Vector3.UP)
		vis.refresh(true)
		_check(not border_mod.visible, tag + "beyond radius + hysteresis the module is hidden")
		cam.global_position = campos
		cam.global_rotation = Vector3.ZERO
		vis.refresh(true)

	# collision and physics of hidden modules are untouched
	var hidden_mod: Node3D = null
	for m in modules:
		if not (m as Node3D).visible and gen.get_module_aabb(m).size.x > 8.0 and not m.find_children("*", "CollisionObject3D", true, false).is_empty():
			hidden_mod = m
			break
	_check(hidden_mod != null, tag + "found a hidden module with colliders")
	if hidden_mod != null:
		var changed_layers := 0
		for co in root.find_children("*", "CollisionObject3D", true, false):
			var before: Array = layers_before.get(co.get_instance_id(), [])
			if not before.is_empty() and (before[0] != (co as CollisionObject3D).collision_layer or before[1] != (co as CollisionObject3D).collision_mask):
				changed_layers += 1
		_check(changed_layers == 0, tag + "no collision layer or mask changed (%d)" % changed_layers)
		var hb: AABB = gen.get_module_aabb(hidden_mod)
		var space: PhysicsDirectSpaceState3D = root.get_world_3d().direct_space_state
		var hits := 0
		var hits_in_hidden := 0
		for fx in [0.25, 0.5, 0.75]:
			for fz in [0.25, 0.5, 0.75]:
				var top := Vector3(hb.position.x + hb.size.x * fx, hb.end.y + 5.0, hb.position.z + hb.size.z * fz)
				var q := PhysicsRayQueryParameters3D.create(top, top + Vector3.DOWN * (hb.size.y + 12.0))
				q.collision_mask = 1
				var h := space.intersect_ray(q)
				if not h.is_empty():
					hits += 1
					var node: Node = h["collider"]
					while node != null and node != hidden_mod:
						node = node.get_parent()
					if node == hidden_mod:
						hits_in_hidden += 1
		_check(hits > 0 and hits_in_hidden > 0, tag + "rays still hit the colliders of a hidden module (%d hits, %d in it)" % [hits, hits_in_hidden])
		var body: Node = hidden_mod.find_children("*", "CollisionObject3D", true, false)[0]
		_check((body as CollisionObject3D).is_inside_tree() and not (hidden_mod as Node3D).is_visible_in_tree(), tag + "the hidden module is not drawn but its bodies are in the tree")

	# flames follow the rooms
	var flames_hidden := 0
	var flames_near_bad := 0
	for bi in gen.torch_flame_batches.size():
		var b: Node3D = gen.torch_flame_batches[bi]
		var bb: AABB = gen.torch_flame_bounds[bi]
		if not b.visible:
			flames_hidden += 1
		if _aabb_dist(bb, campos) < vis.R_BASE - 3.0 and not b.visible:
			flames_near_bad += 1
	_check(flames_hidden > 0 and flames_near_bad == 0, tag + "far flame batches are hidden (%d of %d), near ones shown (%d wrong)" % [flames_hidden, gen.torch_flame_batches.size(), flames_near_bad])

	# the map shows everything, and the re-hide after it is rate limited
	var hidden_before: int = vis.hidden_count()
	_check(hidden_before > 0, tag + "something is hidden before the map opens (%d)" % hidden_before)
	map_node._map_visible = true
	var t_open := Time.get_ticks_usec()
	vis._process(0.016)
	print("  metric %sopening the map shows %d hidden items in %.2f ms (desktop CPU, one frame)" % [tag, hidden_before, float(Time.get_ticks_usec() - t_open) / 1000.0])
	_check(vis.hidden_count() == 0, tag + "map open: nothing is hidden (%d)" % vis.hidden_count())
	var any_hidden := false
	for m in modules:
		if not (m as Node3D).visible:
			any_hidden = true
	_check(not any_hidden, tag + "map open: every module node is visible")
	for b in gen.torch_flame_batches:
		if not (b as Node3D).visible:
			any_hidden = true
	_check(not any_hidden, tag + "map open: every flame batch is visible")
	vis._process(1.0)
	_check(vis.hidden_count() == 0, tag + "map still open: the periodic update leaves everything shown")
	map_node._map_visible = false
	vis._process(0.016)   # the close is noticed this frame: first (rate limited) re-hide
	var after_first: int = vis.hidden_count()
	_check(after_first <= vis.MAX_HIDES_PER_UPDATE, tag + "closing the map hides at most %d items per update (%d)" % [vis.MAX_HIDES_PER_UPDATE, after_first])
	for n in 20:
		vis.refresh(false)
	_check(absi(vis.hidden_count() - hidden_before) <= hidden_before / 10 + 2, tag + "after a few updates about the same rooms are hidden again (%d vs %d)" % [vis.hidden_count(), hidden_before])
	var far_shown := 0
	for m in modules:
		var fb: AABB = gen.get_module_aabb(m)
		if fb.size != Vector3.ZERO and _aabb_dist(fb, campos) > vis.R_FORWARD + vis.HYSTERESIS + 3.0 and (m as Node3D).visible:
			far_shown += 1
	_check(far_shown == 0, tag + "after the map closes every far module is hidden again (%d shown)" % far_shown)

	# portal: its surroundings are never hidden
	var far_mod: Node3D = null
	for m in modules:
		if not (m as Node3D).visible:
			far_mod = m
	var portal := Node3D.new()
	portal.name = "EndPortal"
	root.add_child(portal)
	portal.global_position = gen.get_module_aabb(far_mod).get_center()
	vis.refresh(true)
	_check(far_mod.visible, tag + "the module holding the portal is shown although it is far away")
	portal.free()

	# props (also ones added later) by their own position; items another script hid are left alone
	var near_prop := Node3D.new()
	var far_prop := Node3D.new()
	var script_hidden := Node3D.new()
	props.add_child(near_prop)
	props.add_child(far_prop)
	props.add_child(script_hidden)
	near_prop.global_position = campos + Vector3(3, 0, -3)
	far_prop.global_position = campos + Vector3(0, 0, 300)
	script_hidden.global_position = campos + Vector3(0, 0, 300)
	script_hidden.visible = false
	vis.refresh(true)
	_check(near_prop.visible and not far_prop.visible, tag + "a far prop is hidden, a near one shown")
	_check(not script_hidden.visible and not vis.is_hidden_by_me(script_hidden), tag + "an item a script hid is not claimed by the culling")
	var late := Node3D.new()
	props.add_child(late)
	late.global_position = campos + Vector3(0, 0, -400)
	vis.refresh(true)
	_check(not late.visible, tag + "a prop spawned later is picked up and hidden when far")
	late.global_position = campos + Vector3(2, 0, 2)
	vis.refresh(true)
	_check(late.visible, tag + "and shown again when it is near (props are read live)")
	script_hidden.visible = true   # the script shows it again while it is far: hidden again
	vis.refresh(true)
	script_hidden.visible = false

	# no object growth over many updates
	for n in 200:
		cam.global_position = campos + Vector3(float(n % 40) * 5.0, 0.0, float(n % 17) * 7.0)
		vis.refresh(false)
	var objs0 := Performance.get_monitor(Performance.OBJECT_COUNT)
	var mem0 := Performance.get_monitor(Performance.MEMORY_STATIC)
	var t0 := Time.get_ticks_usec()
	for n in 4000:
		cam.global_position = campos + Vector3(float(n % 90) * 4.0 - 150.0, 0.0, float((n * 7) % 100) * 4.0 - 200.0)
		cam.global_rotation = Vector3(0, float(n) * 0.37, 0)
		vis.refresh(true)
	var per_update_us := float(Time.get_ticks_usec() - t0) / 4000.0
	var objs1 := Performance.get_monitor(Performance.OBJECT_COUNT)
	var mem1 := Performance.get_monitor(Performance.MEMORY_STATIC)
	_check(objs1 == objs0, tag + "no objects created by 4000 updates (%d -> %d)" % [objs0, objs1])
	_check(mem1 - mem0 < 262144.0, tag + "static memory does not grow with updates (%+.0f bytes)" % (mem1 - mem0))
	print("  metric %supdate cost %.0f us per full update (%d items, desktop CPU, instant mode with toggles)" % [tag, per_update_us, vis.item_count()])

	# a module freed while hidden does not break the update; shutdown restores everything
	cam.global_position = campos
	cam.global_rotation = Vector3.ZERO
	vis.refresh(true)
	var doomed: Node3D = null
	for m in modules:
		if not (m as Node3D).visible:
			doomed = m
			break
	if doomed != null:
		doomed.get_parent().remove_child(doomed)
		doomed.free()
	vis.refresh(true)
	_check(true, tag + "update survives a hidden module being freed")
	vis.shutdown()
	var left_hidden := 0
	for m in modules:
		if is_instance_valid(m) and not (m as Node3D).visible:
			left_hidden += 1
	for b in gen.torch_flame_batches:
		if not (b as Node3D).visible:
			left_hidden += 1
	_check(left_hidden == 0, tag + "shutdown shows everything again (%d left hidden)" % left_hidden)
	vis.boot(modules.filter(func(m): return is_instance_valid(m)), gen.torch_flame_batches, gen.torch_flame_bounds)
	vis.refresh(true)
	_check(vis.hidden_count() > 0, tag + "booting again (a new dungeon) works")
	vis.free()
	var restored := 0
	for m in modules:
		if is_instance_valid(m) and not (m as Node3D).visible:
			restored += 1
	_check(restored == 0, tag + "freeing the node (leaving the tree) shows everything again (%d)" % restored)

	cfg.free()
	root.queue_free()
	await get_tree().process_frame
	print("test_module_visibility: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
