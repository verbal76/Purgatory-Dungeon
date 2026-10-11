extends Node
## Steam Deck defaults: Deck detection, the Graphics Quality levels (what they do to the 3D viewport) and the Options > Video row.

const SteamDeck := preload("res://scripts/steam_deck.gd")
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
	var root: Window = get_tree().root
	OS.set_environment("SteamDeck", "")
	OS.set_environment("PURGATORY_FORCE_DECK", "")
	OS.set_environment("PURGATORY_FORCE_TOUCH", "")
	SettingsManager.gameplay_settings.erase(GraphicsQuality.KEY)

	_check(not SteamDeck.is_deck(), "a PC is not a Steam Deck")
	_check(GraphicsQuality.level() == GraphicsQuality.Level.HIGH, "PC default is High (what Windows always did)")
	OS.set_environment("SteamDeck", "1")
	_check(SteamDeck.is_deck(), "SteamDeck=1 (set by Steam on a Deck, also under Proton) is a Steam Deck")
	_check(GraphicsQuality.level() == GraphicsQuality.Level.MEDIUM, "Deck default is Medium")
	OS.set_environment("SteamDeck", "")
	OS.set_environment("PURGATORY_FORCE_DECK", "1")
	_check(SteamDeck.is_deck() and GraphicsQuality.level() == GraphicsQuality.Level.MEDIUM, "PURGATORY_FORCE_DECK=1 pretends to be a Deck")

	# A saved choice beats the device default.
	SettingsManager.gameplay_settings[GraphicsQuality.KEY] = float(GraphicsQuality.Level.HIGH)
	_check(GraphicsQuality.level() == GraphicsQuality.Level.HIGH, "a saved level wins over the Deck default")
	SettingsManager.gameplay_settings.erase(GraphicsQuality.KEY)

	# What each level does to the 3D viewport.
	GraphicsQuality.apply(root, GraphicsQuality.Level.HIGH)
	_check(root.scaling_3d_mode == Viewport.SCALING_3D_MODE_BILINEAR and is_equal_approx(root.scaling_3d_scale, 1.0), "High renders at full resolution")
	GraphicsQuality.apply(root, GraphicsQuality.Level.MEDIUM)
	_check(root.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR and is_equal_approx(root.scaling_3d_scale, 0.77), "Medium: FSR from 77 %")
	GraphicsQuality.apply(root, GraphicsQuality.Level.LOW)
	_check(root.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR and is_equal_approx(root.scaling_3d_scale, 0.59), "Low: FSR from 59 %")
	# 800p at Medium is a sane internal size (the Deck's 1280x800 panel)
	var internal := Vector2(SteamDeck.PANEL) * 0.77
	_check(internal.x > 900.0 and internal.y > 600.0, "Medium at 1280x800 renders about %dx%d" % [internal.x, internal.y])

	# Bloom follows Low.
	SettingsManager.gameplay_settings[GraphicsQuality.KEY] = float(GraphicsQuality.Level.LOW)
	_check(not GraphicsQuality.glow_enabled(), "Low has no bloom")
	SettingsManager.gameplay_settings[GraphicsQuality.KEY] = float(GraphicsQuality.Level.MEDIUM)
	_check(GraphicsQuality.glow_enabled(), "Medium keeps bloom")

	# Phones are untouched (their project settings own the render scale).
	OS.set_environment("PURGATORY_FORCE_TOUCH", "1")
	root.scaling_3d_scale = 0.75
	GraphicsQuality.apply(root, GraphicsQuality.Level.HIGH)
	_check(is_equal_approx(root.scaling_3d_scale, 0.75), "touch platform: apply() does nothing")
	OS.set_environment("PURGATORY_FORCE_TOUCH", "")

	# Options > Video has the row, defaulted from the device, and picking a level saves and applies it.
	SettingsManager.gameplay_settings.erase(GraphicsQuality.KEY)
	var opts := (load("res://scenes/OptionsScreen.tscn") as PackedScene).instantiate()
	add_child(opts)
	for i in 8:
		await get_tree().process_frame
	var row: OptionButton = opts.find_child("GraphicsQuality", true, false) as OptionButton
	_check(row != null and row.selected == GraphicsQuality.Level.MEDIUM, "Options > Video shows Graphics Quality (Deck default Medium)")
	if row != null:
		row.select(GraphicsQuality.Level.LOW)
		row.item_selected.emit(GraphicsQuality.Level.LOW)
		_check(GraphicsQuality.level() == GraphicsQuality.Level.LOW and is_equal_approx(root.scaling_3d_scale, 0.59), "choosing Low saves it and applies it at once")
	opts.queue_free()
	GraphicsQuality.apply(root, GraphicsQuality.Level.HIGH)

	print("test_steam_deck: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
