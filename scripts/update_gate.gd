# ==============================================================================
# File Name: update_gate.gd
# Path: res://scripts/update_gate.gd
#
# Description:
#   Automatic update at cold launch (game layer). It drives the EXISTING native OTA client (autoload `Boot`, docs/OTA.md)
#   through its public API only: check_now() (the very same pipeline as the automatic and manual checks: pointer ->
#   signed manifest -> signature / runtime / save-schema checks -> download -> size + SHA-256 -> stage as PENDING), plus
#   update_state() and status_snapshot(). Nothing here talks to the network, mounts a package or touches the OTA store.
#
#   Flow (the Hot Attic Games card is untouched; this only runs after it, as the start-up hand-off):
#     splash starts            -> start(): the check begins at once, in the background, while the card plays
#     card ends                -> settle():
#         no update / offline / incompatible / rejected / slow check -> carry on to the menu (a check that is still
#                                running after CHECK_WAIT_SECONDS simply continues in the background)
#         an update was found  -> "Downloading update..." (bounded by DOWNLOAD_WAIT_SECONDS)
#         verified and staged  -> "Applying update... <version>" then a restart. The native layer mounts a staged package
#                                 at the next cold start (never mid-run), so the app restarts itself (OS restart-on-exit
#                                 where the platform supports it; otherwise it closes and the text says to open it again).
#     Failure of any kind falls back to the installed game; start-up is never blocked for longer than the caps above.
#
#   Loop guard: the OTA id we restarted for is remembered in user://update_gate.json; if it is still staged afterwards
#   (the mount was refused), the next launch shows "Update ready: restart to apply" and carries on instead of restarting
#   again.
# ==============================================================================
extends Node

const CHECK_WAIT_SECONDS : float = 3.0
const DOWNLOAD_WAIT_SECONDS : float = 30.0
const APPLY_SHOW_SECONDS : float = 2.2
const NOTICE_SECONDS : float = 2.5
const MARKER_PATH : String = "user://update_gate.json"
const BACKGROUND : Color = Color(0.035, 0.03, 0.03, 1.0)

signal restart_requested(ota_id: String)

## The native client (autoload Boot). Tests inject a stand-in with the same few members.
var boot : Node = null
## Replaces the real restart in tests.
var restart_fn : Callable = Callable()
## Test hook: a clock in seconds (real time otherwise) and the per-wait frame step.
var clock_fn : Callable = Callable()

var started : bool = false
var check_result : String = ""
var check_finished : bool = false
var caption_text : String = ""   # what the player is being told right now ("" = nothing shown)
var restart_issued : bool = false
var marker_path : String = MARKER_PATH

var _layer : CanvasLayer = null
var _label : Label = null


## Begins the check now (non-blocking). False when there is no running client (desktop, editor, OTA off).
func start(p_boot: Node = null) -> bool:
	boot = p_boot if p_boot != null else get_node_or_null("/root/Boot")
	if boot == null or not bool(boot.get("ota_enabled")) or not boot.has_method("check_now"):
		return false
	started = true
	_run_check()
	return true


func _run_check() -> void:
	check_result = str(await boot.check_now())
	check_finished = true


func _now() -> float:
	return float(clock_fn.call()) if clock_fn.is_valid() else Time.get_ticks_msec() / 1000.0


func _state() -> String:
	return str(boot.call("update_state")) if boot != null and boot.has_method("update_state") else "inactive"


func _staged_id() -> String:
	if boot == null or not boot.has_method("status_snapshot"):
		return ""
	var snap : Variant = boot.call("status_snapshot")
	return str((snap as Dictionary).get("staged_ota_id", "")) if snap is Dictionary else ""


## Waits for the check as long as the caps allow, tells the player what is happening, and either restarts (never returns
## then) or returns so start-up can go on. `host` is the node the caption hangs under.
func settle(host: Node) -> void:
	if not started:
		return
	var t0 : float = _now()
	# 1. a check that has not finished: give it a short moment (offline resolves in well under this; a stalled network does not hold the player)
	while not check_finished and _state() == "checking" and _now() - t0 < CHECK_WAIT_SECONDS:
		await _frame(host)
	# 2. an update was found: it is small, wait for it while saying so
	var t1 : float = _now()
	if not check_finished and _state() == "downloading":
		_show(host, "Downloading update...")
		while not check_finished and _now() - t1 < DOWNLOAD_WAIT_SECONDS:
			await _frame(host)
	# 3. verified and staged?
	var staged : String = _staged_id()
	if check_finished and _state() == "pending_restart" and staged != "":
		var version : String = str((boot.call("status_snapshot") as Dictionary).get("staged_version", ""))
		if _marker_id() == staged:
			# We already restarted for this update and it did not take: do not loop. Say so once and carry on.
			_show(host, "Update ready: restart Purgatory to apply it")
			await _wait(host, NOTICE_SECONDS)
		else:
			_show(host, "Applying update%s...\nPurgatory restarts to finish. If it closes, open it again." % ((" v" + version) if version != "" else ""))
			await _wait(host, APPLY_SHOW_SECONDS)
			_write_marker(staged)
			restart_issued = true
			restart_requested.emit(staged)
			_restart()
			return
	elif check_finished and _state() == "up_to_date":
		_clear_marker()
	_hide()


func _frame(host: Node) -> void:
	if host != null and host.is_inside_tree():
		await host.get_tree().process_frame
	else:
		await get_tree().process_frame


func _wait(host: Node, seconds: float) -> void:
	var t : float = _now()
	while _now() - t < seconds:
		await _frame(host)


func _restart() -> void:
	if restart_fn.is_valid():
		restart_fn.call()
		return
	# Ask the engine to start the app again as it exits; where the platform cannot, it simply closes and the caption said so.
	OS.set_restart_on_exit(true, OS.get_cmdline_args())
	get_tree().quit()


# ── marker ──────────────────────────────────────────────────────────────────────

func _marker_id() -> String:
	if not FileAccess.file_exists(marker_path):
		return ""
	var v : Variant = JSON.parse_string(FileAccess.get_file_as_string(marker_path))
	return str((v as Dictionary).get("restarted_for", "")) if v is Dictionary else ""


func _write_marker(ota_id: String) -> void:
	var f := FileAccess.open(marker_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"restarted_for": ota_id}))
		f.close()


func _clear_marker() -> void:
	if FileAccess.file_exists(marker_path):
		DirAccess.remove_absolute(marker_path)


# ── the caption (only built when there is something to say) ──────────────────────────────

func _show(host: Node, text: String) -> void:
	caption_text = text
	if _layer == null:
		var parent : Node = host if host != null and host.is_inside_tree() else self
		if not parent.is_inside_tree():
			return
		_layer = CanvasLayer.new()
		_layer.name = "UpdateCaption"
		_layer.layer = 100
		var bg := ColorRect.new()
		bg.color = BACKGROUND
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_layer.add_child(bg)
		_label = Label.new()
		_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		PUI.apply_role(_label, "card_title")
		_layer.add_child(_label)
		parent.add_child(_layer)
	if _label != null:
		_label.text = text


func _hide() -> void:
	caption_text = ""
	if _layer != null:
		_layer.queue_free()
		_layer = null
		_label = null
