# ==============================================================================
#  FILE: dungeon_render_tuning.gd
#  PATH: res://scripts/dungeon_render_tuning.gd
#  DESCRIPTION: Render-cost fixes for the generated dungeon that live in resources, not in nodes.
#
#  Every surface of every dungeon module comes out of the glTF import with
#  transparency = ALPHA_DEPTH_PRE_PASS (the .glb files carry alpha mode BLEND) and no back-face
#  culling, although the albedo textures (<module>_colormap.png) are 100 % opaque. Godot therefore
#  draws the whole level through the sorted transparent pass: no early depth rejection, two draws
#  per surface (depth pre-pass + colour), every wall seen through other walls is fully shaded and
#  blended. That is the single most expensive thing in a dungeon frame on a tile-based phone GPU.
#
#  apply_to_modules() switches those materials to TRANSPARENCY_DISABLED (the opaque pass). The result
#  is pixel-identical because alpha is 1 everywhere; only the draw path changes. It is deliberately
#  narrow: only BaseMaterial3D whose albedo texture lives in "res://dungeon modules/" and ends in
#  "_colormap.png", whose albedo colour alpha is 1 (tests/test_light_budget.gd verifies that every
#  such texture really is opaque, so adding a cut-out texture there fails CI). Face culling is left
#  alone (walls are modelled as single sheets seen from both sides).
#
#  Materials are shared resources of the module scenes, so one pass over the first instance of each
#  scene is enough (a handful of node walks, not one per module).
# ==============================================================================
extends RefCounted

const TEXTURE_DIR : String = "res://dungeon modules/"
const TEXTURE_SUFFIX : String = "_colormap.png"


## True when `mat` is one of the dungeon module materials this script may make opaque.
static func is_tunable(mat: Material) -> bool:
	if not (mat is BaseMaterial3D):
		return false
	var b : BaseMaterial3D = mat as BaseMaterial3D
	if b.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
		return false
	if b.albedo_color.a < 0.999 or b.albedo_texture == null:
		return false
	var path : String = b.albedo_texture.resource_path
	return path.begins_with(TEXTURE_DIR) and path.ends_with(TEXTURE_SUFFIX)


## Makes the module materials opaque. Returns {"surfaces": inspected, "switched": materials changed,
## "scenes": module scenes walked}. Safe to call repeatedly (already-opaque materials are skipped).
static func apply_to_modules(modules: Array) -> Dictionary:
	var scenes_done : Dictionary = {}
	var changed : Dictionary = {}
	var surfaces : int = 0
	for mod in modules:
		if not is_instance_valid(mod):
			continue
		var key : String = (mod as Node).scene_file_path
		if key != "" and scenes_done.has(key):
			continue
		scenes_done[key] = true
		var stack : Array[Node] = [mod]
		while not stack.is_empty():
			var n : Node = stack.pop_back()
			for c in n.get_children():
				stack.append(c)
			if n is GeometryInstance3D and n is MeshInstance3D:
				var mi : MeshInstance3D = n as MeshInstance3D
				if mi.mesh == null:
					continue
				for i in mi.mesh.get_surface_count():
					surfaces += 1
					var m : Material = mi.get_active_material(i)
					if m != null and not changed.has(m) and is_tunable(m):
						(m as BaseMaterial3D).transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
						changed[m] = true
	return {"surfaces": surfaces, "switched": changed.size(), "scenes": scenes_done.size()}
