extends RefCounted
## Load-time repair of the prebuilt dungeon module meshes (data/floor_mesh_repairs.json, written by
## tools/floor_mesh_repair_tool.gd). The glb files stay untouched; the list says, per module scene / mesh node /
## surface, which floor triangles to leave out and which floor vertices to move by a millimetre:
##   drop  the downward-wound back layer of the double-sided floor that lies in the very same plane as the visible
##         floor and carries the grey underside texture (z-fighting with the floor, different on every GPU);
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
		arrays_all.append(mesh.surface_get_arrays(s))
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
		if not drop.is_empty():
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
			arrays[Mesh.ARRAY_INDEX] = out
		arrays_all[s] = arrays
	mesh.clear_surfaces()
	for s in n:
		mesh.add_surface_from_arrays(prims[s] as Mesh.PrimitiveType, arrays_all[s])
		if mats[s] != null:
			mesh.surface_set_material(s, mats[s])
		if names[s] != "":
			mesh.surface_set_name(s, names[s])
	mesh.set_meta(META, true)
	return true
