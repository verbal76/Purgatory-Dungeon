extends Node
## Character model budget. The enemy / player models are glTF imports whose exporter wrote every material of a mesh
## as a COPY of the whole vertex buffer (non-indexed, one primitive per material, all pointing at the same
## accessor). The Mage enemy therefore carried 205 surfaces and 3,079,510 triangles (the whole 15 k triangle body,
## drawn 205 times and skinned 205 times per frame, in view or not for the skin updates), the Brute drew its body
## twice (46,059 triangles). The assets now keep one surface per distinct vertex buffer; the rendered image is
## pixel-identical (checked by rendering before / after).
## This test fails if a model gets a surface that duplicates another surface of the same mesh, or if a model's
## triangle count or surface count grows past a budget that is a little above today's real numbers.

# scene -> [max triangles, max surfaces per mesh]
const BUDGET := {
	"res://characters/brute/scenes/brute_enemy.tscn": [34000, 1],
	"res://characters/brute/scenes/brute_player.tscn": [34000, 1],
	"res://characters/Lutsch Mage/scenes/Mage enemy.tscn": [20000, 1],
	"res://characters/Lutsch Mage/scenes/Mage player.tscn": [36000, 1],
}

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _tris(mesh: Mesh) -> int:
	var tris := 0
	for i in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(i)
		var idx: Variant = arrays[Mesh.ARRAY_INDEX]
		if idx != null and (idx as PackedInt32Array).size() > 0:
			tris += (idx as PackedInt32Array).size() / 3
		else:
			tris += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return tris


## True when two surfaces of `mesh` hold the very same vertices (a full duplicate that only changes the material).
func _has_duplicate_surface(mesh: Mesh) -> bool:
	var seen: Array = []
	for i in mesh.get_surface_count():
		var v: PackedVector3Array = mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX]
		for prev in seen:
			if (prev as PackedVector3Array).size() == v.size() and prev == v:
				return true
		seen.append(v)
	return false


func _scan(node: Node, acc: Dictionary) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mesh := (node as MeshInstance3D).mesh
		acc["tris"] += _tris(mesh)
		acc["max_surfaces"] = maxi(acc["max_surfaces"], mesh.get_surface_count())
		if _has_duplicate_surface(mesh):
			acc["duplicates"].append(str(node.name))
	for c in node.get_children():
		_scan(c, acc)


func _ready() -> void:
	for path in BUDGET:
		var ps := load(path) as PackedScene
		_check(ps != null, "%s loads" % path.get_file())
		if ps == null:
			continue
		var inst := ps.instantiate()
		var acc := {"tris": 0, "max_surfaces": 0, "duplicates": []}
		_scan(inst, acc)
		inst.free()
		var limit: Array = BUDGET[path]
		_check(acc["duplicates"].is_empty(), "%s: no surface duplicates another surface of its mesh (%s)" % [path.get_file(), acc["duplicates"]])
		_check(int(acc["tris"]) <= int(limit[0]), "%s: %d triangles, budget %d" % [path.get_file(), acc["tris"], limit[0]])
		_check(int(acc["max_surfaces"]) <= int(limit[1]), "%s: at most %d surfaces per mesh (has %d)" % [path.get_file(), limit[1], acc["max_surfaces"]])
		print("test_enemy_assets: %-24s %6d triangles, up to %d surface(s) per mesh" % [path.get_file(), acc["tris"], acc["max_surfaces"]])
	print("test_enemy_assets: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
