extends Node3D

# ══════════════════════════════════════════════════════════════
#  lighting_manager.gd
#  res://scripts/lighting_manager.gd
#
#  Owns ALL environmental rendering for a run:
#    • DirectionalLight3D (sun)
#    • WorldEnvironment — randomly chosen panoramic sky each run,
#      plus fog, glow, and tone-mapping
#
#  Call order: _ready() fires as a child node, before the main
#  game scene's _ready(). No other WorldEnvironment is created
#  anywhere else, so this is always the active one.
#
#  Public API:
#    setup_environment()      — called by main game file after dungeon
#                               generation so randi() is already seeded.
#    set_dimming(amount)      — 0.0–1.0, hardcore progressive darkness.
#    refresh_brightness()     — re-reads the "Ambient Brightness" accessibility
#                               setting and applies it live (group
#                               "lighting_manager"; the Options slider calls it).
#
#  VISIBILITY FLOOR (readability, owner requirement after the v7.1 phone test):
#    Torches give atmosphere and local contrast; they must not be the ONLY thing
#    that makes floors, walls, doors, enemies and the player's own arms
#    identifiable. The environment therefore carries a minimum ambient level that
#    costs nothing per light (no extra Light3D, no shadow, no draw call). It is
#    far below a lit room: torch pools still read as bright contrast.
#
#    final ambient energy =
#        lerp(ambient_energy, ambient_energy * dimming_floor_fraction, dimming)   [hardcore]
#        * (1 + brightness * (brightness_ambient_mult - 1))                       [accessibility]
#    final exposure = 1 + brightness * brightness_exposure_lift
#    with dimming 0..1 (0 = normal play) and brightness 0..1 (= slider / 100).
#    The boost is applied AFTER the dimming, so the accessibility slider still helps
#    in hardcore: worst case = ambient_energy * dimming_floor_fraction at 0 % slider.
# ══════════════════════════════════════════════════════════════

## Setting key persisted by the Options slider (SettingsManager.gameplay_settings, percent 0..100, default 0).
const SETTING_KEY : String = "AmbientBrightness"
const GROUP_NAME  : String = "lighting_manager"

## Warm-dark ambient colour (a candle-lit stone tint, never white).
@export var ambient_color  : Color = Color(0.62, 0.54, 0.48)
## The visibility floor at 0 % slider (the intended default look). Was 0.05 with a cold
## (0.15, 0.15, 0.18) tint, i.e. an effective 0.0075 = black outside torch range.
@export var ambient_energy : float = 0.12
## Hardcore dimming never takes the ambient below this fraction of ambient_energy.
@export_range(0.0, 1.0) var dimming_floor_fraction : float = 0.5
## Ambient multiplier at slider 100 % (ceiling: ambient_energy * brightness_ambient_mult).
@export var brightness_ambient_mult : float = 2.25
## Extra tonemap exposure at slider 100 % (1.0 -> 1.0 + lift).
@export var brightness_exposure_lift : float = 0.15
const BASE_EXPOSURE : float = 1.0

## Character materials come out of the glTF import with metallic 0.5, which throws away half of every diffuse
## light (ambient AND torch) on the player's own body/arms and on the brute enemy. They are capped to this value
## once per run (shared resources, no per-instance cost, no new nodes). 0.0 = plain diffuse skin and cloth.
@export var character_metallic_cap : float = 0.0
## The scene properties of the main scene that hold the playable / enemy character scenes.
const CHARACTER_SCENE_PROPS : Array[String] = ["brute_enemy_scene", "mage_enemy_scene", "barbarian_scene", "mage_scene"]


var _world_env : WorldEnvironment = null
var _dimming   : float = 0.0     # 0..1, set by set_dimming()
var _brightness: float = 0.0     # 0..1, from the accessibility setting


func _ready() -> void:
	add_to_group(GROUP_NAME)
	_brightness = brightness_from_setting()
	# No DirectionalLight3D, and no fill light: the ambient floor is free (it adds no Light3D).
	# Build the WorldEnvironment immediately so the renderer always has
	# a background and post-processing — even before the RNG is seeded.
	_setup_sky()


# ══════════════════════════════════════════════════════════════
#  PUBLIC API
# ══════════════════════════════════════════════════════════════

# Called once per run by Purgatory_Dungeon_main_game_file after dungeon gen.
# Re-picks the sky using the now-seeded RNG so every run looks different.
func setup_environment() -> void:
	_setup_sky()
	_lift_character_materials()


func set_dimming(amount: float) -> void:
	_dimming = clampf(amount, 0.0, 1.0)
	_apply_levels()


# Re-reads the saved "Ambient Brightness" setting and applies it immediately (no polling, no allocation).
func refresh_brightness() -> void:
	_brightness = brightness_from_setting()
	_apply_levels()


# 0..1 from SettingsManager (percent in the file). Missing / negative / non-numeric / NaN -> 0, > 100 -> 1.
static func brightness_from_value(raw: Variant) -> float:
	if typeof(raw) != TYPE_FLOAT and typeof(raw) != TYPE_INT:
		return 0.0
	var v : float = float(raw)
	if is_nan(v):
		return 0.0
	return clampf(v, 0.0, 100.0) / 100.0


static func brightness_from_setting() -> float:
	var sm : Node = Engine.get_main_loop().root.get_node_or_null("SettingsManager") if Engine.get_main_loop() is SceneTree else null
	if sm == null:
		return 0.0
	return brightness_from_value(sm.gameplay_settings.get(SETTING_KEY, 0.0))


# The documented formula (see header). Pure function: unit-tested without a renderer.
func ambient_energy_for(dimming: float, brightness: float) -> float:
	var dimmed : float = lerpf(ambient_energy, ambient_energy * dimming_floor_fraction, clampf(dimming, 0.0, 1.0))
	return dimmed * (1.0 + clampf(brightness, 0.0, 1.0) * (brightness_ambient_mult - 1.0))


func exposure_for(brightness: float) -> float:
	return BASE_EXPOSURE + clampf(brightness, 0.0, 1.0) * brightness_exposure_lift


func _apply_levels() -> void:
	if _world_env == null or _world_env.environment == null:
		return
	var env : Environment = _world_env.environment
	env.ambient_light_energy = ambient_energy_for(_dimming, _brightness)
	env.tonemap_exposure     = exposure_for(_brightness)


# ══════════════════════════════════════════════════════════════
#  CHARACTER MATERIALS (once per run, shared resources)
# ══════════════════════════════════════════════════════════════

func _lift_character_materials() -> void:
	var host : Node = get_parent()
	if host == null:
		return
	var seen : Dictionary = {}
	for prop in CHARACTER_SCENE_PROPS:
		var ps : Variant = host.get(prop)
		if ps is PackedScene:
			var inst : Node = (ps as PackedScene).instantiate()   # never enters the tree: no _ready, no side effects
			_cap_metallic(inst, seen)
			inst.free()


func _cap_metallic(n: Node, seen: Dictionary) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var mesh : Mesh = (n as MeshInstance3D).mesh
		for i in mesh.get_surface_count():
			var m : Material = mesh.surface_get_material(i)
			if m is BaseMaterial3D and not seen.has(m):
				seen[m] = true
				var b : BaseMaterial3D = m
				if b.metallic > character_metallic_cap:
					b.metallic = character_metallic_cap
	for c in n.get_children():
		_cap_metallic(c, seen)


# ══════════════════════════════════════════════════════════════
#  ENVIRONMENT
# ══════════════════════════════════════════════════════════════

func _setup_sky() -> void:
	var env := Environment.new()

	# Dungeon interior — no sky, no sun. Torches give the contrast; the ambient floor keeps everything identifiable.
	env.background_mode      = Environment.BG_COLOR
	env.background_color     = Color(0.0, 0.0, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color  = ambient_color
	env.ambient_light_energy = ambient_energy_for(_dimming, _brightness)

	env.tonemap_mode          = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure      = exposure_for(_brightness)

	env.fog_enabled           = true
	env.fog_light_color       = Color(0.408, 0.396, 0.388)
	env.fog_light_energy      = 1.0
	env.fog_sun_scatter       = 0.56
	env.fog_density           = 0.0001
	env.fog_height            = -172.0
	env.fog_height_density    = 0.02

	env.glow_enabled              = true
	env.glow_intensity            = 0.3    # low — flame orb only, not lit walls
	env.glow_strength             = 0.4
	env.glow_bloom                = 0.02
	env.glow_hdr_threshold        = 2.0   # walls lit by torches stay ~1.0; emissive sphere ~3.0 still glows
	env.glow_hdr_scale            = 2.0

	# Reuse the existing WorldEnvironment if it was already created in _ready().
	# This prevents duplicate WorldEnvironment nodes when setup_environment()
	# is called a second time (after dungeon gen seeds the RNG).
	if _world_env == null:
		_world_env             = WorldEnvironment.new()
		_world_env.name        = "WorldEnvironment"
		add_child(_world_env)
	_world_env.environment = env
