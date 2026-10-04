extends Node
## Hot Attic Games studio splash: the exact canonical logo, whole-artwork aspect-correct layout,
## 2-3 s card, cold-launch only, and it can never strand the player. Set REQUIRE_STUDIO_LOGO=1
## (the release build does) to make a missing canonical logo a failure.

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _fixture_texture() -> ImageTexture:
	# A stand-in only for exercising layout / transparency code. It is never shipped or shown.
	var img := Image.create(400, 100, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	img.fill_rect(Rect2i(100, 25, 200, 50), Color(1, 0.5, 0, 1))
	return ImageTexture.create_from_image(img)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _ready() -> void:
	# --- Launch order and configuration ----------------------------------------------------------------
	_check(StudioSplash.LOGO_FILENAME == "Hot_Attic_Games_Master_Logo_ALPHA_FINAL.png", "the canonical file name is exact")
	_check(str(ProjectSettings.get_setting("application/run/main_scene")) == "res://scenes/StudioSplash.tscn", "the studio splash is the main scene (cold launch opens on it)")
	_check(StudioSplash.NEXT_SCENE == "res://scenes/MainMenu.tscn" and ResourceLoader.exists(StudioSplash.NEXT_SCENE), "the splash hands over to the game's own main menu")
	_check(ResourceLoader.exists("res://scenes/StudioSplash.tscn"), "the splash scene exists")
	_check(not bool(ProjectSettings.get_setting("application/boot_splash/show_image", true)), "no engine logo splash is stacked in front of the studio card")
	_check(StudioSplash.TOTAL_SECONDS >= 2.0 and StudioSplash.TOTAL_SECONDS <= 3.0, "the card lasts 2-3 s (%.2f s)" % StudioSplash.TOTAL_SECONDS)
	_check(StudioSplash.FAILSAFE_SECONDS > StudioSplash.TOTAL_SECONDS and StudioSplash.FAILSAFE_SECONDS <= 15.0, "a failsafe ends the card regardless")

	# --- Aspect-preserving fit ---------------------------------------------------------------------------
	for tex_size in [Vector2(400, 100), Vector2(1000, 1000), Vector2(300, 900)]:
		for area in [Rect2(0, 0, 1920, 1080), Rect2(50, 20, 800, 1200), Rect2(0, 0, 100, 100), Rect2(10, 10, 5000, 200)]:
			var r: Rect2 = StudioSplash.fit_rect(tex_size, area)
			_check(absf(r.size.x / r.size.y - tex_size.x / tex_size.y) < 0.0001, "fit %s into %s keeps the aspect ratio" % [tex_size, area])
			_check(area.grow(0.01).encloses(r), "fit %s into %s shows the whole artwork (nothing cropped)" % [tex_size, area])
			_check(absf(r.get_center().x - area.get_center().x) < 0.01 and absf(r.get_center().y - area.get_center().y) < 0.01, "fit %s into %s is centred" % [tex_size, area])
			_check(absf(r.size.x - area.size.x) < 0.01 or absf(r.size.y - area.size.y) < 0.01, "fit %s into %s uses the available space" % [tex_size, area])

	# --- A card with a transparent stand-in image ----------------------------------------------------------
	var tex := _fixture_texture()
	_check(tex.get_image().detect_alpha() != Image.ALPHA_NONE and tex.get_image().get_pixel(0, 0).a == 0.0, "the fixture really has transparency (so the check below means something)")
	var holder := Control.new()
	holder.size = Vector2(1280, 720)
	add_child(holder)
	var splash := StudioSplash.new()
	splash.change_scene_on_finish = false
	splash.logo_override = tex
	var t0 := Time.get_ticks_msec()
	var finished_at := [-1]
	splash.finished.connect(func(): finished_at[0] = Time.get_ticks_msec())
	holder.add_child(splash)
	await _frames(2)
	_check(splash.logo_rect != null and not splash.skipped, "the card is built when a logo exists")
	var lr: TextureRect = splash.logo_rect
	_check(lr.texture == tex, "the card displays the supplied texture itself")
	_check(absf(lr.size.x / lr.size.y - 4.0) < 0.001, "the displayed logo keeps its 4:1 aspect (%s)" % lr.size)
	_check(Rect2(Vector2.ZERO, splash.size).encloses(Rect2(lr.position, lr.size)), "the whole logo is on screen")
	_check(lr.position.x >= 1280 * StudioSplash.SAFE_MARGIN - 1.0 and lr.position.y >= 0.0, "the logo respects the safe margin")
	_check(lr.stretch_mode == TextureRect.STRETCH_SCALE and lr.expand_mode == TextureRect.EXPAND_IGNORE_SIZE and lr.material == null, "no cropping, tiling or shader on the artwork")
	_check(lr.texture.get_image().get_pixel(0, 0).a == 0.0 and lr.texture.get_image().get_pixel(200, 50).a == 1.0, "transparency is preserved in the displayed texture")
	_check(splash.get_node("Background") is ColorRect and (splash.get_node("Background") as ColorRect).color.a == 1.0, "a plain opaque background sits behind the logo")
	_check(splash.get_children().size() == 2, "nothing else is drawn on the card (no text, buttons or effects)")
	# Resizing keeps the layout correct.
	holder.size = Vector2(600, 900)
	await _frames(2)
	_check(absf(lr.size.x / lr.size.y - 4.0) < 0.001 and Rect2(Vector2.ZERO, splash.size).encloses(Rect2(lr.position, lr.size)), "resizing the window keeps the logo whole and in aspect")
	holder.size = Vector2(1280, 720)

	while finished_at[0] < 0 and Time.get_ticks_msec() - t0 < 8000:
		await get_tree().process_frame
	var shown_s: float = (finished_at[0] - t0) / 1000.0
	_check(finished_at[0] >= 0, "the card finishes on its own")
	_check(shown_s >= 2.0 and shown_s <= 3.3, "the card is on screen for about 2-3 s (%.2f s)" % shown_s)
	holder.queue_free()

	# --- Never strands the player ----------------------------------------------------------------------------
	var holder2 := Control.new()
	holder2.size = Vector2(1280, 720)
	add_child(holder2)
	var missing := StudioSplash.new()
	missing.change_scene_on_finish = false
	missing.logo_path_override = "res://does_not_exist/Hot_Attic_Games_Master_Logo_ALPHA_FINAL.png"
	var missing_done := [false]
	missing.finished.connect(func(): missing_done[0] = true)
	holder2.add_child(missing)
	await _frames(3)
	_check(missing.skipped and missing_done[0] and missing.logo_rect == null, "a missing logo skips the card at once instead of hanging")
	holder2.queue_free()

	# --- Cold launch hands over to the next scene; a second visit does not replay -----------------------------
	StudioSplash.shown_this_launch = false
	var nav := []
	var cold := StudioSplash.new()
	cold.logo_override = tex
	cold.navigate = func(packed, path): nav.append([packed, path])
	var holder3 := Control.new()
	holder3.size = Vector2(1280, 720)
	add_child(holder3)
	holder3.add_child(cold)
	await _frames(2)
	_check(StudioSplash.shown_this_launch, "the launch is recorded as shown")
	# Give the background load time to finish, then end the card early.
	await get_tree().create_timer(0.8).timeout
	cold._finish()
	await _frames(2)
	_check(nav.size() == 1 and nav[0][0] is PackedScene and nav[0][1] == "res://scenes/MainMenu.tscn", "after the card the main menu (loaded behind it) is opened")
	var again := StudioSplash.new()
	again.logo_override = tex
	again.navigate = func(packed, path): nav.append([packed, path])
	holder3.add_child(again)
	await _frames(3)
	_check(again.skipped and again.logo_rect == null and nav.size() == 2, "returning to the splash later (resume / re-entry) does not replay it")
	# A scene that cannot be loaded behind the card falls back to a normal scene change.
	StudioSplash.shown_this_launch = false
	var bad := StudioSplash.new()
	bad.logo_override = tex
	bad.next_scene_path = "res://scenes/no_such_scene.tscn"
	var nav_bad := []
	bad.navigate = func(packed, path): nav_bad.append([packed, path])
	holder3.add_child(bad)
	await _frames(2)
	bad._finish()
	await _frames(2)
	_check(nav_bad.size() == 1 and nav_bad[0][0] == null and nav_bad[0][1] == "res://scenes/no_such_scene.tscn", "a failed background load falls back to a normal scene change")
	StudioSplash.shown_this_launch = false
	holder3.queue_free()

	# --- The canonical artwork -------------------------------------------------------------------------------
	var path := StudioSplash.resolve_logo_path()
	if path == "":
		if OS.get_environment("REQUIRE_STUDIO_LOGO") == "1":
			_check(false, "%s is missing from the project (release builds require it)" % StudioSplash.LOGO_FILENAME)
		else:
			print("ANOMALY: %s is not in the project, so the studio card is skipped at runtime (set REQUIRE_STUDIO_LOGO=1 to make this an error)." % StudioSplash.LOGO_FILENAME)
	else:
		var real := load(path) as Texture2D
		_check(real != null and real.get_width() > 0 and real.get_height() > 0, "the canonical logo loads (%s)" % path)
		if real != null:
			var img := real.get_image()
			_check(img.detect_alpha() != Image.ALPHA_NONE, "the canonical logo has transparency (%s)" % img.get_format())
			var holder4 := Control.new()
			holder4.size = Vector2(1920, 1080)
			add_child(holder4)
			var real_splash := StudioSplash.new()
			real_splash.change_scene_on_finish = false
			holder4.add_child(real_splash)
			await _frames(2)
			_check(real_splash.logo_rect != null and real_splash.logo_rect.texture.resource_path == path, "the canonical file is the artwork the splash displays")
			_check(absf(real_splash.logo_rect.size.x / real_splash.logo_rect.size.y - float(real.get_width()) / float(real.get_height())) < 0.001, "the canonical logo keeps its aspect ratio")
			holder4.queue_free()

	print("test_studio_splash: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
