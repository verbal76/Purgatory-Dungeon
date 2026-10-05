# ==============================================================================
# File Name: ota_updater.gd
# Path: res://scripts/ota/ota_updater.gd
#
# Description:
#   Autoload (last in project.godot). While the player sits in the main menu it checks the configured
#   channel, downloads a newer update for THIS native build, verifies it completely and stages it as
#   "pending". It never mounts anything and never changes the running game: a staged update is applied by
#   OtaBoot at the next launch. With no channel configured (ota_channel.json) or no trust anchor it does
#   nothing and makes no network request.
#
#   Network failures, bad signatures, wrong builds, short downloads: all end with the staging folder
#   deleted and the installed game untouched; the reason lands in state.json / diagnostics.
# ==============================================================================
extends Node

const MAIN_MENU_SCENE := "res://scenes/MainMenu.tscn"

signal status_changed

var _busy: bool = false
var _waited: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(OtaRuntime.enabled and OtaRuntime.channel_configured)


func _process(delta: float) -> void:
	var scene: Node = get_tree().current_scene
	if _busy or scene == null or scene.scene_file_path != MAIN_MENU_SCENE:
		_waited = 0.0
		return
	_waited += delta
	if _waited < OtaConst.CHECK_DELAY_SEC:
		return
	set_process(false)
	var st: Dictionary = OtaStore.load_state(OtaStore.root())
	if int(Time.get_unix_time_from_system()) - int(st["last_check_utc"]) < OtaConst.CHECK_INTERVAL_SEC \
			and OS.get_environment(OtaConst.ENV_CHANNEL) == "":
		return
	check_now()


## GET `url` into memory (<= max_bytes). Returns {ok, body}.
func _get_bytes(url: String, max_bytes: int) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = OtaConst.HTTP_TIMEOUT_SEC
	req.body_size_limit = max_bytes
	add_child(req)
	var err: int = req.request(url)
	if err != OK:
		req.queue_free()
		return {"ok": false, "body": PackedByteArray(), "why": "request error %d" % err}
	var res: Array = await req.request_completed
	req.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS or int(res[1]) != 200:
		return {"ok": false, "body": PackedByteArray(), "why": "HTTP result %d status %d" % [int(res[0]), int(res[1])]}
	return {"ok": true, "body": res[3] as PackedByteArray, "why": ""}


## GET `url` straight to a file (large payloads). Returns "" or the reason.
func _download_file(url: String, dest: String, max_bytes: int) -> String:
	var req := HTTPRequest.new()
	req.timeout = 600.0
	req.body_size_limit = max_bytes
	req.download_file = dest
	add_child(req)
	var err: int = req.request(url)
	if err != OK:
		req.queue_free()
		return "request error %d" % err
	var res: Array = await req.request_completed
	req.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS or int(res[1]) != 200:
		return "HTTP result %d status %d" % [int(res[0]), int(res[1])]
	return ""


## One full check: channel -> manifest -> payload -> verify -> stage. Never throws; records the outcome.
func check_now() -> void:
	if _busy or not OtaRuntime.enabled:
		return
	_busy = true
	var root_dir: String = OtaStore.root()
	var st: Dictionary = OtaStore.load_state(root_dir)
	st["last_check_utc"] = int(Time.get_unix_time_from_system())
	OtaRuntime.last_check_utc = int(st["last_check_utc"])
	var why: String = await _check_and_stage(root_dir, st)
	st = OtaStore.load_state(root_dir)   # _check_and_stage may have saved progress
	st["last_check_utc"] = OtaRuntime.last_check_utc
	st["last_error"] = why
	OtaRuntime.last_error = why
	OtaStore.save_state(root_dir, st)
	OtaStore.clean_staging(root_dir)
	_busy = false
	status_changed.emit()


func _check_and_stage(root_dir: String, st: Dictionary) -> String:
	var base_url: String = OtaIdentity.channel_url()
	if base_url == "":
		return ""
	var identity: Dictionary = OtaIdentity.current()
	var pem: String = OtaIdentity.trust_pem()
	var ch: Dictionary = await _get_bytes(base_url + "channel.json", OtaConst.MAX_META_BYTES)
	if not bool(ch["ok"]):
		return "channel unreachable (%s)" % str(ch["why"])
	var chsig: Dictionary = await _get_bytes(base_url + "channel.json.sig", OtaConst.MAX_META_BYTES)
	if not bool(chsig["ok"]):
		return "channel signature unreachable (%s)" % str(chsig["why"])
	if not OtaCrypto.verify(ch["body"], (chsig["body"] as PackedByteArray).get_string_from_utf8(), pem):
		return "channel signature invalid (ignored)"
	var plan_r: Dictionary = OtaCore.plan(OtaManifest.parse(ch["body"]), identity, st)
	if plan_r.has("error"):
		return str(plan_r["error"])
	# Record the new generation and any revocations first: the kill switch must work even if no download follows.
	st["generation"] = int(plan_r["generation"])
	var rv: Array = st["revoked"]
	for r in plan_r["revoked"]:
		if not rv.has(r):
			rv.append(r)
	st["revoked"] = rv
	OtaStore.save_state(root_dir, st)
	var entry: Dictionary = plan_r["entry"]
	if entry.is_empty():
		return ""
	var seq: int = int(entry["seq"])

	var stage: String = OtaStore.staging_dir(root_dir)
	OtaStore.remove_tree(stage)
	DirAccess.make_dir_recursive_absolute(stage)
	var mpath: String = str(entry.get("manifest", ""))
	var spath: String = str(entry.get("signature", ""))
	var ppath: String = str(entry.get("payload", ""))
	for p in [mpath, spath, ppath]:
		if p == "" or p.begins_with("/") or p.contains("..") or p.contains(":"):
			return "channel entry has an unsafe path"
	var man: Dictionary = await _get_bytes(base_url + mpath, OtaConst.MAX_META_BYTES)
	var sig: Dictionary = await _get_bytes(base_url + spath, OtaConst.MAX_META_BYTES)
	if not bool(man["ok"]) or not bool(sig["ok"]):
		return "update %d manifest download failed" % seq
	var mbytes: PackedByteArray = man["body"]
	var sigtxt: String = (sig["body"] as PackedByteArray).get_string_from_utf8()
	if not OtaCrypto.verify(mbytes, sigtxt, pem):
		return "update %d manifest signature invalid" % seq
	var m: Dictionary = OtaManifest.parse(mbytes)
	var cwhy: String = OtaManifest.check(m, identity)
	if cwhy != "":
		return "update %d not applicable: %s" % [seq, cwhy]
	if int(m.get("payload_seq", 0)) != seq:
		return "update %d manifest number mismatch" % seq
	var size: int = int((m["payload"] as Dictionary)["size"])
	var dl: String = await _download_file(base_url + ppath, stage.path_join("payload.pck"), size + 1024)
	if dl != "":
		return "update %d download failed (%s)" % [seq, dl]
	# Stage exactly what will be verified at boot, then run the same verification.
	OtaStore.write_text_atomic(stage.path_join("manifest.json"), mbytes.get_string_from_utf8())
	OtaStore.write_text_atomic(stage.path_join("manifest.sig"), sigtxt)
	var slot: String = OtaStore.slot_dir(root_dir, seq)
	OtaStore.remove_tree(slot)
	DirAccess.make_dir_recursive_absolute(root_dir.path_join("slots"))
	if DirAccess.rename_absolute(stage, slot) != OK:
		return "update %d could not be staged" % seq
	var vwhy: String = OtaVerify.verify_slot(root_dir, seq, identity, pem)
	if vwhy != "":
		OtaStore.remove_tree(slot)
		return "update %d rejected after download: %s" % [seq, vwhy]
	st = OtaStore.load_state(root_dir)
	st["pending"] = seq
	OtaStore.note(st, "update %d downloaded and verified" % seq)
	OtaStore.save_state(root_dir, st)
	OtaRuntime.pending_seq = seq
	return ""
