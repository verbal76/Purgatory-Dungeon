# ==============================================================================
# File Name: graphics_quality.gd
# Path: res://scripts/graphics_quality.gd
#
# Description:
#   One Graphics Quality setting for the desktop game (Options > Video). It only moves the cost of the 3D picture; nothing here changes
#   gameplay. Phones are untouched (their project settings already render at 0.75 scale).
#
#       High    full resolution (what Windows always did)
#       Medium  FSR 1.0 upscaled from 77 % of the screen          <- the default on a Steam Deck
#       Low     FSR 1.0 upscaled from 59 % of the screen, no bloom
#
#   The menu and HUD are drawn at full resolution at every level (only the 3D scene is scaled). Static helper, no node, no class_name:
#   `const GraphicsQuality := preload("res://scripts/graphics_quality.gd")`.
# ==============================================================================
extends RefCounted

const SteamDeck := preload("res://scripts/steam_deck.gd")

enum Level { LOW, MEDIUM, HIGH }

const KEY := "GraphicsQuality"
const SCALE := {Level.LOW: 0.59, Level.MEDIUM: 0.77, Level.HIGH: 1.0}
const NAMES := {Level.LOW: "Low", Level.MEDIUM: "Medium", Level.HIGH: "High"}


static func default_level() -> int:
	return Level.MEDIUM if SteamDeck.is_deck() else Level.HIGH


## The chosen level (the saved setting, else the default for this device).
static func level() -> int:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree != null and tree.root.has_node("SettingsManager"):
		return clampi(int(SettingsManager.get_setting(KEY, float(default_level()))), Level.LOW, Level.HIGH)
	return default_level()


## Bloom is the one post effect worth dropping on the Low level.
static func glow_enabled() -> bool:
	return level() > Level.LOW


## Put `window` (the root viewport) on `lvl`. No-op on phones.
static func apply(window: Viewport, lvl: int = -1) -> void:
	if window == null or TouchControls.is_touch_platform():
		return
	if lvl < 0:
		lvl = level()
	var s: float = SCALE.get(lvl, 1.0)
	if s >= 1.0:
		window.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	else:
		window.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	window.scaling_3d_scale = s
	# A running level change reaches the lighting too (bloom), through the WorldEnvironment the lighting manager owns.
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree != null:
		tree.call_group("lighting_quality", "apply_quality")
