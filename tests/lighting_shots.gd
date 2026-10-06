extends Node
## MANUAL TOOL (not part of run_tests.sh): renders real frames of the real dungeon from a
## fixed seed at representative viewpoints and prints/saves READABILITY statistics.
##
## Needs a renderer. Software Vulkan (mesa lavapipe) works, it is slow (a few minutes):
##   export PURGATORY_SAVE_ROOT=$(mktemp -d)/PurgetoryDungeon
##   LIGHT_OUT=/tmp/shots LIGHT_TAG=after LIGHT_BOOST=0 \
##   nice -n 19 xvfb-run -a -s "-screen 0 1600x720x24" godot --rendering-driver vulkan \
##     --rendering-method mobile --resolution 1600x720 --path . res://tests/lighting_shots.tscn
##
## Environment variables (all optional):
##   LIGHT_OUT    output directory for PNG + stats.csv (default user://lighting_shots)
##   LIGHT_TAG    file-name prefix, e.g. "before" / "after"
##   LIGHT_SEED   fixed dungeon seed (default 12345)
##   LIGHT_BOOST  "Ambient Brightness" accessibility setting 0..100 (ignored by builds without it)
##   LIGHT_ONLY   comma list of viewpoint names to render (default all)
##   LIGHT_AMB / LIGHT_AMB_COLOR  tuning aids: override LightingManager.ambient_energy / ambient_color ("r,g,b")
##   LIGHT_HARDCORE  1 = also run LightingManager.set_dimming(1.0) (end-of-run darkness)
##
## Statistics are taken on the DISPLAYED (sRGB-encoded, tonemapped) 3D view only (HUD layers are hidden),
## over the central 80% of the frame, luma = Rec.709 weights, 0..1:
##   mean, p5/p50/p95, fraction below 0.02 / 0.03 / 0.05 (near-black), fraction above 0.60 (torch pool),
##   enemy: mean luma of the enemy silhouette (found with a flat-colour mask pass), the mean of a ring around it and the
##   ratio, plus how much of the silhouette is near-black.

const MAIN_SCENE : String = "res://scenes/Purgatory_Dungeon_main_game_file.tscn"
const STRIDE : int = 2

var _out_dir : String = ""
var _tag : String = "shot"
var _rows : PackedStringArray = PackedStringArray()


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	_out_dir = OS.get_environment("LIGHT_OUT")
	if _out_dir == "":
		_out_dir = ProjectSettings.globalize_path("user://lighting_shots")
	DirAccess.make_dir_recursive_absolute(_out_dir)
	if OS.get_environment("LIGHT_TAG") != "":
		_tag = OS.get_environment("LIGHT_TAG")
	var seed_v : int = 12345
	if OS.get_environment("LIGHT_SEED") != "":
		seed_v = int(OS.get_environment("LIGHT_SEED"))
	if OS.get_environment("LIGHT_BOOST") != "":
		SettingsManager.gameplay_settings["AmbientBrightness"] = float(OS.get_environment("LIGHT_BOOST"))
	GlobalRunData.character_class = "barbarian"
	GlobalRunData.seed_hash = 0
	var main : Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	main.use_random_seed = false
	main.fixed_seed = seed_v
	add_child(main)
	var gen : Node = main.get_node("DungeonGenerationFunction")
	while gen.placed_modules.size() == 0:
		await get_tree().physics_frame
	for i in 90:
		await get_tree().physics_frame
	_run.call_deferred(main, gen)


func _run(main: Node, gen: Node) -> void:
	var player : Node3D = get_tree().get_nodes_in_group("player")[0]
	# Freeze world logic that is not needed: no enemy manager spawns / attacks while shooting.
	for n in ["EnemyManager", "HealthOrbManager", "TrapManager", "RoomLockManager", "PropSpawner", "ChestManager"]:
		var node : Node = main.get_node_or_null(n)
		if node != null:
			node.process_mode = Node.PROCESS_MODE_DISABLED
	for e in get_tree().get_nodes_in_group("enemies"):
		e.queue_free()
	for e in get_tree().get_nodes_in_group("enemy"):
		e.queue_free()
	GameClock.process_mode = Node.PROCESS_MODE_DISABLED
	player.set_physics_process(false)
	player.set_process(false)
	for layer in _all_canvas_layers(get_tree().root):
		layer.visible = false
	var lm : Node = main.get_node_or_null("LightingManager")
	if lm != null and OS.get_environment("LIGHT_HARDCORE") == "1" and lm.has_method("set_dimming"):
		lm.set_dimming(1.0)

	if lm != null and OS.get_environment("LIGHT_AMB") != "":   # tuning aid: override the default ambient energy
		lm.ambient_energy = float(OS.get_environment("LIGHT_AMB"))
		if OS.get_environment("LIGHT_AMB_COLOR") != "":
			var cc : PackedStringArray = OS.get_environment("LIGHT_AMB_COLOR").split(",")
			lm.ambient_color = Color(float(cc[0]), float(cc[1]), float(cc[2]))
			lm._world_env.environment.ambient_light_color = lm.ambient_color
		lm.refresh_brightness()
	var cam : Camera3D = player.get_node("SpringArm3D/Camera3D")
	cam.current = true
	var views : Array = _pick_viewpoints(gen)
	var only : String = OS.get_environment("LIGHT_ONLY")
	var count_info : String = "lights=%d meshes=%d" % [_count_class(main, "Light3D"), _count_class(main, "MeshInstance3D")]
	print("LIGHTSHOTS tag=%s seed=%s modules=%d torches=%d %s" % [_tag, str(main.fixed_seed), gen.placed_modules.size(), gen.registered_torches.size(), count_info])
	_rows.append("tag,view,mean,p5,p50,p95,lt002,lt003,lt005,gt060,enemy_mean,enemy_ring,enemy_ratio,enemy_lt005,draw_calls,objects,prims")
	for v in views:
		if only != "" and not (v["name"] in only.split(",")):
			continue
		await _shoot(player, cam, v, gen)
	var f := FileAccess.open(_out_dir.path_join("%s_stats.csv" % _tag), FileAccess.WRITE)
	f.store_string("\n".join(_rows) + "\n")
	f.close()
	print("LIGHTSHOTS done -> ", _out_dir)
	get_tree().quit(0)


# ── viewpoints ────────────────────────────────────────────────────────────────

func _pick_viewpoints(gen: Node) -> Array:
	var mods : Array = gen.placed_modules
	var torches : Array = gen.registered_torches
	var starter : Node3D = mods[0]
	var best_area : float = -1.0
	var big : Node3D = null
	var hall : Node3D = null
	var endcap : Node3D = null
	var far_mod : Node3D = null
	var far_d : float = -1.0
	for m in mods:
		if m == null or not is_instance_valid(m):
			continue
		var nm : String = String(m.name).to_lower()
		var aabb : AABB = gen.get_module_aabb(m)
		if aabb.size == Vector3.ZERO:
			continue
		var area : float = aabb.size.x * aabb.size.z
		if "hallway" in nm and hall == null:
			hall = m
		if ("closer" in nm or "end" in nm) and endcap == null:
			endcap = m
		if area > best_area and not ("connector" in nm):
			best_area = area
			big = m
		var c : Vector3 = aabb.get_center()
		var md : float = 1e9
		for t in torches:
			if is_instance_valid(t):
				md = minf(md, Vector2(c.x - t.global_position.x, c.z - t.global_position.z).length())
		if md > far_d and md < 1e8:
			far_d = md
			far_mod = m
	var out : Array = []
	out.append({"name": "spawn", "mod": starter, "corner": false})
	if hall != null: out.append({"name": "corridor", "mod": hall, "corner": false})
	if big != null: out.append({"name": "bigroom", "mod": big, "corner": false})
	if endcap != null: out.append({"name": "endcap", "mod": endcap, "corner": false})
	if far_mod != null: out.append({"name": "farcorner", "mod": far_mod, "corner": true})
	return out


func _floor_hit(player: Node3D, p: Vector3) -> Dictionary:
	var space := player.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 1.5, 0), p + Vector3(0, -6.0, 0))
	q.collision_mask = 1   # the dungeon ceiling body lives on layer 2: never stand on it
	return space.intersect_ray(q)


func _floor_y(player: Node3D, p: Vector3) -> float:
	var space := player.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 1.5, 0), p + Vector3(0, -6.0, 0))
	q.collision_mask = 1   # the dungeon ceiling body lives on layer 2: never stand on it
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return p.y
	return (hit["position"] as Vector3).y


# Height of the node origin above its feet: half the capsule of its CollisionShape3D (CharacterBody origins sit at the capsule centre).
func _origin_height(n: Node3D) -> float:
	for c in n.get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape is CapsuleShape3D:
			var cs : CollisionShape3D = c
			return ((cs.shape as CapsuleShape3D).height * 0.5 * cs.scale.y - cs.position.y) * n.scale.y
	return 1.0


# Sight-line length along a yaw: the shortest of five rays spread over +-8 degrees (collider seams let single rays through).
func _sight(player: Node3D, from: Vector3, yaw: float) -> float:
	var space := player.get_world_3d().direct_space_state
	var shortest : float = 40.0
	for off in [-0.14, -0.07, 0.0, 0.07, 0.14]:
		var dir := Vector3(-sin(yaw + off), 0, -cos(yaw + off))
		var q := PhysicsRayQueryParameters3D.create(from, from + dir * 40.0)
		q.collision_mask = 1
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			shortest = minf(shortest, from.distance_to(hit["position"]))
	return shortest


func _shoot(player: Node3D, cam: Camera3D, v: Dictionary, gen: Node) -> void:
	var m : Node3D = v["mod"]
	var aabb : AABB = gen.get_module_aabb(m)
	var c : Vector3 = aabb.get_center()
	var pos := Vector3(c.x, c.y, c.z)
	# Standable points of the module: a real floor under them (not the invisible "Antifall" plane), a 4 m sight line.
	# "spawn"/"corridor"/"bigroom"/"endcap" stand on the point nearest the module centre; "farcorner" on the point
	# farthest from every torch.
	var best : float = -1e9
	var best_torch : float = 0.0
	var mesh_boxes : Array = []
	for mi in _meshes(m):
		mesh_boxes.append((mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb())
	for min_clear in [10.0, 4.0]:   # prefer a 10 m sight line so both enemies are in view
		var gx : float = 1.5
		while gx < aabb.size.x - 1.4:
			var gz : float = 1.5
			while gz < aabb.size.z - 1.4:
				var p := Vector3(aabb.position.x + gx, c.y, aabb.position.z + gz)
				var fh : Dictionary = _floor_hit(player, p)
				gz += 1.5
				if fh.is_empty() or String(fh["collider"].name).begins_with("Antifall"):
					continue
				if not _covered(mesh_boxes, p):
					continue   # no visible module geometry under this point (open void)
				p.y = (fh["position"] as Vector3).y + 1.0
				var clear : float = 0.0
				for k in 8:
					clear = maxf(clear, _sight(player, p + Vector3(0, 0.6, 0), TAU * float(k) / 8.0))
				if clear < min_clear:
					continue
				var score : float
				var md : float = 1e9
				if bool(v["corner"]):
					for t in gen.registered_torches:
						if is_instance_valid(t):
							md = minf(md, Vector2(p.x - t.global_position.x, p.z - t.global_position.z).length())
					score = md
				else:
					score = -Vector2(p.x - c.x, p.z - c.z).length()
				if score > best:
					best = score
					best_torch = md
					pos = p
			gx += 1.5
		if best > -1e8:
			break
	if bool(v["corner"]):
		print("LIGHTSHOT farcorner nearest torch %.1f m" % best_torch)
	pos.y = _floor_y(player, pos) + _origin_height(player) + 0.02
	player.global_position = pos
	var eye : Vector3 = cam.global_position
	var best_yaw : float = 0.0
	var best_len : float = -1.0
	for k in 24:
		var yaw : float = TAU * float(k) / 24.0
		var d : float = _sight(player, eye, yaw)

		if d > best_len:
			best_len = d
			best_yaw = yaw
	player.rotation.y = best_yaw
	if OS.get_environment("LIGHT_DEBUG") == "2":
		var fh2 : Dictionary = _floor_hit(player, pos)
		print("DEBUG2 floor collider=", fh2.get("collider"), " parent=", fh2["collider"].get_parent().name if fh2.has("collider") else "")
		for mi in _meshes(m):
			var ab : AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
			if ab.grow(0.5).has_point(Vector3(pos.x, ab.position.y + 0.1, pos.z)) or (ab.position.x < pos.x and ab.end.x > pos.x and ab.position.z < pos.z and ab.end.z > pos.z):
				print("DEBUG2 mesh ", mi.name, " visible=", mi.is_visible_in_tree(), " layers=", (mi as MeshInstance3D).layers, " aabb=", ab, " surfaces=", (mi as MeshInstance3D).mesh.get_surface_count() if (mi as MeshInstance3D).mesh else -1)
	if OS.get_environment("LIGHT_DEBUG") != "":
		print("DEBUG ", v["name"], " pos=", pos, " eye=", eye, " best_len=", best_len, " yaw=", best_yaw, " best_score=", best)
	cam.rotation = Vector3.ZERO
	# two enemies in view (brute + mage) on the floor
	var enemies : Array = []
	var fwd := Vector3(-sin(best_yaw), 0, -cos(best_yaw))
	var right := Vector3(cos(best_yaw), 0, -sin(best_yaw))
	var main : Node = get_child(0)
	var scenes : Array = [main.brute_enemy_scene, main.mage_enemy_scene]
	var dists : Array = [minf(5.0, best_len - 1.0), minf(8.0, best_len - 0.5)]
	var offs : Array = [-0.9, 1.0]
	for i in 2:
		var e : Node3D = (scenes[i] as PackedScene).instantiate()
		main.add_child(e)
		e.process_mode = Node.PROCESS_MODE_DISABLED
		var ep : Vector3 = eye + fwd * maxf(dists[i], 2.0) + right * float(offs[i])
		ep.y = _floor_y(player, ep) + _origin_height(e) + 0.02
		e.global_position = ep
		e.rotation.y = best_yaw + PI
		enemies.append(e)
	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img : Image = get_viewport().get_texture().get_image()
	var draw_calls : int = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var objects : int = int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	var prims : int = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	img.save_png(_out_dir.path_join("%s_%s.png" % [_tag, v["name"]]))
	# mask pass: enemies flat magenta, unshaded
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 0, 1)
	for e in enemies:
		for mi in _meshes(e):
			mi.material_override = mat
	for i in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var mask : Image = get_viewport().get_texture().get_image()
	var stats : Dictionary = _analyse(img, mask)
	print("LIGHTSHOT %s/%s mean=%.3f p5=%.3f p50=%.3f p95=%.3f <0.02=%.1f%% <0.03=%.1f%% <0.05=%.1f%% >0.60=%.1f%% | enemy mean=%.3f ring=%.3f ratio=%.2f near-black=%.0f%% (px %d) | draws=%d objs=%d prims=%d" % [
		_tag, v["name"], stats["mean"], stats["p5"], stats["p50"], stats["p95"], stats["lt002"] * 100.0, stats["lt003"] * 100.0, stats["lt005"] * 100.0, stats["gt060"] * 100.0,
		stats["em"], stats["er"], stats["ratio"], stats["elt005"] * 100.0, stats["epx"], draw_calls, objects, prims])
	_rows.append("%s,%s,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%.3f,%d,%d,%d" % [_tag, v["name"], stats["mean"], stats["p5"], stats["p50"], stats["p95"], stats["lt002"], stats["lt003"], stats["lt005"], stats["gt060"], stats["em"], stats["er"], stats["ratio"], stats["elt005"], draw_calls, objects, prims])
	for e in enemies:
		e.queue_free()
	await get_tree().process_frame


# True if some mesh of the module spans the (x, z) point (so the player stands on drawn geometry, not on the invisible floor plane).
func _covered(boxes: Array, p: Vector3) -> bool:
	for ab in boxes:
		if ab.size.y > 0.05 and p.x > ab.position.x + 0.8 and p.x < ab.end.x - 0.8 and p.z > ab.position.z + 0.8 and p.z < ab.end.z - 0.8 and ab.position.y < 0.6:
			return true
	return false


func _meshes(n: Node) -> Array:
	var out : Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out


func _all_canvas_layers(n: Node) -> Array:
	var out : Array = []
	if n is CanvasLayer:
		out.append(n)
	for c in n.get_children():
		out.append_array(_all_canvas_layers(c))
	return out


func _count_class(n: Node, cls: String) -> int:
	var k : int = 1 if n.is_class(cls) else 0
	for c in n.get_children():
		k += _count_class(c, cls)
	return k


# ── statistics ───────────────────────────────────────────────────────────────

func _analyse(img: Image, mask: Image) -> Dictionary:
	img.convert(Image.FORMAT_RGBA8)
	mask.convert(Image.FORMAT_RGBA8)
	var w : int = img.get_width()
	var h : int = img.get_height()
	var d : PackedByteArray = img.get_data()
	var md : PackedByteArray = mask.get_data()
	var x0 : int = int(w * 0.1)
	var x1 : int = int(w * 0.9)
	var y0 : int = int(h * 0.1)
	var y1 : int = int(h * 0.9)
	var hist : PackedInt32Array = PackedInt32Array()
	hist.resize(256)
	var n : int = 0
	var sum : float = 0.0
	var c2 : int = 0
	var c3 : int = 0
	var c5 : int = 0
	var c60 : int = 0
	var ex0 : int = 1 << 30
	var ex1 : int = -1
	var ey0 : int = 1 << 30
	var ey1 : int = -1
	var esum : float = 0.0
	var en : int = 0
	var e5 : int = 0
	var lumas : PackedFloat32Array = PackedFloat32Array()
	lumas.resize(w * h)
	for y in range(0, h, STRIDE):
		for x in range(0, w, STRIDE):
			var i : int = (y * w + x) * 4
			var l : float = (0.2126 * d[i] + 0.7152 * d[i + 1] + 0.0722 * d[i + 2]) / 255.0
			lumas[y * w + x] = l
			var inmask : bool = md[i] > 235 and md[i + 2] > 235 and md[i + 1] < 40
			if inmask:
				ex0 = mini(ex0, x); ex1 = maxi(ex1, x); ey0 = mini(ey0, y); ey1 = maxi(ey1, y)
				esum += l
				en += 1
				if l < 0.05:
					e5 += 1
			if x >= x0 and x < x1 and y >= y0 and y < y1:
				n += 1
				sum += l
				hist[int(l * 255.0 + 0.5)] += 1
				if l < 0.02: c2 += 1
				if l < 0.03: c3 += 1
				if l < 0.05: c5 += 1
				if l > 0.60: c60 += 1
	var res : Dictionary = {}
	res["mean"] = sum / maxf(n, 1)
	res["lt002"] = float(c2) / maxf(n, 1)
	res["lt003"] = float(c3) / maxf(n, 1)
	res["lt005"] = float(c5) / maxf(n, 1)
	res["gt060"] = float(c60) / maxf(n, 1)
	for pr in [[0.05, "p5"], [0.5, "p50"], [0.95, "p95"]]:
		var target : float = float(pr[0]) * n
		var acc : float = 0.0
		var v : float = 0.0
		for b in 256:
			acc += hist[b]
			if acc >= target:
				v = float(b) / 255.0
				break
		res[pr[1]] = v
	res["epx"] = en
	res["em"] = esum / maxf(en, 1)
	res["elt005"] = float(e5) / maxf(en, 1)
	# ring: bounding box grown by 40%, minus the silhouette itself
	var rsum : float = 0.0
	var rn : int = 0
	if en > 0:
		var bw : int = ex1 - ex0
		var bh : int = ey1 - ey0
		var gx0 : int = maxi(0, ex0 - int(bw * 0.4)) & ~1
		var gx1 : int = mini(w - 1, ex1 + int(bw * 0.4))
		var gy0 : int = maxi(0, ey0 - int(bh * 0.2)) & ~1
		var gy1 : int = mini(h - 1, ey1 + int(bh * 0.2))
		for y in range(gy0, gy1, STRIDE):
			for x in range(gx0, gx1, STRIDE):
				var i : int = (y * w + x) * 4
				var inmask : bool = md[i] > 235 and md[i + 2] > 235 and md[i + 1] < 40
				if not inmask and not (x >= ex0 and x <= ex1 and y >= ey0 and y <= ey1):
					rsum += lumas[y * w + x]
					rn += 1
	res["er"] = rsum / maxf(rn, 1)
	res["ratio"] = res["em"] / maxf(res["er"], 0.001)
	return res
