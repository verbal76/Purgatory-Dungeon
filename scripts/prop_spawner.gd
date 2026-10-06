# ============================================================
#  FILE: prop_spawner.gd
#  PATH: res://scripts/prop_spawner.gd
#  ATTACHED TO: Node3D added dynamically in
#               Purgatory_Dungeon_main_game_file.gd
#  DESCRIPTION: Randomly places destructible decorative props on
#               dungeon floors.
#
#  ROOM FILTER: Only spawns in modules with counts_toward_goal=true
#               (main rooms). Connectors and end-caps are skipped
#               to keep doorways clear.
#
#  COUNT:       60 % of eligible rooms skipped; 2–4 props per room
#               that does get props.
# ============================================================

extends Node3D

@export var skip_module_chance : float = 0.00   # Every non-connector room gets props
@export var props_per_room_min : int   = 2       # doubled from original 1
@export var props_per_room_max : int   = 4       # doubled from original 2
@export var spawn_height       : float = 0.05   # y metres above floor

# Furniture grouping — a minority of eligible rooms get a table-with-stools
# arrangement somewhere near (not at) the room centre. Most rooms stay as
# scattered random props — a lone stool can still appear that way.
@export var furniture_group_chance      : float = 0.25
@export var furniture_group_radius      : float = 1.5   # stool orbit radius
@export var furniture_group_centre_jitter : float = 0.6  # table offset from centre
@export var furniture_group_angle_jitter  : float = 0.35 # ± radians per stool
@export var furniture_group_radius_jitter : float = 0.25 # ± metres per stool

# Toppers: small details (book, bottle, candle, coins) placed on top of
# crates / tables / barrels. They also spawn on the floor via the general
# scatter pool, so single-item finds still feel natural.
@export var topper_chance       : float = 0.35   # chance a carrier prop gets toppers
@export var topper_height_offset : float = 0.6   # y above parent origin — sits closer to the visible table/crate top
@export var topper_xz_jitter    : float = 0.22

# Wall furniture: large floor pieces that look best against a wall.
# Independent per-room roll — can coexist with scatter or a furniture group.
@export var wall_furniture_chance : float = 0.12
@export var wall_offset           : float = 0.5   # metres from wall, inward

const PROP_MODELS : Array[String] = [
	"res://addons/props/SM_Anvil.fbx",
	"res://addons/props/SM_LargeBookPile.fbx",
	"res://addons/props/SM_MetalCrate.fbx",
	"res://addons/props/SM_Self.fbx",
	"res://addons/props/SM_Stool.fbx",
	"res://addons/props/SM_WoodenBarrle.fbx",
	"res://addons/props/SM_WoodenContainer.fbx",
	"res://addons/props/SM_WoodenCrate.fbx",
	"res://addons/props/SM_WoodenTable.fbx",
	"res://addons/props/SM_BrownBook.fbx",
	"res://addons/props/SM_Bottle.fbx",
	"res://addons/props/SM_Candle.fbx",
	"res://addons/props/SM_SmallPileOfCoins.fbx",
	"res://addons/props/SM_WoodenBarrlePieces.fbx",
	"res://addons/props/SM_WoodenContainerWithBottles.fbx",
]

# Small details placed on top of carriers. Same models exist in PROP_MODELS
# for floor-scatter duty — this is just the subset eligible to sit on things.
const TOPPER_MODELS : Array[String] = [
	"res://addons/props/SM_BrownBook.fbx",
	"res://addons/props/SM_Bottle.fbx",
	"res://addons/props/SM_Candle.fbx",
	"res://addons/props/SM_SmallPileOfCoins.fbx",
]

# Substrings that identify a carrier (accepts toppers on its top face).
const _TOPPER_CARRIER_KEYWORDS : Array[String] = ["Crate", "Table", "Barrle"]
const _TOPPER_CARRIER_EXCLUDES : Array[String] = ["Pieces"]

# Wall-aligned furniture pool. Not in PROP_MODELS — these never scatter.
const WALL_FURNITURE_MODELS : Array[String] = [
	"res://addons/props/SM_EmptyBookShelf.fbx",
	"res://addons/props/SM_FullBookShelf.fbx",
	"res://addons/props/SM_EssentialOilDistillationKit.fbx",
	"res://addons/props/SM_GrindStone.fbx",
]

const TABLE_MODEL : String = "res://addons/props/SM_WoodenTable.fbx"
const STOOL_MODEL : String = "res://addons/props/SM_Stool.fbx"

const ALBEDO_TEX   : String = "res://addons/props/SM_GeneralProps_Mat_GeneralProps_AlbedoTransparency.tga"
const METALLIC_TEX : String = "res://addons/props/SM_GeneralProps_Mat_GeneralProps_MetallicSmoothness.tga"
const NORMAL_TEX   : String = "res://addons/props/SM_GeneralProps_Mat_GeneralProps_Normal.tga"

const _PropScript = preload("res://scripts/destructible_prop.gd")

var _shared_mat : StandardMaterial3D = null


func _ready() -> void:
	# Wait two frames for the dungeon generator to finish placing all modules.
	await get_tree().process_frame
	await get_tree().process_frame
	_entry_mark("props_begin")
	_build_shared_material()
	_entry_mark("props_material")
	await _spawn_all_props()
	_entry_mark("props_end")


func _entry_mark(label: String) -> void:
	var main : Node = get_parent()
	if main != null and main.has_method("entry_mark"):
		main.entry_mark(label)


func _build_shared_material() -> void:
	_shared_mat = StandardMaterial3D.new()

	if ResourceLoader.exists(ALBEDO_TEX):
		_shared_mat.albedo_texture = load(ALBEDO_TEX)

	if ResourceLoader.exists(METALLIC_TEX):
		var mt : Texture2D = load(METALLIC_TEX)
		_shared_mat.metallic                  = 1.0
		_shared_mat.metallic_texture          = mt
		_shared_mat.metallic_texture_channel  = BaseMaterial3D.TEXTURE_CHANNEL_RED
		_shared_mat.roughness                 = 1.0
		_shared_mat.roughness_texture         = mt
		_shared_mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN

	if ResourceLoader.exists(NORMAL_TEX):
		_shared_mat.normal_enabled = true
		_shared_mat.normal_texture = load(NORMAL_TEX)


func _spawn_all_props() -> void:
	var gen : Node = get_parent().get_node_or_null("DungeonGenerationFunction")
	if gen == null:
		push_warning("PropSpawner: DungeonGenerationFunction not found.")
		return

	var modules : Array = gen.get("placed_modules") if gen.get("placed_modules") != null else []
	if modules.is_empty():
		push_warning("PropSpawner: placed_modules is empty.")
		return

	# Stagger spawning so that hundreds of RigidBody3D + FBX instantiations
	# don't all land on a single frame. Each prop's _ready() sets up physics,
	# contact monitoring, collision shape, material — cheap individually but
	# a hard freeze when 300+ happen synchronously.
	const BATCH_SIZE : int = 15
	var spawned_in_batch : int = 0

	for mod in modules:
		if not (mod is Node3D):
			continue

		# Skip connectors and end-caps — only place props in main rooms.
		# DungeonGenerationFunction registers connectors/caps with
		# counts_toward_goal=false to exclude them from the explore counter.
		if not bool(mod.get_meta("counts_toward_goal", false)):
			continue

		if randf() < skip_module_chance:
			continue

		# Wall furniture (independent per-room roll, stacks with other placements).
		if randf() < wall_furniture_chance:
			var wall_placed : int = _try_spawn_wall_furniture(gen, mod as Node3D)
			spawned_in_batch += wall_placed
			if spawned_in_batch >= BATCH_SIZE:
				spawned_in_batch = 0
				await get_tree().process_frame

		# Furniture rooms: 1 table at centre, 2–4 stools around it.
		# Skips the scatter pass for this room so we don't overcrowd.
		if randf() < furniture_group_chance:
			var placed : int = _try_spawn_furniture_group(gen, mod as Node3D)
			if placed > 0:
				spawned_in_batch += placed
				if spawned_in_batch >= BATCH_SIZE:
					spawned_in_batch = 0
					await get_tree().process_frame
				continue

		var count : int = randi_range(props_per_room_min, props_per_room_max)
		for _i in count:
			var pos : Vector3 = gen.get_random_safe_interior_point(
				mod as Node3D, spawn_height, 2.0)
			if pos == Vector3.ZERO:
				continue
			spawned_in_batch += _place_prop(pos)
			if spawned_in_batch >= BATCH_SIZE:
				spawned_in_batch = 0
				await get_tree().process_frame


func _place_prop(pos: Vector3, model_path: String = "", y_rot: float = -1.0, as_topper: bool = false) -> int:
	# Empty model_path → random prop from PROP_MODELS. Non-empty → caller's choice.
	# y_rot < 0 → random yaw; otherwise use the caller's exact rotation.
	# as_topper = true → the destructible_prop keeps small-decor models solid
	# so they can scatter via shrapnel when the carrier below is kicked.
	# Returns the number of props actually spawned (1 + any toppers placed on top).
	var chosen : String = model_path if model_path != "" else PROP_MODELS[randi() % PROP_MODELS.size()]

	# Set data vars before add_child() so _ready() inside the prop can use them.
	# Props are kickable (no HP) — only mesh + shared material are configured here.
	var prop           := _PropScript.new()
	prop._model_path    = chosen
	prop._shared_mat    = _shared_mat
	prop._is_topper     = as_topper
	prop.rotation.y     = y_rot if y_rot >= 0.0 else randf_range(0.0, TAU)
	add_child(prop)
	prop.global_position = pos

	return 1 + _maybe_spawn_toppers(pos, chosen)


# If the just-placed prop is a carrier (crate/table/barrel, not Pieces), rolls
# topper_chance to place 1–2 small detail items on top. Toppers are regular
# kickable_props; destructible_prop.gd's shrapnel scan picks them up at kick
# time and scatters them upward.
func _maybe_spawn_toppers(parent_pos: Vector3, parent_model: String) -> int:
	var is_carrier : bool = false
	for kw in _TOPPER_CARRIER_KEYWORDS:
		if parent_model.findn(kw) >= 0:
			is_carrier = true
			break
	if not is_carrier:
		return 0
	for kw in _TOPPER_CARRIER_EXCLUDES:
		if parent_model.findn(kw) >= 0:
			return 0
	if randf() >= topper_chance:
		return 0

	var count : int = randi_range(1, 2)
	var placed : int = 0
	for i in count:
		var model : String = TOPPER_MODELS[randi() % TOPPER_MODELS.size()]
		var topper_pos := Vector3(
			parent_pos.x + randf_range(-topper_xz_jitter, topper_xz_jitter),
			parent_pos.y + topper_height_offset,
			parent_pos.z + randf_range(-topper_xz_jitter, topper_xz_jitter)
		)
		placed += _place_prop(topper_pos, model, -1.0, true)
	return placed


# Places one large wall-aligned piece against a random interior wall of the
# room. Oriented so the model's -Z axis points at the wall (standard FBX
# "back" convention — if any model is authored backwards, we'll flip that one
# specifically in a follow-up). Returns 1 on success, 0 if the room is too
# small or the module AABB is unavailable.
func _try_spawn_wall_furniture(gen: Node, mod: Node3D) -> int:
	if not gen.has_method("get_module_aabb"):
		return 0
	var aabb : AABB = gen.get_module_aabb(mod)
	# Need at least a 3×3 m footprint or the wall offset eats the whole room.
	if aabb.size.x < 3.0 or aabb.size.z < 3.0:
		return 0

	var floor_y : float = mod.global_position.y + spawn_height
	var inset   : float = 1.0   # minimum distance along the wall from the corners
	var pos     : Vector3 = Vector3.ZERO
	var y_rot   : float   = 0.0

	# FBX models in this set are authored with +Z as the "back" (user feedback:
	# the previous -Z-faces-wall assumption placed shelves backwards). Each case
	# below rotates so the model's +Z axis points at the wall — effectively the
	# old rotation + PI.
	match randi() % 4:
		0:  # West wall (X-): back (+Z local) → -X world.
			pos = Vector3(
				aabb.position.x + wall_offset,
				floor_y,
				randf_range(aabb.position.z + inset, aabb.position.z + aabb.size.z - inset)
			)
			y_rot = -PI / 2.0
		1:  # East wall (X+): back (+Z local) → +X world.
			pos = Vector3(
				aabb.position.x + aabb.size.x - wall_offset,
				floor_y,
				randf_range(aabb.position.z + inset, aabb.position.z + aabb.size.z - inset)
			)
			y_rot = PI / 2.0
		2:  # North wall (Z-): back (+Z local) → -Z world.
			pos = Vector3(
				randf_range(aabb.position.x + inset, aabb.position.x + aabb.size.x - inset),
				floor_y,
				aabb.position.z + wall_offset
			)
			y_rot = PI
		3:  # South wall (Z+): back (+Z local) → +Z world (default yaw 0).
			pos = Vector3(
				randf_range(aabb.position.x + inset, aabb.position.x + aabb.size.x - inset),
				floor_y,
				aabb.position.z + aabb.size.z - wall_offset
			)
			y_rot = 0.0

	var model : String = WALL_FURNITURE_MODELS[randi() % WALL_FURNITURE_MODELS.size()]
	# Furniture is meant to sit against a wall, but the wall position comes from the room's
	# bounding box; in non-rectangular rooms that can be inside a wall. Skip those.
	if gen.has_method("is_position_clear") and not gen.is_position_clear(pos + Vector3(0.0, 0.6, 0.0), 0.1):
		return 0
	return _place_prop(pos, model, y_rot)


# Attempts to place a table-with-stools group near the room's centre.
# The table is offset from dead-centre by a small random jitter; each stool
# has its own angle + radius jitter so groups don't look mechanically radial.
# Returns the number of props placed (0 if the module's AABB is missing,
# letting the caller fall back to scattered random props for that room).
func _try_spawn_furniture_group(gen: Node, mod: Node3D) -> int:
	if not gen.has_method("get_module_aabb"):
		return 0
	var aabb : AABB = gen.get_module_aabb(mod)
	if aabb.size == Vector3.ZERO:
		return 0

	var centre : Vector3 = aabb.get_center()
	var floor_y : float = mod.global_position.y + spawn_height
	var j : float = furniture_group_centre_jitter
	var table_pos := Vector3(
		centre.x + randf_range(-j, j),
		floor_y,
		centre.z + randf_range(-j, j)
	)
	# Sum _place_prop returns so any toppers on the table count toward the
	# BATCH_SIZE yielding pass in the caller.
	var total : int = _place_prop(table_pos, TABLE_MODEL)

	var stool_count : int = randi_range(2, 4)
	var start_angle : float = randf() * TAU
	for i in stool_count:
		var base_angle : float = start_angle + TAU * float(i) / float(stool_count)
		var angle : float = base_angle + randf_range(-furniture_group_angle_jitter, furniture_group_angle_jitter)
		var r : float = furniture_group_radius + randf_range(-furniture_group_radius_jitter, furniture_group_radius_jitter)
		var stool_pos := Vector3(
			table_pos.x + cos(angle) * r,
			floor_y,
			table_pos.z + sin(angle) * r
		)
		total += _place_prop(stool_pos, STOOL_MODEL)
	return total
