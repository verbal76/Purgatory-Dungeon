# ==============================================================================
# FILE: portal_manager.gd
# PATH: res://scripts/portal_manager.gd
# DESCRIPTION: Spawned at Day 30 when GameClock.run_ended fires.
#   - Picks a module in the far 20% of placed_modules as the portal site
#   - Creates a swirling-light portal visual (glowing sphere + pulsing OmniLight3D)
#   - Spawns 25 elite enemies (400% stats) around the portal — no reinforcements
#   - Portal is visible on the minimap as a blinking gold diamond
#   - Player must kill ALL remaining enemies (portal guards + any still active)
#     before the entry Area3D fires and the end-choice screen appears
# ==============================================================================

extends Node3D

# ── Settings ──────────────────────────────────────────────────────────────────
const PORTAL_ENEMY_COUNT   : int   = 25
const PORTAL_BUFF_MULT     : float = 4.0     # 400% base stats
const PORTAL_LIGHT_RANGE   : float = 18.0
const PORTAL_LIGHT_ENERGY  : float = 6.0
const PORTAL_SPHERE_RADIUS : float = 1.2
const ENTRY_RADIUS         : float = 2.5     # metres — how close to trigger entry
const ANNOUNCE_FONT_SIZE   : int   = 28

# ── Runtime references ────────────────────────────────────────────────────────
var _dungeon_gen    : Node    = null
var _player         : Node3D = null
var _brute_scene    : PackedScene = null
var _mage_scene     : PackedScene = null
var _minimap        : Node   = null
var _enemy_mgr      : Node   = null

# ── Portal node refs ──────────────────────────────────────────────────────────
var _portal_root    : Node3D      = null
var _portal_light   : OmniLight3D = null
var _portal_mesh    : MeshInstance3D = null
var _entry_area     : Area3D      = null

# ── Elite enemy tracking ──────────────────────────────────────────────────────
var _portal_enemies : Array  = []
var _entry_shown    : bool   = false

# ── Portal animation ──────────────────────────────────────────────────────────
var _anim_t         : float  = 0.0

# ── HUD announce ──────────────────────────────────────────────────────────────
var _announce_layer : CanvasLayer = null


# ── Boot ──────────────────────────────────────────────────────────────────────

func boot(dungeon_gen: Node, player: Node3D,
		brute_scene: PackedScene, mage_scene: PackedScene,
		minimap: Node, enemy_mgr: Node) -> void:

	_dungeon_gen = dungeon_gen
	_player      = player
	_brute_scene = brute_scene
	_mage_scene  = mage_scene
	_minimap     = minimap
	_enemy_mgr   = enemy_mgr

	var portal_pos : Vector3 = _pick_portal_position()
	_spawn_portal(portal_pos)
	_spawn_elite_enemies(portal_pos)
	_show_announce(portal_pos)

	if _minimap != null and _minimap.has_method("set_portal_position"):
		_minimap.set_portal_position(portal_pos)


# ── Position selection ────────────────────────────────────────────────────────

func _pick_portal_position() -> Vector3:
	if _dungeon_gen == null or not ("placed_modules" in _dungeon_gen):
		return Vector3(50.0, 0.0, 50.0)

	var modules : Array = _dungeon_gen.placed_modules
	if modules.is_empty():
		return Vector3(50.0, 0.0, 50.0)

	# Far from the start, in a real room, at a point that is actually walkable.
	# (This used to take the origin of one of the last 20 *placed* modules: connectors,
	# end caps and door plugs included, and an origin is often outside the module's
	# footprint or inside a wall, so the Day-30 portal could be unreachable.)
	var start : Node3D = modules[0]
	var rooms : Array = []
	for m in modules:
		if is_instance_valid(m) and m is Node3D and m.has_meta("counts_toward_goal") \
				and bool(m.get_meta("counts_toward_goal")):
			rooms.append(m)
	if rooms.is_empty():
		rooms = [modules[modules.size() - 1]]
	var from : Vector3 = start.global_position
	rooms.sort_custom(func(a, b):
		return a.global_position.distance_squared_to(from) > b.global_position.distance_squared_to(from))
	var far_count : int = maxi(3, int(rooms.size() * 0.20))
	var candidates : Array = rooms.slice(0, mini(far_count, rooms.size()))
	candidates.shuffle()
	if not _dungeon_gen.has_method("get_random_safe_interior_point"):
		return candidates[0].global_position + Vector3(0.0, 1.5, 0.0)
	# get_random_safe_interior_point() returns Vector3.ZERO when a room has no clear point
	# (e.g. obstructed interior). Never place the portal at the world origin: try the far
	# rooms first, then any room (farthest first); tighter margin on the second pass.
	var ordered : Array = candidates.duplicate()
	for r in rooms:
		if not ordered.has(r):
			ordered.append(r)
	for margin in [2.0, 1.0]:
		for room in ordered:
			var p : Vector3 = _dungeon_gen.get_random_safe_interior_point(room, 1.5, margin)
			if p != Vector3.ZERO:
				return p
	push_warning("PortalManager: no clear portal position found; using a room origin.")
	return candidates[0].global_position + Vector3(0.0, 1.5, 0.0)


# ── Portal visual ─────────────────────────────────────────────────────────────

func _spawn_portal(pos: Vector3) -> void:
	_portal_root          = Node3D.new()
	_portal_root.name     = "EndPortal"
	get_parent().add_child(_portal_root)
	_portal_root.global_position = pos

	# ── Swirling light ────────────────────────────────────────
	_portal_light               = OmniLight3D.new()
	_portal_light.light_color   = Color(0.55, 0.25, 1.0)   # Deep violet
	_portal_light.light_energy  = PORTAL_LIGHT_ENERGY
	_portal_light.omni_range    = PORTAL_LIGHT_RANGE
	_portal_light.shadow_enabled = false
	_portal_root.add_child(_portal_light)

	# ── Core sphere ───────────────────────────────────────────
	var sphere_mesh      := SphereMesh.new()
	sphere_mesh.radius    = PORTAL_SPHERE_RADIUS
	sphere_mesh.height    = PORTAL_SPHERE_RADIUS * 2.0

	var mat              := StandardMaterial3D.new()
	mat.albedo_color      = Color(0.6, 0.2, 1.0, 0.85)
	mat.emission_enabled  = true
	mat.emission          = Color(0.55, 0.15, 1.0)
	mat.emission_energy_multiplier = 5.0
	mat.shading_mode      = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency      = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode         = BaseMaterial3D.CULL_DISABLED

	_portal_mesh          = MeshInstance3D.new()
	_portal_mesh.mesh     = sphere_mesh
	_portal_mesh.material_override = mat
	_portal_root.add_child(_portal_mesh)

	# ── Outer glow ring (slightly larger, dimmer) ─────────────
	var ring_mesh          := SphereMesh.new()
	ring_mesh.radius        = PORTAL_SPHERE_RADIUS * 1.6
	ring_mesh.height        = PORTAL_SPHERE_RADIUS * 0.5

	var ring_mat           := StandardMaterial3D.new()
	ring_mat.albedo_color   = Color(0.8, 0.5, 1.0, 0.25)
	ring_mat.emission_enabled = true
	ring_mat.emission       = Color(0.7, 0.4, 1.0)
	ring_mat.emission_energy_multiplier = 2.0
	ring_mat.shading_mode   = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.transparency   = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.cull_mode      = BaseMaterial3D.CULL_DISABLED

	var ring_inst          := MeshInstance3D.new()
	ring_inst.name          = "PortalRing"
	ring_inst.mesh          = ring_mesh
	ring_inst.material_override = ring_mat
	_portal_root.add_child(ring_inst)

	# ── Entry trigger ─────────────────────────────────────────
	_entry_area                 = Area3D.new()
	_entry_area.collision_layer = 0
	_entry_area.collision_mask  = 0xFFFFFFFF
	var shape_node              := CollisionShape3D.new()
	var sphere_col              := SphereShape3D.new()
	sphere_col.radius            = ENTRY_RADIUS
	shape_node.shape             = sphere_col
	_entry_area.add_child(shape_node)
	_portal_root.add_child(_entry_area)
	_entry_area.body_entered.connect(_on_entry_area_body_entered)


# ── Elite enemy spawning ──────────────────────────────────────────────────────

func _spawn_elite_enemies(portal_pos: Vector3) -> void:
	if _brute_scene == null and _mage_scene == null:
		push_warning("PortalManager: no enemy scenes assigned — portal guards skipped.")
		return

	# Use nearby waypoints/coursec positions if available, else scatter in a ring.
	var origins : Array[Vector3] = _get_spawn_origins(portal_pos, PORTAL_ENEMY_COUNT)

	for i in range(PORTAL_ENEMY_COUNT):
		var scene : PackedScene = _brute_scene
		# ~20% mages to match normal spawn weighting
		if _mage_scene != null and randi() % 5 == 0:
			scene = _mage_scene
		if scene == null:
			continue

		var enemy : Node3D = scene.instantiate() as Node3D
		if enemy == null:
			continue

		get_parent().add_child(enemy)
		enemy.global_position = origins[i % origins.size()] + Vector3(
			randf_range(-2.0, 2.0), 0.0, randf_range(-2.0, 2.0))

		# Wait one frame so _ready() has run, then apply the buff.
		await get_tree().process_frame
		if is_instance_valid(enemy) and enemy.has_method("apply_buff"):
			enemy.apply_buff(PORTAL_BUFF_MULT)

		_portal_enemies.append(enemy)


func _get_spawn_origins(center: Vector3, count: int) -> Array[Vector3]:
	var origins : Array[Vector3] = []

	# Try to use coursec waypoints near the portal for realistic positioning.
	if _dungeon_gen != null and _dungeon_gen.has_method("get_module_containing_point"):
		var mod : Node3D = _dungeon_gen.get_module_containing_point(center)
		if mod != null and _dungeon_gen.has_method("get_coursec_positions_in_module"):
			var wps : Array[Vector3] = _dungeon_gen.get_coursec_positions_in_module(mod)
			for wp in wps:
				origins.append(wp)

	# Fill remainder (or all) with a ring around the portal.
	var ring_radius : float = 8.0
	while origins.size() < count:
		var angle : float = (float(origins.size()) / float(count)) * TAU
		origins.append(center + Vector3(cos(angle) * ring_radius, 0.0, sin(angle) * ring_radius))

	return origins


# ── Portal animation ──────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if _portal_root == null:
		return

	_anim_t += delta
	_entry_check_timer += delta
	if _entry_check_timer >= 0.5:
		_entry_check_timer = 0.0
		_recheck_entry()

	# Pulse the light energy between 60% and 140% of base.
	if _portal_light != null:
		_portal_light.light_energy = PORTAL_LIGHT_ENERGY * (1.0 + 0.4 * sin(_anim_t * 2.0))

	# Slowly rotate and bob the core sphere.
	if _portal_mesh != null:
		_portal_mesh.rotation.y = _anim_t * 0.8
		_portal_mesh.position.y = sin(_anim_t * 1.5) * 0.25

	# Rotate the outer ring in the opposite direction.
	var ring := _portal_root.get_node_or_null("PortalRing")
	if ring != null:
		ring.rotation.y = -_anim_t * 1.2
		ring.rotation.x =  _anim_t * 0.5


# ── Entry detection ───────────────────────────────────────────────────────────

func _enemies_remaining() -> int:
	# Living portal guards.
	var guards_alive : int = 0
	for e in _portal_enemies:
		if is_instance_valid(e) and e.get("_is_dead") != true:
			guards_alive += 1

	# Enemies still managed by EnemyManager.
	var mgr_live : int = 0
	if _enemy_mgr != null and "_live_count" in _enemy_mgr:
		mgr_live = int(_enemy_mgr._live_count)
	return guards_alive + mgr_live


func _on_entry_area_body_entered(body: Node3D) -> void:
	if _entry_shown or _disabled:
		return
	if not body.is_in_group("player"):
		return

	var remaining : int = _enemies_remaining()
	if remaining > 0:
		_show_not_ready_hint(remaining)
		return

	_entry_shown = true
	_show_end_screen()


# body_entered only fires on entering the radius. If the last enemy dies while the player is
# already standing in the portal, nothing would happen until they stepped out and back in.
# Re-check periodically (cheap: a distance test, no hint spam).
var _entry_check_timer : float = 0.0
var _disabled          : bool  = false

func _recheck_entry() -> void:
	if _entry_shown or _disabled or _portal_root == null:
		return
	if _player == null or not is_instance_valid(_player) or get_tree().paused:
		return
	if _player.global_position.distance_to(_portal_root.global_position) > ENTRY_RADIUS:
		return
	if _enemies_remaining() > 0:
		return
	_entry_shown = true
	_show_end_screen()


func _show_not_ready_hint(remaining: int) -> void:
	# Flash a temporary warning on screen — all enemies must die first.
	var layer     := CanvasLayer.new()
	layer.layer    = 15
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child(layer)

	var lbl       := Label.new()
	lbl.text       = "%d enemies remain — clear them all to enter the portal!" % remaining
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2, 1.0))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.set_anchors_preset(Control.PRESET_CENTER)
	lbl.offset_top    = -80.0
	lbl.offset_bottom =  80.0
	lbl.offset_left   = -400.0
	lbl.offset_right  =  400.0
	layer.add_child(lbl)

	get_tree().create_timer(3.0).timeout.connect(layer.queue_free)


# ── End screen ────────────────────────────────────────────────────────────────

func _show_end_screen() -> void:
	# Disable the entry area so it can't fire twice.
	if _entry_area != null:
		_entry_area.set_deferred("monitoring", false)

	var screen_script := load("res://scripts/run_end_screen.gd")
	if screen_script == null:
		push_warning("PortalManager: run_end_screen.gd not found.")
		return

	var screen := CanvasLayer.new()
	screen.set_script(screen_script)
	get_tree().root.add_child(screen)
	if screen.has_method("setup"):
		screen.setup(self)


# ── Announce HUD ──────────────────────────────────────────────────────────────

func _show_announce(portal_pos: Vector3) -> void:
	_announce_layer        = CanvasLayer.new()
	_announce_layer.layer  = 12
	_announce_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child(_announce_layer)

	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.65)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_announce_layer.add_child(bg)

	var lbl := Label.new()
	lbl.text = "DAY 30 — AN EXIT HAS APPEARED IN THE DEPTHS\nFind it on your minimap."
	lbl.add_theme_font_size_override("font_size", ANNOUNCE_FONT_SIZE)
	lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2, 1.0))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode        = TextServer.AUTOWRAP_WORD_SMART
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
	lbl.offset_left   = -300.0
	lbl.offset_right  =  300.0
	lbl.offset_top    = -80.0
	lbl.offset_bottom =  80.0
	_announce_layer.add_child(lbl)

	# Fade out after 6 seconds.
	get_tree().create_timer(6.0).timeout.connect(_announce_layer.queue_free)


# ── Public: called by RunEndScreen if player enters legendary mode ─────────────

func disable_portal() -> void:
	_disabled = true
	if _entry_area != null:
		_entry_area.set_deferred("monitoring", false)
	if _minimap != null and _minimap.has_method("clear_portal_marker"):
		_minimap.clear_portal_marker()
