# ==============================================================================
#  FILE: module_visibility.gd
#  PATH: res://scripts/module_visibility.gd
#  DESCRIPTION: Rooms outside the useful player area do not cost any rendering work.
#
#  Godot draws every mesh that is inside the camera frustum, however far away and however many
#  walls are in between (there are no occluders in this project). In a ~110-room dungeon 85-95 % of
#  the meshes in the frustum are more than 50 m from the camera and up to 70 % of the draw calls of
#  a big view are more than 150 m away, where the torches have faded out and nothing is lit.
#
#  This node hides, at ~4 Hz, whole modules (and what visually belongs to them) that are far from
#  the camera. Only `visible` of render nodes is changed: collision shapes, physics bodies,
#  Areas, enemies, AI, navigation waypoints, spawning, exploration and the minimap data are not
#  touched (a hidden Node3D still collides, is still found by rays and queries).
#
#  Rules
#   - Distance is measured from the camera to the module's world AABB (0 inside the module), so the
#     module the camera is in and every doorway neighbour (their AABBs touch) are always shown.
#   - A module is shown within R_BASE (70 m), and within R_FORWARD (110 m) when it lies in the
#     forward cone: that is where a long straight corridor or a big room can be seen from.
#     Beyond that it is hidden. Hysteresis (HYSTERESIS m) stops flip-flopping at the border.
#   - The same rule hides what is not parented under a module: the torch flame batches, the props
#     (PropSpawner children), the chests (group "chest") and the health orbs, by their own position,
#     so nothing hangs in the void. Items another script hid are left alone (see _hid).
#   - While the map is open (minimap_function._map_visible) everything is shown, because the minimap
#     camera sits 550 m above the level and renders the same meshes; it is hidden again after.
#   - The portal ("EndPortal") and everything within KEEP_RADIUS of it is never hidden.
#   - Hides are rate limited (MAX_HIDES_PER_UPDATE) so no update is a hitch; shows never are.
#   - Shutdown (leaving the tree / shutdown()) shows everything again.
#
#  No allocation in the update: every buffer is pre-sized; arrays only grow while props are still
#  being spawned at the start of a run.
#
#  BOOTED BY: Purgatory_Dungeon_main_game_file._boot_torch_light_budget() (after generation).
# ==============================================================================
extends Node

const R_BASE : float = 70.0
const R_FORWARD : float = 110.0
## cos of the half-angle (horizontal) of the forward cone: 0.45 = +-63 degrees.
const FORWARD_COS : float = 0.45
const HYSTERESIS : float = 10.0
const UPDATE_INTERVAL : float = 0.25
const MAX_HIDES_PER_UPDATE : int = 40
const KEEP_RADIUS : float = 40.0
const AABB_MARGIN : float = 2.0
## Radius used for items that are a point (props, chests, orbs).
const POINT_RADIUS : float = 1.5

const KIND_MODULE : int = 0
const KIND_FLAME : int = 1
const KIND_POINT : int = 2     # live position read from the node each update (props, chests, orbs)
const KIND_ORB : int = 3       # as KIND_POINT, and another script also toggles it (see _watch_external)

var enabled : bool = true

var _nodes : Array[Node3D] = []
var _kind : PackedByteArray = PackedByteArray()
var _min : PackedVector3Array = PackedVector3Array()
var _max : PackedVector3Array = PackedVector3Array()
var _hid : PackedByteArray = PackedByteArray()          # 1 = this node hid the item
var _n : int = 0

var _containers : Array[Node] = []
var _container_seen : PackedInt32Array = PackedInt32Array()
var _container_kind : PackedByteArray = PackedByteArray()

var _force_pos : PackedVector3Array = PackedVector3Array()
var _portal : Node3D = null
var _map_node : Node = null
var _map_was_open : bool = false
var _cam : Camera3D = null
var _since : float = 0.0
var _booted : bool = false
var _hidden_count : int = 0
var _updates : int = 0
var _hides_budget : int = 0
var _flame_batches : Array = []
var _gen : Node = null
var _boot_module_count : int = 0


# ══════════════════════════════════════════════════════════════════════════════
#  PUBLIC API
# ══════════════════════════════════════════════════════════════════════════════

## `modules`: generator.placed_modules. `flame_batches`: generator.torch_flame_batches.
## Props, chests and orbs are picked up from the main root's PropSpawner / HealthOrbManager children
## and the "chest" group (also the ones spawned later).
func boot(modules: Array, flame_batches: Array = [], flame_bounds: Array = []) -> void:
	shutdown()
	_flame_batches = flame_batches
	_boot_module_count = modules.size()
	var gen_node : Node = get_parent().get_node_or_null("DungeonGenerationFunction") if get_parent() != null else null
	_gen = gen_node
	for m in modules:
		if not is_instance_valid(m) or not (m is Node3D):
			continue
		var box : AABB = _module_aabb(m as Node3D)
		if box.size == Vector3.ZERO:
			continue   # no geometry: nothing to cull
		_add_item(m as Node3D, KIND_MODULE, box.position - Vector3.ONE * AABB_MARGIN, box.end + Vector3.ONE * AABB_MARGIN)
	for bi in flame_batches.size():
		var b = flame_batches[bi]
		# the generator records each batch's world bounds (a headless MultiMesh reports an empty AABB)
		if is_instance_valid(b) and b is Node3D and bi < flame_bounds.size():
			var wb : AABB = flame_bounds[bi]
			_add_item(b as Node3D, KIND_FLAME, wb.position - Vector3.ONE, wb.end + Vector3.ONE)
	var root : Node = get_parent()
	if root != null:
		_pending_containers = PackedStringArray(["PropSpawner", "HealthOrbManager"])
		_map_node = root.get_node_or_null("minimap_function")
	_booted = true
	process_priority = 100   # after the minimap's _process, so a map opened this frame is seen this frame
	set_process(true)
	refresh(false)


## Shows everything again and forgets all items.
func shutdown() -> void:
	_show_all()
	_nodes.clear()
	_kind.resize(0)
	_min.resize(0)
	_max.resize(0)
	_hid.resize(0)
	_n = 0
	_containers.clear()
	_container_seen.resize(0)
	_container_kind.resize(0)
	_pending_containers = PackedStringArray()
	_chest_known.clear()
	_force_pos.resize(0)
	_portal = null
	_hidden_count = 0
	_booted = false


func set_enabled(on: bool) -> void:
	enabled = on
	if not on:
		_show_all()
	else:
		refresh(true)


## Items (modules, flame batches, props, ...) currently hidden by this node.
func hidden_count() -> int:
	return _hidden_count


func item_count() -> int:
	return _n


func updates_done() -> int:
	return _updates


## True when the item that belongs to `node` has been hidden by this node.
func is_hidden_by_me(node: Node3D) -> bool:
	for i in _n:
		if _nodes[i] == node:
			return _hid[i] == 1
	return false


## Never hide anything within KEEP_RADIUS of this world position (until shutdown).
func keep_visible_near(pos: Vector3) -> void:
	_force_pos.append(pos)


## Re-evaluates now. `instant` ignores the per-update hide limit (tests, boot of tests).
func refresh(instant: bool = false) -> void:
	_since = 0.0
	if not enabled or not _booted:
		return
	var cam : Camera3D = _camera()
	if cam == null:
		return
	if _map_is_open():
		_map_was_open = true
		_show_all()
		return
	_map_was_open = false
	if _generator_changed():
		# the dungeon was regenerated (modules replaced): forget the old items, show them, pick up the new ones
		boot(_gen.placed_modules, _gen.torch_flame_batches, _gen.torch_flame_bounds)
		return
	_pick_up_new_children()
	_updates += 1
	_hides_budget = 1000000 if instant else MAX_HIDES_PER_UPDATE
	_update_items(cam)


# ══════════════════════════════════════════════════════════════════════════════
#  FRAME LOOP
# ══════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	# keeps following the map (which runs while the game is paused) so it is never drawn half culled
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)


func _process(delta: float) -> void:
	if not _booted or not enabled:
		return
	# the map is checked every frame (cheap): it must be fully shown before it is rendered
	var open : bool = _map_is_open()
	if open != _map_was_open:
		refresh(false)   # opening shows everything at once; closing re-hides at the rate limit
		return
	if open:
		return
	_since += delta
	if _since >= UPDATE_INTERVAL:
		refresh(false)


func _exit_tree() -> void:
	if _booted:
		shutdown()


# ══════════════════════════════════════════════════════════════════════════════
#  INTERNALS
# ══════════════════════════════════════════════════════════════════════════════

func _update_items(cam: Camera3D) -> void:
	var cpos : Vector3 = cam.global_position
	var fwd : Vector3 = -cam.global_transform.basis.z
	var fh : Vector3 = Vector3(fwd.x, 0.0, fwd.z)
	var fh_len : float = fh.length()
	var has_cone : bool = fh_len > 0.2
	if has_cone:
		fh /= fh_len
	if _portal == null or not is_instance_valid(_portal):
		var par : Node = get_parent()
		_portal = par.get_node_or_null("EndPortal") as Node3D if par != null else null
		if _portal != null:
			keep_visible_near(_portal.global_position)
	var r_base2 : float = R_BASE * R_BASE
	var r_fwd2 : float = R_FORWARD * R_FORWARD
	var r_base_h2 : float = (R_BASE + HYSTERESIS) * (R_BASE + HYSTERESIS)
	var r_fwd_h2 : float = (R_FORWARD + HYSTERESIS) * (R_FORWARD + HYSTERESIS)
	var keep2 : float = KEEP_RADIUS * KEEP_RADIUS
	var cos2 : float = FORWARD_COS * FORWARD_COS
	for i in _n:
		var node : Node3D = _nodes[i]
		if not is_instance_valid(node):
			continue
		var k : int = _kind[i]
		var closest : Vector3
		if k >= KIND_POINT:
			var p : Vector3 = node.global_position
			closest = p
			_min[i] = p
			_max[i] = p
		else:
			closest = cpos.clamp(_min[i], _max[i])
		var v : Vector3 = closest - cpos
		var d2 : float = v.length_squared()
		if k >= KIND_POINT:
			var dd : float = maxf(sqrt(d2) - POINT_RADIUS, 0.0)
			d2 = dd * dd
		var forward : bool = true
		if has_cone:
			var vh : Vector3 = Vector3(v.x, 0.0, v.z)
			var dot : float = vh.dot(fh)
			var l2 : float = vh.length_squared()
			forward = l2 < 4.0 or (dot > 0.0 and dot * dot > cos2 * l2)
		var shown : bool = _hid[i] == 0
		var r2 : float
		if shown:
			r2 = r_fwd_h2 if forward else r_base_h2
		else:
			r2 = r_fwd2 if forward else r_base2
		var want_show : bool = d2 <= r2
		if not want_show and _forced(closest, keep2):
			want_show = true
		if want_show:
			if not shown:
				_set_item(i, node, true)
		else:
			if shown:
				if _hides_budget > 0:
					_hides_budget -= 1
					_set_item(i, node, false)
			elif k == KIND_ORB and node.visible:
				node.visible = false   # a script showed it again (respawn) inside a hidden area


func _generator_changed() -> bool:
	if _gen == null or not is_instance_valid(_gen) or not ("placed_modules" in _gen):
		return false
	var mods : Array = _gen.placed_modules
	if mods.size() != _boot_module_count:
		return true
	return mods.size() > 0 and not is_instance_valid(mods[0])


func _forced(p: Vector3, keep2: float) -> bool:
	for j in _force_pos.size():
		if p.distance_squared_to(_force_pos[j]) <= keep2:
			return true
	return false


func _set_item(i: int, node: Node3D, show_it: bool) -> void:
	if show_it:
		if _hid[i] == 1:
			_hid[i] = 0
			_hidden_count -= 1
			node.visible = true
	else:
		if not node.visible:
			return   # somebody else (a script) hid it: not ours to hide or to restore
		node.visible = false
		_hid[i] = 1
		_hidden_count += 1


func _show_all() -> void:
	for i in _n:
		if _hid[i] == 1:
			_hid[i] = 0
			_hidden_count -= 1
			if is_instance_valid(_nodes[i]):
				_nodes[i].visible = true
	_hidden_count = maxi(_hidden_count, 0)


func _add_item(node: Node3D, kind: int, bmin: Vector3, bmax: Vector3) -> void:
	_nodes.append(node)
	_kind.append(kind)
	_min.append(bmin)
	_max.append(bmax)
	_hid.append(0)
	_n += 1


# Containers that do not exist yet when this node boots (the health orb manager starts later) are
# looked up again on every update until they appear.
var _pending_containers : PackedStringArray = PackedStringArray()


func _pick_up_new_children() -> void:
	if not _pending_containers.is_empty():
		var root : Node = get_parent()
		var k : int = 0
		while k < _pending_containers.size():
			var c : Node = root.get_node_or_null(_pending_containers[k]) if root != null else null
			if c != null:
				_containers.append(c)
				_container_seen.append(0)
				_container_kind.append(KIND_ORB if _pending_containers[k] == "HealthOrbManager" else KIND_POINT)
				_pending_containers.remove_at(k)
			else:
				k += 1
	for c in _containers.size():
		var cont : Node = _containers[c]
		if not is_instance_valid(cont):
			continue
		var count : int = cont.get_child_count()
		while _container_seen[c] < count:
			var ch : Node = cont.get_child(_container_seen[c])
			_container_seen[c] += 1
			if ch is Node3D:
				_add_item(ch as Node3D, _container_kind[c], Vector3.ZERO, Vector3.ZERO)
	# chests are children of the main root (group "chest"); they all exist a moment after the start,
	# so the group is only looked at every 20th update (the lookup allocates a small array)
	if _updates % 20 == 0:
		for ch in get_tree().get_nodes_in_group("chest"):
			if ch is Node3D and not _chest_known.has(ch.get_instance_id()):
				_chest_known[ch.get_instance_id()] = true
				_add_item(ch as Node3D, KIND_POINT, Vector3.ZERO, Vector3.ZERO)


var _chest_known : Dictionary = {}


func _map_is_open() -> bool:
	if _map_node == null or not is_instance_valid(_map_node):
		return false
	return bool(_map_node.get("_map_visible"))


func _camera() -> Camera3D:
	if _cam != null and is_instance_valid(_cam) and _cam.is_inside_tree():
		return _cam
	var vp : Viewport = get_viewport()
	_cam = vp.get_camera_3d() if vp != null else null
	return _cam


# World AABB of a module (the generator caches it as meta "module_world_aabb" once computed).
func _module_aabb(m: Node3D) -> AABB:
	if m.has_meta("module_world_aabb"):
		var c = m.get_meta("module_world_aabb")
		if c is AABB:
			return c
	var par : Node = get_parent()
	var gen : Node = par.get_node_or_null("DungeonGenerationFunction") if par != null else null
	if gen != null and gen.has_method("get_module_aabb"):
		return gen.get_module_aabb(m)
	return AABB()
