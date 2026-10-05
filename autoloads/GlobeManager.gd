# ============================================================
#  FILE:         GlobeManager.gd
#  PATH:         res://autoloads/GlobeManager.gd
#  AUTOLOAD AS:  GlobeManager
#
#  DEPENDENCIES:
#    - PlayerWallet  (autoload)
#    - BuffManager   (autoload)
#    - Globe.gd      (res://objects/globe/Globe.gd)
#    - Globe.tscn    (res://objects/globe/globe.tscn)
#    - res://data/globe_effects.json
#
#  DESCRIPTION:
#    Spawns dormant effect globes throughout the dungeon and 
#    activates them sequentially over time.
#  MOD NOTES:
#    - Injected AudioManager.play_buff_choice() into _on_globe_collected.
# ============================================================

extends Node


# ── Signals ────────────────────────────────────────────────

signal globe_collected(effect: Dictionary)


# ── File paths ─────────────────────────────────────────────

const EFFECT_DATA_PATH : String = "res://data/globe_effects.json"
const GLOBE_SCENE_PATH : String = "res://objects/globe/globe.tscn"


# ── Rarity spawn weights ────────────────────────────────────

const RARITY_WEIGHTS : Dictionary = {
	"common"    : 60,
	"rare"      : 30,
	"legendary" : 10,
	"cursed"    : 1       # ~1-in-101 orb spawns — grave_whispers only
}


# ── Alert settings ─────────────────────────────────────────

const ALERT_TEXT      : String = "Potent Curse Sensed"
const ALERT_DURATION  : float  = 2.5
const ALERT_FADE_TIME : float  = 0.4
# Look: CardTitle role with an outline; a curse is blood (semantic), a blessing is ember.
const ALERT_COLOR     : Color  = PUI.BLOOD_BRIGHT
const BLESSING_COLOR  : Color  = PUI.EMBER_BRIGHT


# ── Spawn settings ─────────────────────────────────────────

@export var globe_count         : int   = 10
@export var spawn_height        : float = 0.8

# ── Activation timing ─────────────────────────────────────

@export var activation_time_min : float = 45.0
@export var activation_time_max : float = 60.0


# ── Runtime state ──────────────────────────────────────────

var _effect_pool   : Dictionary = { "common": [], "rare": [], "legendary": [], "cursed": [] }
var _globe_scene   : PackedScene = null
var _all_globes    : Array = []
var _activation_timer : float = -1.0
var _is_running : bool = false

# ── Alert UI state ─────────────────────────────────────────

var _alert_layer   : CanvasLayer = null
var _alert_label   : Label       = null
var _alert_timer   : float       = -1.0


# ── Lifecycle ──────────────────────────────────────────────

func _ready() -> void:
	_load_effect_data()

	if ResourceLoader.exists(GLOBE_SCENE_PATH):
		_globe_scene = load(GLOBE_SCENE_PATH)
	else:
		push_warning("GlobeManager: Globe.tscn not found at %s" % GLOBE_SCENE_PATH)

	globe_collected.connect(_on_globe_collected)

	_build_alert_ui()


# ── Data loading ───────────────────────────────────────────

func _load_effect_data() -> void:
	if not FileAccess.file_exists(EFFECT_DATA_PATH):
		push_warning("GlobeManager: globe_effects.json not found at %s" % EFFECT_DATA_PATH)
		return

	var file   := FileAccess.open(EFFECT_DATA_PATH, FileAccess.READ)
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()

	if not parsed is Array:
		push_warning("GlobeManager: globe_effects.json failed to parse. Check for JSON syntax errors.")
		return

	for entry in parsed:
		# The file's "_comment" lines are objects without an id; they must never become effects
		# (they used to land in the common pool, so ~1 in 3 common globes did nothing).
		if not (entry is Dictionary) or not entry.has("id"):
			continue
		var rarity : String = entry.get("rarity", "common")
		if _effect_pool.has(rarity):
			_effect_pool[rarity].append(entry)
		else:
			push_warning("GlobeManager: Unknown rarity '%s' in globe_effects.json — defaulting to common." % rarity)
			_effect_pool["common"].append(entry)


# ── Alert UI ───────────────────────────────────────────────

func _build_alert_ui() -> void:
	_alert_layer       = CanvasLayer.new()
	_alert_layer.layer = 6
	# Transient HUD text keeps its role size on phones too.
	_alert_layer.add_to_group("no_mobile_ui")
	add_child(_alert_layer)

	# One outlined label (no drop-shadow twin); its alpha is animated through modulate.
	_alert_label = PUI.label(ALERT_TEXT, "CardTitle")
	_alert_label.add_theme_constant_override("outline_size", 5)
	# Cinzel's lowercase is small caps, so a world-space alert is set a step larger than the role size.
	_alert_label.add_theme_font_size_override("font_size", int(round(PUI.fs("card_title") * 1.3)))
	_alert_label.add_theme_color_override("font_color", ALERT_COLOR)
	_alert_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_alert_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_alert_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_alert_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_alert_label.offset_top = -180.0
	_alert_label.modulate.a = 0.0
	PUI.adopt(_alert_label)   # a CanvasLayer child does not inherit the root theme
	_alert_layer.add_child(_alert_label)


func _set_alert(text: String, tint: Color) -> void:
	_alert_label.text = text
	_alert_label.add_theme_color_override("font_color", tint)


# Called by Globe.gd on collection — shows the effect name on screen.
func announce_collection(effect: Dictionary) -> void:
	var name_str = effect.get("name", "Unknown Effect")
	var val = float(effect.get("value", 0))
	var sign_str = "+" if val >= 0 else ""
	_set_alert("%s (%s%d)" % [name_str, sign_str, int(val)], BLESSING_COLOR if val >= 0.0 else ALERT_COLOR)
	_alert_timer = 0.0


func show_globe_alert() -> void:
	_alert_timer = 0.0


# ── Process — activation timer + alert fade ────────────────

func _process(delta: float) -> void:
	if _is_running and _activation_timer >= 0.0:
		_activation_timer -= delta
		if _activation_timer <= 0.0:
			_activate_next_globe()

	if _alert_timer >= 0.0:
		_alert_timer += delta

		var alpha : float = 0.0

		if _alert_timer <= ALERT_FADE_TIME:
			alpha = clampf(_alert_timer / ALERT_FADE_TIME, 0.0, 1.0)
		elif _alert_timer <= ALERT_DURATION - ALERT_FADE_TIME:
			alpha = 1.0
		elif _alert_timer <= ALERT_DURATION:
			var fade_progress : float = (_alert_timer - (ALERT_DURATION - ALERT_FADE_TIME)) / ALERT_FADE_TIME
			alpha = clampf(1.0 - fade_progress, 0.0, 1.0)
		else:
			alpha = 0.0
			_alert_timer = -1.0

		if _alert_label != null:
			_alert_label.modulate.a = alpha


# ── Sequential activation ──────────────────────────────────

func _activate_next_globe() -> void:
	var living_player = get_tree().get_first_node_in_group("player")
	if living_player != null and living_player.get("_is_dead") == true:
		return   # no new globes over the death screen
	var dormant : Array = []
	for globe in _all_globes:
		if is_instance_valid(globe) and globe.is_dormant():
			dormant.append(globe)

	if dormant.is_empty():
		_activation_timer = -1.0
		return

	var player = get_tree().get_first_node_in_group("player")
	var chosen : Node3D

	if player != null:
		# Sort so the closest dormant globes to the player are first.
		dormant.sort_custom(func(a, b): return a.global_position.distance_squared_to(player.global_position) < b.global_position.distance_squared_to(player.global_position))
		# Pick from one of the 3 closest so it feels organic but is always nearby.
		var pool_size = mini(3, dormant.size())
		chosen = dormant[randi() % pool_size]
	else:
		chosen = dormant[randi() % dormant.size()]

	chosen.activate()

	_set_alert(ALERT_TEXT, ALERT_COLOR)
	show_globe_alert()
	_start_next_timer()


func _start_next_timer() -> void:
	var has_dormant : bool = false
	for globe in _all_globes:
		if is_instance_valid(globe) and globe.is_dormant():
			has_dormant = true
			break

	if not has_dormant:
		_activation_timer = -1.0
		return

	# Escalate spawn frequency with the run day.
	# Day 1 → 100–130 s between orbs.  Day 30 → 15–30 s (near-constant threat).
	# pow(..., 1.5) keeps early days calm and makes late days feel relentless.
	var day      : float = float(GameClock.current_day)
	var progress : float = pow(clampf(day / 30.0, 0.0, 1.0), 1.5)
	var min_t    : float = lerp(100.0, 15.0, progress)
	var max_t    : float = lerp(130.0, 30.0, progress)
	_activation_timer = randf_range(min_t, max_t)


# ── Spawning ───────────────────────────────────────────────

func spawn_globes(dungeon_gen: Node) -> void:
	if GlobalRunData.debug_no_demonic_orbs:
		return

	if _globe_scene == null:
		push_warning("GlobeManager: Cannot spawn globes — Globe.tscn is missing.")
		return

	var spawn_points := _collect_spawn_points(dungeon_gen)
	if spawn_points.is_empty():
		push_warning("GlobeManager: No valid spawn points found. No globes spawned.")
		return

	spawn_points.shuffle()

	var total_globes : int = mini(globe_count, spawn_points.size())

	for i in total_globes:
		var effect := _pick_random_effect()
		if effect.is_empty():
			continue

		var rarity : String = effect.get("rarity", "common")
		var globe           = _globe_scene.instantiate()

		var pos   : Vector3 = spawn_points[i]
		pos.y              += spawn_height

		dungeon_gen.add_child(globe)
		globe.global_position = pos

		globe.setup(effect, rarity)

		_all_globes.append(globe)

	_is_running = true
	_start_next_timer()


func _collect_spawn_points(dungeon_gen: Node) -> Array:
	var points : Array = []

	var modules : Array = dungeon_gen.get("placed_modules") if dungeon_gen.get("placed_modules") != null else []
	if modules.is_empty():
		push_warning("GlobeManager: placed_modules is empty on the dungeon generator.")
		return points

	for mod in modules:
		if mod is Node3D and dungeon_gen.has_method("get_random_safe_interior_point"):
			var safe_point : Vector3 = dungeon_gen.get_random_safe_interior_point(mod as Node3D, spawn_height)
			if safe_point != Vector3.ZERO:
				points.append(safe_point)

	return points


# Called when a globe is picked up: a modifier curse whose prerequisite the player does not meet
# (e.g. Dimmed Sparks without any spark buff) would do nothing, so another curse of the same
# rarity that does something is handed out instead. Independent curses pass through unchanged.
func resolve_effect_for_pickup(effect: Dictionary) -> Dictionary:
	var player : Node = get_tree().get_first_node_in_group("player")
	if player == null or BuffManager.buff_prerequisites_met(effect, player):
		return effect
	var rarity : String = effect.get("rarity", "common")
	var usable : Array = []
	for entry in _effect_pool.get(rarity, []):
		if BuffManager.buff_prerequisites_met(entry, player) and BuffManager.buff_is_applicable(entry, player):
			usable.append(entry)
	if usable.is_empty():
		for pool_rarity in _effect_pool:
			for entry in _effect_pool[pool_rarity]:
				if BuffManager.buff_prerequisites_met(entry, player) and BuffManager.buff_is_applicable(entry, player):
					usable.append(entry)
	if usable.is_empty():
		return effect
	return usable[randi() % usable.size()]


# ── Rarity and effect selection ────────────────────────────

func _pick_random_effect() -> Dictionary:
	var rarity : String = _weighted_rarity_pick()
	var pool   : Array  = _effect_pool.get(rarity, [])

	if pool.is_empty():
		pool = _effect_pool.get("common", [])

	if pool.is_empty():
		push_warning("GlobeManager: All effect pools are empty. Check globe_effects.json.")
		return {}

	# A curse that touches a stat the player does not have (a Mage-only curse on the Barbarian)
	# would do nothing: skip those when the player is known.
	var player : Node = get_tree().get_first_node_in_group("player")
	if player != null:
		var usable : Array = []
		for entry in pool:
			if BuffManager.buff_is_applicable(entry, player):
				usable.append(entry)
		if not usable.is_empty():
			pool = usable

	return pool[randi() % pool.size()]


func _weighted_rarity_pick() -> String:
	var total : int = 0
	for w in RARITY_WEIGHTS.values():
		total += w

	var roll : int = randi() % total
	var acc  : int = 0
	for rarity in RARITY_WEIGHTS:
		acc += RARITY_WEIGHTS[rarity]
		if roll < acc:
			return rarity

	return "common"


# ── Collection handling ────────────────────────────────────

func _on_globe_collected(_effect: Dictionary) -> void:
	if has_node("/root/AudioManager"):
		AudioManager.play_buff_choice()


# ── Public API ─────────────────────────────────────────────

# Spawns a single potent-curse globe at 'pos', parented to 'parent',
# and immediately activates it so it chases the player.
# Called by destructible_prop.gd on a 15% roll.
func spawn_at(pos: Vector3, parent: Node) -> void:
	if _globe_scene == null:
		push_warning("GlobeManager: spawn_at — Globe.tscn not loaded.")
		return

	# Always use cursed tier for prop drops; fall through to rarer pools if empty.
	var pool : Array = _effect_pool.get("cursed", [])
	if pool.is_empty():
		pool = _effect_pool.get("rare", [])
	if pool.is_empty():
		pool = _effect_pool.get("common", [])
	if pool.is_empty():
		push_warning("GlobeManager: spawn_at — all effect pools empty.")
		return

	var effect : Dictionary = pool[randi() % pool.size()]
	var rarity : String     = effect.get("rarity", "cursed")

	var globe = _globe_scene.instantiate()
	parent.add_child(globe)
	globe.global_position = pos

	globe.setup(effect, rarity)
	globe.activate()

	_all_globes.append(globe)

	# Show the "Potent Curse Sensed" alert so the player is warned.
	_set_alert(ALERT_TEXT, ALERT_COLOR)
	show_globe_alert()


func reset() -> void:
	_all_globes.clear()
	_activation_timer = -1.0
	_alert_timer      = -1.0
	_is_running       = false
	if _alert_label != null:
		_alert_label.modulate.a = 0.0


# Activates the `count` dormant globes nearest to `origin`. Used by the
# chest mimic payload — "opening a mimic wakes the 5 closest curses".
# Returns the number of globes actually activated (may be fewer than
# `count` if there aren't enough dormant globes left in the run).
func activate_nearest_dormant_to(origin: Vector3, count: int) -> int:
	if count <= 0 or _all_globes.is_empty():
		return 0
	var dormant : Array = []
	for g in _all_globes:
		if is_instance_valid(g) and g.is_dormant():
			dormant.append(g)
	if dormant.is_empty():
		return 0
	dormant.sort_custom(func(a, b):
		return a.global_position.distance_squared_to(origin) < b.global_position.distance_squared_to(origin))
	var activated : int = 0
	for i in count:
		if i >= dormant.size():
			break
		dormant[i].activate()
		activated += 1
	if activated > 0:
		show_globe_alert()
	return activated
