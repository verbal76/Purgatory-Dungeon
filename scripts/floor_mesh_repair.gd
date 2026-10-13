extends RefCounted
## Load-time repair of the prebuilt dungeon module meshes (data/floor_mesh_repairs.json, written by
## tools/floor_mesh_repair_tool.gd). The glb files stay untouched; the list says, per module scene / mesh node /
## surface, which floor triangles to leave out and which floor vertices to move by a millimetre:
##   drop  the downward-wound back layer of the double-sided floor that lies in the very same plane as the visible
##         floor and carries the grey underside texture (z-fighting with the floor, different on every GPU);
##   add   pieces of floor triangles that another tile partly overlaps in the same plane (the triangle is dropped,
##         the part outside the winning tile is added): removes the depth tie between stacked floor tiles;
##   snap  floor vertices 1 mm off their neighbours (a 1 mm slit through the middle of the square rooms).
## Applied once per mesh resource (the meshes are shared by every instance of a module), in place, so it costs a few
## milliseconds the first time a module type is instantiated and nothing afterwards. No nodes, materials or draw
## calls are added; the primitive count only goes down. Collision is separate and untouched.
## Plain script, no class_name (OTA-safe): use via preload().

const DATA_PATH := "res://data/floor_mesh_repairs.json"
const META := "floor_mesh_repaired"

static var _data: Dictionary = {}
static var _loaded: bool = false


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(DATA_PATH):
		return
	var f := FileAccess.open(DATA_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		_data = (parsed as Dictionary).get("scenes", {})


## Repairs every listed module's meshes now, on the calling (main) thread. The main game scene calls this BEFORE it starts the
## worker-thread prop loads: rebuilding mesh surfaces on the main thread while workers create meshes raced inside the renderer's
## mesh storage (the headless dummy renderer corrupted its RIDs and crashed; on a real renderer a mesh still being created could be
## skipped, leaving its seam unrepaired). Afterwards apply() finds every mesh already repaired and does nothing.
static func prepare_all() -> int:
	_load()
	var changed: int = 0
	for scene_path in _data:
		var packed := load(str(scene_path)) as PackedScene
		if packed == null:
			continue
		var inst: Node = packed.instantiate()
		changed += apply(inst, str(scene_path))
		inst.free()
	return changed


## Repairs the meshes of a freshly instantiated module. Returns the number of meshes changed by this call.
static func apply(inst: Node, scene_path: String) -> int:
	_load()
	if not _data.has(scene_path):
		return 0
	var entry: Dictionary = _data[scene_path]
	var changed: int = 0
	for node_path in entry:
		var mi := inst.get_node_or_null(NodePath(str(node_path))) as MeshInstance3D
		if mi == null:
			continue
		var mesh := mi.mesh as ArrayMesh
		if mesh == null or mesh.has_meta(META):
			continue
		if _repair(mesh, entry[node_path] as Dictionary):
			changed += 1
	return changed


static func _repair(mesh: ArrayMesh, per_surface: Dictionary) -> bool:
	var n: int = mesh.get_surface_count()
	var arrays_all: Array = []
	var prims: Array[int] = []
	var mats: Array[Material] = []
	var names: Array[String] = []
	for s in n:
		var got: Array = mesh.surface_get_arrays(s)
		# A mesh whose vertex data cannot be read back (no renderer data yet / the headless dummy renderer's mesh storage failing
		# while meshes are still being loaded on worker threads) is left exactly as it is: nothing has been changed at this point.
		if got.size() <= Mesh.ARRAY_VERTEX or got[Mesh.ARRAY_VERTEX] == null:
			return false
		arrays_all.append(got)
		prims.append(mesh.surface_get_primitive_type(s))
		mats.append(mesh.surface_get_material(s))
		names.append(mesh.surface_get_name(s))
	for key in per_surface:
		var s: int = int(key)
		if s < 0 or s >= n:
			return false
		var rep: Dictionary = per_surface[key]
		var arrays: Array = arrays_all[s]
		var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for sn in (rep.get("snap", []) as Array):
			var vi: int = int(sn[0])
			if vi >= 0 and vi < vs.size():
				vs[vi] = Vector3(float(sn[1]), float(sn[2]), float(sn[3]))
		arrays[Mesh.ARRAY_VERTEX] = vs
		var drop: Dictionary = {}
		for t in (rep.get("drop", []) as Array):
			drop[int(t)] = true
		# pieces of partly overlapped floor triangles: new vertices interpolated from the source triangle
		var added := PackedInt32Array()
		var adds: Array = rep.get("add", [])
		if not adds.is_empty():
			var idx0: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var nrm: Variant = arrays[Mesh.ARRAY_NORMAL]
			var tang: Variant = arrays[Mesh.ARRAY_TANGENT]
			var uvs: Variant = arrays[Mesh.ARRAY_TEX_UV]
			for ad in adds:
				var src: int = int(ad[0])
				var i0: int = idx0[src * 3]
				var i1: int = idx0[src * 3 + 1]
				var i2: int = idx0[src * 3 + 2]
				for q in 3:
					var u: float = float(ad[1 + q * 2])
					var v: float = float(ad[2 + q * 2])
					var wa: float = 1.0 - u - v
					vs.append(vs[i0] * wa + vs[i1] * u + vs[i2] * v)
					if nrm != null:
						var nn: PackedVector3Array = nrm
						nn.append((nn[i0] * wa + nn[i1] * u + nn[i2] * v).normalized())
						nrm = nn
					if tang != null:
						var tt: PackedFloat32Array = tang
						for c in 3:
							tt.append(tt[i0 * 4 + c] * wa + tt[i1 * 4 + c] * u + tt[i2 * 4 + c] * v)
						tt.append(tt[i0 * 4 + 3])
						tang = tt
					if uvs != null:
						var uu: PackedVector2Array = uvs
						uu.append(uu[i0] * wa + uu[i1] * u + uu[i2] * v)
						uvs = uu
					added.append(vs.size() - 1)
			arrays[Mesh.ARRAY_VERTEX] = vs
			if nrm != null:
				arrays[Mesh.ARRAY_NORMAL] = nrm
			if tang != null:
				arrays[Mesh.ARRAY_TANGENT] = tang
			if uvs != null:
				arrays[Mesh.ARRAY_TEX_UV] = uvs
		if not drop.is_empty() or not added.is_empty():
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var out := PackedInt32Array()
			out.resize(idx.size())
			var o: int = 0
			for t in idx.size() / 3:
				if drop.has(t):
					continue
				out[o] = idx[t * 3]
				out[o + 1] = idx[t * 3 + 1]
				out[o + 2] = idx[t * 3 + 2]
				o += 3
			out.resize(o)
			out.append_array(added)
			arrays[Mesh.ARRAY_INDEX] = out
		arrays_all[s] = arrays
	mesh.clear_surfaces()
	for s in n:
		# A surface whose every triangle was dropped as covered is simply left out (an empty index array is not a valid surface, and the
		# surfaces after it must keep their own material and name, so they are addressed by the index they actually got).
		var kept: Variant = (arrays_all[s] as Array)[Mesh.ARRAY_INDEX]
		if kept is PackedInt32Array and (kept as PackedInt32Array).is_empty():
			continue
		var si: int = mesh.get_surface_count()
		mesh.add_surface_from_arrays(prims[s] as Mesh.PrimitiveType, arrays_all[s])
		if mats[s] != null:
			mesh.surface_set_material(si, mats[s])
		if names[s] != "":
			mesh.surface_set_name(si, names[s])
	mesh.set_meta(META, true)
	return true
