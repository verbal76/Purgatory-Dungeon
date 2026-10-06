# ==============================================================================
#  FILE: enemy_manager.gd
#  PATH: res://scripts/enemy_manager.gd
#  DESCRIPTION: Proximity-based enemy spawner for a fast-paced action roguelite.
#               Spawns up to initial_zone_size points near the player at boot,
#               maintains a live population cap, and periodically tops up as
#               enemies die.
#               Difficulty escalates each game day via type-3 buff increases;
#               once the buff cap is hit the population cap rises.
#               Dead bodies never count against the live cap.
#
#  ADJUSTABLE SETTINGS:
#  population_cap          — max live enemies at once (default 40)
#  initial_zone_size       — spawn points considered near player at boot (default 100)
#  active_zone_radius      — metres around player that defines the spawn zone (default 50)
#  min_spawn_distance      — minimum metres from player before a point can be used (default 8)
#  min_separation_distance — minimum metres between any two chosen spawn points (default 12)
#                            controls spread — higher = more spread, lower = more clustered
#  respawn_check_interval  — seconds between population top-up ticks
#  respawn_batch_size      — max enemies spawned per top-up tick
#  spawn_batch_size        — enemies per deferred frame during initial spawn
#  cull_check_interval     — seconds between dead-body cleanup sweeps
#  dungeon_raycast_down    — metres downward to cast to validate dungeon floor (default 8)
#
#  MOD NOTES:
#  - NavMesh is gone. Navigation uses the Connection_/coursec waypoint graph.
#  - Typed spawn routing: type 1 → Brute, type 2 → Mage,
#    type 3 → random Brute or Mage + escalating buff + red glow.
#  - _live_count maintained as an integer (not re-scanned each frame).
#  - No Array/Dictionary construction inside _physics_process.
#  - SURGICAL FIX: Added min_spawn_distance to _refresh_active_zone() to prevent 
#    enemies from dropping directly on the player's head.
#  - SURGICAL FIX: Converted _top_up_population() to trigger a staggered, asynchronous 
#    spawn wave that yields one frame between instantiations to prevent the 10-second lag spike.
#  - SURGICAL FIX: Changed cull_check_interval to 1.0s so the live count drops instantly when an enemy dies.
#  - SURGICAL FIX: Added PROCESS_MODE_ALWAYS to _ready() so the manager ignores the Loading
#    Screen pause state and successfully builds the enemies in the background.
# ==============================================================================
extends Node3D

# Emitted when the initial batch spawn is fully complete.
# loading_screen.gd listens for this to know when to dismiss.
signal spawn_complete

# ── Population ─────────────────────────────────────────────────────────────────
@export var population_cap            : int   = 30     # Max live enemies at any time.
														# Was 36 → lowered to 30 to give room-lock
														# encounters headroom without hitting the
														# 40-enemy AI budget ceiling.
@export var initial_zone_size         : int   = 40     # Spawn points sampled near player at boot (was 60)
@export var active_zone_radius        : float = 40.0   # Metres around player for spawn selection
@export var min_spawn_distance        : float = 8.0    # Minimum metres from player to spawn
@export var min_separation_distance   : float = 12.0   # Minimum metres between any two chosen spawn points
@export var respawn_check_interval    : float = 4.0    # Seconds between top-up ticks (was 2.0 — too aggressive)
@export var respawn_batch_size        : int   = 5      # Max spawned per top-up tick (was 8 — smoother per-tick cost)
@export var spawn_batch_size          : int   = 3      # Spawned per deferred frame at boot
@export var cull_check_interval       : float = 1.0    # Seconds between dead-body cleanup sweeps

# ── Mage spawn weighting ───────────────────────────────────────────────────────
# 0.0 = no mages ever, 1.0 = all mages. Applied to type-2 (dedicated mage slots)
# and type-3 (buffed random slots). Type-1 slots always spawn brutes.
# Mages are more expensive to run than brutes (strafe, spell AI, fireball particles)
# so keeping this below 0.3 is recommended for stable framerates.
@export var mage_spawn_chance         : float = 0.2   # 20% — mages are rare and scary

# ── Room population cap ────────────────────────────────────────────────────────
# Enemies will not spawn into a spawn point if room_enemy_cap or more alive
# enemies are already within room_cap_radius metres of it. They instead wait
# at their current position (corridor, adjacent room) and flood in naturally
# as the player kills and the local count drops below the cap.
@export var room_enemy_cap            : int   = 5     # Max enemies per room-sized area
@export var room_cap_radius           : float = 10.0  # Metres defining a "room" for the cap check

# ── Difficulty escalation ──────────────────────────────────────────────────────
# Type-3 (spawnpoint3) enemies start at base_buff_multiplier and escalate
# each game day up to buff_cap. After buff_cap is reached the live population
# cap grows instead, making the dungeon progressively more dangerous.
@export var base_buff_multiplier     : float = 1.25  # 25% above base at day 1
@export var buff_cap                 : float = 2.25  # Type-3 ceiling — caps day 20 (was 1.75/day 6)
@export var buff_increment_per_day   : float = 0.05  # Buff added per in-game day — slower ramp, longer climb
@export var pop_cap_increment_per_day: int   = 1     # Pop cap added per day once type-3 buff is maxed
@export var max_population_cap       : int   = 40    # Hard ceiling — 40 is the known safe budget for this dungeon
													 # (see population_cap comment: >40 enemies tanks FPS)

# ── Global daily stat progression ─────────────────────────────────────────────
# Applies a multiplier to ALL enemies (not just type-3) that grows each day.
# Uses linear + quadratic formula so early game is forgiving and late game is
# relentless. Stacks with type-3 buff so elite enemies are doubly scary.
@export var global_stat_mult_per_day : float = 0.025 # 2.5 % linear per day
@export var global_stat_mult_cap     : float = 2.50  # Hard cap — day 30 reaches ~2.39× with quad bonus

# ── Runtime references — set in boot_up, never fetched mid-frame ──────────────
var _player         : Node3D       = null
var _brute_scene    : PackedScene  = null
var _mage_scene     : PackedScene  = null
var _waypoints      : Array        = []       # Array[Vector3] passed to each enemy
var _main_root      : Node3D       = null
# Reference to the dungeon generator — used for AABB-based spawn validation.
var _dungeon_gen    : Node         = null

# ── Enemy recycling pools ─────────────────────────────────────────────────────
# Dead enemies are returned here instead of queue_free()'d. On the next
# top-up tick, _acquire_enemy() pulls from the pool before instantiating.
# Pool size is bounded by population_cap to avoid unbounded memory growth.
var _brute_pool : Array = []
var _mage_pool  : Array = []

# ── Spawn data — populated at boot, never modified after ──────────────────────
var _all_spawns  : Array = []            # Full registered_typed_spawns list
var _active_zone : Array = []            # Current proximity subset of _all_spawns

# ── Initial spawn queue — drained across deferred frames ──────────────────────
var _spawn_queue : Array = []
var _spawn_index : int   = 0

# ── Live enemy tracking ────────────────────────────────────────────────────────
# _live_count is maintained as a plain integer — incremented on spawn,
# decremented on death/cull — so we never scan the full array mid-frame.
var _active_enemies       : Array = []   # All spawned, possibly dead nodes
var _live_count           : int   = 0    # Live (not dead) enemy count
# Set true when _spawn_next_batch() drains the initial queue fully.
# loading_screen.gd polls this as a race-condition safety check.
var _initial_spawn_done   : bool  = false

# ── Pool pre-warm (entry stage worker) ─────────────────────────────────────────
# Instantiating an enemy (scene instance, its _ready, a mage's six pooled fireballs) costs about 5-10 ms on a desktop
# core and several times that on a phone. During play that landed as a spike whenever the pool was empty: the first
# top-ups after the opening wave, every pressure spawn, and every enemy that was freed (not recycled) and replaced.
# So a few spare enemies are built here, behind the loading screen, one per frame, and parked in the pools; the
# main game file waits for stage_near_done before it hands control over (same protocol as the other stage workers).
const PREWARM_MAX   : int     = 12                       # upper bound on parked spares built at entry
const PREWARM_SPARE : int     = 2                        # spares beyond the opening wave's shortfall
const PARK_POSITION : Vector3 = Vector3(0.0, -400.0, 0.0)  # far under the dungeon: no AoE / distance query reaches a parked enemy
var stage_near_done : bool = false
var stage_done      : bool = false
var _prewarmed      : int  = 0

# Set true when the run ends (day 30) — stops all reinforcement spawning.
# The live population drains naturally as the player kills enemies.
var _spawning_locked      : bool  = false

# ── Timers — all updated in _physics_process ──────────────────────────────────
var _cull_timer       : float = 0.0
var _paused_since_msec : int  = 0     # wall-clock start of the current pause (0 = not paused)
var _respawn_timer    : float = 0.0
var _diff_timer       : float = 0.0
var _pressure_timer   : float = 0.0   # Tracks seconds since player last took damage
const DIFF_CHECK_INTERVAL    : float = 10.0
const KILL_PLANE_Y            : float = -15.0  # Same floor the player uses (brute_player.gd)
const PRESSURE_THRESHOLD     : float = 30.0  # Seconds of no damage before pressure spawn
const PRESSURE_CHECK_INTERVAL: float = 5.0   # How often to check pressure condition
const BASE_RESPAWN_INTERVAL  : float = 4.0   # Baseline interval — compressed by day in _check_difficulty_escalation

# ── Day-cull settings ──────────────────────────────────────────────────────────
# Each time a new day ticks, a fraction of live enemies that are far from the
# player are instant-killed so they respawn moments later with the updated
# day buff applied.  Enemies close to the player (in active combat) are never
# culled — disappearing mid-fight would feel wrong.
const CULL_START_DAY      : int   = 3     # No culling before this day
const CULL_FRACTION       : float = 0.25  # Fraction of live count to cull per day
const CULL_MIN_DISTANCE   : float = 18.0  # Only cull enemies further than this from player

# ── Difficulty state ───────────────────────────────────────────────────────────
var _current_buff_mult  : float = 1.25   # Type-3 specific multiplier
var _global_base_mult   : float = 1.0    # Applied to ALL enemies; grows with the day
var _current_pop_cap    : int   = 40
var _last_day_checked   : int   = 0
var _pop_cap_day_accum  : int   = 0      # Counts days for the 1-per-3-day gradual growth


# ══════════════════════════════════════════════════════════════════════════════
#  BOOT
# ══════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	# Register in the enemy_spawner group so loading_screen.gd can find
	# this node and connect to the spawn_complete signal.
	add_to_group("enemy_spawner")
	# SURGICAL FIX: Allow the manager to keep building enemies while the loading screen pauses the game
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Stays idle until boot_up() is called by the main game file.
	set_physics_process(false)


# Called by main game file after dungeon generation completes.
func boot_up(
	player_node  : Node3D,
	typed_spawns : Array,
	waypoints    : Array,
	brute_scene  : PackedScene,
	mage_scene   : PackedScene,
	dungeon_gen  : Node = null
) -> void:
	print("\n--- ENEMY MANAGER BOOTING ---")
	print("Total spawn points registered: ", typed_spawns.size())
	print("Waypoints available: ", waypoints.size())
	print("Player valid: ", player_node != null)
	print("Brute scene: ", brute_scene != null, "  Mage scene: ", mage_scene != null)

	# GLOBAL_PLAYER_LAST_DAMAGE_TIME is static and starts at 0 (or holds the last
	# run's value), which made the "no damage for 30s" pressure spawn fire the
	# moment a run began. Treat run start as the last "damage" moment.
	CharacterBase.GLOBAL_PLAYER_LAST_DAMAGE_TIME = Time.get_ticks_msec() * 0.001

	_player            = player_node
	_brute_scene       = brute_scene
	_mage_scene        = mage_scene
	_waypoints         = waypoints
	_main_root         = get_parent()
	_dungeon_gen       = dungeon_gen
	_current_buff_mult = base_buff_multiplier
	_current_pop_cap   = population_cap

	# ── Run-count difficulty scaling ──────────────────────────────────────────
	# Early runs get a reduced population so new players aren't overwhelmed.
	# Runs 1-5:  25% of cap  (minimum 5 so there's always some action)
	# Runs 6-10: 50% of cap
	# Runs 11-15: 75% of cap
	# Run 16+:   full cap
	# Run-count scaling — new players start with fewer enemies; veterans get the full dungeon.
	# Tuned to feel dangerous but not overwhelming for early runs.
	# All thresholds and percentages are @export vars (see top of file).
	var run_count : int = int(SaveManager.current_profile.get("run_count", 1))
	if run_count <= 3:
		_current_pop_cap = maxi(int(_current_pop_cap * 0.50), 6)   # 50 % — ~9 enemies
	elif run_count <= 8:
		_current_pop_cap = maxi(int(_current_pop_cap * 0.65), 8)   # 65 % — ~12 enemies
	elif run_count <= 14:
		_current_pop_cap = maxi(int(_current_pop_cap * 0.80), 10)  # 80 % — ~14 enemies
	# run_count 15+ uses full _current_pop_cap — no reduction
	print("Run ", run_count, " → effective pop cap: ", _current_pop_cap)

	# ── Difficulty scaling — applied once at boot, never touches hot paths ────
	var diff : String = ""
	if has_node("/root/GlobalRunData"):
		diff = str(GlobalRunData.difficulty)
	match diff:
		"easy":
			_current_buff_mult    = base_buff_multiplier * 0.7
			global_stat_mult_per_day *= 0.6
			_current_pop_cap      = maxi(int(_current_pop_cap * 0.75), 5)
		"hardcore":
			_current_buff_mult    = base_buff_multiplier * 1.2
			global_stat_mult_per_day *= 1.3
		# "medium" and anything else: no change
	print("Difficulty: ", diff, " → buff ×%.2f  stat/day ×%.3f  pop %d" % [
		_current_buff_mult, global_stat_mult_per_day, _current_pop_cap])

	if typed_spawns.is_empty():
		push_warning("EnemyManager: no spawn points registered. No enemies will spawn.")
		stage_near_done = true
		stage_done = true
		return

	if _brute_scene == null and _mage_scene == null:
		push_warning("EnemyManager: no enemy scenes assigned. No enemies will spawn.")
		stage_near_done = true
		stage_done = true
		return

	_all_spawns = typed_spawns.duplicate()

	# Pre-validate spawn points: discard any that are not above dungeon geometry.
	# A downward raycast from each point checks for a floor hit within dungeon_raycast_down
	# metres. Points that miss (outside rooms, in voids, clipped through walls) are
	# removed here so they can never be selected at boot or during top-up ticks.
	var valid_spawns : Array = []
	for entry in _all_spawns:
		var pos : Vector3 = entry.get("position", Vector3.ZERO)
		if _is_above_dungeon(pos):
			valid_spawns.append(entry)
	_all_spawns = valid_spawns
	print("Valid spawn points after dungeon validation: ", _all_spawns.size())

	# Find the closest spawn points to the player and build the initial queue.
	_refresh_active_zone()
	_build_initial_queue()
	_spawn_next_batch()


# ══════════════════════════════════════════════════════════════════════════════
#  DUNGEON FLOOR VALIDATION
# ══════════════════════════════════════════════════════════════════════════════

# Returns true if pos falls within any placed dungeon module's XZ AABB footprint.
# Caches the world-space position of every live torch in the dungeon so the
# active-zone sort can prefer spawn points far from light sources without
# doing an O(torches) lookup per candidate in a hot loop elsewhere.
func _collect_torch_positions() -> Array:
	var out : Array = []
	if _dungeon_gen == null:
		return out
	var torch_list = _dungeon_gen.get("registered_torches")
	if typeof(torch_list) != TYPE_ARRAY:
		return out
	for t in torch_list:
		if t is Node3D and is_instance_valid(t):
			out.append((t as Node3D).global_position)
	return out


# Squared distance from `pos` to the nearest entry in `positions`. Returns 0
# if the list is empty (treats "no torches" as uniformly lit — no darkness
# preference possible).
func _dist_sq_to_nearest(pos: Vector3, positions: Array) -> float:
	if positions.is_empty():
		return 0.0
	var best : float = INF
	for p in positions:
		var d : float = pos.distance_squared_to(p)
		if d < best:
			best = d
	return 0.0 if best == INF else best


# Same answer as _dist_sq_to_nearest() for a torch list bucketed by _bucket_positions(): scans square
# rings of cells outward from the point and stops as soon as no farther ring can hold a closer torch.
# The boot used to compare every candidate spawn with every torch (~150 x ~760 distances).
const _BUCKET : float = 10.0

func _bucket_positions(positions: Array) -> Dictionary:
	var grid : Dictionary = {}
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-(1 << 30), -(1 << 30))
	for p in positions:
		var c := Vector2i(int(floorf(p.x / _BUCKET)), int(floorf(p.z / _BUCKET)))
		if grid.has(c):
			(grid[c] as Array).append(p)
		else:
			grid[c] = [p]
		lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
		hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
	if not positions.is_empty():
		grid["_lo"] = lo
		grid["_hi"] = hi
	return grid


func _dist_sq_to_nearest_bucketed(pos: Vector3, grid: Dictionary) -> float:
	if not grid.has("_lo"):
		return 0.0
	var lo : Vector2i = grid["_lo"]
	var hi : Vector2i = grid["_hi"]
	var cx : int = int(floorf(pos.x / _BUCKET))
	var cz : int = int(floorf(pos.z / _BUCKET))
	var best : float = INF
	var ring : int = 0
	# Rings reach every torch once they span the whole bucketed area from the point's own cell.
	var max_ring : int = maxi(maxi(absi(cx - lo.x), absi(cx - hi.x)), maxi(absi(cz - lo.y), absi(cz - hi.y)))
	while ring <= max_ring:
		# Rings from `ring` outward are at least (ring - 1) cells away horizontally.
		if ring > 1 and best <= (float(ring - 1) * _BUCKET) * (float(ring - 1) * _BUCKET):
			break
		for dx in range(-ring, ring + 1):
			for dz in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dz)) != ring:
					continue
				var cell = grid.get(Vector2i(cx + dx, cz + dz))
				if cell == null:
					continue
				for p in cell:
					var d : float = pos.distance_squared_to(p)
					if d < best:
						best = d
		ring += 1
	return 0.0 if best == INF else best


# Delegates to dungeon_generation_function.is_position_inside_dungeon() which
# uses the already-cached AABBs — zero additional raycasts needed.
# This replaces the downward raycast which was hitting the safety floor and
# incorrectly validating void spawn points outside the actual rooms.
func _is_above_dungeon(pos: Vector3) -> bool:
	if _dungeon_gen != null and _dungeon_gen.has_method("is_position_inside_dungeon"):
		return _dungeon_gen.is_position_inside_dungeon(pos)
	# Fallback: if dungeon gen wasn't passed, allow the spawn so the game
	# doesn't silently lose all enemy spawn points.
	push_warning("EnemyManager: _dungeon_gen not set — skipping AABB validation.")
	return true


# ══════════════════════════════════════════════════════════════════════════════
#  ZONE MANAGEMENT
# ══════════════════════════════════════════════════════════════════════════════

# Selects spawn points within active_zone_radius using a greedy nearest-first
# algorithm that enforces min_separation_distance between every chosen point.
#
# The natural result is an expanding ring pattern:
#   1. Nearest valid point is always chosen first.
#   2. Next candidate must be ≥ min_separation_distance from all chosen so far.
#   3. This spirals outward through the dungeon organically.
#
# Enemies therefore start spawning close to the player and fan out, so they
# arrive in waves rather than all converging from one direction at once.
func _refresh_active_zone() -> void:
	if _player == null or not is_instance_valid(_player):
		return

	var player_pos   : Vector3 = _player.global_position
	var max_sq       : float   = active_zone_radius * active_zone_radius
	var min_sq       : float   = min_spawn_distance * min_spawn_distance
	var sep_sq       : float   = min_separation_distance * min_separation_distance

	# Cache the torch list once up-front — iterating it per-candidate would be
	# O(candidates × torches) which is still fine at 50 × 300 but this saves it.
	var torches : Dictionary = _bucket_positions(_collect_torch_positions())

	# Collect and sort all candidates within the doughnut zone (min to max distance).
	var candidates : Array = []
	for entry in _all_spawns:
		var pos     : Vector3 = entry.get("position", Vector3.ZERO)
		var dist_sq : float   = player_pos.distance_squared_to(pos)
		if dist_sq >= min_sq and dist_sq <= max_sq:
			candidates.append({
				"data": entry,
				"pos": pos,
				"dist_sq": dist_sq,
				"torch_dist_sq": _dist_sq_to_nearest_bucketed(pos, torches),
			})

	# Sort by composite score: mostly nearest-to-player, with a soft nudge
	# toward DARKER spots (further from the nearest torch). Two candidates at
	# similar distance to the player will prefer the darker one, so a pair of
	# enemies spawning near you tend to emerge from shadow rather than from
	# under a torch — hides the "pop in" visual. Weight is deliberately mild.
	const DARKNESS_WEIGHT : float = 0.25
	candidates.sort_custom(func(a, b):
		var sa : float = a.dist_sq - DARKNESS_WEIGHT * a.torch_dist_sq
		var sb : float = b.dist_sq - DARKNESS_WEIGHT * b.torch_dist_sq
		return sa < sb)

	# Greedy selection: accept each candidate only if it is far enough from every
	# already-accepted point. Builds spread from the inside out automatically.
	_active_zone.clear()
	var accepted_positions : Array = []   # Vector3 list — no per-frame allocation

	for candidate in candidates:
		if _active_zone.size() >= initial_zone_size:
			break
		var pos      : Vector3 = candidate.pos
		var too_close : bool   = false
		for accepted_pos in accepted_positions:
			if pos.distance_squared_to(accepted_pos) < sep_sq:
				too_close = true
				break
		if not too_close:
			_active_zone.append(candidate.data)
			accepted_positions.append(pos)


# Fills the initial spawn queue from the active zone, capped at population_cap.
func _build_initial_queue() -> void:
	_spawn_queue.clear()
	_spawn_index = 0
	var limit : int = mini(_active_zone.size(), _current_pop_cap)
	for i in range(limit):
		_spawn_queue.append(_active_zone[i])


# ══════════════════════════════════════════════════════════════════════════════
#  DEFERRED BATCH SPAWNING  (initial boot only)
# ══════════════════════════════════════════════════════════════════════════════

# Spawns up to spawn_batch_size enemies per deferred call.
func _spawn_next_batch() -> void:
	var spawned : int = 0

	while _spawn_index < _spawn_queue.size() \
		  and spawned < spawn_batch_size \
		  and _live_count < _current_pop_cap:
		var data : Dictionary = _spawn_queue[_spawn_index]
		_spawn_index += 1
		if _spawn_enemy_from_data(data):
			spawned += 1

	if _spawn_index < _spawn_queue.size() and _live_count < _current_pop_cap:
		# More enemies queued and cap not yet reached — continue next frame
		call_deferred("_spawn_next_batch")
	else:
		print("✅ Initial spawn complete. Live enemies: ", _live_count)
		_initial_spawn_done = true
		var main : Node = get_parent()
		if main != null and main.has_method("entry_mark"):
			main.entry_mark("initial_spawn_done")
		emit_signal("spawn_complete")
		set_physics_process(true)
		_prewarm_pool()   # coroutine: one spare per frame, flags stage_near_done / stage_done when finished


# ══════════════════════════════════════════════════════════════════════════════
#  ENEMY INSTANTIATION
# ══════════════════════════════════════════════════════════════════════════════

# Instantiates one enemy from a spawn data dictionary.
func _spawn_enemy_from_data(data: Dictionary) -> bool:
	var spawn_type : int     = data.get("type",     1)
	var spawn_pos  : Vector3 = data.get("position", Vector3.ZERO)
	var spawn_rot  : Vector3 = data.get("rotation", Vector3.ZERO)
	var is_buffed  : bool    = (spawn_type == 3)

	# ── LOS check — skip any point the player can currently see ──────────────
	# Spawning in the player's field of vision breaks immersion hard.
	# We raycast from the player's eye position to the spawn point through
	# static geometry only. If nothing blocks it, the point is visible — skip.
	if _player_can_see_spawn(spawn_pos):
		return false

	# ── Room cap check ────────────────────────────────────────────────────────
	if _count_enemies_near(spawn_pos) >= room_enemy_cap:
		return false

	# ── Stacking check — prevent spawning directly on top of another enemy ────
	# Tighter than room_cap_radius. Two enemies within 1m of each other clip
	# badly and read as one target. Skip if any live enemy is within 1.5m.
	if _enemy_too_close(spawn_pos, 1.5):
		return false

	var scene_to_use : PackedScene = _pick_scene_for_type(spawn_type)
	if scene_to_use == null:
		return false

	# ── Pool acquire — reuse a recycled enemy before instantiating a new one ──
	var is_brute   : bool   = (scene_to_use == _brute_scene)
	var pool       : Array  = _brute_pool if is_brute else _mage_pool
	var from_pool  : bool   = not pool.is_empty()
	var enemy      : Node3D

	if from_pool:
		enemy = pool.pop_back() as Node3D
		if not is_instance_valid(enemy):
			# Stale reference — try again without pool
			from_pool = false
	if not from_pool:
		enemy = scene_to_use.instantiate() as Node3D
		if enemy == null:
			return false
		_main_root.add_child(enemy)

	# ── Floor snap ────────────────────────────────────────────────────────────
	var safe_pos : Vector3 = _snap_to_floor(spawn_pos)

	if from_pool and enemy.has_method("reset_for_pool"):
		# Reused enemy: reset all AI/health state, re-position in one call.
		enemy.reset_for_pool(safe_pos, spawn_rot, _waypoints)
	else:
		# Fresh enemy: standard first-time setup.
		# NOTE: Do NOT set global_rotation — mesh facing is fully managed by
		# _physics_tick's atan2 formula, which assumes CharacterBody3D.rotation.y = 0.
		# Setting global_rotation from spawn data would offset the local mesh rotation
		# and flip the facing direction (the moonwalk bug).
		enemy.global_position = safe_pos
		if enemy.has_method("initialize_waypoints"):
			enemy.initialize_waypoints(_waypoints)

	# Wire the pool-return callback so _on_die() recycles instead of freeing.
	if enemy.has_method("set_pool_return"):
		enemy.set_pool_return(
			Callable(self, "_on_enemy_returned_to_pool").bind(enemy, is_brute))

	# Apply daily progression to every enemy.
	# Regular enemies get the global base multiplier.
	# Type-3 (buffed) enemies stack the global mult × their type-3 specific mult.
	var effective_mult : float = _global_base_mult
	if is_buffed:
		effective_mult = _global_base_mult * _current_buff_mult

	if effective_mult > 1.001 and enemy.has_method("apply_buff"):
		enemy.apply_buff(effective_mult)
	if is_buffed and enemy.has_method("apply_red_glow"):
		enemy.apply_red_glow()

	_active_enemies.append(enemy)
	_live_count += 1
	return true


# ── Scripted spawn for RoomLockManager ───────────────────────────────────────
# Spawns one enemy at an exact position with a custom waypoint list.
# Bypasses LOS / room-cap / separation checks — these are intentional
# encounters, not ambient proximity spawns.
# Still respects a hard live-count ceiling (max_population_cap + 5 overflow)
# so room-lock encounters can't push the AI budget past the frame budget.
# Returns the enemy node so the caller can connect to its `died` signal.
func force_spawn_at(pos: Vector3, waypoints: Array, override_mult: float = 0.0) -> Node3D:
	# Allow up to 5 over the normal cap for room-lock events, no more.
	if _live_count >= max_population_cap + 5:
		return null
	# Respect debug suppression — room-lock encounters still obey the toggles.
	var no_brutes : bool = GlobalRunData.debug_no_brutes
	var no_mages  : bool = GlobalRunData.debug_no_mages
	if no_brutes and no_mages:
		return null
	var scene_to_use : PackedScene
	if no_brutes:
		scene_to_use = _mage_scene
	elif no_mages:
		scene_to_use = _brute_scene
	else:
		scene_to_use = _brute_scene if _brute_scene != null else _mage_scene
	if scene_to_use == null:
		return null

	var is_brute  : bool  = (scene_to_use == _brute_scene)
	var pool      : Array = _brute_pool if is_brute else _mage_pool
	var from_pool : bool  = not pool.is_empty()
	var enemy     : Node3D

	if from_pool:
		enemy = pool.pop_back() as Node3D
		if not is_instance_valid(enemy):
			from_pool = false
	if not from_pool:
		enemy = scene_to_use.instantiate() as Node3D
		if enemy == null:
			return null
		_main_root.add_child(enemy)

	var safe_pos  : Vector3 = _snap_to_floor(pos)
	var wps_final : Array   = waypoints if not waypoints.is_empty() else _waypoints

	if from_pool and enemy.has_method("reset_for_pool"):
		enemy.reset_for_pool(safe_pos, Vector3.ZERO, wps_final)
	else:
		enemy.global_position = safe_pos
		if enemy.has_method("initialize_waypoints"):
			enemy.initialize_waypoints(wps_final)

	if enemy.has_method("set_pool_return"):
		enemy.set_pool_return(
			Callable(self, "_on_enemy_returned_to_pool").bind(enemy, is_brute))

	# override_mult > 0 means the caller (e.g. room_lock_manager) wants a specific
	# multiplier applied instead of the default day-progression value.
	var final_mult : float = override_mult if override_mult > 0.001 else _global_base_mult
	if final_mult > 1.001 and enemy.has_method("apply_buff"):
		enemy.apply_buff(final_mult)

	_active_enemies.append(enemy)
	_live_count += 1
	return enemy


# Counts alive enemies within room_cap_radius of a position.
# Used by _spawn_enemy_from_data to enforce the per-room enemy cap.
# Runs only on spawn events, not per-frame — O(n) is acceptable here.
func _count_enemies_near(pos: Vector3) -> int:
	var cap_sq : float = room_cap_radius * room_cap_radius
	var count  : int   = 0
	for enemy in _active_enemies:
		if is_instance_valid(enemy) and enemy.get("_is_dead") != true:
			if pos.distance_squared_to(enemy.global_position) < cap_sq:
				count += 1
	return count


# Returns true if any live enemy is within radius metres of pos.
# Separate from room_enemy_cap — this is a tight personal-space check
# (1.5m) that prevents two enemies occupying the same floor tile.
func _enemy_too_close(pos: Vector3, radius: float) -> bool:
	var sq : float = radius * radius
	for enemy in _active_enemies:
		if is_instance_valid(enemy) and enemy.get("_is_dead") != true:
			if pos.distance_squared_to(enemy.global_position) < sq:
				return true
	return false


# Raycasts downward from 3m above pos to find the actual floor surface.
# Spawn points may be placed at room-centre height — without this, enemies
# spawn mid-air and visibly skydive. Uses static geometry only (mask=1)
# so we snap to floors, not to other enemy capsules.
# Returns the hit surface + 0.15m, or pos + 0.1m as a safe fallback.
func _snap_to_floor(pos: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var from  := pos + Vector3(0.0, 1.5, 0.0)   # 1.5 m up — stays below the 3.5 m ceiling
	var to    := pos + Vector3(0.0, -6.0, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1
	# mask 1 also contains props/enemies/chests; ray_world skips those so a prop at the
	# spawn point cannot lift the enemy onto its top.
	var result := PhysicsUtil.ray_world(space, query)
	if not result.is_empty():
		return result.position + Vector3(0.0, 0.15, 0.0)
	return pos + Vector3(0.0, 0.1, 0.0)


# Returns true if the player has unobstructed LOS to pos (eye→spawn point).
# Uses static geometry only so dynamic objects don't falsely block the check.
# A clear result means the player would see the enemy appear — skip that point.
func _player_can_see_spawn(pos: Vector3) -> bool:
	if _player == null or not is_instance_valid(_player):
		return false
	var world := get_world_3d()
	if world == null:
		return false
	var space := world.direct_space_state
	if space == null:
		return false
	var from  := _player.global_position + Vector3(0.0, 1.6, 0.0)  # Eye height
	var to    := pos + Vector3(0.0, 1.0, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1
	query.exclude        = [_player.get_rid()]
	# Only level geometry hides a spawn point; an enemy or prop in the line must not.
	var result := PhysicsUtil.ray_world(space, query)
	return result.is_empty()   # Empty = nothing blocking = player can see it



# mage_spawn_chance (0.0–1.0) controls how often a mage is chosen.
# Type-1 slots always spawn brutes — they are the baseline fighter.
# Type-2 slots respect mage_spawn_chance (default 20% mage).
# Type-3 buffed slots also use mage_spawn_chance for the random pick.
# Keeping mages rare is important — they are more CPU-expensive than brutes
# (spell AI, fireball particles, strafe logic).
func _pick_scene_for_type(spawn_type: int) -> PackedScene:
	var no_brutes : bool = GlobalRunData.debug_no_brutes
	var no_mages  : bool = GlobalRunData.debug_no_mages

	# Both types suppressed — nothing spawns.
	if no_brutes and no_mages:
		return null

	match spawn_type:
		1:
			# Type-1: always brute — fall back to mage if brutes suppressed
			if no_brutes:
				return _mage_scene
			return _brute_scene if _brute_scene != null else _mage_scene
		2:
			# Type-2: dedicated mage slot, weighted — respect suppression flags
			if no_mages:
				return _brute_scene if _brute_scene != null else null
			if no_brutes:
				return _mage_scene if _mage_scene != null else null
			if _mage_scene != null and _brute_scene != null:
				return _mage_scene if randf() < mage_spawn_chance else _brute_scene
			return _mage_scene if _mage_scene != null else _brute_scene
		3:
			# Type-3: buffed random — respect suppression flags
			if no_mages:
				return _brute_scene if _brute_scene != null else null
			if no_brutes:
				return _mage_scene if _mage_scene != null else null
			if _mage_scene != null and _brute_scene != null:
				return _mage_scene if randf() < mage_spawn_chance else _brute_scene
			return _brute_scene if _brute_scene != null else _mage_scene
		_:
			if no_brutes:
				return _mage_scene if _mage_scene != null else null
			return _brute_scene if _brute_scene != null else _mage_scene


# ══════════════════════════════════════════════════════════════════════════════
#  POOL RETURN
# ══════════════════════════════════════════════════════════════════════════════

# Called by brute_ai/_mage_ai._on_die() via the _pool_return Callable instead of
# queue_free(). Hides the enemy and pushes it into the appropriate recycle pool
# so the next top-up tick can reactivate it without a fresh instantiate().
# Pool size is capped at population_cap to prevent unbounded memory growth.
func _on_enemy_returned_to_pool(enemy: Node3D, is_brute: bool) -> void:
	if not is_instance_valid(enemy):
		return

	# An enemy retired alive (stuck for 12 s, see brute_ai._retire_stuck) is still in the live list: take it out now
	# so the pool and the live list never both hold it (a corpse was already dropped by the 1 s sweep).
	var live_idx : int = _active_enemies.find(enemy)
	if live_idx >= 0:
		_active_enemies.remove_at(live_idx)
		_live_count = maxi(_live_count - 1, 0)

	_park(enemy)

	var pool : Array = _brute_pool if is_brute else _mage_pool
	if pool.size() < _current_pop_cap:
		pool.append(enemy)
	else:
		# Pool full — just free. Keeps memory bounded on very long runs.
		enemy.queue_free()


# Parks an enemy: hidden, no processing, its animation stopped (an AnimationPlayer keeps evaluating a ~100-650 bone
# skeleton every frame whatever is visible), and out of the "enemy" / "enemies" groups so the many loops over them
# (area attacks, kill flashes, room locks, the touch tutorial) never see it. reset_for_pool() puts it back.
func _park(enemy: Node3D) -> void:
	enemy.visible = false
	enemy.set_physics_process(false)
	enemy.set_process(false)
	var ap : Variant = enemy.get("anim_player")
	if ap is AnimationPlayer:
		(ap as AnimationPlayer).stop()
		(ap as AnimationPlayer).active = false   # an inactive mixer is skipped by the engine's per-frame animation pass
	enemy.remove_from_group("enemy")
	enemy.remove_from_group("enemies")


# Builds one spare enemy and parks it in the pool (see PREWARM_MAX). Dead + collision-less + far below the level
# until reset_for_pool() revives it, so it can neither be hit, counted nor seen while parked.
func _park_new_enemy(scene: PackedScene, is_brute: bool) -> bool:
	if scene == null or _main_root == null:
		return false
	var enemy : Node3D = scene.instantiate() as Node3D
	if enemy == null:
		return false
	enemy.visible = false
	_main_root.add_child(enemy)   # _ready() runs here (the expensive part)
	enemy.set("_is_dead", true)
	enemy.set("collision_layer", 0)
	enemy.global_position = PARK_POSITION
	_park(enemy)
	(_brute_pool if is_brute else _mage_pool).append(enemy)
	_prewarmed += 1
	return true


# Entry stage: parks enough spares to cover the opening wave's shortfall (cap - live) plus PREWARM_SPARE, in the
# type mix the spawner uses (mage_spawn_chance). One build per frame: the loading screen keeps animating.
func _prewarm_pool() -> void:
	var want : int = clampi(_current_pop_cap - _live_count + PREWARM_SPARE, PREWARM_SPARE, PREWARM_MAX)
	var mages : int = int(round(float(want) * mage_spawn_chance)) if _mage_scene != null else 0
	if _brute_scene == null:
		mages = want
	if GlobalRunData.debug_no_mages:
		mages = 0
	if GlobalRunData.debug_no_brutes:
		mages = want
	for i in want:
		var as_mage : bool = i < mages
		_park_new_enemy(_mage_scene if as_mage else _brute_scene, not as_mage)
		await get_tree().process_frame
	stage_near_done = true
	stage_done = true


# ══════════════════════════════════════════════════════════════════════════════
#  PHYSICS PROCESS — timers only, no per-frame allocation
# ══════════════════════════════════════════════════════════════════════════════

func _physics_process(delta: float) -> void:
	if not is_instance_valid(_player):
		return

	# This node is PROCESS_MODE_ALWAYS only so it can build enemies during the loading
	# screen (that work is coroutine-driven, not timer-driven). Gameplay timers must
	# freeze while the game is paused (pause menu, buff pick), otherwise enemies spawn
	# behind the menu and the pressure-spawn timeout runs down while the player is away.
	if get_tree().paused:
		if _paused_since_msec == 0:
			_paused_since_msec = Time.get_ticks_msec()
		return
	if _paused_since_msec != 0:
		var paused_sec : float = (Time.get_ticks_msec() - _paused_since_msec) * 0.001
		_paused_since_msec = 0
		CharacterBase.GLOBAL_PLAYER_LAST_DAMAGE_TIME = minf(
			CharacterBase.GLOBAL_PLAYER_LAST_DAMAGE_TIME + paused_sec,
			Time.get_ticks_msec() * 0.001)

	_cull_timer    += delta
	_respawn_timer += delta
	_diff_timer    += delta
	_pressure_timer += delta

	# Periodically remove dead/invalid enemies from the tracking array
	if _cull_timer >= cull_check_interval:
		_cull_timer = 0.0
		_run_cull_sweep()

	# Periodically top up the live population from nearby spawn points
	if _respawn_timer >= respawn_check_interval:
		_respawn_timer = 0.0
		_top_up_population()

	# Check for day change and escalate difficulty
	if _diff_timer >= DIFF_CHECK_INTERVAL:
		_diff_timer = 0.0
		_check_difficulty_escalation()

	# Pressure spawn: if the player hasn't taken damage in PRESSURE_THRESHOLD seconds,
	# force-spawn a type-3 buffed enemy near them regardless of normal spawn rules.
	if _pressure_timer >= PRESSURE_CHECK_INTERVAL:
		_pressure_timer = 0.0
		_check_pressure_spawn()


# ══════════════════════════════════════════════════════════════════════════════
#  PRESSURE SPAWN
# ══════════════════════════════════════════════════════════════════════════════

# Called every PRESSURE_CHECK_INTERVAL seconds. If the player has gone
# PRESSURE_THRESHOLD seconds without taking damage, the dungeon punishes
# turtling by force-spawning a type-3 buffed enemy from the closest type-3
# spawn point. This runs independently of the normal population cap.
func _check_pressure_spawn() -> void:
	# After Day 30 the dungeon must drain to zero (stop_spawning); a careful player who stays
	# undamaged would otherwise be sent a fresh enemy every 5 s and could never clear the portal.
	if _spawning_locked:
		return
	if _player == null or not is_instance_valid(_player):
		return
	# Only trigger if enough time has passed since the last damage event.
	var now : float = Time.get_ticks_msec() * 0.001
	var time_safe : float = now - CharacterBase.GLOBAL_PLAYER_LAST_DAMAGE_TIME
	if time_safe < PRESSURE_THRESHOLD:
		return

	# Find the nearest type-3 spawn point — these are the designated buffed slots.
	var player_pos  : Vector3 = _player.global_position
	var best_pos    : Vector3 = Vector3.ZERO
	var best_dist_sq : float  = 9999999.0
	var found       : bool    = false

	for entry in _all_spawns:
		if int(entry.get("type", 1)) != 3:
			continue
		var pos      : Vector3 = entry.get("position", Vector3.ZERO)
		var dist_sq  : float   = player_pos.distance_squared_to(pos)
		if dist_sq < best_dist_sq and dist_sq > (min_spawn_distance * min_spawn_distance):
			best_dist_sq = dist_sq
			best_pos     = pos
			found        = true

	if not found:
		return

	# Spawn a single buffed brute or mage — respect debug suppression flags.
	var no_brutes : bool = GlobalRunData.debug_no_brutes
	var no_mages  : bool = GlobalRunData.debug_no_mages
	if no_brutes and no_mages:
		return
	var scene : PackedScene
	if no_mages:
		scene = _brute_scene
	elif no_brutes:
		scene = _mage_scene
	else:
		scene = _mage_scene if _mage_scene != null else _brute_scene
	if scene == null:
		return

	# ── Pool acquire (same pattern as _spawn_enemy_from_data) ────────────────
	var is_brute  : bool   = (scene == _brute_scene)
	var pool      : Array  = _brute_pool if is_brute else _mage_pool
	var from_pool : bool   = not pool.is_empty()
	var enemy     : Node3D

	if from_pool:
		enemy = pool.pop_back() as Node3D
		if not is_instance_valid(enemy):
			from_pool = false
	if not from_pool:
		enemy = scene.instantiate() as Node3D
		_main_root.add_child(enemy)

	if _player_can_see_spawn(best_pos):
		# Visible — abort. Return to pool or free depending on origin.
		if from_pool:
			_on_enemy_returned_to_pool(enemy, is_brute)
		else:
			enemy.queue_free()
		return

	var safe_pos : Vector3 = _snap_to_floor(best_pos)

	if from_pool and enemy.has_method("reset_for_pool"):
		enemy.reset_for_pool(safe_pos, Vector3.ZERO, _waypoints)
	else:
		enemy.global_position = safe_pos
		if enemy.has_method("initialize_waypoints"):
			enemy.initialize_waypoints(_waypoints)

	if enemy.has_method("set_pool_return"):
		enemy.set_pool_return(
			Callable(self, "_on_enemy_returned_to_pool").bind(enemy, is_brute))

	# Apply the maximum buff multiplier to make this a real threat.
	if enemy.has_method("apply_buff"):
		enemy.apply_buff(buff_cap)

	_active_enemies.append(enemy)
	_live_count += 1
	print("Pressure spawn: player safe for %.0fs — buffed enemy deployed." % time_safe)


# ══════════════════════════════════════════════════════════════════════════════
#  CULL SWEEP
# ══════════════════════════════════════════════════════════════════════════════

# Walks the active enemies list and removes any that are dead or freed.
func _run_cull_sweep() -> void:
	for i in range(_active_enemies.size() - 1, -1, -1):
		# Check validity BEFORE casting — casting a freed object throws an error.
		var enemy_ref = _active_enemies[i]
		if not is_instance_valid(enemy_ref):
			_active_enemies.remove_at(i)
			_live_count = maxi(_live_count - 1, 0)
			continue
		var enemy : Node = enemy_ref as Node
		if enemy.get("_is_dead") == true:
			_active_enemies.remove_at(i)
			_live_count = maxi(_live_count - 1, 0)


# Enemies that are alive right now. `_live_count` lags a kill by up to cull_check_interval and is
# not refreshed while paused, so the Day-30 portal asks this instead.
func count_live_enemies() -> int:
	var n : int = 0
	for e in _active_enemies:
		if is_instance_valid(e) and e.get("_is_dead") != true:
			n += 1
	return n


# World positions of every enemy that is alive right now (the last-stand minimap markers).
func live_enemy_positions() -> Array:
	var out : Array = []
	for e in _active_enemies:
		if is_instance_valid(e) and e.get("_is_dead") != true:
			out.append((e as Node3D).global_position)
	return out


# Enemies have no kill plane (the player does): one that fell out of the world stays "alive"
# forever and would keep the Day-30 portal shut. Kill any alive enemy below KILL_PLANE_Y.
# Returns how many were rescued. take_damage(.., null) credits no kill to the player.
func rescue_stranded_enemies() -> int:
	var rescued : int = 0
	for e in _active_enemies:
		if not is_instance_valid(e) or e.get("_is_dead") == true:
			continue
		if (e as Node3D).global_position.y < KILL_PLANE_Y and e.has_method("take_damage"):
			e.take_damage(1.0e6, null)
			rescued += 1
	return rescued


# ══════════════════════════════════════════════════════════════════════════════
#  POPULATION TOP-UP
# ══════════════════════════════════════════════════════════════════════════════

# Called every respawn_check_interval seconds.
# Refreshes the active zone (player may have moved) then triggers a staggered 
# asynchronous spawn loop to safely bring the live count back up to the cap.
func stop_spawning() -> void:
	_spawning_locked = true


# Legendary Mode: the run continues past Day 30, so reinforcements must come back.
func resume_spawning() -> void:
	_spawning_locked = false


func _top_up_population() -> void:
	if _spawning_locked:
		return
	var deficit : int = _current_pop_cap - _live_count
	if deficit <= 0:
		return

	# Refresh the zone so new rooms the player has entered are included
	_refresh_active_zone()

	if _active_zone.is_empty():
		return

	var limit : int = mini(deficit, respawn_batch_size)

	# Pick random entries from the active zone to keep spawning unpredictable
	var zone_copy : Array = _active_zone.duplicate()
	zone_copy.shuffle()

	# SURGICAL FIX: Run the heavy spawning in an async coroutine
	_staggered_spawn_wave(zone_copy, limit)


# Iterates through the selected spawn zones and yields one process frame 
# between each enemy instantiation. This prevents the physics loop from locking 
# up and dropping FPS.
func _staggered_spawn_wave(zone_copy: Array, limit: int) -> void:
	var spawned : int = 0

	for entry in zone_copy:
		if spawned >= limit:
			break
		
		# A top-up wave that was mid-flight when the game paused (or the Day-30 lock engaged)
		# must not keep spawning.
		if get_tree().paused or _spawning_locked:
			break

		# Build the heavy enemy hierarchy
		if _spawn_enemy_from_data(entry):
			spawned += 1
			# Pause this coroutine for one frame so the engine can render smoothly
			await get_tree().process_frame

	if spawned > 0:
		print("Top-up: +", spawned, " enemies. Live: ", _live_count, " / ", _current_pop_cap)


# ══════════════════════════════════════════════════════════════════════════════
#  DIFFICULTY ESCALATION
# ══════════════════════════════════════════════════════════════════════════════

func _check_difficulty_escalation() -> void:
	if not has_node("/root/GameClock"):
		return
	if not ("current_day" in GameClock):
		return

	var current_day : int = int(GameClock.current_day)
	if current_day <= _last_day_checked:
		return

	var days_passed : int = current_day - _last_day_checked
	_last_day_checked = current_day

	# ── Global base mult — recomputed fresh from current_day each tick ────────
	# Linear component + quadratic late-game bonus that kicks in after day 10.
	# Brotato-style: early game forgiving, late game exponentially relentless.
	#   Day 10 → 1.25×  (linear only, +0 quad)
	#   Day 15 → 1.42×  (+0.04 quad)
	#   Day 20 → 1.66×  (+0.16 quad)
	#   Day 25 → 2.11×  (+0.36 quad)
	#   Day 30 → 2.39×  (+0.64 quad)  — speed already scales via _on_buff_applied
	var linear_part : float = 1.0 + float(current_day) * global_stat_mult_per_day
	var quad_bonus  : float = maxf(0.0, pow(float(current_day) - 10.0, 2.0) / 25.0) * 0.04
	_global_base_mult = clampf(linear_part + quad_bonus, 1.0, global_stat_mult_cap)

	# ── Spawn interval compression — enemies arrive faster in late game ───────
	# 1.8 % faster per day; floors at 45 % of base interval (~day 30 = 1.8 s).
	var interval_mult      : float = clampf(1.0 - float(current_day) * 0.018, 0.45, 1.0)
	respawn_check_interval = BASE_RESPAWN_INTERVAL * interval_mult

	for _i in range(days_passed):
		# ── Type-3 specific buff ──────────────────────────────────────────────
		if _current_buff_mult < buff_cap:
			# Phase 1: escalate the buff on type-3 enemies (caps day ~20)
			_current_buff_mult = minf(_current_buff_mult + buff_increment_per_day, buff_cap)
		else:
			# Phase 2: type-3 buff maxed — widen the population cap instead
			_current_pop_cap = mini(_current_pop_cap + pop_cap_increment_per_day, max_population_cap)

		# ── Gradual population growth from day 1 (1 enemy per 3 days) ─────────
		_pop_cap_day_accum += 1
		if _pop_cap_day_accum >= 3:
			_pop_cap_day_accum = 0
			_current_pop_cap   = mini(_current_pop_cap + 1, max_population_cap)

	print("Day %d → global ×%.2f  type-3 ×%.2f  pop %d  interval %.1fs" % [
		current_day, _global_base_mult, _current_buff_mult, _current_pop_cap, respawn_check_interval])

	# ── Cull stale enemies so they respawn with the new day's buff ────────────
	if current_day >= CULL_START_DAY:
		var cull_count : int = int(ceil(float(_live_count) * CULL_FRACTION))
		_cull_stale_enemies(cull_count)


# ══════════════════════════════════════════════════════════════════════════════
#  ROOM-LOCK CULL
# ══════════════════════════════════════════════════════════════════════════════

# Called by RoomLockManager before spawning encounter enemies.
# Kills enemies to make room for the room-lock squad.
# Only culls enemies that are:
#   1. At least 15 m from the player (never interrupt a fight)
#   2. Behind the player — dot(player_forward, to_enemy) <= 0
#      This prevents removing enemies the player is looking at or
#      engaging with in their peripheral view.
func cull_for_room_lock(count: int) -> void:
	if count <= 0 or _player == null or not is_instance_valid(_player):
		return

	var player_pos : Vector3 = _player.global_position

	# Flat forward vector of the player (XZ plane only)
	var player_fwd : Vector3 = -_player.global_transform.basis.z
	player_fwd.y = 0.0
	if player_fwd.length_squared() > 0.01:
		player_fwd = player_fwd.normalized()
	else:
		player_fwd = Vector3.FORWARD

	const MIN_CULL_DIST_SQ : float = 15.0 * 15.0   # Never cull closer than 15 m

	var candidates : Array = []
	for enemy_node in _active_enemies:
		# is_instance_valid MUST come before 'is' — 'is' on a freed object crashes.
		if not is_instance_valid(enemy_node):
			continue
		if not (enemy_node is Node3D):
			continue
		var enemy : Node3D = enemy_node
		if enemy.get("_is_dead") == true: continue

		var dist_sq : float = player_pos.distance_squared_to(enemy.global_position)
		if dist_sq < MIN_CULL_DIST_SQ:
			continue   # Too close — never interrupt nearby combat

		# Directional check: skip enemies in front of or to the sides of the player.
		# Only enemies clearly behind (dot <= 0) are eligible.
		var to_enemy : Vector3 = enemy.global_position - player_pos
		to_enemy.y = 0.0
		if to_enemy.length_squared() > 0.01:
			var dot : float = player_fwd.dot(to_enemy.normalized())
			if dot > 0.0:
				continue   # In front of or beside — leave them alone

		candidates.append({"enemy": enemy, "dist_sq": dist_sq})

	if candidates.is_empty():
		return

	# Furthest-behind first
	candidates.sort_custom(func(a, b): return a.dist_sq > b.dist_sq)

	var actual : int = mini(count, candidates.size())
	for i in actual:
		var enemy : Node3D = candidates[i].enemy as Node3D
		if is_instance_valid(enemy) and enemy.has_method("take_damage"):
			enemy.take_damage(99999.0)

	print("Room lock: cleared ", actual, " behind-player enemies to make room for encounter.")


# ══════════════════════════════════════════════════════════════════════════════
#  DAY CULL
# ══════════════════════════════════════════════════════════════════════════════

# Instant-kills up to cull_count live enemies that are safely far from the
# player.  Each one goes through its normal death → pool-return path and will
# respawn moments later via the regular top-up tick with the current day's
# buff multiplier applied — so the dungeon gradually replaces weak early-game
# enemies with stronger versions without requiring a full wipe or restart.
#
# Enemies within CULL_MIN_DISTANCE are never touched — interrupting a fight
# mid-swing would feel wrong and jarring.
func _cull_stale_enemies(cull_count: int) -> void:
	if cull_count <= 0 or _player == null or not is_instance_valid(_player):
		return

	var player_pos  : Vector3 = _player.global_position
	var min_dist_sq : float   = CULL_MIN_DISTANCE * CULL_MIN_DISTANCE

	# Collect candidates: alive, valid, far enough from the player
	var candidates : Array = []
	for enemy_node in _active_enemies:
		# Validity check must precede the `is Node3D` test — the `is`
		# operator throws on a previously-freed instance.
		if not is_instance_valid(enemy_node):
			continue
		if not (enemy_node is Node3D):
			continue
		var enemy : Node3D = enemy_node
		if enemy.get("_is_dead") == true:
			continue
		if player_pos.distance_squared_to(enemy.global_position) > min_dist_sq:
			candidates.append(enemy)

	if candidates.is_empty():
		return

	candidates.shuffle()
	var actual : int = mini(cull_count, candidates.size())

	for i in actual:
		var enemy : Node3D = candidates[i] as Node3D
		if is_instance_valid(enemy) and enemy.has_method("take_damage"):
			# Massive damage triggers the normal death flow:
			# animation → _on_die → pool return → respawn with fresh buff.
			enemy.take_damage(99999.0)

	print("Day cull: retired ", actual, " stale enemies — will respawn stronger.")
