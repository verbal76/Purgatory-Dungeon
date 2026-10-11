# ==============================================================================
#  FILE: torch_dimming_manager.gd
#  PATH: res://scripts/torch_dimming_manager.gd
#  DESCRIPTION: Hardcore-only global torch dimming system.
#               Dims all torch OmniLight3D nodes from starting_light_value to
#               ending_light_value over dimming_duration seconds (day 1→30).
#               Each torch has a torch_die_chance of dying completely, timed
#               to occur between day 25 and day 30.
#               10% of torches also get a wind-flicker effect — short random
#               bursts of energy dips with random sub-step gaps so each torch
#               flickers independently and looks like a real flame in a draft.
#               Also drives LightingManager.set_dimming() for global sun/ambient.
#
#  BOOTED BY: Purgatory_Dungeon_main_game_file._boot_torch_dimming_manager()
#             Only called when GlobalRunData.difficulty == "hardcore".
# ==============================================================================
extends Node

# ── Adjustable settings ───────────────────────────────────────────────────────
## OmniLight3D energy at the start of the run (day 1).
@export var starting_light_value  : float = 5.0
## OmniLight3D energy by day 30 — still visible but noticeably dim.
@export var ending_light_value    : float = 1.0
## Per-torch chance of dying completely. Death fires between day 25 and day 30.
@export var torch_die_chance      : float = 0.10
## Per-torch chance of having the wind-flicker trait (independent of die chance).
@export var torch_flicker_chance  : float = 0.10
## Total seconds of the run (matches GameClock — 30 real minutes = 30 days).
@export var dimming_duration      : float = 1800.0


# ── Runtime state ─────────────────────────────────────────────────────────────
var _elapsed         : float = 0.0
var _lighting_mgr    : Node  = null

# OmniLight3D references — one per registered torch.
var _torch_lights    : Array = []

# Torches scheduled to die: Array of { light: OmniLight3D, die_at: float }
# Sorted ascending so we can pop from the front.
var _early_die_queue : Array = []

# Instance IDs of lights that have fully died — skipped in the main loop.
var _dead_light_ids  : Dictionary = {}

# The level's TorchLightBudget (a sibling node), when there is one. It owns the energy and the
# visibility of every torch light (only the nearest few are on), so this manager hands it the global
# energy, the flicker factors and the deaths instead of writing ~750 lights every frame. Without a
# budget the manager writes the lights itself, exactly as before.
var _budget : Node = null

# Flicker states for torches with the flicker trait.
# Each entry: { light, idle_timer, burst_timer, sub_timer }
#   idle_timer  — seconds until the next flicker burst starts
#   burst_timer — seconds remaining in the current burst (0 = not bursting)
#   sub_timer   — seconds until the next energy dip within a burst
var _flicker_states  : Array = []

# Instance IDs of torches currently mid-burst — excluded from the main
# energy-set loop so the flicker code owns their energy during a burst.
var _flickering_now  : Dictionary = {}


# ══════════════════════════════════════════════════════════════════════════════
#  PUBLIC API
# ══════════════════════════════════════════════════════════════════════════════

func boot(torch_nodes: Array, lighting_mgr: Node) -> void:
	_lighting_mgr = lighting_mgr
	var par : Node = get_parent()
	_budget = par.get_node_or_null("TorchLightBudget") if par != null else null

	# Collect OmniLight3D children from each torch root.
	for torch_root in torch_nodes:
		if not is_instance_valid(torch_root):
			continue
		var light := _find_omni_light_in(torch_root)
		if light != null:
			_torch_lights.append(light)

	# Assign die schedules — fires between day 25 (83 % of run) and day 30.
	for light in _torch_lights:
		if randf() < torch_die_chance:
			var die_at : float = randf_range(
				dimming_duration * 0.833,
				dimming_duration * 1.0
			)
			_early_die_queue.append({"light": light, "die_at": die_at})

	_early_die_queue.sort_custom(func(a, b): return a.die_at < b.die_at)

	# Assign flicker trait — each flickering torch gets a unique staggered
	# idle offset so they never all start a burst at the same moment.
	for light in _torch_lights:
		if randf() < torch_flicker_chance:
			_flicker_states.append({
				"light"       : light,
				"index"       : _budget.index_of(light) if _budget != null else -1,
				"idle_timer"  : randf_range(1.0, 25.0),  # staggered first burst
				"burst_timer" : 0.0,
				"sub_timer"   : 0.0,
			})

	print("TorchDimmingManager: %d torches, %d will die (day 25-30), %d will flicker." % [
		_torch_lights.size(), _early_die_queue.size(), _flicker_states.size()])

	set_process(true)


# ══════════════════════════════════════════════════════════════════════════════
#  PROCESS
# ══════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	set_process(false)   # idle until boot() is called


func _process(delta: float) -> void:
	_elapsed += delta
	var t : float = clampf(_elapsed / dimming_duration, 0.0, 1.0)

	# Global sun + ambient dim via LightingManager.
	if _lighting_mgr != null and is_instance_valid(_lighting_mgr) \
			and _lighting_mgr.has_method("set_dimming"):
		_lighting_mgr.set_dimming(t)

	# Process die queue — lights whose time has come go fully dark.
	while not _early_die_queue.is_empty():
		var entry : Dictionary = _early_die_queue[0]
		if _elapsed < float(entry.get("die_at", 0.0)):
			break
		_early_die_queue.pop_front()
		var dying_light : OmniLight3D = entry.get("light") as OmniLight3D
		if is_instance_valid(dying_light):
			if _budget != null:
				_budget.kill_light(dying_light)
			else:
				dying_light.light_energy = 0.0
			_dead_light_ids[dying_light.get_instance_id()] = true

	# Global dimmed energy level this frame.
	var global_energy : float = lerpf(starting_light_value, ending_light_value, t)

	# ── Flicker update ────────────────────────────────────────────────────────
	# Run before the main loop so _flickering_now is fresh for this frame.
	_flickering_now.clear()
	for fs in _flicker_states:
		var fl : OmniLight3D = fs["light"] as OmniLight3D
		if not is_instance_valid(fl):
			continue
		var id : int = fl.get_instance_id()
		if _dead_light_ids.has(id):
			continue   # Dead — no flickering on a dead torch

		if fs["burst_timer"] > 0.0:
			# ── Actively bursting ─────────────────────────────────────────
			fs["burst_timer"] -= delta
			fs["sub_timer"]   -= delta

			if fs["sub_timer"] <= 0.0:
				# Each sub-step: dip to a random fraction of current base energy.
				# Range 0.45–0.88 gives believable wind-flicker without going dark.
				fs["sub_timer"] = randf_range(0.04, 0.22)
				if _budget != null:
					_budget.set_light_factor_at(int(fs["index"]), randf_range(0.45, 0.88))
				else:
					fl.light_energy = global_energy * randf_range(0.45, 0.88)

			if fs["burst_timer"] <= 0.0:
				# Burst finished — restore to base and schedule next idle wait.
				if _budget != null:
					_budget.set_light_factor_at(int(fs["index"]), 1.0)
				else:
					fl.light_energy = global_energy
				fs["idle_timer"]  = randf_range(5.0, 40.0)
			else:
				# Still bursting — exclude from main energy-set loop this frame.
				_flickering_now[id] = true

		else:
			# ── Idle — counting down to next burst ────────────────────────
			fs["idle_timer"] -= delta
			if fs["idle_timer"] <= 0.0:
				# Kick off a new burst: short random duration, sub_timer fires immediately.
				fs["burst_timer"] = randf_range(0.25, 2.0)
				fs["sub_timer"]   = 0.0

	# ── With a TorchLightBudget: one call. It applies the energy (times each light's flicker /
	# death factor and its fade) to the few lights that are on, and to the others when they come on.
	if _budget != null:
		_budget.set_global_energy(global_energy)
		if t >= 1.0:
			set_process(false)
		return

	# ── Main energy loop — set all living, non-bursting torches ───────────────
	for light in _torch_lights:
		if not is_instance_valid(light):
			continue
		var id : int = (light as OmniLight3D).get_instance_id()
		if _dead_light_ids.has(id):
			continue
		if _flickering_now.has(id):
			continue   # Flicker code owns this torch's energy right now
		(light as OmniLight3D).light_energy = global_energy

	if t >= 1.0:
		set_process(false)


# ══════════════════════════════════════════════════════════════════════════════
#  HELPERS
# ══════════════════════════════════════════════════════════════════════════════

func _find_omni_light_in(node: Node) -> OmniLight3D:
	if node is OmniLight3D:
		return node as OmniLight3D
	for child in node.get_children():
		var found := _find_omni_light_in(child)
		if found != null:
			return found
	return null
