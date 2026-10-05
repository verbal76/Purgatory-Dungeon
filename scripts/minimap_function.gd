# ============================================================
#  FILE: minimap_function.gd
#  PATH: res://scripts/minimap_function.gd
#  ATTACHED TO: CanvasLayer (minimap_function)
#  USED BY: Main gameplay scene
#  NOTES: 
#
#  NEW FEATURE: Optimized compass rose. Removed initial "phantom" 
#  text to fix the random top-left letter bug. Adjusted elliptical 
#  padding to keep heading letters away from torn parchment edges.
#
#  SURGICAL FIX: Minimap bounds refresh logic now shuts down once 
#  _bounds_valid becomes true, removing the heavy 1.0s interval
#  stutter while traversing the static generation tree.
# ============================================================

extends CanvasLayer

@export var minimap_action_name: String = "minimap"
@export var hide_when_released: bool = true

@export var map_margin_left: float = 0.0
@export var map_margin_top: float = 0.0
@export var map_margin_right: float = 0.0
@export var map_margin_bottom: float = 0.0

@export var top_down_height: float = 550.0
@export var extra_size_padding: float = 30.0
@export var bounds_padding_world: float = 10.0
# Fraction of the shorter screen dimension the dungeon should occupy (0.0–1.0).
# Increase to zoom in; decrease to zoom out. Compass labels need ~0.12 of space on each side.
@export var map_fill_fraction: float = 0.82
@export var refresh_bounds_interval: float = 1.0

@export var arrow_scale: float = 1.35
@export var arrow_edge_padding: float = 10.0
@export var world_x_to_map_sign: float = 1.0
@export var world_z_to_map_sign: float = 1.0

@onready var root_control: Control = $Root
@onready var parchment_rect: TextureRect = $Root/Parchment
@onready var map_frame: Panel = $Root/MapFrame
@onready var viewport_container: SubViewportContainer = $Root/MapFrame/SubViewportContainer
@onready var minimap_viewport: SubViewport = $Root/MapFrame/SubViewportContainer/SubViewport
@onready var minimap_camera: Camera3D = $Root/MapFrame/SubViewportContainer/SubViewport/MinimapCamera
@onready var player_arrow: Polygon2D = $Root/MapFrame/PlayerArrow

var _generator_root : Node3D
var _player         : Node3D

var _bounds_min    : Vector3 = Vector3.ZERO
var _bounds_max    : Vector3 = Vector3.ZERO
var _bounds_center : Vector3 = Vector3.ZERO
var _bounds_valid  : bool    = false
var _bounds_refresh_timer : float = 0.0
const MOBILE_MAP_INTERVAL : float = 0.12   # phones: the map image refreshes ~8 Hz, the arrow stays per-frame
var _mobile_map_timer     : float = 0.0

var _map_visible : bool = false

var _gameplay_compass_label : Label = null
var _edge_compass_labels    : Array[Label] = []
var _edge_compass_angles    : Array[float] = []

# ── Portal marker ────────────────────────────────────────────
var _portal_dot        : Polygon2D = null
var _portal_world_pos  : Vector3   = Vector3.ZERO
var _portal_active     : bool      = false
var _portal_blink_t    : float     = 0.0
# Last-stand enemy markers: once the portal is open and only a few enemies remain, they are shown
# as red dots so the final hunt is never blind. Pre-allocated, set by PortalManager (see
# set_enemy_markers); nothing is drawn while the list is empty.
const MAX_ENEMY_MARKERS : int = 6
var _enemy_marker_pos   : Array[Vector3] = []
var _enemy_dots         : Array[Polygon2D] = []

# Set false once arrow position is confirmed correct
var _debug_print_position : bool  = false
var _debug_print_timer    : float = 0.0
const DEBUG_PRINT_INTERVAL : float = 1.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	_generator_root = get_parent() as Node3D
	_player         = _find_player()

	_configure_ui()
	_configure_viewport()
	_configure_camera()
	_set_visible_state(false)

	if get_viewport() != null and not get_viewport().size_changed.is_connected(_update_layout):
		get_viewport().size_changed.connect(_update_layout)

	_update_layout()

	await get_tree().process_frame
	force_refresh_bounds()


func _process(delta: float) -> void:
	if _generator_root == null:
		_generator_root = get_parent() as Node3D
	if _player == null:
		_player = _find_player()

	var wants_visible : bool = false
	if InputMap.has_action(minimap_action_name):
		if hide_when_released:
			wants_visible = Input.is_action_pressed(minimap_action_name)
		else:
			wants_visible = Input.is_action_just_pressed(minimap_action_name)

	_set_visible_state(wants_visible)
	_update_compass_labels()

	if not _map_visible:
		return

	if not _bounds_valid:
		_bounds_refresh_timer -= delta
		if _bounds_refresh_timer <= 0.0:
			_bounds_refresh_timer = refresh_bounds_interval
			force_refresh_bounds()

	if TouchControls.is_touch_platform() and minimap_viewport != null:
		_mobile_map_timer -= delta
		if _mobile_map_timer <= 0.0:
			_mobile_map_timer = MOBILE_MAP_INTERVAL
			minimap_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

	_update_camera_from_bounds()
	_update_player_arrow()
	_update_portal_dot()
	_update_enemy_dots()

	if _debug_print_position and _player != null:
		_debug_print_timer -= delta
		if _debug_print_timer <= 0.0:
			_debug_print_timer = DEBUG_PRINT_INTERVAL
			var pw  : Vector3 = _player.global_position
			var pos : Vector2 = _project_player_to_frame()
			print("Player world: ", pw, " | Arrow screen: ", pos, " | Bounds valid: ", _bounds_valid)


func _configure_ui() -> void:
	layer = 30

	if parchment_rect != null:
		parchment_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Darken the parchment to increase map contrast
		parchment_rect.modulate = Color(0.7, 0.7, 0.7, 1.0)

	if map_frame != null:
		map_frame.mouse_filter  = Control.MOUSE_FILTER_IGNORE
		map_frame.clip_contents = true

	if viewport_container != null:
		viewport_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
		viewport_container.stretch      = false

	if player_arrow != null:
		player_arrow.visible = true
		player_arrow.color   = Color(0.9, 0.08, 0.08, 1.0)
		player_arrow.scale   = Vector2(arrow_scale, arrow_scale)

	_build_compass_overlays()


func _build_compass_overlays() -> void:
	# 1. Standard HUD Compass (Anchored perfectly under the health bar)
	if root_control != null and _gameplay_compass_label == null:
		_gameplay_compass_label = Label.new()
		_gameplay_compass_label.name = "GameplayCompassLabel"
		_gameplay_compass_label.position = Vector2(20.0, 52.0)
		_gameplay_compass_label.add_theme_font_size_override("font_size", 22)
		_gameplay_compass_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.8, 1.0))
		_gameplay_compass_label.text = "" # Start empty to prevent random letters on load
		root_control.add_child(_gameplay_compass_label)

	# 2. Minimap Edge Compass Rose (Elliptical layout)
	if map_frame != null and _edge_compass_labels.is_empty():
		var map_ink_color := Color(0.102, 0.102, 0.102, 1.0)
		
		# Mathematically maps the 8 standard points to an elliptical ring
		var directions = [
			{"name": "N",  "angle": -PI / 2.0},
			{"name": "NE", "angle": -PI / 4.0},
			{"name": "E",  "angle": 0.0},
			{"name": "SE", "angle": PI / 4.0},
			{"name": "S",  "angle": PI / 2.0},
			{"name": "SW", "angle": 3.0 * PI / 4.0},
			{"name": "W",  "angle": PI},
			{"name": "NW", "angle": -3.0 * PI / 4.0}
		]
		
		for dir in directions:
			var lbl := Label.new()
			lbl.text = dir["name"]
			var font_size = 28 if dir["name"].length() == 1 else 20
			lbl.add_theme_font_size_override("font_size", font_size)
			lbl.add_theme_color_override("font_color", map_ink_color)
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			
			# Lock the label's local origin to the exact center of the screen
			lbl.set_anchors_preset(Control.PRESET_CENTER)
			lbl.grow_horizontal = Control.GROW_DIRECTION_BOTH
			lbl.grow_vertical   = Control.GROW_DIRECTION_BOTH
			
			map_frame.add_child(lbl)
			_edge_compass_labels.append(lbl)
			_edge_compass_angles.append(dir["angle"])


func _configure_viewport() -> void:
	if minimap_viewport == null:
		return

	minimap_viewport.transparent_bg               = false
	minimap_viewport.handle_input_locally         = false
	# Phones draw the whole dungeon a second time for this view: no MSAA there (see _set_visible_state
	# for the refresh-rate cap).
	minimap_viewport.msaa_3d                      = Viewport.MSAA_DISABLED if TouchControls.is_touch_platform() else Viewport.MSAA_2X
	minimap_viewport.use_occlusion_culling        = false
	minimap_viewport.render_target_update_mode    = SubViewport.UPDATE_ALWAYS
	minimap_viewport.positional_shadow_atlas_size = 0


func _configure_camera() -> void:
	if minimap_camera == null:
		return

	minimap_camera.projection       = Camera3D.PROJECTION_ORTHOGONAL
	minimap_camera.current          = true
	minimap_camera.near             = 0.05
	minimap_camera.far              = 5000.0
	minimap_camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	minimap_camera.cull_mask        = 1   # Layer 1 only — excludes FlameMesh spheres (layer 2)

	# Per-camera environment: dark background so dungeon floors are visible regardless of material color.
	# transparent_bg=false means the SubViewport shows this environment background instead of the main scene sky.
	var cam_env := Environment.new()
	cam_env.background_mode      = Environment.BG_COLOR
	cam_env.background_color     = Color(0.06, 0.05, 0.04, 1.0)   # Very dark warm
	cam_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	cam_env.ambient_light_color  = Color(0.60, 0.55, 0.50, 1.0)   # Warm neutral
	cam_env.ambient_light_energy = 2.0
	minimap_camera.environment   = cam_env


func _set_minimap_near_clip() -> void:
	# Camera sits at _bounds_center.y + top_down_height looking straight down.
	# We want to clip past the ceiling (~3.5 m above floor) but keep the floor visible.
	# near = distance from camera to a point halfway between ceiling and floor.
	if minimap_camera == null:
		return
	var ceiling_y : float = _bounds_max.y if _bounds_valid else 3.5
	var floor_y   : float = _bounds_min.y if _bounds_valid else 0.0
	var cam_y     : float = _bounds_center.y + top_down_height
	var dist_ceiling : float = cam_y - ceiling_y
	var dist_floor   : float = cam_y - floor_y
	# Midpoint between ceiling and floor gives clean clip without touching either
	minimap_camera.near = (dist_ceiling + dist_floor) * 0.5


func _set_visible_state(state: bool) -> void:
	_map_visible = state

	if parchment_rect != null:
		parchment_rect.visible = state

	if map_frame != null:
		map_frame.visible = state

	if player_arrow != null:
		player_arrow.visible = state

	for lbl in _edge_compass_labels:
		if lbl != null:
			lbl.visible = state

	if minimap_viewport != null:
		if state and TouchControls.is_touch_platform():
			pass   # throttled: _process re-renders it with UPDATE_ONCE every MOBILE_MAP_INTERVAL
		else:
			minimap_viewport.render_target_update_mode = \
				SubViewport.UPDATE_ALWAYS if state else SubViewport.UPDATE_DISABLED

	# On every open: force a fresh bounds scan so the camera re-centers on the dungeon
	if state:
		_bounds_valid = false
		_bounds_refresh_timer = 0.0
		_set_minimap_near_clip()
	elif minimap_camera != null:
		minimap_camera.near = 0.05


func _update_layout() -> void:
	if root_control == null:
		return

	root_control.anchor_left   = 0.0
	root_control.anchor_top    = 0.0
	root_control.anchor_right  = 1.0
	root_control.anchor_bottom = 1.0
	root_control.offset_left   = 0.0
	root_control.offset_top    = 0.0
	root_control.offset_right  = 0.0
	root_control.offset_bottom = 0.0

	if parchment_rect != null:
		parchment_rect.anchor_left   = 0.0
		parchment_rect.anchor_top    = 0.0
		parchment_rect.anchor_right  = 1.0
		parchment_rect.anchor_bottom = 1.0
		parchment_rect.offset_left   = 0.0
		parchment_rect.offset_top    = 0.0
		parchment_rect.offset_right  = 0.0
		parchment_rect.offset_bottom = 0.0

	if map_frame != null:
		map_frame.anchor_left   = 0.0
		map_frame.anchor_top    = 0.0
		map_frame.anchor_right  = 1.0
		map_frame.anchor_bottom = 1.0
		map_frame.offset_left   =  map_margin_left
		map_frame.offset_top    =  map_margin_top
		map_frame.offset_right  = -map_margin_right
		map_frame.offset_bottom = -map_margin_bottom

	if viewport_container != null:
		viewport_container.anchor_left   = 0.0
		viewport_container.anchor_top    = 0.0
		viewport_container.anchor_right  = 1.0
		viewport_container.anchor_bottom = 1.0
		viewport_container.offset_left   = 0.0
		viewport_container.offset_top    = 0.0
		viewport_container.offset_right  = 0.0
		viewport_container.offset_bottom = 0.0

	if minimap_viewport != null and map_frame != null:
		var frame_size : Vector2 = map_frame.size
		minimap_viewport.size = Vector2i(maxi(int(frame_size.x), 1), maxi(int(frame_size.y), 1))
		
		# Calculate the elliptical ring for the edge compass
		if not _edge_compass_labels.is_empty():
			var padding := 35.0 # Increased to push NW/NE away from torn corners
			var rx := maxf((frame_size.x * 0.5) - padding, 10.0)
			var ry := maxf((frame_size.y * 0.5) - padding, 10.0)
			
			for i in range(_edge_compass_labels.size()):
				var lbl = _edge_compass_labels[i]
				var angle = _edge_compass_angles[i]
				
				# Push labels outward from the center based on the ellipse
				var tx = cos(angle) * rx
				var ty = sin(angle) * ry
				
				lbl.offset_left   = tx
				lbl.offset_right  = tx
				lbl.offset_top    = ty
				lbl.offset_bottom = ty

	_update_camera_from_bounds()
	_update_player_arrow()


func _find_player() -> Node3D:
	if _generator_root == null:
		return null

	var direct : Node = _generator_root.get_node_or_null("Player")
	if direct is Node3D:
		return direct as Node3D

	var found : Array[Node] = get_tree().get_nodes_in_group("player")
	for entry in found:
		if entry is Node3D:
			return entry as Node3D

	return null


func _refresh_dungeon_bounds() -> void:
	if _generator_root == null:
		return

	var module_nodes : Array = []
	if "placed_modules" in _generator_root:
		module_nodes = _generator_root.placed_modules

	if module_nodes.is_empty():
		_build_bounds_from_root_children()
		return

	# Use the generator's true world-space AABB for each module. Module pivots
	# often sit at one edge (at a Connection_* marker), so position-only bounds
	# clipped hallway-end modules whose meshes extend outward from the pivot.
	# get_module_aabb() is the generator's cached accessor (dungeon_generation_function.gd:722).
	var gen : Node = _generator_root.get_node_or_null("DungeonGenerationFunction")
	var use_generator_aabb : bool = gen != null and gen.has_method("get_module_aabb")

	var first_found : bool    = false
	var temp_min    : Vector3 = Vector3.ZERO
	var temp_max    : Vector3 = Vector3.ZERO

	for module_entry in module_nodes:
		if not (module_entry is Node3D):
			continue
		var mn : Node3D = module_entry as Node3D
		if not is_instance_valid(mn):
			continue

		var lo : Vector3
		var hi : Vector3
		if use_generator_aabb:
			var aabb : AABB = gen.get_module_aabb(mn)
			if aabb.size == Vector3.ZERO:
				# AABB computation failed (no MeshInstance3D children yet) —
				# fall back to pivot + small pad so the module isn't dropped entirely.
				lo = mn.global_position - Vector3(5, 0, 5)
				hi = mn.global_position + Vector3(5, 0, 5)
			else:
				lo = aabb.position
				hi = aabb.position + aabb.size
		else:
			lo = mn.global_position
			hi = mn.global_position

		if not first_found:
			temp_min    = lo
			temp_max    = hi
			first_found = true
		else:
			temp_min = temp_min.min(lo)
			temp_max = temp_max.max(hi)

	if not first_found:
		_build_bounds_from_root_children()
		return

	# Small breathing-room pad on all sides — no longer compensating for pivot offsets,
	# just keeping the outermost walls from touching the frame edge.
	temp_min.x -= bounds_padding_world
	temp_min.z -= bounds_padding_world
	temp_max.x += bounds_padding_world
	temp_max.z += bounds_padding_world

	_bounds_min    = temp_min
	_bounds_max    = temp_max
	_bounds_center = (_bounds_min + _bounds_max) * 0.5
	_bounds_valid  = true


func _build_bounds_from_root_children() -> void:
	if _generator_root == null:
		return

	var first_found : bool    = false
	var temp_min    : Vector3 = Vector3.ZERO
	var temp_max    : Vector3 = Vector3.ZERO

	for child in _generator_root.get_children():
		if child == self or child == _player or child is CanvasLayer:
			continue
		if not (child is Node3D):
			continue
		var cb : Dictionary = _collect_visual_bounds(child as Node3D)
		if not bool(cb.get("valid", false)):
			continue
		if not first_found:
			temp_min    = cb["min"]
			temp_max    = cb["max"]
			first_found = true
		else:
			temp_min = temp_min.min(cb["min"])
			temp_max = temp_max.max(cb["max"])

	if not first_found:
		_bounds_valid = false
		return

	temp_min.x -= bounds_padding_world
	temp_min.z -= bounds_padding_world
	temp_max.x += bounds_padding_world
	temp_max.z += bounds_padding_world

	_bounds_min    = temp_min
	_bounds_max    = temp_max
	_bounds_center = (_bounds_min + _bounds_max) * 0.5
	_bounds_valid  = true


func _collect_visual_bounds(root_node: Node3D) -> Dictionary:
	var found_any : bool    = false
	var temp_min  : Vector3 = Vector3.ZERO
	var temp_max  : Vector3 = Vector3.ZERO
	var stack     : Array[Node] = [root_node]

	while not stack.is_empty():
		var current : Node = stack.pop_back()
		for child in current.get_children():
			stack.append(child)
		if current == _player:
			continue
		if current is MeshInstance3D:
			var mi : MeshInstance3D = current as MeshInstance3D
			if mi.mesh == null:
				continue
			for corner in _aabb_to_world_corners(mi.get_aabb(), mi.global_transform):
				if not found_any:
					temp_min  = corner
					temp_max  = corner
					found_any = true
				else:
					temp_min = temp_min.min(corner)
					temp_max = temp_max.max(corner)

	return { "valid": found_any, "min": temp_min, "max": temp_max }


func _aabb_to_world_corners(box: AABB, xform: Transform3D) -> Array[Vector3]:
	var corners : Array[Vector3] = []
	var p : Vector3 = box.position
	var s : Vector3 = box.size
	corners.append(xform * Vector3(p.x,       p.y,       p.z      ))
	corners.append(xform * Vector3(p.x + s.x, p.y,       p.z      ))
	corners.append(xform * Vector3(p.x,       p.y + s.y, p.z      ))
	corners.append(xform * Vector3(p.x,       p.y,       p.z + s.z))
	corners.append(xform * Vector3(p.x + s.x, p.y + s.y, p.z      ))
	corners.append(xform * Vector3(p.x + s.x, p.y,       p.z + s.z))
	corners.append(xform * Vector3(p.x,       p.y + s.y, p.z + s.z))
	corners.append(xform * Vector3(p.x + s.x, p.y + s.y, p.z + s.z))
	return corners


func _update_camera_from_bounds() -> void:
	if not _bounds_valid or minimap_camera == null or map_frame == null:
		return

	var map_width  : float = maxf(_bounds_max.x - _bounds_min.x, 1.0)
	var map_depth  : float = maxf(_bounds_max.z - _bounds_min.z, 1.0)
	var frame_size : Vector2 = map_frame.size
	var aspect     : float = maxf(frame_size.x, 1.0) / maxf(frame_size.y, 1.0)

	var req_from_depth : float = map_depth
	var req_from_width : float = map_width / maxf(aspect, 0.001)
	# Scale so the dungeon fills map_fill_fraction of the screen, leaving edges for compass labels.
	# Falls back to extra_size_padding if fill_fraction is too small (< 0.1).
	var map_span   : float = maxf(req_from_depth, req_from_width)
	var ortho_size : float = map_span / maxf(map_fill_fraction, 0.1)

	minimap_camera.position = Vector3(_bounds_center.x, _bounds_center.y + top_down_height, _bounds_center.z)
	minimap_camera.size     = ortho_size
	if _map_visible:
		_set_minimap_near_clip()


func _project_world_to_frame(world_pos: Vector3) -> Vector2:
	if minimap_camera == null or map_frame == null:
		return Vector2.ZERO

	var projected : Vector2 = minimap_camera.unproject_position(world_pos)

	projected.x *= world_x_to_map_sign
	projected.y *= world_z_to_map_sign

	if world_x_to_map_sign < 0.0:
		projected.x = map_frame.size.x - projected.x
	if world_z_to_map_sign < 0.0:
		projected.y = map_frame.size.y - projected.y

	projected.x = clampf(projected.x, arrow_edge_padding, map_frame.size.x - arrow_edge_padding)
	projected.y = clampf(projected.y, arrow_edge_padding, map_frame.size.y - arrow_edge_padding)

	return projected


func _project_player_to_frame() -> Vector2:
	if minimap_camera == null or map_frame == null or _player == null:
		return map_frame.size * 0.5 if map_frame != null else Vector2.ZERO

	return _project_world_to_frame(_player.global_position)


func _update_player_arrow() -> void:
	if not _bounds_valid or _player == null or map_frame == null or player_arrow == null or minimap_camera == null:
		return

	var player_screen : Vector2 = _project_world_to_frame(_player.global_position)

	var forward_3d : Vector3 = (-_player.global_transform.basis.z).normalized()
	var sample_distance : float = 3.0
	var forward_sample_world : Vector3 = _player.global_position + (forward_3d * sample_distance)
	var forward_screen : Vector2 = _project_world_to_frame(forward_sample_world)

	var facing_2d : Vector2 = forward_screen - player_screen
	if facing_2d.length_squared() <= 0.0001:
		facing_2d = Vector2.UP

	player_arrow.position = player_screen

	# Arrow art points up, but Vector2.angle() uses +X as zero.
	# Add 90 degrees so the arrow points where the player is actually facing.
	player_arrow.rotation = facing_2d.angle() + (PI * 0.5)


func _update_compass_labels() -> void:
	if _player == null:
		return

	var heading_degrees : int = _get_player_heading_degrees()
	var cardinal : String = _get_cardinal_from_degrees(heading_degrees)

	# Exclusively print the raw cardinal letter(s) to the HUD
	if _gameplay_compass_label != null:
		_gameplay_compass_label.text = cardinal


func _get_player_heading_degrees() -> int:
	if _player == null:
		return 0

	var forward_3d : Vector3 = (-_player.global_transform.basis.z).normalized()

	# 0° = north/top of map = world -Z
	var heading_radians : float = atan2(forward_3d.x, -forward_3d.z)
	var heading_degrees : int = int(round(rad_to_deg(heading_radians)))

	if heading_degrees < 0:
		heading_degrees += 360

	return heading_degrees % 360


func _get_cardinal_from_degrees(degrees: int) -> String:
	var directions := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	var index : int = int(round(float(degrees) / 15.0)) % 8
	return directions[index]


func force_refresh_bounds() -> void:
	_refresh_dungeon_bounds()
	_update_camera_from_bounds()
	_update_player_arrow()
	_update_compass_labels()


# ── Portal marker public API ─────────────────────────────────

# Called by PortalManager once the portal spawns.
# Creates a gold blinking diamond on the minimap at the portal's world position.
func set_portal_position(world_pos: Vector3) -> void:
	_portal_world_pos = world_pos
	_portal_active    = true

	if map_frame == null:
		return

	if _portal_dot != null:
		_portal_dot.queue_free()

	_portal_dot = Polygon2D.new()
	_portal_dot.name   = "PortalDot"
	# Diamond shape — 8-pixel half-size
	var s : float = 8.0
	_portal_dot.polygon = PackedVector2Array([
		Vector2(0.0, -s), Vector2(s, 0.0), Vector2(0.0, s), Vector2(-s, 0.0)
	])
	_portal_dot.color = Color(1.0, 0.85, 0.0, 1.0)   # Gold
	_portal_dot.z_index = 5
	map_frame.add_child(_portal_dot)


## World positions of the enemies to mark (at most MAX_ENEMY_MARKERS; empty clears them).
func set_enemy_markers(positions: Array) -> void:
	_enemy_marker_pos.clear()
	for p in positions:
		if _enemy_marker_pos.size() >= MAX_ENEMY_MARKERS:
			break
		_enemy_marker_pos.append(p)
	if _enemy_marker_pos.is_empty():
		for dot in _enemy_dots:
			dot.visible = false


func _update_enemy_dots() -> void:
	if _enemy_marker_pos.is_empty() or not _bounds_valid:
		return
	while _enemy_dots.size() < _enemy_marker_pos.size():
		var dot := Polygon2D.new()
		dot.name = "EnemyDot%d" % _enemy_dots.size()
		var pts := PackedVector2Array()
		for i in 10:
			pts.append(Vector2.from_angle(TAU * float(i) / 10.0) * 7.0)
		dot.polygon = pts
		dot.color   = Color(1.0, 0.15, 0.1, 1.0)   # Red, distinct from the gold portal diamond
		dot.z_index = 5
		map_frame.add_child(dot)
		_enemy_dots.append(dot)
	for i in _enemy_dots.size():
		if i < _enemy_marker_pos.size():
			_enemy_dots[i].position = _project_world_to_frame(_enemy_marker_pos[i])
			_enemy_dots[i].visible = true
		else:
			_enemy_dots[i].visible = false


func clear_portal_marker() -> void:
	set_enemy_markers([])
	_portal_active = false
	if _portal_dot != null:
		_portal_dot.queue_free()
		_portal_dot = null


func _update_portal_dot() -> void:
	if not _portal_active or _portal_dot == null or not _bounds_valid:
		return

	_portal_blink_t += get_process_delta_time() * 3.0
	_portal_dot.visible = int(_portal_blink_t) % 2 == 0

	var screen_pos : Vector2 = _project_world_to_frame(_portal_world_pos)
	_portal_dot.position = screen_pos
