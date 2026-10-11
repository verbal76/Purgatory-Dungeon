# ==============================================================================
#  FILE: Purgatory_Dungeon_main_game_file.gd
#  PATH: res://scenes/Purgatory_Dungeon_main_game_file.gd
#  DESCRIPTION: Main level controller. Dynamically builds the EnemyManager
#               identically to the HealthOrbManager to guarantee stability.
#  MOD NOTES:
#  - Fixed the "previously freed" race condition by directly passing
#    the instantiated player node instead of querying the tree for it.
#  - SURGICAL CHANGE: Replaced enemy_scenes: Array[PackedScene] with two
#    separate exports: brute_enemy_scene (type-1 spawns) and mage_enemy_scene
#    (type-2 spawns). Type-3 spawn points pick randomly and receive a buff.
#  - SURGICAL CHANGE: _boot_enemy_manager() now reads registered_typed_spawns
#    and registered_waypoints from dungeon_generation_function and passes
#    them to EnemyManager.boot_up() with the two separate scene references.
#  - SURGICAL FIX: update_player_exploration() throttled to EXPLORE_INTERVAL
#    (0.5s) in _process. Previously called raw every frame (60Hz) which caused
#    a full dungeon tree traversal 60 times per second.
#  ALSO REQUIRED IN GODOT EDITOR (one-time, not a code change):
#  - In the Inspector, replace the old enemy_scenes[] array slot with the
#    two new brute_enemy_scene and mage_enemy_scene slots and assign scenes.
# ==============================================================================
extends Node3D

@export var starter_module        : PackedScene
@export var branch_modules        : Array[PackedScene] = []
@export var room_connector_module : PackedScene
@export var end_cap_module        : PackedScene

# ── SURGICAL CHANGE: Two separate enemy scene exports replace enemy_scenes[] ──
# Type-1 spawn points (easy_enemy_spawnpoint)  → always Brute
# Type-2 spawn points (easy_enemy_spawnpoint2) → always Mage
# Type-3 spawn points (easy_enemy_spawnpoint3) → random, buffed 25% + red glow
@export var brute_enemy_scene : PackedScene  # Assign brute_enemy.tscn here
@export var mage_enemy_scene  : PackedScene  # Assign mage_enemy.tscn here

# ── Character scenes (assign in Inspector) ─────────────────
@export var barbarian_scene : PackedScene
@export var mage_scene      : PackedScene

@export var target_piece_count        : int   = 125
@export var total_generation_attempts : int   = 20000
@export var attempts_per_connection   : int   = 25
@export var use_random_seed           : bool  = true
@export var fixed_seed                : int   = 12345

@export var weight_4_connection : int = 12
@export var weight_3_connection : int = 9
@export var weight_2_connection : int = 3
@export var weight_1_connection : int = 1

@export var overlap_shrink     : float         = 0.0
@export var connection_nudge   : float         = 0.04
@export var exclude_keywords   : Array[String] = ["boss", "wave", "connector", "end"]

@export var exploration_padding : float = 0.5
@export var enemy_spawn_chance  : float = 1.0

# ── Jump scare trap resources — assign in Inspector ────────────────────────────
# Drag your scary face image into jumpscare_texture and your scream audio
# into jumpscare_sound. Both are optional — the trap still fires without them
# but will show a black screen and silence if left unassigned.
@export var jumpscare_texture : Texture2D   # Scary face image (.png, .jpg, etc.)
@export var jumpscare_sound   : AudioStream # Scream / stinger audio file

const Juice = preload("res://scripts/juice.gd")
const FloorMeshRepair = preload("res://scripts/floor_mesh_repair.gd")
const PropSpawnerScript = preload("res://scripts/prop_spawner.gd")

@onready var dungeon_generation_function : Node = get_node_or_null("DungeonGenerationFunction")
@onready var kill_counter_label : Label = get_node_or_null("HUD/KillCounterMargin/KillCounterVBox/KillCounterLabel")

var _kill_margin : Control = null
var placed_modules : Array[Node3D] = []

# ── Exploration update throttle ────────────────────────────────────────────────
# update_player_exploration() walks the dungeon tree to reveal explored rooms.
# Running it at 60Hz is wasteful — the player can't move fast enough to matter.
# 0.5s gives smooth map reveal with a fraction of the CPU cost.
const EXPLORE_INTERVAL : float = 0.5
var _explore_timer     : float = 0.0

# ── Entry-sequence timeline (diagnostics) ──────────────────────────────────────
# One [label, Time.get_ticks_usec(), node_count] entry per phase of the dungeon entry. A handful of
# appends per run; tests/entry_profile.gd prints them. Not used by gameplay.
var entry_marks : Array = []
var entry_profiling : bool = false   # set by tests/entry_profile.gd before the scene enters the tree


func _mark(label: String) -> void:
	if not entry_profiling:
		return
	entry_marks.append([label, Time.get_ticks_usec(), get_tree().get_node_count()])


# Public so the managers booted from here can add their own phases (they check has_method first).
func entry_mark(label: String) -> void:
	_mark(label)


func _ready() -> void:
	_mark("ready_begin")
	_reset_kill_counter()
	_style_kill_counter()
	add_to_group("dungeon_generator")

	if has_node("/root/AudioManager"):
		AudioManager.play_gameplay_music()
	else:
		push_warning("AudioManager not found. Gameplay music will not start.")

	_apply_run_seed()
	_mark("pre_player")

	# THE FIX: Directly capture the newly spawned player so we never grab a ghost
	var active_player = _spawn_selected_character()

	# The shared effect pool (hit sparks, damage numbers, flash lights) is built now, under the loading screen, so no combat
	# frame ever pays for it.
	Juice.ensure_pool(self)

	# Phones: the touch layer feeds the same input actions as keyboard / gamepad (no-op on desktop).
	TouchControls.install(self)
	_mark("player_spawned")

	if dungeon_generation_function == null:
		push_error("DungeonGenerationFunction node not found in main scene.")
		return

	_push_generation_settings_into_child()

	# Heavy resources the population passes need (prop models and textures) load on worker threads
	# while the layout is being built, so they are ready by the time they are first instantiated.
	# The floor-mesh repairs run first, on this thread, while no worker thread is creating meshes (see FloorMeshRepair.prepare_all).
	FloorMeshRepair.prepare_all()
	_request_background_loads()

	# Yield two frames so the loading screen (created by the player's _ready)
	# has time to composite and appear on screen before generation starts.
	await get_tree().process_frame
	await get_tree().process_frame
	_mark("generate_begin")

	# The layout is built in slices (about LOAD_SLICE_US of work per frame) so the loading screen keeps
	# animating instead of the device freezing for the whole generation.
	var generation_result : Dictionary = await dungeon_generation_function.generate_dungeon_async(LOAD_SLICE_US)
	if not bool(generation_result.get("success", false)):
		push_error("Dungeon generation failed.")
		return

	_mark("generate_end")
	var starter : Node3D = generation_result.get("starter")
	placed_modules = dungeon_generation_function.placed_modules

	var spawn_origin : Vector3 = Vector3.ZERO
	if starter != null:
		var spawn_marker = starter.get_node_or_null("Player_Spawn") as Node3D
		if active_player and spawn_marker:
			# 1. Suspend physics so they don't fall or accumulate gravity while waiting
			active_player.set_physics_process(false)
			if "velocity" in active_player:
				active_player.velocity = Vector3.ZERO

			# 2. Wait exactly two frames to guarantee all dungeon colliders are fully built
			await get_tree().physics_frame
			await get_tree().physics_frame

			# 3. Build spawn position — use the starter module's AABB centre for X/Z
			#    so the player can never clip into a wall even if the Player_Spawn
			#    marker sits close to an edge.  Y comes from the marker + drop height.
			var safe_pos : Vector3 = spawn_marker.global_position
			if dungeon_generation_function != null and \
					dungeon_generation_function.has_method("get_module_aabb"):
				var aabb : AABB = dungeon_generation_function.get_module_aabb(starter)
				if aabb.size != Vector3.ZERO:
					var centre := aabb.get_center()
					safe_pos.x = centre.x
					safe_pos.z = centre.z
			safe_pos.y += 2.5
			active_player.global_position = safe_pos
			spawn_origin = safe_pos

			# 3b. Face the useful open space, with the nearest wall behind the player (see compute_spawn_yaw).
			if active_player.has_method("set_facing_yaw"):
				var ray_origin := Vector3(safe_pos.x, spawn_marker.global_position.y + SPAWN_RAY_HEIGHT, safe_pos.z)
				var exclude: Array[RID] = []
				if active_player is CollisionObject3D:
					exclude.append((active_player as CollisionObject3D).get_rid())
				active_player.set_facing_yaw(compute_spawn_yaw(active_player.get_world_3d().direct_space_state, ray_origin, exclude))

			# 4. Turn physics back on
			active_player.set_physics_process(true)
			_mark("player_placed")
	if spawn_origin == Vector3.ZERO and active_player != null:
		spawn_origin = active_player.global_position

	await _boot_population(active_player, spawn_origin)
	_mark("ready_end")


# ══════════════════════════════════════════════════════════════
#  STAGED ENTRY
# ══════════════════════════════════════════════════════════════
# Everything that fills the dungeon after the layout exists is a "stage worker": a manager coroutine that
# places things nearest-the-player first and gives the frame back whenever stage_over() says this frame's
# share of work is spent. The player's neighbourhood (every module with its centre within NEAR_RADIUS of the
# spawn) must be finished before control is handed over; the rest completes in the background, in
# distance order, a few milliseconds per frame, so no frame carries the cost of a whole pass.

## Microseconds of layout work per frame while the loading screen is up.
const LOAD_SLICE_US : int = 10000


# ── Spawn orientation ────────────────────────────────────────────────────────
# The player is placed in the starter room and must start looking into the useful open space, with the nearest wall
# behind them, never into a wall. Rays are cast all round at chest height; every candidate facing is scored by how open
# it is in front (mean clear distance over a +-SPAWN_FRONT_HALF_DEG window, capped at SPAWN_OPEN_CAP so a very long
# corridor does not outweigh everything) minus how open it is behind (a near wall behind is the primary signal). A wall
# straight ahead is therefore never chosen when any direction is open, a corner resolves to the diagonal facing away from
# it, and two equidistant side walls (a corridor-like room) resolve to the open direction along it. Props, chests,
# enemies and other bodies are skipped: only static world geometry counts as a wall.
const SPAWN_RAY_HEIGHT : float = 1.0
const SPAWN_RAY_COUNT : int = 36
const SPAWN_RAY_RANGE : float = 30.0
const SPAWN_OPEN_CAP : float = 12.0
const SPAWN_FRONT_HALF_DEG : float = 35.0
const SPAWN_BACK_WEIGHT : float = 0.5
const SPAWN_GAP_FRACTION : float = 0.6   # a ray belongs to the open gap while it sees at least this much of the gap's best ray


## Clear horizontal distance from `origin` along yaw `yaw` (forward = (-sin, 0, -cos)), SPAWN_RAY_RANGE when nothing blocks.
static func spawn_clearance(space: PhysicsDirectSpaceState3D, origin: Vector3, yaw: float, exclude: Array[RID]) -> float:
	var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var skip: Array[RID] = exclude.duplicate()
	for _i in 6:
		var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * SPAWN_RAY_RANGE, 1)
		q.exclude = skip
		var hit: Dictionary = space.intersect_ray(q)
		if hit.is_empty():
			return SPAWN_RAY_RANGE
		var col: Object = hit.get("collider")
		var is_wall: bool = col is StaticBody3D and not (col as Node).is_in_group("chest")
		if is_wall:
			return origin.distance_to(hit["position"] as Vector3)
		skip.append(hit["rid"])   # a prop / body / chest: look through it
	return SPAWN_RAY_RANGE


## The yaw (radians, the players' own convention) a player placed at `origin` should start with.
static func compute_spawn_yaw(space: PhysicsDirectSpaceState3D, origin: Vector3, exclude: Array[RID] = []) -> float:
	var n: int = SPAWN_RAY_COUNT
	var clear: PackedFloat32Array = PackedFloat32Array()
	clear.resize(n)
	for i in n:
		clear[i] = minf(spawn_clearance(space, origin, TAU * float(i) / float(n), exclude), SPAWN_OPEN_CAP)
	return spawn_yaw_from_clearances(clear)


## Pure scoring step (unit-testable): `clear[i]` is the capped clear distance along yaw TAU * i / n.
static func spawn_yaw_from_clearances(clear: PackedFloat32Array) -> float:
	var n: int = clear.size()
	if n == 0:
		return 0.0
	var half: int = maxi(int(round(deg_to_rad(SPAWN_FRONT_HALF_DEG) / (TAU / float(n)))), 0)
	var best_i: int = 0
	var best_score: float = -INF
	for i in n:
		var front: float = 0.0
		var back: float = 0.0
		for k in range(-half, half + 1):
			front += clear[posmod(i + k, n)]
			back += clear[posmod(i + (n >> 1) + k, n)]
		var cnt: float = float(2 * half + 1)
		var score: float = (front - SPAWN_BACK_WEIGHT * back) / (cnt * SPAWN_OPEN_CAP)
		if score > best_score + 0.0001:   # ties keep the first (lowest yaw): deterministic
			best_score = score
			best_i = i
	# Refine to the middle of the open gap around the winner (so a corridor or a doorway is faced squarely rather than at the
	# edge of the window): the nearest-to-centre ray with the greatest clearance, widened both ways while it stays open.
	var peak_i: int = best_i
	var peak: float = clear[best_i]
	for k in range(1, half + 1):
		for sgn in [1, -1]:
			var j: int = posmod(best_i + sgn * k, n)
			if clear[j] > peak + 0.0001:
				peak = clear[j]
				peak_i = j
	var left: int = 0
	var right: int = 0
	while right < n / 4 and clear[posmod(peak_i + right + 1, n)] >= SPAWN_GAP_FRACTION * peak:
		right += 1
	while left < n / 4 and clear[posmod(peak_i - left - 1, n)] >= SPAWN_GAP_FRACTION * peak:
		left += 1
	return TAU * (float(peak_i) + float(right - left) * 0.5) / float(n)

## Per-frame population budget (microseconds) behind the loading screen / once the player has control.
const STAGE_BUDGET_LOADING_US : int = 10000
const STAGE_BUDGET_PLAY_US : int = 2500
## The player's neighbourhood: modules whose box centre is within this many metres (XZ) of the spawn.
const NEAR_RADIUS : float = 40.0

signal entry_ready      # the neighbourhood is complete and the first enemy wave exists: safe to hand over
signal entry_complete   # every background stage has finished

var entry_is_ready : bool = false
var entry_is_complete : bool = false
var _stage_workers : Array[Node] = []
var _stage_frame : int = -1
var _stage_t0 : int = 0


# True once this frame's population budget is spent. Workers check it between small units of work and
# `await stage_next_frame()` when it is. The budget is shared by every worker (first come, first served).
func stage_over() -> bool:
	var f : int = Engine.get_process_frames()
	var now : int = Time.get_ticks_usec()
	if f != _stage_frame:
		_stage_frame = f
		_stage_t0 = now
		return false
	var budget : int = STAGE_BUDGET_PLAY_US if entry_is_ready else STAGE_BUDGET_LOADING_US
	return now - _stage_t0 >= budget


func stage_next_frame() -> void:
	await get_tree().process_frame


# Workers register here; each has `stage_near_done: bool` and `stage_done: bool` (set by the worker).
func register_stage_worker(worker: Node) -> void:
	_stage_workers.append(worker)


# One step per frame (each a few ms to a few tens of ms): creating the managers used to be one block of ~200 ms.
func _boot_population(active_player: Node3D, spawn_origin: Vector3) -> void:
	await get_tree().process_frame   # the layout's last frame (and the torch block) presents first
	_boot_prop_spawner(spawn_origin)
	_mark("props_booted")
	await get_tree().process_frame
	_boot_chest_manager(spawn_origin)
	_mark("chests_booted")
	await get_tree().process_frame
	# Build and activate the Proximity Spawner natively (Health Orb Style)
	_boot_enemy_manager(active_player)
	_mark("enemy_manager_booted")
	await get_tree().process_frame
	_boot_room_lock_manager(active_player, spawn_origin)

	dungeon_generation_function.update_player_exploration()

	var lm := get_node_or_null("LightingManager")
	if lm and lm.has_method("setup_environment"):
		lm.setup_environment()
	_boot_torch_light_budget()   # before the dimming manager: it hands its energy changes to the budget
	_boot_torch_dimming_manager()
	GameClock.start_run()
	GameClock.run_ended.connect(_on_run_ended)
	_mark("clock_started")
	await get_tree().process_frame
	GlobeManager.spawn_globes(dungeon_generation_function)
	_mark("globes_spawned")
	await get_tree().process_frame
	_boot_health_orb_manager(spawn_origin)
	await get_tree().process_frame
	_boot_trap_manager(spawn_origin)
	# SURGICAL ADD: Show the wallet overlay only in the dungeon.
	# It is hidden by default and hidden again when returning to menus.
	PlayerWallet.show_hud()

	_update_kill_counter_label()
	_run_stage_monitor()


# Watches the workers: emits entry_ready when the neighbourhood is complete (and the enemy manager's first
# wave exists), entry_complete when everything is. Polls once per frame; no per-frame allocation.
func _run_stage_monitor() -> void:
	var enemy_mgr := get_node_or_null("EnemyManager")
	while not entry_is_complete:
		var all_done : bool = true
		var near_done : bool = true
		for w in _stage_workers:
			if not is_instance_valid(w):
				continue
			if not bool(w.get("stage_done")):
				all_done = false
			if not bool(w.get("stage_near_done")):
				near_done = false
		# The first enemy wave exists (an enemy manager without spawn points never reports one: nothing to wait for).
		var enemies_done : bool = enemy_mgr == null or not is_instance_valid(enemy_mgr) \
				or bool(enemy_mgr.get("_initial_spawn_done")) or (enemy_mgr.get("_all_spawns") as Array).is_empty()
		if not entry_is_ready and near_done and enemies_done:
			entry_is_ready = true
			_mark("entry_ready")
			entry_ready.emit()
		if all_done and entry_is_ready:
			entry_is_complete = true
			_mark("entry_complete")
			entry_complete.emit()
			return
		await get_tree().process_frame


# Scripts, models and textures the population passes load on first use. Listed here so they are requested on
# worker threads at the start of the entry (see _request_background_loads); a path that does not exist is skipped.
const BACKGROUND_LOADS : Array[String] = [
	"res://scripts/chest_manager.gd", "res://scripts/chest.gd", "res://scripts/health_orb_manager.gd",
	"res://scripts/trap_manager.gd", "res://scripts/trap_banner_hud.gd", "res://scripts/room_lock_manager.gd",
	"res://scripts/enemy_manager.gd", "res://scripts/destructible_prop.gd", "res://scripts/kickable_potion.gd",
	"res://addons/props/chests and keys/SM_LockedChestBronze.fbx",
	"res://addons/props/chests and keys/SM_LockedChestSilver.fbx",
	"res://addons/props/chests and keys/SM_LockedChestGold.fbx",
	"res://addons/props/chests and keys/SM_Chests_Mat_Chests_AlbedoTransparency.tga",
	"res://addons/props/chests and keys/SM_Chests_Mat_Chests_MetallicSmoothness.tga",
	"res://addons/props/chests and keys/SM_Chests_Mat_Chests_Normal.tga",
	"res://addons/kenney_particle_pack/magic_04.png", "res://addons/kenney_particle_pack/smoke_07.png",
]


# Prop models and textures are requested on worker threads right away (they are only used after the layout
# exists). load() later returns the cached resource, or waits for the thread that is still loading it.
func _request_background_loads() -> void:
	var paths : Array[String] = BACKGROUND_LOADS.duplicate()
	paths.append_array(PropSpawnerScript.PROP_MODELS)
	paths.append_array(PropSpawnerScript.WALL_FURNITURE_MODELS)
	paths.append_array([PropSpawnerScript.ALBEDO_TEX, PropSpawnerScript.METALLIC_TEX,
			PropSpawnerScript.NORMAL_TEX, "res://addons/props/SM_ManaPotion.fbx"])
	for path in paths:
		if ResourceLoader.exists(path):
			ResourceLoader.load_threaded_request(path)


# ══════════════════════════════════════════════════════════════
#  CHARACTER SPAWNING
# ══════════════════════════════════════════════════════════════

# THE FIX: Now returns the specific Node3D it just created
func _spawn_selected_character() -> Node3D:
	var existing_player := get_node_or_null("Player")
	if existing_player != null:
		# Detach first: queue_free() alone leaves the old node in the tree until
		# end of frame, so the new "Player" would be auto-renamed (@Node3D@N) and
		# every get_node_or_null("Player") lookup would fail.
		remove_child(existing_player)
		existing_player.queue_free()

	var chosen_class := "barbarian"
	var run_data := get_node_or_null("/root/GlobalRunData")
	if run_data != null and "character_class" in run_data:
		chosen_class = run_data.character_class

	var scene_to_use : PackedScene = null
	match chosen_class:
		"mage":
			scene_to_use = mage_scene
		_:
			scene_to_use = barbarian_scene

	if scene_to_use == null:
		push_error("No character scene assigned for class: " + chosen_class)
		return null

	var player_instance := scene_to_use.instantiate() as Node3D
	player_instance.name = "Player"
	add_child(player_instance)

	return player_instance


func _process(delta: float) -> void:
	# Throttle the dungeon exploration update — this walks the full room tree
	# to reveal explored modules. 0.5s is imperceptible to the player and
	# cuts the CPU cost from 60 calls/sec to 2 calls/sec.
	if dungeon_generation_function != null:
		_explore_timer += delta
		if _explore_timer >= EXPLORE_INTERVAL:
			_explore_timer = 0.0
			if dungeon_generation_function.has_method("update_player_exploration"):
				dungeon_generation_function.update_player_exploration()


# ══════════════════════════════════════════════════════════════
#  ENEMY PROXIMITY MANAGER
# ══════════════════════════════════════════════════════════════

func _boot_enemy_manager(player_node: Node3D) -> void:
	var enemy_script := load("res://scripts/enemy_manager.gd")
	if enemy_script == null:
		push_warning("EnemyManager: script not found at res://scripts/enemy_manager.gd")
		return

	# Exactly identical to health_orb_manager deployment
	var manager := Node3D.new()
	manager.name = "EnemyManager"
	manager.set_script(enemy_script)
	add_child(manager)

	# SURGICAL CHANGE: Pull typed spawn data and the waypoint graph from the
	# dungeon generator. registered_typed_spawns holds {position, rotation, type}
	# per spawn point. registered_waypoints is the Array[Vector3] of Connection_
	# and coursec marker positions for waypoint-based navigation.
	var typed_spawns : Array = dungeon_generation_function.registered_typed_spawns \
		if dungeon_generation_function else []
	var waypoints    : Array = dungeon_generation_function.registered_waypoints \
		if dungeon_generation_function else []

	if manager.has_method("boot_up"):
		# The enemy manager parks a few spare enemies behind the loading screen (pool pre-warm): the hand-over waits
		# for it like for the props and orbs, so no enemy has to be instantiated in the middle of play.
		register_stage_worker(manager)
		manager.boot_up(player_node, typed_spawns, waypoints,
						brute_enemy_scene, mage_enemy_scene,
						dungeon_generation_function)


# ══════════════════════════════════════════════════════════════
#  HEALTH ORB MANAGER
# ══════════════════════════════════════════════════════════════

func _boot_trap_manager(spawn_origin: Vector3) -> void:
	var trap_script := load("res://scripts/trap_manager.gd")
	if trap_script == null:
		push_warning("TrapManager script not found — no traps will spawn.")
		return
	var trap_mgr := Node3D.new()
	trap_mgr.name = "TrapManager"
	trap_mgr.set_script(trap_script)
	add_child(trap_mgr)
	if trap_mgr.has_method("boot_traps"):
		var player_node = get_node_or_null("Player")
		trap_mgr.boot_traps(dungeon_generation_function, player_node,
				jumpscare_texture, jumpscare_sound, spawn_origin)
		register_stage_worker(trap_mgr)


func _boot_health_orb_manager(spawn_origin: Vector3) -> void:
	var orb_script := load("res://scripts/health_orb_manager.gd")
	if orb_script == null:
		push_warning("HealthOrbManager: script not found at res://scripts/health_orb_manager.gd")
		return

	var orb_manager := Node3D.new()
	orb_manager.name = "HealthOrbManager"
	orb_manager.set_script(orb_script)
	add_child(orb_manager)
	register_stage_worker(orb_manager)
	orb_manager.stage_begin(spawn_origin)


func _boot_prop_spawner(spawn_origin: Vector3) -> void:
	var prop_script := load("res://scripts/prop_spawner.gd")
	if prop_script == null:
		push_warning("PropSpawner: script not found at res://scripts/prop_spawner.gd")
		return
	var spawner := Node3D.new()
	spawner.name = "PropSpawner"
	spawner.set_script(prop_script)
	add_child(spawner)
	register_stage_worker(spawner)
	spawner.stage_begin(spawn_origin, NEAR_RADIUS)


func _boot_chest_manager(spawn_origin: Vector3) -> void:
	var chest_script := load("res://scripts/chest_manager.gd")
	if chest_script == null:
		push_warning("ChestManager: script not found at res://scripts/chest_manager.gd")
		return
	var mgr := Node3D.new()
	mgr.name = "ChestManager"
	mgr.set_script(chest_script)
	add_child(mgr)
	register_stage_worker(mgr)
	mgr.stage_begin(spawn_origin, NEAR_RADIUS)


func _boot_room_lock_manager(player_node: Node3D, spawn_origin: Vector3) -> void:
	var script := load("res://scripts/room_lock_manager.gd")
	if script == null:
		push_warning("RoomLockManager: script not found.")
		return
	var mgr := Node3D.new()
	mgr.name = "RoomLockManager"
	mgr.set_script(script)
	add_child(mgr)
	var enemy_mgr := get_node_or_null("EnemyManager")
	if mgr.has_method("boot"):
		mgr.boot(player_node, dungeon_generation_function, enemy_mgr, spawn_origin)
		register_stage_worker(mgr)



# ══════════════════════════════════════════════════════════════
#  KILL COUNTER
# ══════════════════════════════════════════════════════════════

func register_enemy_kill() -> void:
	_update_kill_counter_label()


func _reset_kill_counter() -> void:
	CharacterBase.GLOBAL_KILL_COUNT = 0


# Kills row of the top-left HUD cluster (under the health / ability bars, see HudKit): a small blade icon and
# "Kills: N" in the HudValue role. The label keeps its node path and name; the icon is its child, so hiding or
# freeing the label takes the icon along.
func _style_kill_counter() -> void:
	if kill_counter_label == null:
		return
	kill_counter_label.theme_type_variation = &"HudValue"
	kill_counter_label.remove_theme_font_size_override("font_size")   # the scene's hard-coded 22 would fight the role
	var icon_px: float = HudKit.icon_px()
	var pad := StyleBoxEmpty.new()
	pad.content_margin_left = icon_px + float(PUI.S2)
	kill_counter_label.add_theme_stylebox_override("normal", pad)
	kill_counter_label.custom_minimum_size.y = float(HudKit.ROW_KILLS_H)
	kill_counter_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var icon := PUIIcon.make("blade", icon_px)
	icon.position = Vector2(0.0, (float(HudKit.ROW_KILLS_H) - icon_px) * 0.5)
	kill_counter_label.add_child(icon)
	_kill_margin = get_node_or_null("HUD/KillCounterMargin") as Control
	if _kill_margin != null:
		_place_kill_counter()
		get_viewport().size_changed.connect(_place_kill_counter)


func _place_kill_counter() -> void:
	var o: Vector2 = HudKit.origin(get_viewport())
	_kill_margin.offset_left = o.x
	_kill_margin.offset_top = o.y + HudKit.kills_row_top()
	_kill_margin.offset_right = o.x
	_kill_margin.offset_bottom = _kill_margin.offset_top


func _update_kill_counter_label() -> void:
	if kill_counter_label != null:
		var before : String = kill_counter_label.text
		kill_counter_label.text = "Kills: %d" % CharacterBase.GLOBAL_KILL_COUNT
		# Each kill ticks the counter: it pops and settles (not on the reset to 0 at run start).
		if before != "" and CharacterBase.GLOBAL_KILL_COUNT > 0:
			kill_counter_label.pivot_offset = Vector2(0.0, kill_counter_label.size.y * 0.5)
			kill_counter_label.scale = Vector2.ONE * 1.3
			create_tween().tween_property(kill_counter_label, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# ══════════════════════════════════════════════════════════════
#  INTERNALS
# ══════════════════════════════════════════════════════════════

func _apply_run_seed() -> void:
	var run_data_node := get_node_or_null("/root/GlobalRunData")

	if run_data_node != null:
		if int(run_data_node.seed_hash) != 0:
			seed(int(run_data_node.seed_hash))
		else:
			if use_random_seed:
				randomize()
			else:
				seed(fixed_seed)
	else:
		if use_random_seed:
			randomize()
		else:
			seed(fixed_seed)


func _push_generation_settings_into_child() -> void:
	dungeon_generation_function.target_piece_count        = target_piece_count
	dungeon_generation_function.total_generation_attempts = total_generation_attempts
	dungeon_generation_function.attempts_per_connection   = attempts_per_connection

	dungeon_generation_function.weight_4_connection = weight_4_connection
	dungeon_generation_function.weight_3_connection = weight_3_connection
	dungeon_generation_function.weight_2_connection = weight_2_connection
	dungeon_generation_function.weight_1_connection = weight_1_connection

	dungeon_generation_function.overlap_shrink   = overlap_shrink
	dungeon_generation_function.connection_nudge = connection_nudge
	dungeon_generation_function.exclude_keywords = exclude_keywords.duplicate()

	dungeon_generation_function.exploration_padding = exploration_padding
	dungeon_generation_function.enemy_spawn_chance  = enemy_spawn_chance

	# Aligned setup_generation call (stripped old enemy_scene singular)
	dungeon_generation_function.setup_generation(
		self,
		starter_module,
		branch_modules,
		room_connector_module,
		end_cap_module
	)


# ══════════════════════════════════════════════════════════════
#  HARDCORE TORCH DIMMING
# ══════════════════════════════════════════════════════════════

# Render-cost setup that runs once the level exists: (1) the module materials go back to the opaque
# pass (see scripts/dungeon_render_tuning.gd), (2) one light budget for the level: only the torches
# nearest to the camera keep their OmniLight3D on (flame spheres stay for all of them), see
# scripts/torch_light_budget.gd.
func _boot_torch_light_budget() -> void:
	var tuning = load("res://scripts/dungeon_render_tuning.gd")
	if tuning != null and dungeon_generation_function != null:
		tuning.apply_to_modules(dungeon_generation_function.placed_modules)
	var script := load("res://scripts/torch_light_budget.gd")
	if script == null:
		push_warning("TorchLightBudget: script not found - every torch light stays on.")
		return
	var mgr := Node.new()
	mgr.name = "TorchLightBudget"
	mgr.set_script(script)
	mgr.set("flicker_amount", 0.09)   # torches breathe (game feel); the budget's own tests leave it at 0
	add_child(mgr)
	var torches : Array = dungeon_generation_function.registered_torches \
		if dungeon_generation_function != null else []
	if mgr.has_method("boot"):
		mgr.boot(torches)
	# rooms far from the camera are hidden (render nodes only), see scripts/module_visibility.gd
	var vis_script = load("res://scripts/module_visibility.gd")
	if vis_script != null and dungeon_generation_function != null:
		var vis := Node.new()
		vis.name = "ModuleVisibility"
		vis.set_script(vis_script)
		add_child(vis)
		vis.boot(dungeon_generation_function.placed_modules, dungeon_generation_function.torch_flame_batches,
				dungeon_generation_function.torch_flame_bounds)


func _boot_torch_dimming_manager() -> void:
	if not has_node("/root/GlobalRunData"):
		return
	if GlobalRunData.difficulty != "hardcore":
		return
	var script := load("res://scripts/torch_dimming_manager.gd")
	if script == null:
		push_warning("TorchDimmingManager: script not found — torch dimming disabled.")
		return
	var mgr := Node.new()
	mgr.name = "TorchDimmingManager"
	mgr.set_script(script)
	add_child(mgr)
	var lighting_mgr := get_node_or_null("LightingManager")
	var torches : Array = dungeon_generation_function.registered_torches \
		if dungeon_generation_function != null else []
	if mgr.has_method("boot"):
		mgr.boot(torches, lighting_mgr)


func get_map_bounds_xz() -> Rect2:
	if dungeon_generation_function != null and dungeon_generation_function.has_method("get_map_bounds_xz"):
		return dungeon_generation_function.get_map_bounds_xz()
	return Rect2()


func get_minimap_module_data() -> Array[Dictionary]:
	if dungeon_generation_function != null and dungeon_generation_function.has_method("get_minimap_module_data"):
		return dungeon_generation_function.get_minimap_module_data()
	return []


# ══════════════════════════════════════════════════════════════
#  DAY 30 — END PORTAL
# ══════════════════════════════════════════════════════════════

func _on_run_ended() -> void:
	# Lock reinforcement spawning — the dungeon drains to zero from here.
	var enemy_mgr := get_node_or_null("EnemyManager")
	if enemy_mgr != null and enemy_mgr.has_method("stop_spawning"):
		enemy_mgr.stop_spawning()

	# Build and boot the portal manager.
	var portal_script := load("res://scripts/portal_manager.gd")
	if portal_script == null:
		push_warning("PortalManager: script not found — end portal will not appear.")
		return

	var portal_mgr := Node3D.new()
	portal_mgr.name = "PortalManager"
	portal_mgr.set_script(portal_script)
	add_child(portal_mgr)

	var minimap_node := get_node_or_null("minimap_function")
	var player_node  := get_node_or_null("Player")

	if portal_mgr.has_method("boot"):
		portal_mgr.boot(
			dungeon_generation_function,
			player_node,
			brute_enemy_scene,
			mage_enemy_scene,
			minimap_node,
			enemy_mgr
		)


func get_player_map_position() -> Vector2:
	if dungeon_generation_function != null and dungeon_generation_function.has_method("get_player_map_position"):
		return dungeon_generation_function.get_player_map_position()
	return Vector2.ZERO


func get_player_map_forward() -> Vector2:
	if dungeon_generation_function != null and dungeon_generation_function.has_method("get_player_map_forward"):
		return dungeon_generation_function.get_player_map_forward()
	return Vector2.UP


func reveal_all_modules() -> void:
	if dungeon_generation_function != null and dungeon_generation_function.has_method("reveal_all_modules"):
		dungeon_generation_function.reveal_all_modules()


func set_lock_overlay_for_all(color_name: String, visible_value: bool) -> void:
	if dungeon_generation_function != null and dungeon_generation_function.has_method("set_lock_overlay_for_all"):
		dungeon_generation_function.set_lock_overlay_for_all(color_name, visible_value)
