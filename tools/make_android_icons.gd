# One-off generator for the Android launcher icons from the game's own icon (config/icon, the VPP SVG):
#   godot --headless --path . --script tools/make_android_icons.gd
# Writes android_icons/{main_192,adaptive_fg_432,adaptive_bg_432,adaptive_mono_432}.png. The artwork
# is the existing project icon, untouched apart from scaling into the adaptive-icon safe zone.
extends SceneTree


func _initialize() -> void:
	var f := FileAccess.open("res://Music & background images/VPP_logo_from_source_256.svg", FileAccess.READ)
	var svg := f.get_as_text()

	var main := Image.new()
	main.load_svg_from_string(svg, 192.0 / 256.0)
	main.save_png("res://android_icons/main_192.png")

	# Adaptive icons: 432 px layers of which the middle 288 px (66.7%) are always visible.
	var art := Image.new()
	art.load_svg_from_string(svg, 288.0 / 256.0)
	var fg := Image.create(432, 432, false, Image.FORMAT_RGBA8)
	fg.fill(Color(0, 0, 0, 0))
	var off := Vector2i((432 - art.get_width()) / 2, (432 - art.get_height()) / 2)
	fg.blend_rect(art, Rect2i(Vector2i.ZERO, art.get_size()), off)
	fg.save_png("res://android_icons/adaptive_fg_432.png")

	var bg := Image.create(432, 432, false, Image.FORMAT_RGBA8)
	bg.fill(Color(0.13, 0.09, 0.17, 1.0))
	bg.save_png("res://android_icons/adaptive_bg_432.png")

	# Themed (monochrome) icon: white, shaped by the artwork's light areas.
	var mono := Image.create(432, 432, false, Image.FORMAT_RGBA8)
	mono.fill(Color(0, 0, 0, 0))
	for y in art.get_height():
		for x in art.get_width():
			var c := art.get_pixel(x, y)
			var lum := (0.299 * c.r + 0.587 * c.g + 0.114 * c.b)
			var a := clampf((lum - 0.15) * 2.2, 0.0, 1.0) * c.a
			mono.set_pixel(off.x + x, off.y + y, Color(1, 1, 1, a))
	mono.save_png("res://android_icons/adaptive_mono_432.png")
	print("icons written")
	quit()
