extends SceneTree
## Process-level probe for tests/ota_e2e.py. Run with the REAL packaged game (docs/OTA.md section 7 contract):
##   godot --headless --main-pack <base.pck> --script tests/ota_e2e_probe.gd -- <mode> [seconds] --ota-enable --ota-root=DIR ...
## Autoload #1 `Boot` has already done its cold start (choose PENDING/CURRENT/PREVIOUS, verify, count the start, mount) when
## this runs, so what the probe sees is exactly what the game would see.
## Modes:  plain        report what the packaged game sees, then quit (a launch that never reaches a healthy menu)
##         stay N       tell Boot the game is ready (what the main menu does), keep running N real seconds
##                      (>= 7 lets "ready + 5 s" promote a pending OTA), report, quit
## It prints KEY=value lines that the driver parses; it never ships (tests/ is not exported).

func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var mode: String = args[0] if args.size() > 0 else "plain"
	var secs: float = float(args[1]) if args.size() > 1 and args[1].is_valid_float() else 8.0
	await process_frame
	await process_frame
	var boot: Node = root.get_node_or_null("Boot")
	print("PROBE_BOOT=%s" % ("present" if boot != null else "absent"))
	if mode == "stay":
		if boot != null and boot.has_method("report_ready"):
			boot.call("report_ready")
		var end_ms: int = Time.get_ticks_msec() + int(secs * 1000.0)
		while Time.get_ticks_msec() < end_ms:
			await process_frame
	var raw: String = FileAccess.get_file_as_string("res://data/ota_probe.json").replace("\n", " ").strip_edges()
	print("PROBE_RAW=%s" % raw)
	print("PROBE_PATCHED=%s" % str("ota_self_test" in raw))
	var variant: int = 0
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/ota_probe.json"))
	if parsed is Dictionary:
		variant = int((parsed as Dictionary).get("variant", 0))
	print("PROBE_VARIANT=%d" % variant)
	print("PROBE_FOOTER=%s" % BuildInfo.display_string())
	if boot != null and boot.has_method("diagnostics"):
		print("PROBE_DIAG=%s" % str(boot.call("diagnostics")).replace("\n", " | "))
	quit()
