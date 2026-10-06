extends Node
## Floor seams: nothing may be see-through where two pieces of dungeon floor meet.
##
## Owner report (physical Pixel play): thin cracks across otherwise continuous floors. Cause: two hand-placed
## floor pieces in the module scenes were off the 4 m grid, one row of six tiles of the 24 m wide hall by 3 cm
## (a slot across the whole hall) and the end tile of a corridor by 3 cm in height (a lip: from eye level the
## lower floor ended under it and a hairline of void showed through). They show as a one pixel line at a
## distance, which is why they came and went with the camera.
##
## Part A  (every module scene, local space, no generator): the base floor (flat faces at y = 0) must not have
##         a gap between neighbouring tiles, and no floor tile may float above or sink below y = 0.
## Part B  (several generated dungeons): at every doorway the base floors of the two modules must meet without
##         a gap, the doorway markers must sit exactly one connection_nudge apart (sub-millimetre snapping) and
##         every module must be turned by an exact multiple of 90 degrees.
## Pure geometry, headless, ~20 s. Needs PURGATORY_SAVE_ROOT like the other tests (the main scene is read for
## its exported settings).

const MAIN_SCENE := "res://scenes/Purgatory_Dungeon_main_game_file.tscn"
const GEN_SCENE := "res://scenes/dungeon_generation_function.tscn"
const SEEDS : Array[int] = [3, 11, 29, 101, 2024, 777]
## Triangles whose three corners are within this of y = 0 are the "base floor".
const BASE_Y : float = 0.002
const CELL : float = 2.0
## A gap between two floor tiles narrower than this (and wider than TOUCH) is a crack.
const MAX_CRACK : float = 0.25
const TOUCH : float = 0.0002

var _fails : int = 0
var _checks : int = 0
## scene path -> {"a": PackedVector3Array, "b": ..., "c": ..., "grid": {Vector2i: Array[int]}}
var _scene_geo : Dictionary = {}
## The end cap / wall plug: a wall in the doorway, it has no floor of its own beyond its marker.
var _cap_path : String = ""


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	var t0 : int = Time.get_ticks_msec()
	var cfg : Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	_cap_path = (cfg.end_cap_module as PackedScene).resource_path
	var scenes : Array[PackedScene] = [cfg.starter_module]
	for s in cfg.branch_modules:
		scenes.append(s)
	scenes.append(cfg.room_connector_module)
	scenes.append(cfg.end_cap_module)

	# ── Part A ───────────────────────────────────────────────────────────────
	var seen : Dictionary = {}
	for sc in scenes:
		if seen.has(sc.resource_path):
			continue
		seen[sc.resource_path] = true
		var inst : Node3D = sc.instantiate()
		add_child(inst)
		var tiles : Array = _scene_floor(inst)
		var gaps : Array[String] = _tile_gaps(tiles, sc.resource_path)
		for g in gaps:
			_check(false, g)
		var floating : Array[String] = _floating_tiles(inst)
		for f in floating:
			_check(false, "%s: %s" % [sc.resource_path.get_file(), f])
		_check(true, "%s audited (%d floor tiles)" % [sc.resource_path.get_file(), tiles.size()])
		inst.queue_free()
	print("  part A: %d module scenes audited" % seen.size())

	# ── Part B ───────────────────────────────────────────────────────────────
	var doors_total : int = 0
	var cracks_total : int = 0
	var worst_lateral : float = 0.0
	var worst_normal : float = 0.0
	var worst_yaw : float = 0.0
	for sd in SEEDS:
		var root := Node3D.new()
		add_child(root)
		var gen : Node = (load(GEN_SCENE) as PackedScene).instantiate()
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
		seed(sd)
		var result : Dictionary = gen.generate_dungeon()
		_check(bool(result.get("success", false)), "seed %d: generation succeeds" % sd)
		var stats : Dictionary = _check_doors(gen, sd, float(cfg.connection_nudge))
		doors_total += int(stats["doors"])
		cracks_total += int(stats["cracks"])
		worst_lateral = maxf(worst_lateral, float(stats["lateral"]))
		worst_normal = maxf(worst_normal, float(stats["normal"]))
		worst_yaw = maxf(worst_yaw, float(stats["yaw"]))
		print("  seed %d: %d modules, %d doorways, floor cracks at doorways %d, marker error lateral %.6f m / along %.6f m, yaw error %.8f rad" % [
			sd, gen.placed_modules.size(), stats["doors"], stats["cracks"], stats["lateral"], stats["normal"], stats["yaw"]])
		for c in root.get_children():
			c.queue_free()
		root.queue_free()
		await get_tree().process_frame
	print("  part B: %d doorways over %d seeds, %d floor cracks; worst marker error lateral %.6f m, along %.6f m, yaw %.8f rad" % [
		doors_total, SEEDS.size(), cracks_total, worst_lateral, worst_normal, worst_yaw])
	print("floor seams: %d checks, %d failed, %d ms" % [_checks, _fails, Time.get_ticks_msec() - t0])
	cfg.free()
	get_tree().quit(1 if _fails > 0 else 0)


# ══════════════════════════════════════════════════════════════════════════════
#  Geometry helpers
# ══════════════════════════════════════════════════════════════════════════════

## Base-floor tiles of a module instance in the module's own space. One entry per mesh that has base-floor faces:
## {"name", "minx", "maxx", "minz", "maxz", "top", "bottom"}.
func _scene_floor(inst: Node3D) -> Array:
	var tiles : Array = []
	var stack : Array = [inst]
	while not stack.is_empty():
		var n : Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is MeshInstance3D) or (n as MeshInstance3D).mesh == null:
			continue
		var mi : MeshInstance3D = n as MeshInstance3D
		var xf : Transform3D = inst.global_transform.affine_inverse() * mi.global_transform
		var faces : PackedVector3Array = mi.mesh.get_faces()
		var mn := Vector2(1e9, 1e9)
		var mx := Vector2(-1e9, -1e9)
		var cnt : int = 0
		var i : int = 0
		while i + 2 < faces.size():
			var a : Vector3 = xf * faces[i]
			var b : Vector3 = xf * faces[i + 1]
			var c2 : Vector3 = xf * faces[i + 2]
			i += 3
			if _is_base(a, b, c2):
				cnt += 1
				for v in [a, b, c2]:
					mn = mn.min(Vector2(v.x, v.z))
					mx = mx.max(Vector2(v.x, v.z))
		if cnt > 0:
			tiles.append({"name": String(mi.name), "minx": mn.x, "maxx": mx.x, "minz": mn.y, "maxz": mx.y})
	return tiles


func _is_base(a: Vector3, b: Vector3, c: Vector3) -> bool:
	if absf(a.y) > BASE_Y or absf(b.y) > BASE_Y or absf(c.y) > BASE_Y:
		return false
	# a floor-level triangle that is not a sliver
	return absf((b - a).cross(c - a).y) > 1e-9


## Floor pieces (not walls) whose top face floats above or sinks below the floor plane: the biggest flat upward
## face of every non-wall mesh must lie on y = 0.
func _floating_tiles(inst: Node3D) -> Array[String]:
	var out : Array[String] = []
	var stack : Array = [inst]
	while not stack.is_empty():
		var n : Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is MeshInstance3D) or (n as MeshInstance3D).mesh == null:
			continue
		var mi : MeshInstance3D = n as MeshInstance3D
		var nm : String = String(mi.name).to_lower()
		if nm.contains("wall") or nm.begins_with("template-corner") or nm.begins_with("room-corner"):
			continue
		var xf : Transform3D = inst.global_transform.affine_inverse() * mi.global_transform
		var faces : PackedVector3Array = mi.mesh.get_faces()
		var best_area : float = 0.0
		var best_y : float = 0.0
		var flat_low : bool = false
		var i : int = 0
		while i + 2 < faces.size():
			var a : Vector3 = xf * faces[i]
			var b : Vector3 = xf * faces[i + 1]
			var c2 : Vector3 = xf * faces[i + 2]
			i += 3
			var cr : Vector3 = (b - a).cross(c2 - a)
			var ln : float = cr.length()
			if ln < 1e-9 or absf(cr.y) / ln < 0.999 or maxf(a.y, maxf(b.y, c2.y)) > 0.3 or minf(a.y, minf(b.y, c2.y)) < -0.3:
				continue
			if maxf(absf(a.y - b.y), absf(a.y - c2.y)) > 1e-4:
				continue
			if absf(a.y) <= BASE_Y:
				flat_low = true
			if cr.y < 0.0 and ln * 0.5 > best_area:   # faces seen from above (clockwise from above in Godot)
				best_area = ln * 0.5
				best_y = a.y
		# a big floor-level face that is not on the plane: a tile 3 cm above or below the floor
		if best_area > 1.0 and absf(best_y) > BASE_Y and not flat_low:
			out.append("floor tile '%s' lies at y = %.4f (must be 0)" % [mi.name, best_y])
	return out


## Pairs of base-floor tiles that face each other across a gap of TOUCH..MAX_CRACK with the gap really open.
func _tile_gaps(tiles: Array, scene_path: String) -> Array[String]:
	var out : Array[String] = []
	var geo : Dictionary = _geo_for_scene(scene_path)
	for i in tiles.size():
		for j in tiles.size():
			if i == j:
				continue
			var ti : Dictionary = tiles[i]
			var tj : Dictionary = tiles[j]
			for axis in 2:
				var kmin : String = "minx" if axis == 0 else "minz"
				var kmax : String = "maxx" if axis == 0 else "maxz"
				var omin_k : String = "minz" if axis == 0 else "minx"
				var omax_k : String = "maxz" if axis == 0 else "maxx"
				var g : float = float(tj[kmin]) - float(ti[kmax])
				if g < TOUCH or g > MAX_CRACK:
					continue
				var lo : float = maxf(float(ti[omin_k]), float(tj[omin_k]))
				var hi : float = minf(float(ti[omax_k]), float(tj[omax_k]))
				if hi - lo < 0.5:
					continue
				var q : float = lo + 0.125
				while q < hi:
					var m : float = float(ti[kmax]) + g * 0.5
					var px : float = m if axis == 0 else q
					var pz : float = q if axis == 0 else m
					if not _base_covered(geo, px, pz):
						out.append("%s: %.1f cm gap in the floor between tiles '%s' and '%s' (along %s at %s %.2f)" % [
							scene_path.get_file(), g * 100.0, ti["name"], tj["name"], "z" if axis == 0 else "x", "z" if axis == 0 else "x", q])
						break
					q += 0.25
	return out


## Base-floor triangles of a module scene in module space, indexed on a 2 m grid.
func _geo_for_scene(scene_path: String) -> Dictionary:
	if _scene_geo.has(scene_path):
		return _scene_geo[scene_path]
	var inst : Node3D = (load(scene_path) as PackedScene).instantiate()
	add_child(inst)
	var ta := PackedVector3Array()
	var tb := PackedVector3Array()
	var tc := PackedVector3Array()
	var grid : Dictionary = {}
	var stack : Array = [inst]
	while not stack.is_empty():
		var n : Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is MeshInstance3D) or (n as MeshInstance3D).mesh == null:
			continue
		var mi : MeshInstance3D = n as MeshInstance3D
		var xf : Transform3D = inst.global_transform.affine_inverse() * mi.global_transform
		var faces : PackedVector3Array = mi.mesh.get_faces()
		var i : int = 0
		while i + 2 < faces.size():
			var a : Vector3 = xf * faces[i]
			var b : Vector3 = xf * faces[i + 1]
			var c2 : Vector3 = xf * faces[i + 2]
			i += 3
			if not _is_base(a, b, c2):
				continue
			var idx : int = ta.size()
			ta.append(a)
			tb.append(b)
			tc.append(c2)
			var lo := Vector2i(int(floorf(minf(a.x, minf(b.x, c2.x)) / CELL)), int(floorf(minf(a.z, minf(b.z, c2.z)) / CELL)))
			var hi := Vector2i(int(floorf(maxf(a.x, maxf(b.x, c2.x)) / CELL)), int(floorf(maxf(a.z, maxf(b.z, c2.z)) / CELL)))
			for gx in range(lo.x, hi.x + 1):
				for gz in range(lo.y, hi.y + 1):
					var k := Vector2i(gx, gz)
					if grid.has(k):
						(grid[k] as Array).append(idx)
					else:
						grid[k] = [idx]
	remove_child(inst)
	inst.free()
	var geo : Dictionary = {"a": ta, "b": tb, "c": tc, "grid": grid}
	_scene_geo[scene_path] = geo
	return geo


func _base_covered(geo: Dictionary, px: float, pz: float) -> bool:
	var k := Vector2i(int(floorf(px / CELL)), int(floorf(pz / CELL)))
	var grid : Dictionary = geo["grid"]
	if not grid.has(k):
		return false
	var ta : PackedVector3Array = geo["a"]
	var tb : PackedVector3Array = geo["b"]
	var tc : PackedVector3Array = geo["c"]
	for t in (grid[k] as Array):
		var a : Vector3 = ta[t]
		var b : Vector3 = tb[t]
		var c : Vector3 = tc[t]
		var d1 : float = (px - b.x) * (a.z - b.z) - (a.x - b.x) * (pz - b.z)
		var d2 : float = (px - c.x) * (b.z - c.z) - (b.x - c.x) * (pz - c.z)
		var d3 : float = (px - a.x) * (c.z - a.z) - (c.x - a.x) * (pz - a.z)
		var neg : bool = d1 < -1e-9 or d2 < -1e-9 or d3 < -1e-9
		var pos : bool = d1 > 1e-9 or d2 > 1e-9 or d3 > 1e-9
		if not (neg and pos):
			return true
	return false


## True when the base floor of module `m` (placed) covers the world XZ point.
func _module_covers(m: Node3D, inv: Transform3D, px: float, pz: float) -> bool:
	var geo : Dictionary = _geo_for_scene(m.scene_file_path)
	var lp : Vector3 = inv * Vector3(px, 0.0, pz)
	return _base_covered(geo, lp.x, lp.z)


# ══════════════════════════════════════════════════════════════════════════════
#  Part B: doorways of a generated dungeon
# ══════════════════════════════════════════════════════════════════════════════

func _check_doors(gen: Node, seed_value: int, nudge: float) -> Dictionary:
	var mods : Array = gen.placed_modules
	var conns : Array = []   # [module, marker]
	var worst_yaw : float = 0.0
	for m in mods:
		if not is_instance_valid(m) or (m as Node3D).scene_file_path == "":
			continue
		var b : Basis = (m as Node3D).global_basis
		# every module is turned by an exact multiple of 90 degrees (the generator aligns by atan2 of axes)
		var yaw_err : float = minf(minf(absf(b.x.x), absf(b.x.z)), 1.0)
		yaw_err = minf(absf(b.x.y), 1.0) + yaw_err
		worst_yaw = maxf(worst_yaw, yaw_err)
		for c in gen.get_module_connections(m):
			conns.append([m, c])
	_check(worst_yaw < 1e-4, "seed %d: every module is turned by an exact multiple of 90 degrees (error %.8f)" % [seed_value, worst_yaw])
	var doors : int = 0
	var cracks : int = 0
	var worst_lat : float = 0.0
	var worst_nrm : float = 0.0
	var used : Dictionary = {}
	for i in conns.size():
		if used.has(i):
			continue
		var ci : Node3D = conns[i][1]
		for j in range(i + 1, conns.size()):
			if used.has(j) or conns[i][0] == conns[j][0]:
				continue
			var cj : Node3D = conns[j][1]
			var d : Vector3 = ci.global_position - cj.global_position
			if Vector2(d.x, d.z).length() > 0.25 or absf(d.y) > 0.05:
				continue
			used[i] = true
			used[j] = true
			doors += 1
			var nrm : Vector3 = ci.global_basis.z
			nrm.y = 0.0
			nrm = nrm.normalized()
			var tgt : Vector3 = Vector3(-nrm.z, 0.0, nrm.x)
			var sep : Vector3 = cj.global_position - ci.global_position
			var sep_n : float = sep.dot(nrm)
			var sep_t : float = sep.dot(tgt)
			worst_nrm = maxf(worst_nrm, absf(sep_n + nudge))
			worst_lat = maxf(worst_lat, absf(sep_t))
			worst_lat = maxf(worst_lat, absf(sep.y))
			var open : int = _door_uncovered(conns[i][0], conns[j][0], ci, cj, nrm, tgt)
			if open > 0:
				cracks += 1
				var key : String = "%s <-> %s" % [(conns[i][0] as Node3D).scene_file_path.get_file(), (conns[j][0] as Node3D).scene_file_path.get_file()]
				if OS.get_environment("SEAMDEBUG") != "":
					print("   OPEN ", key, " samples=", open, " at ", ci.global_position)
				_check(false, "seed %d: floor crack at the doorway %s near (%.2f, %.2f), %d of 155 samples open" % [
					seed_value, key, ci.global_position.x, ci.global_position.z, open])
			break
	_check(worst_nrm < 0.001, "seed %d: doorway markers sit one connection_nudge apart (error %.6f m)" % [seed_value, worst_nrm])
	_check(worst_lat < 0.001, "seed %d: doorway markers line up sideways and in height (error %.6f m)" % [seed_value, worst_lat])
	_check(doors > 50, "seed %d: the dungeon has doorways to check (%d)" % [seed_value, doors])
	return {"doors": doors, "cracks": cracks, "lateral": worst_lat, "normal": worst_nrm, "yaw": worst_yaw}


## Uncovered base-floor samples across the doorway: the central 3.2 m, +-0.3 m along the walking direction (s = 0 is
## half way between the two markers; the first module's marker is at s = +nudge/2, the second one's at -nudge/2). The
## base floors of the two modules together must cover all of it: the second module is nudged into the first, so they
## overlap by a few centimetres instead of leaving a slot, or ending in a lip (a floor that starts a few centimetres
## above the other one lets eye-level rays pass under its edge). A module without any floor (the end cap is just a
## wall) only has to be backed by the other module's floor up to its own marker.
func _door_uncovered(ma: Node3D, mb: Node3D, ca: Node3D, cb: Node3D, nrm: Vector3, tgt: Vector3) -> int:
	var inv_a : Transform3D = ma.global_transform.affine_inverse()
	var inv_b : Transform3D = mb.global_transform.affine_inverse()
	var mid : Vector3 = (ca.global_position + cb.global_position) * 0.5
	var s_lo : float = -0.3
	var s_hi : float = 0.3
	if mb.scene_file_path == _cap_path or (_geo_for_scene(mb.scene_file_path)["a"] as PackedVector3Array).is_empty():
		s_hi = 0.0
	elif ma.scene_file_path == _cap_path or (_geo_for_scene(ma.scene_file_path)["a"] as PackedVector3Array).is_empty():
		s_lo = 0.0
	var open : int = 0
	for ti in 5:
		var t : float = -1.6 + 0.8 * float(ti)
		for si in 31:
			var s : float = -0.3 + 0.02 * float(si)
			if s < s_lo - 0.0001 or s > s_hi + 0.0001:
				continue
			var px : float = mid.x + tgt.x * t + nrm.x * s
			var pz : float = mid.z + tgt.z * t + nrm.z * s
			if not (_module_covers(ma, inv_a, px, pz) or _module_covers(mb, inv_b, px, pz)):
				open += 1
				if OS.get_environment("SEAMDEBUG") != "" and open < 4:
					print("      open sample t=%.2f s=%.2f  a-local=%s" % [t, s, str(inv_a * Vector3(px, 0.0, pz))])
	return open
