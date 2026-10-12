extends Node
## Codex progress is written atomically (temp file + rename) and survives a restart; the Graphics Quality names follow the master standard.

const GraphicsQuality := preload("res://scripts/graphics_quality.gd")

var _fails: int = 0
var _checks: int = 0


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
	var path: String = StoragePaths.ensure_root().path_join(CodexManager.CODEX_FILE_NAME)
	var before: int = CodexManager.get_total_completions()
	CodexManager.increment_completions()
	_check(CodexManager.get_total_completions() == before + 1, "a completion is counted")
	_check(FileAccess.file_exists(path), "codex.json is on disk")
	_check(not FileAccess.file_exists(path + ".tmp"), "no temp file is left behind (the write went through the atomic helper)")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(parsed is Dictionary and int((parsed as Dictionary).get("total_completions", -1)) == before + 1, "the file holds the new total and is valid JSON")
	# A restart reads it back.
	CodexManager._load_codex_data()
	_check(CodexManager.get_total_completions() == before + 1, "the total survives a reload")

	_check(GraphicsQuality.NAMES[GraphicsQuality.Level.HIGH] == "Quality" and GraphicsQuality.NAMES[GraphicsQuality.Level.MEDIUM] == "Balanced"
			and GraphicsQuality.NAMES[GraphicsQuality.Level.LOW] == "Cool / Battery", "graphics levels are named Quality / Balanced / Cool / Battery")
	var opts := (load("res://scenes/OptionsScreen.tscn") as PackedScene).instantiate()
	add_child(opts)
	for i in 8:
		await get_tree().process_frame
	var row: OptionButton = opts.find_child("GraphicsQuality", true, false) as OptionButton
	var recommended: int = 0
	if row != null:
		for i in row.item_count:
			if row.get_item_text(i).ends_with("(Recommended)"):
				recommended += 1
				_check(row.get_item_id(i) == GraphicsQuality.default_level(), "the recommended level is this device's default")
	_check(recommended == 1, "exactly one graphics level is marked (Recommended)")
	opts.queue_free()
	print("test_codex_save: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
