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
##   "add":  [source triangle, u0, v0, u1, v1, u2, v2]: pieces of a floor triangle that another tile partly overlaps
##           in the same plane. The triangle itself is in "drop"; the piece (barycentric corners in the source
##           triangle, so position, normal, tangent and uv are interpolated) is the part outside the winning tile.
##           The earlier surface wins (surfaces whose mesh is shared by several nodes always win), the winner is
##           shrunk by 1.5 mm so the piece still overlaps it by 1.5 mm (watertight), overlaps thinner than 2.7 mm
##           (the intentional seam overlaps) are left alone. This removes the depth tie between stacked off-grid
##           floor tiles (template rooms) that a GPU resolves differently from view to view.
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
const SNAP_MAX := 0.0012   # below the 1.5 mm clip margin: vertices created by the clipping are never snapped


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
	# a mesh resource used by several nodes cannot be clipped per node: such surfaces win every overlap
	var mesh_uses := {}
	for sf in surfs:
		var mk := "%d:%d" % [(sf["mesh"] as Mesh).get_instance_id(), sf["surface"]]
		mesh_uses[mk] = int(mesh_uses.get(mk, 0)) + 1
	for sf in surfs:
		var mk2 := "%d:%d" % [(sf["mesh"] as Mesh).get_instance_id(), sf["surface"]]
		sf["shared"] = int(mesh_uses[mk2]) > 1
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
			tris.append({"sf": si, "shared": sf["shared"], "rank": (0 if sf["shared"] else 1000000) + si, "t": t, "a": a, "b": b, "c": c, "y": (a.y + b.y + c.y) / 3.0, "up": (b - a).cross(c - a).y < 0.0, "img": img, "ua": ua, "ub": ub, "uc": uc, "dropped": false})
			var lo := Vector2i(int(floorf(minf(a.x, minf(b.x, c.x)) / CELL)), int(floorf(minf(a.z, minf(b.z, c.z)) / CELL)))
			var hi := Vector2i(int(floorf(maxf(a.x, maxf(b.x, c.x)) / CELL)), int(floorf(maxf(a.z, maxf(b.z, c.z)) / CELL)))
			for gx in range(lo.x, hi.x + 1):
				for gz in range(lo.y, hi.y + 1):
					var k := Vector2i(gx, gz)
					if grid.has(k):
						(grid[k] as Array).append(ti)
					else:
						grid[k] = [ti]
	# edges shared by two triangles of the same surface (the diagonal of a tile): not shrunk when clipping against
	# the tile, otherwise a 3 mm strip of the lower tile would survive along every diagonal
	var edge_count := {}
	for f in tris:
		var vv: Array = [f["a"], f["b"], f["c"]]
		for i in 3:
			var ek := _edge_key(int(f["sf"]), vv[i], vv[(i + 1) % 3])
			edge_count[ek] = int(edge_count.get(ek, 0)) + 1
	for f in tris:
		var vv2: Array = [f["a"], f["b"], f["c"]]
		var internal: Array = []
		for i in 3:
			internal.append(int(edge_count[_edge_key(int(f["sf"]), vv2[i], vv2[(i + 1) % 3])]) > 1)
		f["internal"] = internal
	# 4a. back layer: downward-wound triangles completely covered by upward-wound ones (any texture: the upward
	#     layer is the one seen from above)
	for f in tris:
		if f["up"] or f["shared"]:
			continue
		if _all_samples(f, func(p: Vector3) -> bool: return _covered_by(grid, tris, p, f, true, false)):
			f["dropped"] = true
	# 4b. stacked tiles: any floor triangle completely covered by ONE other kept floor triangle of (nearly) the same
	#     colour in the same plane (one triangle, not a union: a union can hide a millimetre gap between its parts). Downward-wound ones first. Coplanar layers of the same colour are invisible
	#     duplicates that only z-fight; the kept layer shows exactly the colour of the dropped one.
	for pass_up in [false, true]:
		for f in tris:
			if f["dropped"] or f["up"] != pass_up or f["shared"]:
				continue
			if _single_cover(grid, tris, f):
				f["dropped"] = true
	# 4c. stacked tiles that overlap only PARTLY (off-grid tiles laid over their neighbours): the earlier surface
	#     wins. The later triangle is replaced by the part of it that lies outside the winner, with the winner shrunk
	#     by CLIP_MARGIN, so the pieces still overlap the winner by 1.5 mm (watertight, no gap, and a 1.5 mm strip of
	#     tie is invisible). Overlaps thinner than MIN_OVERLAP are the intentional few-millimetre seam overlaps and
	#     are left alone. No vertex moves; the added pieces take position, normal, tangent and uv from the original.
	var new_pieces: Array = []
	for f in tris:
		if f["dropped"] or not f["up"] or f["shared"]:
			continue
		var pieces: Array = [_tri2(f)]
		var changed := false
		var seen_w := {}
		var fa: Vector3 = f["a"]
		var fb: Vector3 = f["b"]
		var fc: Vector3 = f["c"]
		var lo := Vector2i(int(floorf(minf(fa.x, minf(fb.x, fc.x)) / CELL)), int(floorf(minf(fa.z, minf(fb.z, fc.z)) / CELL)))
		var hi := Vector2i(int(floorf(maxf(fa.x, maxf(fb.x, fc.x)) / CELL)), int(floorf(maxf(fa.z, maxf(fb.z, fc.z)) / CELL)))
		for gx in range(lo.x, hi.x + 1):
			for gz in range(lo.y, hi.y + 1):
				for wi in (grid.get(Vector2i(gx, gz), []) as Array):
					if seen_w.has(wi):
						continue
					seen_w[wi] = true
					var w: Dictionary = tris[wi]
					if w["dropped"] or not w["up"] or int(w["sf"]) == int(f["sf"]) or int(w["rank"]) >= int(f["rank"]) or absf(float(w["y"]) - float(f["y"])) > CLIP_PLANE_TOL:
						continue
					var hp_full := _halfplanes(w, 0.0)
					if hp_full.is_empty():
						continue
					var ov := _clip_all(_tri2(f), hp_full)
					if not _thick(ov):
						continue
					var hp_shrunk := _halfplanes(w, CLIP_MARGIN)
					if hp_shrunk.is_empty():
						continue
					var next: Array = []
					for piece in pieces:
						var cut := _clip_all(piece, hp_shrunk)
						if _area(cut) < 1e-7:
							next.append(piece)   # does not reach beyond the 1.5 mm margin: nothing to cut
							continue
						changed = true
						var rest: Array = piece
						for h in hp_shrunk:
							var outside := _clip(rest, -(h[0] as Vector2), -float(h[1]))
							if _area(outside) > 1e-9:
								next.append(outside)
							rest = _clip(rest, h[0], float(h[1]))
					pieces = next
		if not changed:
			continue
		f["clipped"] = true
		var forient: float = signf((fb.x - fa.x) * (fc.z - fa.z) - (fb.z - fa.z) * (fc.x - fa.x))
		for piece in pieces:
			if _area(piece) < 1e-8 or piece.size() < 3 or not _wider_than(piece, 0.0003):
				continue   # slivers thinner than 0.3 mm lie inside the winner's 1.5 mm margin
			for k in range(1, piece.size() - 1):
				var pts: Array = [piece[0], piece[k], piece[k + 1]]
				var cr2: float = (pts[1].x - pts[0].x) * (pts[2].y - pts[0].y) - (pts[1].y - pts[0].y) * (pts[2].x - pts[0].x)
				if absf(cr2) * 0.5 < 1e-7:
					continue   # zero-area sliver of the fan triangulation
				var o: float = signf(cr2)
				if o != forient:
					pts = [pts[0], pts[2], pts[1]]
				var entry: Array = [f["t"]]
				var p3: Array = []
				var uv3: Array = []
				for q in pts:
					var bc := _bary(fa, fb, fc, q)
					entry.append(snappedf(bc.x, 0.0000001))
					entry.append(snappedf(bc.y, 0.0000001))
					p3.append(Vector3(q.x, f["y"], q.y))
					uv3.append((f["ua"] as Vector2) * (1.0 - bc.x - bc.y) + (f["ub"] as Vector2) * bc.x + (f["uc"] as Vector2) * bc.y)
				new_pieces.append({"sf": f["sf"], "shared": false, "rank": f["rank"], "t": -1, "a": p3[0], "b": p3[1], "c": p3[2], "y": f["y"], "up": true, "img": f["img"], "ua": uv3[0], "ub": uv3[1], "uc": uv3[2], "dropped": false, "piece": true, "entry": entry, "internal": [false, false, false]})
	# the pieces take part in the grid like any triangle; the clipped originals are gone
	for f in tris:
		if f.get("clipped", false):
			f["dropped"] = true
	for pc in new_pieces:
		var pi := tris.size()
		tris.append(pc)
		var pa: Vector3 = pc["a"]
		var pb: Vector3 = pc["b"]
		var pcc: Vector3 = pc["c"]
		var plo := Vector2i(int(floorf(minf(pa.x, minf(pb.x, pcc.x)) / CELL)), int(floorf(minf(pa.z, minf(pb.z, pcc.z)) / CELL)))
		var phi := Vector2i(int(floorf(maxf(pa.x, maxf(pb.x, pcc.x)) / CELL)), int(floorf(maxf(pa.z, maxf(pb.z, pcc.z)) / CELL)))
		for gx in range(plo.x, phi.x + 1):
			for gz in range(plo.y, phi.y + 1):
				var pk := Vector2i(gx, gz)
				if grid.has(pk):
					(grid[pk] as Array).append(pi)
				else:
					grid[pk] = [pi]
	# 4d. the pieces can newly cover a neighbour completely: repeat the duplicate pass until nothing changes, so the
	#     list is a fixed point (re-running the tool on the repaired meshes finds nothing left)
	for iter in 6:
		var again := false
		for pass_up in [false, true]:
			for f in tris:
				if f["dropped"] or f["up"] != pass_up or f["shared"]:
					continue
				if _single_cover(grid, tris, f):
					f["dropped"] = true
					again = true
		if not again:
			break
	var adds := {}   # surface index -> [[src tri, u0, v0, u1, v1, u2, v2], ...]
	for pc in new_pieces:
		if pc["dropped"]:
			continue
		if not adds.has(pc["sf"]):
			adds[pc["sf"]] = []
		adds[pc["sf"]].append(pc["entry"])
	var result := {}
	var drops := {}
	for f in tris:
		if (f["dropped"] or f.get("clipped", false)) and not f.get("piece", false):
			if not drops.has(f["sf"]):
				drops[f["sf"]] = []
			drops[f["sf"]].append(f["t"])
	for si in surfs.size():
		var sf: Dictionary = surfs[si]
		var drop: Array = drops.get(si, [])
		if not drop.is_empty() or not (sf["snap"] as Array).is_empty():
			if not result.has(sf["path"]):
				result[sf["path"]] = {}
			result[sf["path"]][str(sf["surface"])] = {"drop": drop, "snap": sf["snap"], "add": adds.get(si, [])}
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
		var add_src := {}
		for sf in group:
			var entry2: Dictionary = (result.get(sf["path"], {}) as Dictionary).get(str(sf["surface"]), {"add": []})
			for ad in entry2.get("add", []):
				add_src[int(ad[0])] = true
		var common: Array = []
		for t in counts:
			if int(counts[t]) == group.size() and not add_src.has(int(t)):
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
			result[sf["path"]][surf_key] = {"drop": common, "snap": snap_list, "add": []}
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
	return ln > 2e-7 and absf(cr.y) / ln > 0.99


const SAMPLES := 8


func _edge_key(sf: int, p: Vector3, q: Vector3) -> String:
	var a := "%d,%d" % [int(roundf(p.x * 10000.0)), int(roundf(p.z * 10000.0))]
	var b := "%d,%d" % [int(roundf(q.x * 10000.0)), int(roundf(q.z * 10000.0))]
	return "%d|%s|%s" % [sf, a, b] if a < b else "%d|%s|%s" % [sf, b, a]
const DEEP := 0.003


## Independent measure for the regression test: sample points of floor triangles that lie more than 3 mm inside a
## floor triangle of ANOTHER mesh in the same plane (within 1.5 mm) (any texel), i.e. a depth tie between two tiles. Zero after the repair (the intentional few-millimetre seam overlaps are shallower than 3 mm).
var last_pairs := {}
## Overlaps between two surfaces that both use a mesh resource shared by several nodes: they cannot be clipped per
## node (the mesh is one resource), so the measure reports them separately and does not count them.
var last_shared_pairs: int = 0


func stacked_overlap_samples(inst: Node3D) -> int:
	last_pairs.clear()
	last_shared_pairs = 0
	var names: Array = []
	var shared_flags: Array = []
	var uses := {}
	for n0 in inst.find_children("*", "MeshInstance3D", true, false):
		var m0 := n0 as MeshInstance3D
		if m0.mesh != null:
			uses[m0.mesh.get_instance_id()] = int(uses.get(m0.mesh.get_instance_id(), 0)) + 1
	var tris: Array = []
	var grid := {}
	var si := 0
	for n in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf: Transform3D = inst.global_transform.affine_inverse() * mi.global_transform
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var uvs = arr[Mesh.ARRAY_TEX_UV]
			var img := _albedo_image(mi, s)
			for t in idx.size() / 3:
				var a: Vector3 = xf * vs[idx[t * 3]]
				var b: Vector3 = xf * vs[idx[t * 3 + 1]]
				var c: Vector3 = xf * vs[idx[t * 3 + 2]]
				if not _is_floor_flat([a, b, c]) or (b - a).cross(c - a).y >= 0.0:
					continue   # only upward-wound floor triangles (the ones seen from above)
				var f := {"sf": si, "a": a, "b": b, "c": c, "y": (a.y + b.y + c.y) / 3.0, "img": img, "ua": uvs[idx[t * 3]] if uvs != null else Vector2.ZERO, "ub": uvs[idx[t * 3 + 1]] if uvs != null else Vector2.ZERO, "uc": uvs[idx[t * 3 + 2]] if uvs != null else Vector2.ZERO}
				var ti := tris.size()
				tris.append(f)
				var lo := Vector2i(int(floorf(minf(a.x, minf(b.x, c.x)) / CELL)), int(floorf(minf(a.z, minf(b.z, c.z)) / CELL)))
				var hi := Vector2i(int(floorf(maxf(a.x, maxf(b.x, c.x)) / CELL)), int(floorf(maxf(a.z, maxf(b.z, c.z)) / CELL)))
				for gx in range(lo.x, hi.x + 1):
					for gz in range(lo.y, hi.y + 1):
						var k := Vector2i(gx, gz)
						if grid.has(k):
							(grid[k] as Array).append(ti)
						else:
							grid[k] = [ti]
		names.append(str(mi.name))
		shared_flags.append(int(uses[mi.mesh.get_instance_id()]) > 1)
		si += 1
	var count := 0
	for f in tris:
		var a: Vector3 = f["a"]
		var b: Vector3 = f["b"]
		var c: Vector3 = f["c"]
		for i in 6:
			for j in 6 - i:
				var p: Vector3 = a + (b - a) * ((float(i) + 0.4) / 6.0) + (c - a) * ((float(j) + 0.4) / 6.0)
				var k := Vector2i(int(floorf(p.x / CELL)), int(floorf(p.z / CELL)))
				for gi in (grid.get(k, []) as Array):
					var g: Dictionary = tris[gi]
					if int(g["sf"]) == int(f["sf"]) or absf(float(g["y"]) - float(f["y"])) > CLIP_PLANE_TOL:
						continue
					var both_shared: bool = shared_flags[int(f["sf"])] and shared_flags[int(g["sf"])]
					var hps := _halfplanes(g, DEEP)
					if hps.is_empty():
						continue
					var inside := true
					for h in hps:
						if (h[0] as Vector2).dot(Vector2(p.x, p.z)) < float(h[1]):
							inside = false
							break
					if not inside:
						continue
					if both_shared:
						last_shared_pairs += 1
						break
					count += 1
					var pk := "%s over %s" % [names[int(f["sf"])], names[int(g["sf"])]]
					last_pairs[pk] = int(last_pairs.get(pk, 0)) + 1
					break
	return count


const CLIP_MARGIN := 0.0015
const CLIP_PLANE_TOL := 0.0015
const MIN_OVERLAP := 0.0027   # inradius (m) of the overlap below which it counts as an intentional seam overlap


func _tri2(f: Dictionary) -> Array:
	var a: Vector3 = f["a"]
	var b: Vector3 = f["b"]
	var c: Vector3 = f["c"]
	return [Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z)]


## Inward half-planes [normal, d] (inside: normal . p >= d) of a triangle, shifted inward by margin.
func _halfplanes(w: Dictionary, margin: float) -> Array:
	var t := _tri2(w)
	var orient: float = (t[1].x - t[0].x) * (t[2].y - t[0].y) - (t[1].y - t[0].y) * (t[2].x - t[0].x)
	if absf(orient) < 1e-6:
		return []
	var out: Array = []
	for i in 3:
		var p0: Vector2 = t[i]
		var p1: Vector2 = t[(i + 1) % 3]
		var e := p1 - p0
		if e.length() < 1e-6:
			return []
		var n := Vector2(-e.y, e.x).normalized() if orient > 0.0 else Vector2(e.y, -e.x).normalized()
		var m: float = 0.0 if (w.has("internal") and bool((w["internal"] as Array)[i])) else margin
		out.append([n, n.dot(p0) + m])
	return out


## Sutherland-Hodgman: the part of a convex polygon with normal . p >= d.
func _clip(poly: Array, n: Vector2, d: float) -> Array:
	var out: Array = []
	var cnt := poly.size()
	for i in cnt:
		var cur: Vector2 = poly[i]
		var nxt: Vector2 = poly[(i + 1) % cnt]
		var dc: float = n.dot(cur) - d
		var dn: float = n.dot(nxt) - d
		if dc >= 0.0:
			out.append(cur)
		if (dc >= 0.0) != (dn >= 0.0):
			var t: float = dc / (dc - dn)
			out.append(cur + (nxt - cur) * t)
	return out


func _clip_all(poly: Array, hps: Array) -> Array:
	var r := poly
	for h in hps:
		if r.size() < 3:
			return []
		r = _clip(r, h[0], float(h[1]))
	return r


func _area(poly: Array) -> float:
	var a := 0.0
	var cnt := poly.size()
	for i in cnt:
		var p: Vector2 = poly[i]
		var q: Vector2 = poly[(i + 1) % cnt]
		a += p.x * q.y - q.x * p.y
	return absf(a) * 0.5


## Does the polygon have an inscribed width of at least MIN_OVERLAP (2 * area / perimeter)?
func _thick(poly: Array) -> bool:
	if poly.size() < 3:
		return false
	var per := 0.0
	for i in poly.size():
		per += (poly[i] as Vector2).distance_to(poly[(i + 1) % poly.size()])
	return per > 1e-9 and 2.0 * _area(poly) / per >= MIN_OVERLAP


func _wider_than(poly: Array, w: float) -> bool:
	var per := 0.0
	for i in poly.size():
		per += (poly[i] as Vector2).distance_to(poly[(i + 1) % poly.size()])
	return per > 1e-9 and 2.0 * _area(poly) / per >= w


func _centroid2(poly: Array) -> Vector2:
	var c := Vector2.ZERO
	for p in poly:
		c += p
	return c / float(maxi(poly.size(), 1))


func _similar_at(f: Dictionary, w: Dictionary, p2: Vector2) -> bool:
	var p := Vector3(p2.x, float(f["y"]), p2.y)
	var cf := _color_at(f, p)
	var cw := _color_at(w, p)
	return maxf(absf(cf.r - cw.r), maxf(absf(cf.g - cw.g), absf(cf.b - cw.b))) <= SIMILAR


func _bary(a: Vector3, b: Vector3, c: Vector3, q: Vector2) -> Vector2:
	var v0 := Vector2(b.x - a.x, b.z - a.z)
	var v1 := Vector2(c.x - a.x, c.z - a.z)
	var v2 := Vector2(q.x - a.x, q.y - a.z)
	var den: float = v0.x * v1.y - v1.x * v0.y
	return Vector2((v2.x * v1.y - v1.x * v2.y) / den, (v0.x * v2.y - v2.x * v0.y) / den)


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
