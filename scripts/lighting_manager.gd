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
#    setup_environment() — called by main game file after dungeon
#                          generation so randi() is already seeded.
#    set_dimming(amount) — 0.0–1.0, dims sun for cinematic moments.
# ══════════════════════════════════════════════════════════════

@export var ambient_color  : Color = Color(0.15, 0.15, 0.18)
@export var ambient_energy : float = 0.05   # Low — torches are the primary light source


var _world_env : WorldEnvironment = null


func _ready() -> void:
	# No DirectionalLight3D — torches are the primary light source.
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


func set_dimming(amount: float) -> void:
	amount = clampf(amount, 0.0, 1.0)
	if _world_env != null:
		_world_env.environment.ambient_light_energy = lerp(ambient_energy, 0.0, amount)


# ══════════════════════════════════════════════════════════════
#  ENVIRONMENT
# ══════════════════════════════════════════════════════════════

func _setup_sky() -> void:
	var env := Environment.new()

	# Dungeon interior — no sky, no sun. Torches are the only light source.
	env.background_mode      = Environment.BG_COLOR
	env.background_color     = Color(0.0, 0.0, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color  = ambient_color
	env.ambient_light_energy = ambient_energy

	env.tonemap_mode          = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure      = 1.0

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
