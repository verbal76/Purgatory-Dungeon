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

@onready var dungeon_generation_function : Node = get_node_or_null("DungeonGenerationFunction")
@onready var kill_counter_label : Label = get_node_or_null("HUD/KillCounterMargin/KillCounterVBox/KillCounterLabel")

var placed_modules : Array[Node3D] = []

# ── Exploration update throttle ────────────────────────────────────────────────
# update_player_exploration() walks the dungeon tree to reveal explored rooms.
# Running it at 60Hz is wasteful — the player can't move fast enough to matter.
# 0.5s gives smooth map reveal with a fraction of the CPU cost.
const EXPLORE_INTERVAL : float = 0.5
var _explore_timer     : float = 0.0


func _ready() -> void:
	_reset_kill_counter()
	add_to_group("dungeon_generator")

	if has_node("/root/AudioManager"):
		AudioManager.play_gameplay_music()
	else:
		push_warning("AudioManager not found. Gameplay music will not start.")

	_apply_run_seed()

	# THE FIX: Directly capture the newly spawned player so we never grab a ghost
	var active_player = _spawn_selected_character()

	if dungeon_generation_function == null:
		push_error("DungeonGenerationFunction node not found in main scene.")
		return

	_push_generation_settings_into_child()

	# Yield two frames so the loading screen (created by the player's _ready)
	# has time to composite and appear on screen before generation blocks the thread.
	await get_tree().process_frame
	await get_tree().process_frame

	var generation_result : Dictionary = dungeon_generation_function.generate_dungeon()
	if not bool(generation_result.get("success", false)):
		push_error("Dungeon generation failed.")
		return

	var starter : Node3D = generation_result.get("starter")
	placed_modules = dungeon_generation_function.placed_modules

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

			# 4. Turn physics back on
			active_player.set_physics_process(true)

	# T1.3: spawn props + chests FIRST (both stagger over frames via await),
	# so by the time the enemy manager boots and its first spawn wave fires,
	# props have already started materialising. Staggered prop-batch cost
	# overlaps the enemy-manager-boot cost instead of stacking sequentially.
	_boot_prop_spawner()
	_boot_chest_manager()
	# Build and activate the Proximity Spawner natively (Health Orb Style)
	_boot_enemy_manager(active_player)
	_boot_room_lock_manager(active_player)

	dungeon_generation_function.update_player_exploration()

	var lm := get_node_or_null("LightingManager")
	if lm and lm.has_method("setup_environment"):
		lm.setup_environment()
	_boot_torch_dimming_manager()
	GameClock.start_run()
	GameClock.run_ended.connect(_on_run_ended)
	_boot_health_orb_manager()
	GlobeManager.spawn_globes(dungeon_generation_function)
	_boot_trap_manager()
	# SURGICAL ADD: Show the wallet overlay only in the dungeon.
	# It is hidden by default and hidden again when returning to menus.
	PlayerWallet.show_hud()

	_update_kill_counter_label()


# ══════════════════════════════════════════════════════════════
#  CHARACTER SPAWNING
# ══════════════════════════════════════════════════════════════

# THE FIX: Now returns the specific Node3D it just created
func _spawn_selected_character() -> Node3D:
	var existing_player := get_node_or_null("Player")
	if existing_player != null:
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
		manager.boot_up(player_node, typed_spawns, waypoints,
						brute_enemy_scene, mage_enemy_scene,
						dungeon_generation_function)


# ══════════════════════════════════════════════════════════════
#  HEALTH ORB MANAGER
# ══════════════════════════════════════════════════════════════

func _boot_trap_manager() -> void:
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
				jumpscare_texture, jumpscare_sound)


func _boot_health_orb_manager() -> void:
	var orb_script := load("res://scripts/health_orb_manager.gd")
	if orb_script == null:
		push_warning("HealthOrbManager: script not found at res://scripts/health_orb_manager.gd")
		return

	var orb_manager := Node3D.new()
	orb_manager.name = "HealthOrbManager"
	orb_manager.set_script(orb_script)
	add_child(orb_manager)


func _boot_prop_spawner() -> void:
	var prop_script := load("res://scripts/prop_spawner.gd")
	if prop_script == null:
		push_warning("PropSpawner: script not found at res://scripts/prop_spawner.gd")
		return
	var spawner := Node3D.new()
	spawner.name = "PropSpawner"
	spawner.set_script(prop_script)
	add_child(spawner)


func _boot_chest_manager() -> void:
	var chest_script := load("res://scripts/chest_manager.gd")
	if chest_script == null:
		push_warning("ChestManager: script not found at res://scripts/chest_manager.gd")
		return
	var mgr := Node3D.new()
	mgr.name = "ChestManager"
	mgr.set_script(chest_script)
	add_child(mgr)


func _boot_room_lock_manager(player_node: Node3D) -> void:
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
		mgr.boot(player_node, dungeon_generation_function, enemy_mgr)



# ══════════════════════════════════════════════════════════════
#  KILL COUNTER
# ══════════════════════════════════════════════════════════════

func register_enemy_kill() -> void:
	_update_kill_counter_label()


func _reset_kill_counter() -> void:
	CharacterBase.GLOBAL_KILL_COUNT = 0


func _update_kill_counter_label() -> void:
	if kill_counter_label != null:
		kill_counter_label.text = "Kills: %d" % CharacterBase.GLOBAL_KILL_COUNT


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
