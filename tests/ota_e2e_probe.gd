extends SceneTree
## Process-level probe for tests/ota_e2e.py: run with
##   godot --headless --main-pack <base.pck> --script tests/ota_e2e_probe.gd -- <mode>
## Modes:  plain    just report what the packaged game sees (a launch that never reaches a healthy menu)
##         check    run one OTA channel check (what the updater does from the main menu), then report
##         confirm  report, then mark the running update healthy (what OtaBoot does after the menu has been up 10 s)
## It prints KEY=value lines that the test parses. It never ships (tests/ is not exported).

func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var mode: String = args[0] if args.size() > 0 else "plain"
	# Let the tree finish starting: HTTPRequest only works for nodes that are inside a running tree.
	await process_frame
	await process_frame
	if mode == "check":
		var up: Node = root.get_node_or_null("OtaUpdater")
		if up != null:
			await up.check_now()
	var raw: String = FileAccess.get_file_as_string("res://data/ota_probe.json").replace("\n", " ").strip_edges()
	print("PROBE_RAW=%s" % raw)
	print("PROBE_PATCHED=%s" % str("ota_self_test" in raw))
	print("OTA_STATUS=%s active=%d pending=%d known_good=%d rolled_back=%d reason=%s confirmed=%s last_error=%s" % [OtaIdentity.status_word(),
			OtaRuntime.active_seq, OtaRuntime.pending_seq, OtaRuntime.known_good_seq, OtaRuntime.rolled_back_seq,
			OtaRuntime.rolled_back_reason, str(OtaRuntime.confirmed), OtaRuntime.last_error])
	print("FOOTER=%s" % BuildInfo.display_string())
	if mode == "confirm":
		OtaCore.confirm_health(OtaStore.root())
		print("CONFIRMED=%s" % str(OtaRuntime.confirmed))
	quit()
