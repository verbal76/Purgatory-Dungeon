extends SceneTree
## Process-level probe for tests/ota_e2e.sh: run with `godot --headless --main-pack <base.pck> --script <this file>`.
## Prints what the packaged game sees after the OTA client has done (or not done) its work.

func _initialize() -> void:
	var probe: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/ota_probe.json"))
	print("PROBE=%s" % (str((probe as Dictionary).get("probe", "?")) if probe is Dictionary else "?"))
	print("PROBE_NEW=%s" % str(FileAccess.file_exists("res://data/ota_probe_new.json")))
	print("OTA_STATUS=%s active=%d pending=%d known_good=%d rolled_back=%d reason=%s confirmed=%s" % [OtaIdentity.status_word(),
			OtaRuntime.active_seq, OtaRuntime.pending_seq, OtaRuntime.known_good_seq, OtaRuntime.rolled_back_seq,
			OtaRuntime.rolled_back_reason, str(OtaRuntime.confirmed)])
	print("FOOTER=%s" % BuildInfo.display_string())
	quit()
