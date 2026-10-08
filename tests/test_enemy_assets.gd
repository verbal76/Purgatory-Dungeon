extends Node
## Character model budget. The Mage enemy glTF export wrote every material of its mesh as a COPY of the whole vertex
## buffer (non-indexed): 205 primitives (103 x Vampire_MAT1, 102 x Vampire_MAT_Transparent) = 3,079,510 triangles,
## the whole 15 k triangle body drawn and skinned 205 times per frame. The asset now keeps ONE surface per distinct
## (vertex buffer, material) pair: 2 surfaces, one of each material, in the original order, so the look (both
## materials, MAT1's normal map included) and the draw order are unchanged. The Brute keeps its original two Body
## primitives (Body_MAT4 and EyeSpec_MAT2 differ in the eye region, so neither can be dropped safely).
## This test fails if a mesh carries two surfaces with the same vertices AND the same material (a pure duplicate),
## if a model's surface structure or material set changes (a lost material is caught), or if triangles exceed the budget.

## scene -> {tris: budget, mesh_surfaces: {mesh node name: expected surface count}, materials: names that must exist}
const MODELS := {
	"res://characters/Lutsch Mage/scenes/Mage enemy.tscn": {"tris": 31000, "mesh_surfaces": {"Vampire": 2},
		"materials": ["Vampire_MAT1", "Vampire_MAT_Transparent"]},
	"res://characters/brute/scenes/brute_enemy.tscn": {"tris": 47000, "mesh_surfaces": {"MaleBruteA_Body": 2},
		"materials": ["Body_MAT4", "EyeSpec_MAT2"]},
	"res://characters/brute/scenes/brute_player.tscn": {"tris": 47000, "mesh_surfaces": {"MaleBruteA_Body": 2},
		"materials": ["Body_MAT4", "EyeSpec_MAT2"]},
	"res://characters/Lutsch Mage/scenes/Mage player.tscn": {"tris": 49000, "mesh_surfaces": {"MaleBruteA_Body": 2},
		"materials": ["Body_MAT4", "EyeSpec_MAT2"]},
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


## Surfaces of `mesh` that repeat an earlier surface's vertices AND material (pure duplicates).
func _pure_duplicates(mesh: Mesh) -> int:
	var seen: Array = []   # [vertices, material]
	var dup := 0
	for i in mesh.get_surface_count():
		var v: PackedVector3Array = mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX]
		var m: Material = mesh.surface_get_material(i)
		for prev in seen:
			if prev[1] == m and (prev[0] as PackedVector3Array).size() == v.size() and prev[0] == v:
				dup += 1
				break
		seen.append([v, m])
	return dup


func _scan(node: Node, acc: Dictionary) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mesh := (node as MeshInstance3D).mesh
		acc["tris"] += _tris(mesh)
		acc["duplicates"] += _pure_duplicates(mesh)
		acc["surfaces"][str(node.name)] = mesh.get_surface_count()
		for i in mesh.get_surface_count():
			var mat := mesh.surface_get_material(i)
			if mat != null:
				acc["materials"][mat.resource_name] = mat
	for c in node.get_children():
		_scan(c, acc)


func _ready() -> void:
	for path in MODELS:
		var spec: Dictionary = MODELS[path]
		var ps := load(path) as PackedScene
		_check(ps != null, "%s loads" % path.get_file())
		if ps == null:
			continue
		var inst := ps.instantiate()
		var acc := {"tris": 0, "duplicates": 0, "surfaces": {}, "materials": {}}
		_scan(inst, acc)
		inst.free()
		var fname: String = path.get_file()
		_check(int(acc["duplicates"]) == 0, "%s: %d surface(s) duplicate another surface's vertices and material" % [fname, acc["duplicates"]])
		_check(int(acc["tris"]) <= int(spec["tris"]), "%s: %d triangles, budget %d" % [fname, acc["tris"], spec["tris"]])
		for mesh_name in spec["mesh_surfaces"]:
			_check(int(acc["surfaces"].get(mesh_name, -1)) == int(spec["mesh_surfaces"][mesh_name]),
					"%s: mesh %s has %d surfaces (expected %d)" % [fname, mesh_name, acc["surfaces"].get(mesh_name, -1), spec["mesh_surfaces"][mesh_name]])
		for mat_name in spec["materials"]:
			_check(acc["materials"].has(mat_name), "%s: material %s is still used by a surface" % [fname, mat_name])
		# the Mage's MAT1 carries the normal map: it must not get lost
		if acc["materials"].has("Vampire_MAT1"):
			var m1 := acc["materials"]["Vampire_MAT1"] as BaseMaterial3D
			_check(m1 != null and m1.normal_enabled and m1.normal_texture != null, "%s: Vampire_MAT1 keeps its normal map" % fname)
		print("test_enemy_assets: %-24s %6d triangles, surfaces %s, materials %s" % [fname, acc["tris"], acc["surfaces"], acc["materials"].keys()])
	print("test_enemy_assets: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
