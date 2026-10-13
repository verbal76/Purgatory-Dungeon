extends Node
## Readability floor (owner requirement after the v7.1 phone test): the environment keeps floors, walls, enemies and the
## player identifiable without any extra Light3D, hardcore darkness never drops below a gameplay floor, and the
## "Ambient Brightness" accessibility slider (Options > Accessibility) lifts only the ambient/exposure.
## Needs no renderer. The rendered-frame measurement lives in tests/lighting_shots.gd (manual tool).

const LM_SCRIPT : String = "res://scripts/lighting_manager.gd"

# Documented numbers (scripts/lighting_manager.gd header): the test pins them so a later tweak cannot silently
# bring the black voids back (floor) or make the dungeon bright (ceiling).
const FLOOR_MIN_ENERGY : float = 0.10      # default ambient energy must not fall below this (v7.1 had 0.05 * dark tint)
const FLOOR_MAX_ENERGY : float = 0.20      # ... nor above this: the default look stays dark
const FLOOR_MIN_LUMA   : float = 0.045     # energy * colour luminance, linear (v7.1: 0.0075)
const CEILING_MULT_MAX : float = 2.5       # slider at 100 %: at most 2.5x the default ambient
const EXPOSURE_LIFT_MAX: float = 0.2

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _lights_in(n: Node, out: Array) -> void:
	if n is Light3D:
		out.append(n)
	for c in n.get_children():
		_lights_in(c, out)


func _env_of(lm: Node) -> Environment:
	return (lm.get_node("WorldEnvironment") as WorldEnvironment).environment


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	var script : GDScript = load(LM_SCRIPT)
	_check(script != null, "lighting_manager.gd loads")

	# ── 1. the setting parser: default 0, clamped, non-numeric safe ───────────────────────────────────────────────
	SettingsManager.gameplay_settings.erase("AmbientBrightness")
	_check(script.brightness_from_setting() == 0.0, "setting missing -> 0 (the default look)")
	_check(script.brightness_from_value(null) == 0.0, "null -> 0")
	_check(script.brightness_from_value("abc") == 0.0 and script.brightness_from_value("50") == 0.0, "strings -> 0")
	_check(script.brightness_from_value(true) == 0.0, "bool -> 0")
	_check(script.brightness_from_value([1, 2]) == 0.0 and script.brightness_from_value({"a": 1}) == 0.0, "array/dict -> 0")
	_check(script.brightness_from_value(NAN) == 0.0, "NaN -> 0")
	_check(script.brightness_from_value(-40.0) == 0.0 and script.brightness_from_value(-1) == 0.0, "negative -> 0")
	_check(script.brightness_from_value(250.0) == 1.0 and script.brightness_from_value(101) == 1.0 and script.brightness_from_value(INF) == 1.0, "above 100 -> 1")
	_check(is_equal_approx(script.brightness_from_value(40), 0.4) and is_equal_approx(script.brightness_from_value(37.5), 0.375), "valid percent -> fraction")

	# ── 2. standalone manager: environment values ─────────────────────────────────────────────────────────────
	var host := Node3D.new()
	add_child(host)
	var lm : Node = script.new()
	host.add_child(lm)
	var env : Environment = _env_of(lm)
	_check(env.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR, "ambient comes from a flat colour (free)")
	var ec : Color = env.ambient_light_color
	var luma : float = env.ambient_light_energy * (0.2126 * ec.r + 0.7152 * ec.g + 0.0722 * ec.b)
	_check(env.ambient_light_energy >= FLOOR_MIN_ENERGY, "default ambient energy %.3f >= floor %.2f" % [env.ambient_light_energy, FLOOR_MIN_ENERGY])
	_check(env.ambient_light_energy <= FLOOR_MAX_ENERGY, "default ambient energy %.3f <= %.2f: still a dark dungeon" % [env.ambient_light_energy, FLOOR_MAX_ENERGY])
	_check(luma >= FLOOR_MIN_LUMA, "effective ambient %.4f >= %.3f (v7.1 shipped 0.0075)" % [luma, FLOOR_MIN_LUMA])
	_check(ec.r > ec.b and ec.r < 0.8, "ambient tint is warm and dark, not white")
	_check(is_equal_approx(env.tonemap_exposure, 1.0), "0 % keeps exposure 1.0")
	_check(env.tonemap_mode == Environment.TONE_MAPPER_FILMIC, "filmic tonemap kept")
	_check(not env.ssao_enabled and not env.ssil_enabled and not env.sdfgi_enabled and not env.volumetric_fog_enabled, "no SSAO/SSIL/SDFGI/volumetric fog (mobile cost)")
	var default_energy : float = env.ambient_light_energy

	# ── 3. lights: none added by the manager, no shadows, at most one fill and it follows the player ────────────
	var found : Array = []
	_lights_in(lm, found)
	_check(found.size() <= 1, "LightingManager owns at most one light (%d)" % found.size())
	for l in found:
		_check(not (l as Light3D).shadow_enabled, "manager light casts no shadow")
	_check(found.size() == 0, "no fill light is needed: the ambient floor alone keeps the traversal space readable")
	_check(lm.is_in_group("lighting_manager"), "manager is in group lighting_manager (slider live-apply)")

	# ── 4. hardcore dimming: never below the gameplay floor, monotonic, floor >= half of the minimum ───────────
	_check(lm.dimming_floor_fraction >= 0.5, "dimming floor fraction %.2f >= 0.5" % lm.dimming_floor_fraction)
	var prev : float = 1e9
	var worst : float = 1e9
	for i in 21:
		lm.set_dimming(float(i) / 20.0)
		var e : float = _env_of(lm).ambient_light_energy
		worst = minf(worst, e)
		_check(e <= prev + 1e-9, "dimming monotonic (step %d)" % i)
		prev = e
	_check(worst >= default_energy * 0.5 - 1e-9, "hardcore ambient never below half of the minimum (%.4f >= %.4f)" % [worst, default_energy * 0.5])
	lm.set_dimming(5.0)
	_check(is_equal_approx(_env_of(lm).ambient_light_energy, default_energy * lm.dimming_floor_fraction), "dimming input is clamped to 1.0")
	lm.set_dimming(-3.0)
	_check(is_equal_approx(_env_of(lm).ambient_light_energy, default_energy), "dimming input is clamped to 0.0")
	# the boost is applied AFTER the dimming (still helps in hardcore)
	SettingsManager.gameplay_settings["AmbientBrightness"] = 100.0
	lm.refresh_brightness()
	lm.set_dimming(1.0)
	var hc_boosted : float = _env_of(lm).ambient_light_energy
	_check(is_equal_approx(hc_boosted, lm.ambient_energy_for(1.0, 1.0)) and hc_boosted > default_energy * lm.dimming_floor_fraction, "slider 100 %% helps in hardcore (%.3f)" % hc_boosted)
	_check(is_equal_approx(hc_boosted, default_energy * lm.dimming_floor_fraction * lm.brightness_ambient_mult), "formula: dimmed * (1 + b * (mult - 1))")
	lm.set_dimming(0.0)

	# ── 5. slider -> environment: monotonic, ceiling, 0 % reproduces the default exactly ───────────────────────
	var last_e : float = -1.0
	var last_x : float = -1.0
	for pct in range(0, 101, 5):
		SettingsManager.gameplay_settings["AmbientBrightness"] = float(pct)
		lm.refresh_brightness()
		var en : Environment = _env_of(lm)
		_check(en.ambient_light_energy >= last_e - 1e-9 and en.tonemap_exposure >= last_x - 1e-9, "monotonic at %d %%" % pct)
		last_e = en.ambient_light_energy
		last_x = en.tonemap_exposure
		if pct == 0:
			_check(en.ambient_light_energy == default_energy and en.tonemap_exposure == 1.0, "0 %% reproduces the default environment exactly")
	_check(last_e <= default_energy * CEILING_MULT_MAX + 1e-9, "100 %% ambient %.3f <= ceiling %.3f" % [last_e, default_energy * CEILING_MULT_MAX])
	_check(last_e > default_energy * 1.5, "100 %% is a real lift (%.3f)" % last_e)
	_check(last_x <= 1.0 + EXPOSURE_LIFT_MAX + 1e-9 and last_x > 1.0, "100 %% exposure %.3f within the small lift" % last_x)
	SettingsManager.gameplay_settings["AmbientBrightness"] = 9999.0
	lm.refresh_brightness()
	_check(_env_of(lm).ambient_light_energy <= default_energy * CEILING_MULT_MAX + 1e-9, "out-of-range stored value cannot exceed the ceiling")
	SettingsManager.gameplay_settings["AmbientBrightness"] = "junk"
	lm.refresh_brightness()
	_check(_env_of(lm).ambient_light_energy == default_energy, "non-numeric stored value -> default look")
	lm.setup_environment()   # the second build (after generation) must keep the setting and the dimming
	SettingsManager.gameplay_settings["AmbientBrightness"] = 100.0
	lm.refresh_brightness()
	lm.setup_environment()
	_check(is_equal_approx(_env_of(lm).ambient_light_energy, lm.ambient_energy_for(0.0, 1.0)), "environment rebuild keeps the saved brightness")
	_check(lm.get_children().filter(func(c): return c is WorldEnvironment).size() == 1, "still exactly one WorldEnvironment")
	SettingsManager.gameplay_settings.erase("AmbientBrightness")
	host.queue_free()
	await get_tree().process_frame

	# ── 6. Options slider: exists, 0..100 step 5, writes the key, drives the manager live, survives a round trip ─
	var host2 := Node3D.new()
	add_child(host2)
	var lm2 : Node = script.new()
	host2.add_child(lm2)
	var opts : Control = (load("res://scenes/OptionsScreen.tscn") as PackedScene).instantiate()
	add_child(opts)
	await _frames(3)
	var sl : HSlider = opts._sliders.get("AmbientBrightness") as HSlider
	_check(sl != null, "Options has an Ambient Brightness slider")
	if sl != null:
		_check(sl.min_value == 0.0 and sl.max_value == 100.0 and sl.step == 5.0, "slider range 0..100 step 5")
		_check(sl.value == 0.0, "slider shows 0 when the key is missing")
		sl.value = 55.0
		_check(float(SettingsManager.gameplay_settings.get("AmbientBrightness", -1.0)) == 55.0, "slider writes the AmbientBrightness key")
		_check(is_equal_approx(_env_of(lm2).ambient_light_energy, lm2.ambient_energy_for(0.0, 0.55)), "slider moves the live environment immediately (no polling)")
		_check(opts._val_labels["AmbientBrightness"].text == "55%", "value label reads 55%")
	_check(_find_text(opts, "Ambient Brightness"), "slider row label present")
	# persistence: settings.json round trip keeps the key
	SettingsManager.save_settings()
	SettingsManager.gameplay_settings.erase("AmbientBrightness")
	SettingsManager.load_settings()
	_check(float(SettingsManager.gameplay_settings.get("AmbientBrightness", -1.0)) == 55.0, "AmbientBrightness survives the settings.json round trip")
	opts.queue_free()
	host2.queue_free()
	await get_tree().process_frame

	# ── 7. the real run: no lights/nodes/shadows added by the setting, characters respond to ambient ─────────────
	SettingsManager.gameplay_settings["AmbientBrightness"] = 0.0
	GlobalRunData.character_class = "barbarian"
	var main : Node = (load("res://scenes/Purgatory_Dungeon_main_game_file.tscn") as PackedScene).instantiate()
	add_child(main)
	await _frames(240)
	var rlm : Node = main.get_node_or_null("LightingManager")
	_check(rlm != null and is_equal_approx(_env_of(rlm).ambient_light_energy, rlm.ambient_energy), "run starts at the default look")
	var wenvs : int = _count_class(main, "WorldEnvironment")
	_check(wenvs == 1, "exactly one WorldEnvironment in the run (%d)" % wenvs)
	var mgr_lights : Array = []
	_lights_in(rlm, mgr_lights)
	_check(mgr_lights.size() <= 1, "run: LightingManager owns at most one light (%d)" % mgr_lights.size())
	var all0 : Array = []
	_lights_in(main, all0)
	var shadows0 : int = 0
	for l in all0:
		if (l as Light3D).shadow_enabled:
			shadows0 += 1
	_check(shadows0 == 0, "run: no shadow-casting light at all (%d)" % shadows0)
	var nodes0 : int = get_tree().get_node_count()
	var meshes0 : int = _count_class(main, "MeshInstance3D")
	SettingsManager.gameplay_settings["AmbientBrightness"] = 100.0
	get_tree().call_group("lighting_manager", "refresh_brightness")
	var all1 : Array = []
	_lights_in(main, all1)
	_check(all1.size() == all0.size(), "100 %% adds no light (%d vs %d)" % [all1.size(), all0.size()])
	_check(get_tree().get_node_count() == nodes0 and _count_class(main, "MeshInstance3D") == meshes0, "100 %% adds no node (%d)" % nodes0)
	_check(_env_of(rlm).ambient_light_energy > rlm.ambient_energy * 2.0 and _env_of(rlm).ambient_light_energy <= rlm.ambient_energy * CEILING_MULT_MAX, "live run reacts to the slider")
	SettingsManager.gameplay_settings["AmbientBrightness"] = 0.0
	get_tree().call_group("lighting_manager", "refresh_brightness")
	_check(is_equal_approx(_env_of(rlm).ambient_light_energy, rlm.ambient_energy), "back to 0 % = the default look again")
	# the player's own body/arms (shared glTF materials) no longer discard half the light
	var player : Node = get_tree().get_nodes_in_group("player")[0]
	var worst_metal : float = 0.0
	for mi in _meshes(player):
		if (mi as MeshInstance3D).mesh == null:
			continue
		for s in (mi as MeshInstance3D).mesh.get_surface_count():
			var m : Material = (mi as MeshInstance3D).mesh.surface_get_material(s)
			if m is BaseMaterial3D and (m as BaseMaterial3D).albedo_texture != null:
				worst_metal = maxf(worst_metal, (m as BaseMaterial3D).metallic)
	_check(worst_metal <= rlm.character_metallic_cap + 1e-6, "player materials capped to metallic %.2f (worst %.2f)" % [rlm.character_metallic_cap, worst_metal])

	print("test_lighting_readability: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _count_class(n: Node, cls: String) -> int:
	var k : int = 1 if n.is_class(cls) else 0
	for c in n.get_children():
		k += _count_class(c, cls)
	return k


func _meshes(n: Node) -> Array:
	var out : Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out


func _find_text(n: Node, text: String) -> bool:
	if n is Label and (n as Label).text == text:
		return true
	for c in n.get_children():
		if _find_text(c, text):
			return true
	return false
