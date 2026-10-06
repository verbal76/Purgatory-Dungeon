extends Node
## Developer tool (not shipped logic): regenerates data/floor_mesh_repairs.json, the repair list that
## scripts/floor_mesh_repair.gd applies to the module meshes at load time.
##
## What the list contains, per module scene -> mesh node -> surface:
##   "drop": triangle numbers (index buffer position / 3) of FLOOR triangles that are wound downward, lie in the
##           same plane as an upward-wound floor triangle and are completely covered by upward-wound floor
##           triangles. They are the back layer of a double-sided floor: never visible from above, but drawn in
##           the very same plane as the visible floor with a different (grey underside) texture, so the depth test
##           between the two layers is a coin flip that changes with view angle and GPU (z-fighting).
##   "snap": [vertex index, x, y, z] in mesh space: floor vertices a millimetre off their neighbours (the 1 mm slit
##           in the square rooms) moved onto the majority position of the neighbourhood.
## Run (with a save root like the tests):
##   PURGATORY_SAVE_ROOT=/tmp/x godot --headless --path . res://tools/floor_mesh_repair_tool.tscn
## Every drop is validated: a dense barycentric grid over the dropped triangle must be covered by kept upward-wound
## floor triangles of the same plane, otherwise it is kept.

const MAIN_SCENE := "res://scenes/Purgatory_Dungeon_main_game_file.tscn"
const OUT_PATH := "res://data/floor_mesh_repairs.json"
const CELL := 2.0
const PLANE_TOL := 0.002
const SNAP_MAX := 0.002


func _ready() -> void:
	var cfg: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	var scenes: Array = [cfg.starter_module]
	scenes.append_array(cfg.branch_modules)
	scenes.append(cfg.room_connector_module)
	scenes.append(cfg.end_cap_module)
	var out := {"version": 1, "scenes": {}}
	var seen := {}
	var total_drop := 0
	var total_snap := 0
	for sc in scenes:
		var path: String = (sc as PackedScene).resource_path
		if seen.has(path):
			continue
		seen[path] = true
		var inst: Node3D = (sc as PackedScene).instantiate()
		add_child(inst)
		var entry := _scene_repairs(inst)
		inst.queue_free()
		var dn := 0
		var sn := 0
		for node_path in entry:
			for s in entry[node_path]:
				dn += (entry[node_path][s]["drop"] as Array).size()
				sn += (entry[node_path][s]["snap"] as Array).size()
		if not entry.is_empty():
			out["scenes"][path] = entry
		total_drop += dn
		total_snap += sn
		print("REPAIR %-60s drop=%d snap=%d" % [path.get_file(), dn, sn])
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT_PATH), FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "", false))
	f.close()
	print("REPAIR total drop=%d snap=%d -> %s" % [total_drop, total_snap, OUT_PATH])
	get_tree().quit()


## node path (relative to the scene root) -> {surface: {"drop": [...], "snap": [...]}}
func _scene_repairs(inst: Node3D) -> Dictionary:
	# 1. collect surfaces
	var surfs: Array = []   # {path, surface, xf, verts(local, snapped), idx, node}
	for n in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf: Transform3D = inst.global_transform.affine_inverse() * mi.global_transform
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if idx.is_empty():
				continue
			surfs.append({"path": str(inst.get_path_to(mi)), "surface": s, "xf": xf, "verts": vs.duplicate(), "orig": vs, "idx": idx, "snap": [], "mesh": mi.mesh, "uvs": arr[Mesh.ARRAY_TEX_UV], "img": _albedo_image(mi, s)})
	# 2. snap pass: floor vertices (y ~ 0) a few mm off a larger cluster
	var clusters := {}   # key -> [count, Vector3 position module space]
	for sf in surfs:
		var xf: Transform3D = sf["xf"]
		var vs: PackedVector3Array = sf["verts"]
		var seen_v := {}
		var idx: PackedInt32Array = sf["idx"]
		for t in idx.size() / 3:
			var wv: Array[Vector3] = [xf * vs[idx[t * 3]], xf * vs[idx[t * 3 + 1]], xf * vs[idx[t * 3 + 2]]]
			if not _is_floor_flat(wv):
				continue
			for k in 3:
				var vi: int = idx[t * 3 + k]
				if seen_v.has(vi):
					continue
				seen_v[vi] = true
				var p: Vector3 = wv[k]
				if absf(p.y) > 0.001:
					continue
				var key := _ck(p)
				if clusters.has(key):
					clusters[key][0] += 1
				else:
					clusters[key] = [1, p]
	for sf in surfs:
		var xf: Transform3D = sf["xf"]
		var inv: Transform3D = xf.affine_inverse()
		var vs: PackedVector3Array = sf["verts"]
		var idx: PackedInt32Array = sf["idx"]
		var done := {}
		for t in idx.size() / 3:
			var wv: Array[Vector3] = [xf * vs[idx[t * 3]], xf * vs[idx[t * 3 + 1]], xf * vs[idx[t * 3 + 2]]]
			if not _is_floor_flat(wv):
				continue
			for k in 3:
				var vi: int = idx[t * 3 + k]
				if done.has(vi):
					continue
				done[vi] = true
				var p: Vector3 = wv[k]
				if absf(p.y) > 0.001:
					continue
				var mine: Array = clusters[_ck(p)]
				var best: Array = []
				var best_d := SNAP_MAX + 1.0
				for dx in range(-3, 4):
					for dz in range(-3, 4):
						var q := Vector3(p.x + float(dx) * 0.0005, 0.0, p.z + float(dz) * 0.0005)
						var key := _ck(q)
						if not clusters.has(key) or key == _ck(p):
							continue
						var c: Array = clusters[key]
						var d := Vector2(c[1].x - p.x, c[1].z - p.z).length()
						if d > 0.00005 and d <= SNAP_MAX and int(c[0]) > int(mine[0]) and d < best_d:
							best = c
							best_d = d
				if not best.is_empty():
					var target := Vector3(best[1].x, p.y, best[1].z)
					var lp: Vector3 = inv * target
					vs[vi] = lp
					(sf["snap"] as Array).append([vi, snappedf(lp.x, 0.0001), snappedf(lp.y, 0.0001), snappedf(lp.z, 0.0001)])
	# 3. every floor triangle of the module (all meshes), indexed on a grid
	var tris: Array = []   # {sf, t, a, b, c, y, up, img, ua, ub, uc, dropped}
	var grid := {}
	for si in surfs.size():
		var sf: Dictionary = surfs[si]
		var xf: Transform3D = sf["xf"]
		var vs: PackedVector3Array = sf["verts"]
		var idx: PackedInt32Array = sf["idx"]
		var uvs = sf["uvs"]
		var img: Image = sf["img"]
		for t in idx.size() / 3:
			var a: Vector3 = xf * vs[idx[t * 3]]
			var b: Vector3 = xf * vs[idx[t * 3 + 1]]
			var c: Vector3 = xf * vs[idx[t * 3 + 2]]
			if not _is_floor_flat([a, b, c]):
				continue
			var ti := tris.size()
			var ua := Vector2.ZERO
			var ub := Vector2.ZERO
			var uc := Vector2.ZERO
			if uvs != null:
				ua = uvs[idx[t * 3]]
				ub = uvs[idx[t * 3 + 1]]
				uc = uvs[idx[t * 3 + 2]]
			tris.append({"sf": si, "t": t, "a": a, "b": b, "c": c, "y": (a.y + b.y + c.y) / 3.0, "up": (b - a).cross(c - a).y < 0.0, "img": img, "ua": ua, "ub": ub, "uc": uc, "dropped": false})
			var lo := Vector2i(int(floorf(minf(a.x, minf(b.x, c.x)) / CELL)), int(floorf(minf(a.z, minf(b.z, c.z)) / CELL)))
			var hi := Vector2i(int(floorf(maxf(a.x, maxf(b.x, c.x)) / CELL)), int(floorf(maxf(a.z, maxf(b.z, c.z)) / CELL)))
			for gx in range(lo.x, hi.x + 1):
				for gz in range(lo.y, hi.y + 1):
					var k := Vector2i(gx, gz)
					if grid.has(k):
						(grid[k] as Array).append(ti)
					else:
						grid[k] = [ti]
	# 4a. back layer: downward-wound triangles completely covered by upward-wound ones (any texture: the upward
	#     layer is the one seen from above)
	for f in tris:
		if f["up"]:
			continue
		if _all_samples(f, func(p: Vector3) -> bool: return _covered_by(grid, tris, p, f, true, false)):
			f["dropped"] = true
	# 4b. stacked tiles: any floor triangle completely covered by ONE other kept floor triangle of (nearly) the same
	#     colour in the same plane (one triangle, not a union: a union can hide a millimetre gap between its parts). Downward-wound ones first. Coplanar layers of the same colour are invisible
	#     duplicates that only z-fight; the kept layer shows exactly the colour of the dropped one.
	for pass_up in [false, true]:
		for f in tris:
			if f["dropped"] or f["up"] != pass_up:
				continue
			if _single_cover(grid, tris, f):
				f["dropped"] = true
	var result := {}
	var drops := {}
	for f in tris:
		if f["dropped"]:
			if not drops.has(f["sf"]):
				drops[f["sf"]] = []
			drops[f["sf"]].append(f["t"])
	for si in surfs.size():
		var sf: Dictionary = surfs[si]
		var drop: Array = drops.get(si, [])
		if not drop.is_empty() or not (sf["snap"] as Array).is_empty():
			if not result.has(sf["path"]):
				result[sf["path"]] = {}
			result[sf["path"]][str(sf["surface"])] = {"drop": drop, "snap": sf["snap"]}
	# a mesh resource used by several nodes (different transforms): keep only what is safe for all of them
	var by_mesh := {}
	for sf in surfs:
		var key := "%d:%d" % [(sf["mesh"] as Mesh).get_instance_id(), sf["surface"]]
		if not by_mesh.has(key):
			by_mesh[key] = []
		by_mesh[key].append(sf)
	for key in by_mesh:
		var group: Array = by_mesh[key]
		if group.size() < 2:
			continue
		var counts := {}
		var snap_sigs := {}
		for sf in group:
			var entry: Dictionary = (result.get(sf["path"], {}) as Dictionary).get(str(sf["surface"]), {"drop": [], "snap": []})
			for t in entry["drop"]:
				counts[t] = int(counts.get(t, 0)) + 1
			snap_sigs[JSON.stringify(entry["snap"])] = true
		var common: Array = []
		for t in counts:
			if int(counts[t]) == group.size():
				common.append(t)
		common.sort()
		var keep_snap: bool = snap_sigs.size() == 1
		for sf in group:
			var surf_key := str(sf["surface"])
			var snap_list: Array = []
			if keep_snap and result.has(sf["path"]) and result[sf["path"]].has(surf_key):
				snap_list = result[sf["path"]][surf_key]["snap"]
			if common.is_empty() and snap_list.is_empty():
				if result.has(sf["path"]):
					(result[sf["path"]] as Dictionary).erase(surf_key)
					if (result[sf["path"]] as Dictionary).is_empty():
						result.erase(sf["path"])
				continue
			if not result.has(sf["path"]):
				result[sf["path"]] = {}
			result[sf["path"]][surf_key] = {"drop": common, "snap": snap_list}
	return result


func _ck(p: Vector3) -> String:
	return "%d,%d" % [int(roundf(p.x * 100000.0)), int(roundf(p.z * 100000.0))]


## flat, near-vertical-normal floor triangle at y in [-0.05, 0.3]
func _is_floor_flat(v: Array) -> bool:
	var a: Vector3 = v[0]
	var b: Vector3 = v[1]
	var c: Vector3 = v[2]
	if maxf(a.y, maxf(b.y, c.y)) > 0.3 or minf(a.y, minf(b.y, c.y)) < -0.05:
		return false
	var cr := (b - a).cross(c - a)
	var ln := cr.length()
	return ln > 1e-9 and absf(cr.y) / ln > 0.99


const SAMPLES := 8


## A single kept triangle (same plane, similar texel) that covers every sample point of f.
func _single_cover(grid: Dictionary, tris: Array, f: Dictionary) -> bool:
	var a: Vector3 = f["a"]
	var b: Vector3 = f["b"]
	var c: Vector3 = f["c"]
	var cen := (a + b + c) / 3.0
	var k := Vector2i(int(floorf(cen.x / CELL)), int(floorf(cen.z / CELL)))
	for ti in (grid.get(k, []) as Array):
		var g: Dictionary = tris[ti]
		if g == f or g["dropped"] or absf(float(g["y"]) - float(f["y"])) > PLANE_TOL:
			continue
		var ok := true
		for i in SAMPLES + 1:
			for j in SAMPLES + 1 - i:
				var u: float = float(i) / float(SAMPLES)
				var v: float = float(j) / float(SAMPLES)
				var p: Vector3 = a + (b - a) * u + (c - a) * v
				if not _in_tri(g, p):
					ok = false
					break
				var oc := _color_at(g, p)
				var own := _color_at(f, p)
				if maxf(absf(oc.r - own.r), maxf(absf(oc.g - own.g), absf(oc.b - own.b))) > SIMILAR:
					ok = false
					break
			if not ok:
				break
		if ok:
			return true
	return false


func _in_tri(g: Dictionary, p: Vector3) -> bool:
	var a: Vector3 = g["a"]
	var b: Vector3 = g["b"]
	var c: Vector3 = g["c"]
	var d1 := (p.x - b.x) * (a.z - b.z) - (a.x - b.x) * (p.z - b.z)
	var d2 := (p.x - c.x) * (b.z - c.z) - (b.x - c.x) * (p.z - c.z)
	var d3 := (p.x - a.x) * (c.z - a.z) - (c.x - a.x) * (p.z - a.z)
	var neg := d1 < -1e-7 or d2 < -1e-7 or d3 < -1e-7
	var pos := d1 > 1e-7 or d2 > 1e-7 or d3 > 1e-7
	return not (neg and pos)
const SIMILAR := 0.08
var _images := {}


func _albedo_image(mi: MeshInstance3D, surface: int) -> Image:
	var mat := mi.get_active_material(surface)
	if mat is BaseMaterial3D and (mat as BaseMaterial3D).albedo_texture != null:
		var tp: String = (mat as BaseMaterial3D).albedo_texture.resource_path
		if not _images.has(tp):
			_images[tp] = Image.load_from_file(ProjectSettings.globalize_path(tp))
		return _images[tp]
	return null


func _all_samples(f: Dictionary, covered: Callable) -> bool:
	var a: Vector3 = f["a"]
	var b: Vector3 = f["b"]
	var c: Vector3 = f["c"]
	for i in SAMPLES:
		for j in SAMPLES - i:
			var u: float = (float(i) + 0.3) / float(SAMPLES)
			var v: float = (float(j) + 0.3) / float(SAMPLES)
			if not covered.call(a + (b - a) * u + (c - a) * v):
				return false
	return true


func _color_at(g: Dictionary, p: Vector3) -> Color:
	var img: Image = g["img"]
	if img == null:
		return Color(0, 0, 0)
	var a: Vector3 = g["a"]
	var v0: Vector3 = (g["b"] as Vector3) - a
	var v1: Vector3 = (g["c"] as Vector3) - a
	var v2: Vector3 = p - a
	var d00 := v0.dot(v0)
	var d01 := v0.dot(v1)
	var d11 := v1.dot(v1)
	var d20 := v2.dot(v0)
	var d21 := v2.dot(v1)
	var den := d00 * d11 - d01 * d01
	if absf(den) < 1e-12:
		return Color(0, 0, 0)
	var bv := (d11 * d20 - d01 * d21) / den
	var cv := (d00 * d21 - d01 * d20) / den
	var uv: Vector2 = (g["ua"] as Vector2) * (1.0 - bv - cv) + (g["ub"] as Vector2) * bv + (g["uc"] as Vector2) * cv
	return img.get_pixel(clampi(int(uv.x * img.get_width()), 0, img.get_width() - 1), clampi(int(uv.y * img.get_height()), 0, img.get_height() - 1))


## Is p covered (inclusive, same plane within PLANE_TOL) by a kept triangle other than `self_t`? only_up: only
## upward-wound candidates; similar: the candidate's texel at p must match self_t's within SIMILAR.
func _covered_by(grid: Dictionary, tris: Array, p: Vector3, self_t: Dictionary, only_up: bool, similar: bool) -> bool:
	var k := Vector2i(int(floorf(p.x / CELL)), int(floorf(p.z / CELL)))
	var own := Color(0, 0, 0)
	if similar:
		own = _color_at(self_t, p)
	for ti in (grid.get(k, []) as Array):
		var u: Dictionary = tris[ti]
		if u == self_t or u["dropped"] or (only_up and not u["up"]):
			continue
		if absf(float(u["y"]) - float(self_t["y"])) > PLANE_TOL:
			continue
		var a: Vector3 = u["a"]
		var b: Vector3 = u["b"]
		var c: Vector3 = u["c"]
		var d1 := (p.x - b.x) * (a.z - b.z) - (a.x - b.x) * (p.z - b.z)
		var d2 := (p.x - c.x) * (b.z - c.z) - (b.x - c.x) * (p.z - c.z)
		var d3 := (p.x - a.x) * (c.z - a.z) - (c.x - a.x) * (p.z - a.z)
		var neg := d1 < -1e-7 or d2 < -1e-7 or d3 < -1e-7
		var pos := d1 > 1e-7 or d2 > 1e-7 or d3 > 1e-7
		if neg and pos:
			continue
		if similar:
			var oc := _color_at(u, p)
			if maxf(absf(oc.r - own.r), maxf(absf(oc.g - own.g), absf(oc.b - own.b))) > SIMILAR:
				continue
		return true
	return false
