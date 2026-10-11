extends Node
## Game-feel layer (scripts/juice.gd, camera_fx.gd, vfx_pool.gd, hud_toast.gd, AudioManager's pools): presentation only, so the checks
## are about the CONTRACT: pooled (no node growth), priority/gap rules, reduced motion (Screen Shake 0), hit-stop restores the animation
## speed, the camera smoothing never wanders or teleports, and that the real player / enemies / UI actually call it.
## JUICE_CLASS=barbarian (default) | mage.

const Juice := preload("res://scripts/juice.gd")
const CameraFx := preload("res://scripts/camera_fx.gd")

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _count_nodes(root: Node) -> int:
	var n := 1
	for c in root.get_children():
		n += _count_nodes(c)
	return n


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	await _audio_tests()
	await _camera_fx_tests()
	await _pool_tests()
	await _game_tests()
	print("test_juice: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


# ── AudioManager: pooled voices, priorities, gaps, footsteps ─────────────────────────────────────────────────────────
func _audio_tests() -> void:
	var am: Node = AudioManager
	for nm in AudioManager.JUICE_NAMES:
		_check(am.sfx(nm) != null, "game-feel sound '%s' is imported and loaded" % nm)
	for nm in AudioManager.JUICE_LOOPS:
		var w := am.sfx(nm) as AudioStreamWAV
		_check(w != null and w.loop_mode == AudioStreamWAV.LOOP_FORWARD, "'%s' loops" % nm)

	# 3D one-shots come from a fixed pool: no node is created per call (it used to build an AudioStreamPlayer3D per hit).
	var before: int = am.get_child_count()
	var thud: AudioStream = am.sfx("impact_thud")
	for i in 80:
		am.play_3d_one_shot(thud, Vector3(i, 0, 0), 0.0, 1.0 + 0.01 * float(i), 25.0, 1)
		am.play_one_shot(thud, 0.0, 1.0 + 0.01 * float(i), 1, 0)
		await get_tree().process_frame
	_check(am.get_child_count() == before, "80 positional + 80 flat one-shots create no node (%d -> %d)" % [before, am.get_child_count()])

	# The same clip inside its minimum gap is dropped (a kill burst must not stack one clip into mush).
	await get_tree().create_timer(0.3).timeout
	for p in am._sfx_pool:
		p.stop()
	var tick: AudioStream = am.sfx("tick")
	am.play_one_shot(tick, 0.0, 1.0, 1, 200)
	am.play_one_shot(tick, 0.0, 1.0, 1, 200)
	var n_tick := 0
	for p in am._sfx_pool:
		if p.playing and p.stream == tick:
			n_tick += 1
	_check(n_tick == 1, "the same clip inside its gap plays once (%d voices)" % n_tick)

	# A full pool of important sounds is not stolen by an ambient one; an important one does take a slot.
	await get_tree().create_timer(0.3).timeout
	for p in am._sfx_pool:
		p.stop()
	var important: Array = ["footstep_1", "footstep_2", "footstep_3", "footstep_4", "coin", "key_jingle", "heal_chime", "pop_soft"]
	for nm in important:
		am.play_one_shot(am.sfx(nm), 0.0, 1.0, 2, 0)
	var busy := 0
	for p in am._sfx_pool:
		if p.playing:
			busy += 1
	_check(busy == am.SFX_POOL_SIZE, "eight priority-2 sounds fill the %d voices (%d busy)" % [am.SFX_POOL_SIZE, busy])
	var amb: AudioStream = am.sfx("drip")
	am.play_one_shot(amb, 0.0, 1.0, 0, 0)
	var stolen := false
	for p in am._sfx_pool:
		if p.playing and p.stream == amb:
			stolen = true
	_check(not stolen, "an ambient (priority 0) sound does not steal a voice from important ones")
	var hit: AudioStream = am.sfx("explosion")
	am.play_one_shot(hit, 0.0, 1.0, 2, 0)
	var took := false
	for p in am._sfx_pool:
		if p.playing and p.stream == hit:
			took = true
	_check(took, "an equally important sound does take the oldest voice")
	for p in am._sfx_pool:
		p.stop()

	# Footsteps: four variants, never the same twice in a row.
	_check(am._footsteps.size() == 4, "four footstep variants")
	await get_tree().create_timer(0.15).timeout   # (clear of the per-clip gap left by the voices filled above)
	am.play_footstep(-6.0)
	var stepping := false
	for p in am._sfx_pool:
		if p.playing and p.stream in am._footsteps:
			stepping = true
	_check(stepping, "play_footstep sounds a step")

	# Filters / low health.
	am.set_low_health(true)
	_check(am._target_music_cutoff() < am.FILTER_OPEN_HZ, "low health dulls the music")
	am.set_low_health(false)
	am.set_pause_muffle(true)
	_check(am._target_music_cutoff() < am.FILTER_OPEN_HZ, "the pause muffles the music")
	am.set_pause_muffle(false)
	_check(is_equal_approx(am._target_music_cutoff(), am.FILTER_OPEN_HZ), "and both release")


# ── CameraFx on a stand-in player ────────────────────────────────────────────────────────────────────────────────────────
func _camera_fx_tests() -> void:
	var body := CharacterBody3D.new()
	add_child(body)
	var arm := Node3D.new()
	body.add_child(arm)
	var cam := Camera3D.new()
	cam.fov = 75.0
	arm.add_child(cam)
	var ap := AnimationPlayer.new()
	body.add_child(ap)
	var fx = CameraFx.new()
	body.add_child(fx)
	fx.setup(body, cam, arm, ap)
	await get_tree().process_frame

	var saved: Variant = SettingsManager.gameplay_settings.get("ShakeSlider", 50.0)
	SettingsManager.gameplay_settings["ShakeSlider"] = 50.0
	fx.trauma = 0.0
	fx.add_trauma(0.5)
	_check(is_equal_approx(fx.trauma, 0.5), "trauma accumulates at the default setting")
	fx.add_trauma(2.0)
	_check(fx.trauma <= 1.0, "trauma is capped at 1")

	# Reduced motion: Screen Shake 0 switches every motion effect off.
	SettingsManager.gameplay_settings["ShakeSlider"] = 0.0
	fx.trauma = 0.0
	fx.add_trauma(0.9)
	fx.punch_fov(6.0)
	fx.dip(0.2)
	fx.kick_pitch(3.0)
	ap.speed_scale = 1.0
	fx.hit_stop(0.1)
	_check(fx.trauma == 0.0 and fx._fov_off == 0.0 and fx._dip == 0.0 and fx._pitch_kick == 0.0, "Screen Shake 0: no trauma, FOV punch, dip or kick")
	_check(is_equal_approx(ap.speed_scale, 1.0), "Screen Shake 0: no hit-stop")
	SettingsManager.gameplay_settings["ShakeSlider"] = 50.0

	# Hit-stop freezes the animation speed (not Engine.time_scale) and restores it.
	ap.speed_scale = 2.5
	var ts: float = Engine.time_scale
	fx.hit_stop(0.12)
	_check(ap.speed_scale < 0.1, "hit-stop freezes the animation (%.2f)" % ap.speed_scale)
	_check(is_equal_approx(Engine.time_scale, ts), "hit-stop never touches Engine.time_scale")
	await get_tree().create_timer(0.35).timeout
	_check(is_equal_approx(ap.speed_scale, 2.5), "and the animation speed comes back exactly (%.2f)" % ap.speed_scale)
	# ... but not over a speed somebody else set meanwhile.
	fx.hit_stop(0.12)
	ap.speed_scale = 1.7
	await get_tree().create_timer(0.35).timeout
	_check(is_equal_approx(ap.speed_scale, 1.7), "hit-stop does not overwrite a speed set during the freeze (%.2f)" % ap.speed_scale)

	# FOV punch is capped.
	fx._fov_off = 0.0
	fx.punch_fov(40.0)
	await get_tree().process_frame
	_check(cam.fov <= 75.0 + CameraFx.FOV_MAX_PUNCH + 0.01, "FOV punch is capped (%.2f)" % cam.fov)
	await get_tree().create_timer(0.7).timeout
	_check(absf(cam.fov - 75.0) < 0.6, "and relaxes back to the base FOV (%.2f)" % cam.fov)

	# Damage vignette scales with the hit.
	fx._flash_alpha = 0.0
	fx.on_damage(1.0, 100.0)
	var small: float = fx._flash_alpha
	fx._flash_alpha = 0.0
	fx.on_damage(40.0, 100.0)
	var big: float = fx._flash_alpha
	_check(big > small and small > 0.0, "a big hit tints the screen harder than a graze (%.2f vs %.2f)" % [big, small])
	fx._flash_alpha = 0.0
	fx.on_damage(0.05, 100.0, true)
	_check(fx._flash_color.g > fx._flash_color.r, "acid / poison ticks tint green, not red")
	fx._flash_alpha = 0.0
	fx.trauma = 0.0
	fx.on_damage(0.05, 100.0, true)
	_check(fx.trauma == 0.0, "a damage-over-time tick adds no shake")

	# Low-health state follows health_changed.
	fx.on_health_changed(20.0, 100.0)
	_check(fx._low_health and AudioManager._low_health, "20% health: low-health pulse + heartbeat on")
	fx.on_health_changed(80.0, 100.0)
	_check(not fx._low_health and not AudioManager._low_health, "80% health: both off")
	fx.on_health_changed(0.0, 100.0)
	_check(not fx._low_health, "dead is not low-health")

	# Render-rate smoothing: offsets the arm against the last physics step, never beyond it, and not at all across a teleport.
	arm.position = Vector3.ZERO
	body.global_position = Vector3.ZERO
	fx._have_prev = false
	fx._physics_process(0.03)
	body.global_position = Vector3(1.0, 0.0, 0.0)
	fx._physics_process(0.03)
	fx._smooth_camera()
	_check(arm.position.x <= 0.0001 and arm.position.x >= -1.0001, "smoothing pulls the camera back along the last step, at most the full step (%.3f)" % arm.position.x)
	body.global_position = Vector3(100.0, 0.0, 0.0)
	fx._physics_process(0.03)
	fx._smooth_camera()
	_check(absf(arm.position.x) < 0.001, "a teleport is not smoothed (%.3f)" % arm.position.x)

	# Landing dip decays back to rest.
	fx.dip(0.15)
	_check(fx._dip > 0.1, "the dip starts")
	await get_tree().create_timer(1.0).timeout
	_check(absf(fx._dip) < 0.01, "and springs back (%.4f)" % fx._dip)

	# Death camera.
	fx.on_death()
	await get_tree().create_timer(1.6).timeout
	_check(absf(rad_to_deg(cam.rotation.z) - CameraFx.DEATH_ROLL_DEG) < 3.0, "the death camera rolls onto its side (%.1f deg)" % rad_to_deg(cam.rotation.z))
	_check(arm.position.y < -0.3, "and sinks (%.2f m)" % arm.position.y)
	SettingsManager.gameplay_settings["ShakeSlider"] = saved
	body.queue_free()


# ── Effect pool, banner layer ─────────────────────────────────────────────────────────────────────────────────────────────
func _pool_tests() -> void:
	var holder := Node3D.new()
	add_child(holder)
	var pool: Node = Juice.ensure_pool(holder)
	await get_tree().process_frame
	_check(pool != null and Juice.pool() == pool, "the effect pool is built once and found by group")
	_check(Juice.ensure_pool(holder) == pool, "ensure_pool is idempotent")
	var presets: Dictionary = pool.PRESETS
	for nm in presets:
		_check(pool._bursts.has(nm) and (pool._bursts[nm] as Array).size() == pool.PER_PRESET, "preset '%s' is pre-built" % nm)
	var nodes_before: int = _count_nodes(holder)
	for i in 120:
		Juice.burst(presets.keys()[i % presets.size()], Vector3(i % 7, 1, i % 5), Vector3.UP, 1.0)
		Juice.number(Vector3(i % 3, 2, 0), str(i), Color.WHITE, 1.0)
		Juice.flash(Vector3(0, 2, 0), Color(1, 0.5, 0.2), 3.0, 0.2, 4.0)
		if i % 10 == 0:
			await get_tree().process_frame
	_check(_count_nodes(holder) == nodes_before, "120 bursts + numbers + flashes create no node (%d -> %d)" % [nodes_before, _count_nodes(holder)])
	var lit := 0
	for l in pool._lights:
		if l.visible:
			lit += 1
	_check(lit <= pool.LIGHTS, "at most %d flash lights are on at once (%d)" % [pool.LIGHTS, lit])
	await get_tree().create_timer(1.2).timeout
	lit = 0
	for l in pool._lights:
		if l.visible:
			lit += 1
	var shown := 0
	for lb in pool._labels:
		if lb.visible:
			shown += 1
	_check(lit == 0 and shown == 0, "flashes and numbers expire (%d lights, %d labels)" % [lit, shown])
	_check(not pool.is_processing(), "an idle pool does not run a per-frame process")

	# Banner / counter layer.
	var toast: Node = holder.get_node_or_null("HudToast")
	_check(toast != null, "the banner layer is built with the pool")
	Juice.banner("DAY 4", 0.3)
	await get_tree().process_frame
	_check(toast._banner.visible and toast._banner.text == "DAY 4", "a banner shows its text")
	Juice.counter("Sealed: 3 left")
	_check(toast._counter.visible and toast._counter.text == "Sealed: 3 left", "the counter line shows")
	Juice.counter("")
	_check(not toast._counter.visible, "and clears")
	await get_tree().create_timer(1.3).timeout
	_check(not toast._banner.visible, "the banner fades out by itself")
	holder.queue_free()
	await get_tree().process_frame


# ── The real game: the player, enemies and UI really use it ─────────────────────────────────────────────────────────────────
func _game_tests() -> void:
	var cls := OS.get_environment("JUICE_CLASS")
	if cls == "":
		cls = "barbarian"
	GlobalRunData.character_class = cls
	var main: Node = (load("res://scenes/Purgatory_Dungeon_main_game_file.tscn") as PackedScene).instantiate()
	add_child(main)
	await _frames(120)
	var player: Node = get_tree().get_first_node_in_group("player")
	var waited := 0
	while (get_tree().paused or not player.is_on_floor()) and waited < 3000:
		await get_tree().physics_frame
		waited += 1
	await _frames(10)
	var pool: Node = Juice.pool()
	_check(pool != null, "the run builds the effect pool during loading")
	_check(get_tree().get_first_node_in_group("hud_toast") != null, "the run builds the banner layer")
	var fx: Node = player.get("camera_fx")
	_check(fx != null and fx.get_parent() == player, "the player owns a CameraFx")
	_check(player.get_node_or_null("DustMotes") != null, "and the ambient dust motes")
	_check(player.get_node_or_null("DamageDirectionLayer") != null, "the damage-direction fan is still there")

	# Footsteps are audible (there was no FootstepPlayer node, so they never were).
	for p in AudioManager._sfx_pool:
		p.stop()
	player.velocity = Vector3(5.0, 0.0, 0.0)
	player._footstep_timer = 0.0
	player._update_footsteps(0.016)
	var stepped := false
	for p in AudioManager._sfx_pool:
		if p.playing and p.stream in AudioManager._footsteps:
			stepped = true
	_check(stepped, "walking sounds a footstep")
	_check(player._footstep_timer > 0.1, "and schedules the next one (%.2f s)" % player._footstep_timer)
	player.velocity = Vector3.ZERO

	# Hurt: size-scaled vignette, the grunt, no vignette node of the old kind.
	_check(not ("_damage_vignette" in player), "the old flat red overlay is gone")
	var grunt: AudioStream = player.get("hit_grunt_sound") as AudioStream
	_check(grunt != null, "the player has a hurt grunt assigned")
	fx._flash_alpha = 0.0
	player._current_health = player.max_health
	player.take_damage(2.0, null)
	var graze: float = fx._flash_alpha
	fx._flash_alpha = 0.0
	player._current_health = player.max_health
	player.take_damage(player.max_health * 0.3, null)
	_check(fx._flash_alpha > graze, "the player's vignette follows the hit size (%.2f > %.2f)" % [fx._flash_alpha, graze])
	_check(fx.trauma > 0.0, "a real hit shakes the camera")
	# Low health from real damage turns the heartbeat on, a heal turns it off.
	player._current_health = player.max_health
	player.take_damage(player.max_health * 0.8, null)
	_check(fx._low_health, "dropping under 30% starts the low-health state")
	player.receive_heal(player.max_health)
	_check(not fx._low_health, "a heal ends it")
	fx._flash_alpha = 0.0
	player.receive_heal(0.0)

	# Landing.
	fx._dip = 0.0
	player._landing_armed = true
	player._was_on_floor = false
	player._fall_speed = 12.0
	player._detect_landing()
	_check(fx._dip > 0.05, "a hard landing dips the camera (%.3f m)" % fx._dip)
	fx._dip = 0.0
	player._was_on_floor = false
	player._fall_speed = 2.0
	player._detect_landing()
	_check(fx._dip == 0.0, "a small drop does not")

	# Enemies.
	var manager: Node = main.get_node_or_null("EnemyManager")
	var gen: Node = main.get_node_or_null("DungeonGenerationFunction")
	if manager != null and gen != null:
		manager.set_physics_process(false)
		for want_mage in [false, true]:
			var label: String = "mage" if want_mage else "brute"
			var e = _find_enemy(manager, gen, want_mage)
			if e == null:
				_check(false, label + ": found an enemy to test")
				continue
			e.global_position = player.global_position + Vector3(0, 0, -30)   # far from the player: its own attacks stay out of this
			e.reset_for_pool(e.global_position, Vector3.ZERO, manager._waypoints)
			await _frames(3)
			_check(e._bar != null and not e._bar.visible, label + ": a healthy enemy shows no health bar")
			e.take_damage(7.0, player)
			_check(e._bar.visible, label + ": a hurt enemy shows its health bar")
			var fill: float = e._bar_mat.get_shader_parameter("fill")
			_check(fill < 1.0 and fill > 0.0, label + ": the bar reflects its health (%.2f)" % fill)
			var number_shown := false
			for lb in pool._labels:
				if lb.visible and lb.text == "7":
					number_shown = true
			_check(number_shown, label + ": the player's hit floats a damage number")
			# Elite mark.
			e.apply_red_glow()
			_check(e._elite_mark != null and e._elite_mark.visible, label + ": an elite carries the floor mark")
			# A flinch cancels an attack in flight.
			e._attack_cooldown_timer = 0.0
			if want_mage:
				e._do_spell_attack(player)
			else:
				e._do_attack(player)
			await get_tree().physics_frame
			var token: int = e._attack_token
			_check(e._is_attacking, label + ": the attack started")
			e.take_damage(1.0, player)
			_check(e._attack_token == token + 1, label + ": a hit mid-attack cancels it")
			_check(e._attack_cooldown_timer >= e.attack_cooldown - 0.01, label + ": and the enemy has to wait before the next one")
			await get_tree().create_timer(2.5).timeout
			_check(not e._is_attacking or e._is_reacting == false, label + ": no stuck attack state after the cancel")
			# Credited kills vs culls.
			e.reset_for_pool(e.global_position, Vector3.ZERO, manager._waypoints)
			await _frames(3)
			e.take_damage(1.0e6, null)
			_check(e._is_dead and not e._credited_kill, label + ": a cull (no source) is not a credited kill")
			var wait := 0.0
			while e.visible and wait < 8.0:
				await get_tree().create_timer(0.25).timeout
				wait += 0.25
			e.reset_for_pool(e.global_position, Vector3.ZERO, manager._waypoints)
			await _frames(3)
			_check(is_equal_approx(e.mesh_root.scale.x, CharacterBase.MESH_SCALE), label + ": a reborn enemy has its full size back (%.4f)" % e.mesh_root.scale.x)
			_check(e._elite_mark == null or not e._elite_mark.visible, label + ": and no elite mark")
			e.take_damage(1.0e6, player)
			_check(e._is_dead and e._credited_kill, label + ": the player's kill is credited")
			_check(e._bar == null or not e._bar.visible, label + ": a dead enemy shows no bar")

	# The Mage's bolts are pooled: a ring of 16 (the dome) builds no node, and every bolt returns to the pool.
	if cls == "mage":
		var pool_n: int = player._bolt_pool.size()
		_check(pool_n >= 18, "the bolt pool is pre-built (%d)" % pool_n)
		for i in 16:
			var a: float = TAU * float(i) / 16.0
			player._launch_fireball(player.global_position + Vector3(0, 1.4, 0), Vector3(sin(a), 0.0, cos(a)))
		await get_tree().physics_frame
		var active := 0
		for b in player._bolt_pool:
			if b.visible:
				active += 1
		_check(active == 16, "16 bolts are in flight (%d)" % active)
		_check(player._bolt_pool.size() == pool_n, "and the pool did not have to grow for them")
		# Impacts leave scorch decals, but the cap holds and the oldest decal is moved rather than freed + rebuilt.
		var marks_before: int = player._scorch_pool.size()
		_check(marks_before <= player.MAX_SCORCH_MARKS, "scorch marks are capped (%d)" % marks_before)
		var names_ok := true
		for b in player._bolt_pool:
			if b.visible and not str(b.name).begins_with("MageFireball_"):
				names_ok = false
			if not b.visible and not str(b.name).begins_with("MageBolt_Idle_"):
				names_ok = false
		_check(names_ok, "flying bolts are named MageFireball_*, idle ones MageBolt_Idle_*")
		await get_tree().create_timer(2.2).timeout
		active = 0
		for b in player._bolt_pool:
			if b.visible:
				active += 1
		_check(active == 0, "every bolt has returned to the pool (%d still flying)" % active)
		player._launch_fireball(player.global_position + Vector3(0, 1.4, 0), Vector3(0, 0, -1))
		await get_tree().physics_frame
		active = 0
		for b in player._bolt_pool:
			if b.visible:
				active += 1
		_check(active == 1, "a bolt can be fired again from the pool")

	# Wallet bump.
	PlayerWallet.show_hud()
	PlayerWallet._set_row("potions", 3)
	PlayerWallet._set_row("potions", 4)
	var plabel: Label = PlayerWallet._rows["potions"][2]
	_check(plabel.scale.x > 1.1, "a potion gain pops the wallet number (%.2f)" % plabel.scale.x)
	await get_tree().create_timer(0.6).timeout
	_check(is_equal_approx(plabel.scale.x, 1.0), "and it settles")

	# Torch flicker is off in the budget by default, on in the run.
	var budget: Node = main.get_node_or_null("TorchLightBudget")
	_check(budget != null and budget.get("flicker_amount") > 0.0, "the run's torches flicker")



func _find_enemy(manager, gen, want_mage: bool):
	for e in manager._active_enemies:
		if is_instance_valid(e) and e.visible and ("mage_ai" in e.get_script().resource_path) == want_mage:
			return e
	var entries: Array = gen.registered_typed_spawns.duplicate()
	entries.shuffle()
	for entry in entries:
		var forced: Dictionary = entry.duplicate()
		forced["type"] = 2 if want_mage else 1
		var before: int = manager._active_enemies.size()
		if manager._spawn_enemy_from_data(forced) and manager._active_enemies.size() > before:
			var e = manager._active_enemies.back()
			if ("mage_ai" in e.get_script().resource_path) == want_mage:
				return e
	return null
