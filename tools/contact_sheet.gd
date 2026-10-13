# Dev utility: tile PNGs into one contact sheet for side-by-side visual review.
#   godot --headless --path . --script tools/contact_sheet.gd -- out.png cols cell_w a.png b.png c.png ...
# Each image is scaled to cell_w (aspect kept) and captioned with its file name.
extends SceneTree


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 4:
		push_error("usage: -- out.png cols cell_w img1 [img2 ...]")
		quit(2)
		return
	var out_path: String = args[0]
	var cols: int = int(args[1])
	var cell_w: int = int(args[2])
	var imgs: Array[Image] = []
	var names: Array[String] = []
	for i in range(3, args.size()):
		var im := Image.load_from_file(args[i])
		if im == null:
			push_warning("cannot load " + args[i])
			continue
		var s: float = float(cell_w) / float(im.get_width())
		im.resize(cell_w, int(round(float(im.get_height()) * s)), Image.INTERPOLATE_LANCZOS)
		imgs.append(im)
		names.append(args[i].get_file())
	var rows: int = int(ceil(float(imgs.size()) / float(cols)))
	var cap_h := 22
	var pad := 8
	var row_h: Array[int] = []
	for r in rows:
		var h := 0
		for c in cols:
			var idx: int = r * cols + c
			if idx < imgs.size():
				h = maxi(h, imgs[idx].get_height())
		row_h.append(h + cap_h)
	var total_h := pad
	for h in row_h:
		total_h += h + pad
	var sheet := Image.create(cols * (cell_w + pad) + pad, total_h, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.35, 0.35, 0.38, 1))
	var y := pad
	for r in rows:
		for c in cols:
			var idx: int = r * cols + c
			if idx >= imgs.size():
				continue
			var x: int = pad + c * (cell_w + pad)
			sheet.blit_rect(imgs[idx], Rect2i(Vector2i.ZERO, imgs[idx].get_size()), Vector2i(x, y + cap_h))
		y += row_h[r] + pad
	sheet.save_png(out_path)
	print("sheet ", out_path, " ", sheet.get_size(), " (", imgs.size(), " images: ", ", ".join(names), ")")
	quit(0)
