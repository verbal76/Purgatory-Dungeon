extends Node
## Headless parse/load validation. Runs as a scene so project autoloads exist.
## Run: godot --headless --path . res://tests/validate_project.tscn
## Loads every .gd script and every .tscn/.tres under res:// (skipping addons and
## .godot) and exits non-zero if any fail to load.

const SKIP_DIRS: Array[String] = ["addons", ".godot", "godot"]


func _ready() -> void:
	var failures: Array[String] = []
	var scripts := 0
	var scenes := 0
	for path in _collect("res://"):
		var ext := path.get_extension()
		if ext == "gd":
			scripts += 1
			var s = load(path)
			if s == null or (s is GDScript and not (s as GDScript).can_instantiate() and not (s as GDScript).is_abstract()):
				failures.append("SCRIPT " + path)
		elif ext == "tscn" or ext == "tres":
			scenes += 1
			var r = load(path)
			if r == null:
				failures.append("RESOURCE " + path)
			elif r is PackedScene and not (r as PackedScene).can_instantiate():
				failures.append("SCENE (cannot instantiate) " + path)
	print("validate_project: %d scripts, %d scenes/resources checked, %d failures" % [scripts, scenes, failures.size()])
	for f in failures:
		printerr("FAIL: " + f)
	get_tree().quit(1 if failures.size() > 0 else 0)


func _collect(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not n.begins_with(".") or n == ".":
			var full := dir_path.path_join(n)
			if d.current_is_dir():
				if not SKIP_DIRS.has(n):
					out.append_array(_collect(full))
			else:
				out.append(full)
		n = d.get_next()
	return out
