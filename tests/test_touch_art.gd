extends Node
## The baked touch-control art (assets/touch/, made by tools/make_control_art.gd): every file the controls reference
## exists, imports as a texture with mipmaps, has the expected size, every state has a texture, and the buttons pick
## the right one. Run with PURGATORY_FORCE_TOUCH=1 (run_tests.sh sets it).

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _ready() -> void:
	var total_bytes: int = 0
	var names: Array[String] = TouchButton.art_names()
	_check(names.size() == 4 * (TouchButton.ART_BASE_PX.size() + TouchButton.ART_ICONS.size()), "one texture per base/icon per state (%d)" % names.size())
	for nm in names:
		var path: String = TouchButton.ART_DIR + nm + ".png"
		_check(FileAccess.file_exists(path), "%s exists" % path)
		_check(FileAccess.file_exists(path + ".import"), "%s has its .import (committed)" % path)
		var imp: String = FileAccess.get_file_as_string(path + ".import")
		_check(imp.contains("mipmaps/generate=true"), "%s imports with mipmaps" % nm)
		_check(not imp.contains("compress/mode=1") and not imp.contains("compress/mode=2"), "%s is lossless / VRAM-neutral (crisp alpha edges, no ETC/ASTC dependency)" % nm)
		var tex: Texture2D = TouchButton.art_texture(nm)
		_check(tex != null, "%s loads" % nm)
		if tex == null:
			continue
		var want: int = 0
		if nm.begins_with("base_attack"):
			want = int(TouchButton.ART_BASE_PX["attack"])
		elif nm.begins_with("base_sub"):
			want = int(TouchButton.ART_BASE_PX["sub"])
		else:
			want = TouchButton.ART_ICON_PX
		_check(tex.get_width() == want and tex.get_height() == want, "%s is %dx%d (%dx%d)" % [nm, want, want, tex.get_width(), tex.get_height()])
		var img: Image = tex.get_image()
		_check(img != null and img.has_mipmaps(), "%s carries a mip chain" % nm)
		if nm.begins_with("base"):
			_check(img != null and img.get_pixel(want / 2, want / 2).a > 0.9, "%s is opaque at its centre" % nm)
		else:
			var solid: int = 0
			for gy in range(0, want, 8):
				for gx in range(0, want, 8):
					if img.get_pixel(gx, gy).a > 0.9:
						solid += 1
			_check(solid > 40, "%s has solid art (%d samples)" % [nm, solid])
		_check(img != null and img.get_pixel(1, 1).a < 0.05, "%s has a transparent corner" % nm)
		total_bytes += FileAccess.get_file_as_bytes(path).size()
	_check(total_bytes < 6 * 1024 * 1024, "the baked art stays modest (%.2f MB < 6 MB)" % (float(total_bytes) / 1048576.0))

	# The states really differ (a tint could not do it): compare centre-ish pixel colours of the Attack base.
	var rim_px := func(state: String) -> Color:
		var im: Image = TouchButton.art_texture("base_attack_" + state).get_image()
		return im.get_pixel(int(512 * 0.5), int(512 * 0.5 - 512 * 0.5 / TouchButton.ART_CANVAS_HALF * 0.9))
	var d: Color = rim_px.call("default")
	var p: Color = rim_px.call("pressed")
	var c: Color = rim_px.call("cooldown")
	var z: Color = rim_px.call("disabled")
	_check(p.r > d.r * 0.95 and (p.r - p.b) > (d.r - d.b) * 0.9, "pressed rim is ember-warm")
	_check(absf(c.r - c.b) < absf(d.r - d.b) * 0.5, "cooldown rim is desaturated")
	_check(z.get_luminance() < c.get_luminance(), "disabled rim is darker than cooldown")

	# Buttons pick the right textures per state, for every control that uses baked art.
	var tc := TouchControls.new()
	tc.layout_override_insets = Vector4.ZERO
	tc.view_override = Vector2(1602, 720)
	add_child(tc)
	await get_tree().process_frame
	await get_tree().process_frame
	for action in ["attack", "kick", "jump", "block", "AOE", "equip"]:
		var b: TouchButton = tc.buttons[action]
		_check(b._base_art() != null and b._icon_art() != null, "%s has base and icon art" % action)
		_check(b.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS, "%s samples with mipmaps" % action)
		b.unavailable = false
		b.cooldown = 0.0
		b.pressed_visual = false
		_check(b.art_state() == "default", "%s default state" % action)
		b.pressed_visual = true
		_check(b.art_state() == "pressed", "%s pressed state" % action)
		b.pressed_visual = false
		b.cooldown = 0.5
		_check(b.art_state() == "cooldown", "%s cooldown state" % action)
		b.unavailable = true
		_check(b.art_state() == "disabled", "%s disabled state" % action)
		b.unavailable = false
		b.cooldown = 0.0
	_check(tc.buttons["ui_menu"]._base_art() == null and tc.buttons["minimap"]._base_art() == null, "Pause / Map stay the quiet code-drawn members")
	_check(tc.buttons["attack"]._base_art().get_width() > tc.buttons["kick"]._base_art().get_width(), "Attack has the larger base texture")
	# Drawing every button in every state raises no errors.
	for st in ["default", "pressed", "cooldown", "disabled"]:
		for action in tc.buttons:
			var b2: TouchButton = tc.buttons[action]
			b2.pressed_visual = st == "pressed"
			b2.cooldown = 0.5 if st == "cooldown" else 0.0
			b2.unavailable = st == "disabled"
			b2.queue_redraw()

	# Icon readability (v8.3): Repulse is an open palm with shock rings spreading all round (get back from me), the old rightward
	# chevrons are gone, and Kick is a boot swung up and forward with a swing trail and an ember impact star at the toe.
	_check(TouchButton.ART_ICONS.get("repulse", "") == "repulse" and not TouchButton.ART_ICONS.has("slide") and not TouchButton.ART_ICONS.values().has("chevrons"), "the jump/Repulse button uses the radial Repulse icon, not the chevrons")
	_check(not FileAccess.file_exists(TouchButton.ART_DIR + "icon_chevrons_default.png"), "the three-arrows-to-the-right art is gone")
	_check(not TouchIcons.KINDS.has("slide") and TouchIcons.KINDS.has("repulse"), "the code-drawn icon family names it Repulse")
	var rep: Image = TouchButton.art_texture("icon_repulse_default").get_image()
	var ring_hits: int = 0
	for k in 4:
		var v := Vector2.from_angle(TAU * (float(k) + 0.5) / 4.0) * 0.70 * 128.0 + Vector2(128, 128)
		var found := false
		for dx in range(-8, 9, 2):
			for dy in range(-8, 9, 2):
				var rc: Color = rep.get_pixel(clampi(int(v.x) + dx, 0, 255), clampi(int(v.y) + dy, 0, 255))
				if rc.a > 0.8 and rc.r > 0.7 and rc.b < 0.4:   # an ember ring pixel
					found = true
		if found:
			ring_hits += 1
	_check(ring_hits == 4, "Repulse: shock rings spread from the centre in all four quarters (%d of 4)" % ring_hits)
	var palm_px := 0
	for gy in range(96, 176, 4):
		for gx in range(104, 152, 4):
			var pc: Color = rep.get_pixel(gx, gy)
			if pc.a > 0.9 and pc.r > 0.7 and pc.g > 0.65 and pc.b > 0.5:   # bone / ivory
				palm_px += 1
	_check(palm_px >= 25, "Repulse: an open palm (bone) is held out at the centre (%d samples)" % palm_px)
	var halves := {"left": 0, "right": 0}
	for gy in range(0, 256, 4):
		for gx in range(0, 256, 4):
			if rep.get_pixel(gx, gy).a > 0.8:
				halves["left" if gx < 128 else "right"] += 1
	_check(absf(float(halves["left"] - halves["right"])) <= 0.15 * float(halves["left"] + halves["right"]), "Repulse is balanced about its centre: nothing says 'move right' (%s)" % [halves])
	var kick: Image = TouchButton.art_texture("icon_boot_default").get_image()
	var ember := 0
	for dx in range(-14, 15):
		for dy in range(-14, 15):
			var kc: Color = kick.get_pixel(216 + dx, 81 + dy)
			if kc.a > 0.9 and kc.r > 0.75 and kc.g > 0.45 and kc.g < 0.8 and kc.b < 0.4:
				ember += 1
	_check(ember >= 40, "Kick has an ember impact star at the toe's strike (%d ember pixels)" % ember)
	var left_leg := 0
	for gy in range(40, 120, 4):
		for gx in range(40, 110, 4):
			if kick.get_pixel(gx, gy).a > 0.8:
				left_leg += 1
	_check(left_leg >= 6, "Kick has the shin (steel) rising up-left behind the boot (%d samples)" % left_leg)
	await get_tree().process_frame
	await get_tree().process_frame
	tc.queue_free()
	print("test_touch_art: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
