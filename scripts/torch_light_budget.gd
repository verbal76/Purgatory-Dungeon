# ==============================================================================
#  FILE: torch_light_budget.gd
#  PATH: res://scripts/torch_light_budget.gd
#  DESCRIPTION: One light budget for the whole level. The dungeon has ~750 torches, each an
#               OmniLight3D, and the Mobile renderer pays for every enabled light (light
#               instances, per-mesh light lists capped at 8, per-pixel work on every lit
#               mesh). Only the torches nearest to the camera keep their light enabled; the
#               rest are hidden. The emissive flame spheres are separate (MultiMesh batches
#               in the generator) and always stay, so distant torches still glow as points.
#
#               - Selection: nearest-first from a spatial grid, refreshed ~6x per second, with
#                 hysteresis (a light that is on keeps its slot until another one is ~25 %
#                 closer). No allocation after boot(): all buffers are pre-sized.
#               - Fade: a light never pops. Its energy ramps over FADE_TIME seconds in and out.
#               - One budget: torches + every other OmniLight3D near the camera (pickups, health
#                 orbs, portal, kill flashes, spell bolts) share TOTAL_LIGHT_BUDGET. Dynamic
#                 lights are never switched by this node (their scripts own them); they only
#                 shrink the number of torches that may be on (never below MIN_TORCH_LIGHTS).
#               - Energy ownership: this node is the only writer of a torch light's energy and
#                 visibility. TorchDimmingManager (Hardcore) talks to it through
#                 set_global_energy() / set_light_factor() / kill_light() instead of touching
#                 ~750 lights every frame, so the two systems cannot fight.
#
#  BOOTED BY: Purgatory_Dungeon_main_game_file._boot_torch_light_budget() after generation.
# ==============================================================================
extends Node

## Torches allowed on at once when nothing else is lit.
const MAX_TORCH_LIGHTS : int = 16
## Torches + other omni lights near the camera. Torches give way to dynamic lights down to MIN.
const TOTAL_LIGHT_BUDGET : int = 24
const MIN_TORCH_LIGHTS : int = 8
## Seconds between selection refreshes (the per-frame work is only the fade of a few lights).
const UPDATE_INTERVAL : float = 0.15
## Seconds a light needs to fade fully in or out.
const FADE_TIME : float = 0.3
## Torches farther than this from the camera are never candidates (their lights already fade out
## between 30 and 40 m).
const SELECT_RADIUS : float = 45.0
## Squared distance multiplier for lights that are already on: hysteresis against flip-flopping.
const KEEP_BIAS_SQ : float = 0.64
## Dynamic (non-torch) lights count against the budget only within this distance of the camera.
const DYNAMIC_RADIUS : float = 40.0
const CELL : float = 24.0

# Per-torch data (parallel arrays, filled once in boot()).
var _lights : Array[OmniLight3D] = []
var _pos : PackedVector3Array = PackedVector3Array()
var _base : PackedFloat32Array = PackedFloat32Array()      # energy the light had at boot
var _factor : PackedFloat32Array = PackedFloat32Array()    # external multiplier (flicker, death = 0)
var _fade : PackedFloat32Array = PackedFloat32Array()      # 0..1 fade state
var _want : PackedByteArray = PackedByteArray()            # 1 = selected to be on
var _applied : PackedFloat32Array = PackedFloat32Array()   # last energy written to the light
var _in_active : PackedByteArray = PackedByteArray()       # 1 = listed in _active
var _index_of : Dictionary = {}                            # OmniLight3D instance id -> index
var _grid : Dictionary = {}                                # Vector2i -> PackedInt32Array
var _empty : PackedInt32Array = PackedInt32Array()         # shared default for empty grid cells

# Lights that currently have fade > 0 or are wanted (a handful), fixed capacity.
var _active : PackedInt32Array = PackedInt32Array()
var _active_n : int = 0

# Selection scratch (fixed size).
var _sel_idx : PackedInt32Array = PackedInt32Array()
var _sel_key : PackedFloat32Array = PackedFloat32Array()
var _sel_n : int = 0

## Continuous fire flicker: each lit torch's energy wobbles by up to +-`flicker_amount` (a fraction, two incommensurate sines per light so
## neighbours never pulse together), stepped at ~14 Hz so a light is only rewritten that often. 0 = steady (the default; the game turns it
## on for a run, tests leave it off so energies stay exact).
var flicker_amount : float = 0.0
var _flick_t : float = 0.0
var _flick_q : float = 0.0
const FLICKER_HZ : float = 14.0

var _global_energy : float = -1.0      # < 0: every torch uses its own boot energy
var _dynamic : Array = []              # non-torch OmniLight3D nodes seen (pruned in place)
var _dynamic_near : int = 0
var _since_update : float = 0.0
var _booted : bool = false
var _radius_cells : int = 2
var _cam : Camera3D = null
var _update_count : int = 0


# ══════════════════════════════════════════════════════════════════════════════
#  PUBLIC API
# ══════════════════════════════════════════════════════════════════════════════

## `torch_nodes`: the generator's registered torches (Node3D with an OmniLight3D child).
## Every torch light starts hidden; the first update (instant, no fade) switches on the nearest.
func boot(torch_nodes: Array) -> void:
	_lights.clear()
	_index_of.clear()
	_grid.clear()
	var positions : Array[Vector3] = []
	for t in torch_nodes:
		if not is_instance_valid(t):
			continue
		var l : OmniLight3D = _find_light(t)
		if l == null or _index_of.has(l.get_instance_id()):
			continue
		_index_of[l.get_instance_id()] = _lights.size()
		_lights.append(l)
		positions.append(l.global_position)
	var n : int = _lights.size()
	_pos.resize(n)
	_base.resize(n)
	_factor.resize(n)
	_fade.resize(n)
	_want.resize(n)
	_applied.resize(n)
	_in_active.resize(n)
	_active.resize(n)
	_active_n = 0
	for i in n:
		_pos[i] = positions[i]
		_base[i] = _lights[i].light_energy
		_factor[i] = 1.0
		_fade[i] = 0.0
		_want[i] = 0
		_applied[i] = -1.0
		_in_active[i] = 0
		_lights[i].visible = false
		var key := Vector2i(int(floor(_pos[i].x / CELL)), int(floor(_pos[i].z / CELL)))
		var cell : PackedInt32Array = _grid.get(key, _empty)
		cell = cell.duplicate() if cell.is_empty() else cell
		cell.append(i)
		_grid[key] = cell
	_radius_cells = int(ceil(SELECT_RADIUS / CELL))
	_sel_idx.resize(MAX_TORCH_LIGHTS)
	_sel_key.resize(MAX_TORCH_LIGHTS)
	_scan_existing_dynamic_lights()
	if not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)
	_booted = true
	set_process(true)
	refresh(true)


## Absolute energy for every torch light (Hardcore dimming). Negative = back to each light's own.
func set_global_energy(energy: float) -> void:
	_global_energy = energy


## Multiplier for one torch light (wind flicker). 0 = out.
func set_light_factor(light: OmniLight3D, factor: float) -> void:
	var i : int = index_of(light)
	if i >= 0:
		_factor[i] = factor


func set_light_factor_at(index: int, factor: float) -> void:
	if index >= 0 and index < _factor.size():
		_factor[index] = factor


## Torch dies for good (it stays selected-or-not like any other, but never shines again).
func kill_light(light: OmniLight3D) -> void:
	set_light_factor(light, 0.0)


func index_of(light: OmniLight3D) -> int:
	if light == null:
		return -1
	return int(_index_of.get(light.get_instance_id(), -1))


func torch_count() -> int:
	return _lights.size()


## Torch lights switched on right now (any fade state above zero).
func active_torch_lights() -> int:
	var c : int = 0
	for k in _active_n:
		if _lights[_active[k]].visible:
			c += 1
	return c


## Torches that are selected (target on), whatever their fade state.
func wanted_torch_lights() -> int:
	var c : int = 0
	for k in _active_n:
		if _want[_active[k]] == 1:
			c += 1
	return c


## Dynamic (non-torch) lights currently on within DYNAMIC_RADIUS of the camera.
func dynamic_lights_near() -> int:
	return _dynamic_near


## Torch allowance given the dynamic lights that are lit near the camera.
func torch_allowance() -> int:
	return clampi(TOTAL_LIGHT_BUDGET - _dynamic_near, MIN_TORCH_LIGHTS, MAX_TORCH_LIGHTS)


func is_light_on(index: int) -> bool:
	return index >= 0 and index < _lights.size() and _lights[index].visible


func updates_done() -> int:
	return _update_count


## Re-selects now. `instant` skips the fade (used at boot and by tests).
func refresh(instant: bool = false) -> void:
	_since_update = 0.0
	var cam : Camera3D = _camera()
	if cam == null:
		return
	_update_selection(cam.global_position)
	if instant:
		for k in _active_n:
			var i : int = _active[k]
			if _want[i] == 1:
				_fade[i] = 1.0
		_apply_all()


# ══════════════════════════════════════════════════════════════════════════════
#  FRAME LOOP
# ══════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	set_process(false)   # idle until boot()


func _process(delta: float) -> void:
	if not _booted:
		return
	_since_update += delta
	if _since_update >= UPDATE_INTERVAL:
		refresh(false)
	if flicker_amount > 0.0:
		_flick_t += delta
		_flick_q = floorf(_flick_t * FLICKER_HZ) / FLICKER_HZ
	_step_fades(delta)


func _step_fades(delta: float) -> void:
	var step : float = delta / FADE_TIME
	var k : int = 0
	while k < _active_n:
		var i : int = _active[k]
		var target : float = 1.0 if _want[i] == 1 else 0.0
		_fade[i] = move_toward(_fade[i], target, step)
		_apply(i)
		if _fade[i] <= 0.0 and _want[i] == 0:
			# fully faded out: leave the active list (swap-remove)
			_in_active[i] = 0
			_active_n -= 1
			_active[k] = _active[_active_n]
			continue
		k += 1


func _apply_all() -> void:
	for k in _active_n:
		_apply(_active[k])


# Writes energy / visibility of one light, only when they change.
func _apply(i: int) -> void:
	var l : OmniLight3D = _lights[i]
	if not is_instance_valid(l):
		return
	var base : float = _global_energy if _global_energy >= 0.0 else _base[i]
	var e : float = base * _factor[i] * _fade[i]
	if flicker_amount > 0.0:
		var fi : float = float(i)
		e *= 1.0 + flicker_amount * (0.6 * sin(_flick_q * 6.7 + fi * 1.913) + 0.4 * sin(_flick_q * 13.3 + fi * 3.77))
	var on : bool = _fade[i] > 0.0 and _factor[i] > 0.0
	if on != l.visible:
		l.visible = on
	if absf(e - _applied[i]) > 0.0005:
		_applied[i] = e
		l.light_energy = e


# ══════════════════════════════════════════════════════════════════════════════
#  SELECTION (no allocation)
# ══════════════════════════════════════════════════════════════════════════════

func _update_selection(cam_pos: Vector3) -> void:
	_update_count += 1
	_count_dynamic_near(cam_pos)
	var budget : int = mini(torch_allowance(), _sel_idx.size())
	_sel_n = 0
	var r2 : float = SELECT_RADIUS * SELECT_RADIUS
	var cx : int = int(floor(cam_pos.x / CELL))
	var cz : int = int(floor(cam_pos.z / CELL))
	for dx in range(-_radius_cells, _radius_cells + 1):
		for dz in range(-_radius_cells, _radius_cells + 1):
			var cell : PackedInt32Array = _grid.get(Vector2i(cx + dx, cz + dz), _empty)
			for j in cell.size():
				var i : int = cell[j]
				var d2 : float = cam_pos.distance_squared_to(_pos[i])
				if d2 > r2 or _factor[i] <= 0.0:
					continue   # out of range, or a dead torch (never worth a slot)
				var key : float = d2 * KEEP_BIAS_SQ if _want[i] == 1 else d2
				_insert_candidate(i, key, budget)
	# Apply: lights not selected any more lose their wish; selected ones gain it.
	for k in _active_n:
		_want[_active[k]] = 0
	for s in _sel_n:
		var i : int = _sel_idx[s]
		_want[i] = 1
		if _in_active[i] == 0:
			_in_active[i] = 1
			_active[_active_n] = i
			_active_n += 1


# Insertion into the best-`budget` list (ascending key), fixed-size arrays.
func _insert_candidate(i: int, key: float, budget: int) -> void:
	if _sel_n >= budget and key >= _sel_key[_sel_n - 1]:
		return
	var p : int = mini(_sel_n, budget - 1)
	if _sel_n < budget:
		_sel_n += 1
	while p > 0 and _sel_key[p - 1] > key:
		_sel_key[p] = _sel_key[p - 1]
		_sel_idx[p] = _sel_idx[p - 1]
		p -= 1
	_sel_key[p] = key
	_sel_idx[p] = i


# ══════════════════════════════════════════════════════════════════════════════
#  DYNAMIC LIGHTS (counted, never switched)
# ══════════════════════════════════════════════════════════════════════════════

func _scan_existing_dynamic_lights() -> void:
	_dynamic.clear()
	var stack : Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var n : Node = stack.pop_back()
		if n is OmniLight3D and not _index_of.has(n.get_instance_id()):
			_dynamic.append(n)
		for c in n.get_children():
			stack.append(c)


func _on_node_added(n: Node) -> void:
	if n is OmniLight3D and not _index_of.has(n.get_instance_id()):
		_dynamic.append(n)


func _count_dynamic_near(cam_pos: Vector3) -> void:
	var r2 : float = DYNAMIC_RADIUS * DYNAMIC_RADIUS
	var c : int = 0
	var k : int = 0
	while k < _dynamic.size():
		var l = _dynamic[k]
		if not is_instance_valid(l):
			_dynamic[k] = _dynamic[_dynamic.size() - 1]
			_dynamic.pop_back()
			continue
		var ol : OmniLight3D = l as OmniLight3D
		if ol.is_inside_tree() and ol.is_visible_in_tree() and ol.light_energy > 0.0 \
				and cam_pos.distance_squared_to(ol.global_position) <= r2:
			c += 1
		k += 1
	_dynamic_near = c


# ══════════════════════════════════════════════════════════════════════════════
#  HELPERS
# ══════════════════════════════════════════════════════════════════════════════

func _camera() -> Camera3D:
	if _cam != null and is_instance_valid(_cam) and _cam.is_inside_tree():
		return _cam
	var vp : Viewport = get_viewport()
	_cam = vp.get_camera_3d() if vp != null else null
	return _cam


func _find_light(node: Node) -> OmniLight3D:
	var direct : Node = node.get_node_or_null("OmniLight3D")
	if direct is OmniLight3D:
		return direct as OmniLight3D
	if node is OmniLight3D:
		return node as OmniLight3D
	for child in node.get_children():
		var found : OmniLight3D = _find_light(child)
		if found != null:
			return found
	return null
