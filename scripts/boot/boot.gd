# ==============================================================================
# File Name: boot.gd
# Path: res://scripts/boot/boot.gd
#
# Description:
#   NATIVE LAYER, autoload #1 `Boot` (docs/OTA.md section 7). Installed with the APK; an OTA
#   pack can never replace it (it and everything it preloads load before any pack is mounted).
#
#   Boot order:  APK starts -> Boot._init(): read the baked native identity, select + verify +
#   mount the OTA package -> the remaining autoloads and the main scene load from the mounted pack.
#
#   Also owns the boot-health checkpoint, the update client, the "Applying update" panel and
#   the diagnostics overlay (reachable even when the game layer is broken: F9, or five quick taps
#   in the top-left corner).
#
#   Inert (does nothing, never touches user://ota or the network) unless the export feature
#   `ota` is present, or, in NON-template builds only, the user arg `--ota-enable` is given.
#   PURGATORY_NO_OTA=1 or `--no-ota` switch everything off everywhere. Without a baked native
#   identity (no res://build_info.json commit + runtime fingerprint, e.g. an editor run) the client
#   stays in baseline mode: it never mounts or downloads anything.
#
#   Desktop test hooks (user args after `--`, NON-template builds only; ignored in any shipped build):
#     --ota-enable  --ota-root=DIR  --ota-pointer=URL (http://127.0.0.1 allowed)  --ota-platform=android
#     --ota-channel=X  --ota-action=rollback|disable|enable  --ota-quit-after-check  --ota-no-autocheck
#     --ota-pubkey=FILE (a PEM public key replacing the embedded one: runs with throw-away keys)
#
#   Offline first: nothing here waits for the network. The game starts from the newest verified
#   package already on the device (or the embedded baseline); checks run afterwards in the
#   background and any failure just leaves the current game running.
#
#   Game-layer scripts are never referenced from this directory (they would be cached before the
#   mount); the few game facts it needs (save schema) are read through load() after the mount.
# ==============================================================================
extends Node

const Config := preload("res://scripts/boot/ota_config.gd")
const OtaCore := preload("res://scripts/boot/ota_core.gd")
const OtaUpdater := preload("res://scripts/boot/ota_updater.gd")
const Overlay := preload("res://scripts/boot/diagnostics_overlay.gd")

## Emitted when anything the footer/diagnostics show changed (update staged, status, rollback ...).
signal status_changed

## report_ready() + this long running = boot healthy.
const HEALTHY_AFTER_MS := 5000
const HEALTHY_MIN_FRAMES := 30
## Automatic checks: once per launch (after boot health), on foreground return when the last attempt
## is at least AUTO_CHECK_MIN_GAP_S old, and every AUTO_CHECK_PERIOD_S while running.
const AUTO_CHECK_MIN_GAP_S := 15 * 60
const AUTO_CHECK_PERIOD_S := 60 * 60
const AUTO_CHECK_TICK_S := 60.0
const PANEL_MIN_MS := 800
const PANEL_MAX_MS := 20000
const TAPS_NEEDED := 5
const TAP_WINDOW_MS := 2500
## A touch tap also arrives as an emulated mouse click in the same instant: count it once.
const TAP_DEBOUNCE_MS := 80
const TAP_ZONE := Vector2(0.12, 0.16)
const SAVE_SCHEMA_PATH := "res://scripts/save_schema.gd"

## The OTA client is running (feature gate open, native identity valid). False = inert.
var ota_enabled := false
## Why the client is inert ("" while it runs).
var inert_reason := ""
var channel := ""
var platform := ""
var runtime_id := ""
var native_info: Dictionary = {}
var core: OtaCore
var updater: OtaUpdater
var healthy := false
## True in non-template builds, where the desktop test hooks are honoured.
var hooks_allowed := false

var _args: Dictionary = {}
var _ready_at_ms := -1
var _ready_frames := 0
var _last_auto_check_ms := -1
var _overlay: Overlay
var _tap_times: PackedInt64Array = PackedInt64Array([0, 0, 0, 0, 0])
var _tap_count := 0
var _last_tap_ms := -100000
var _panel: CanvasLayer
var _panel_since_ms := 0
var _tick: Timer
var _action_done := false


func _init() -> void:
	hooks_allowed = not OS.has_feature("template")
	var user_args: PackedStringArray = OS.get_cmdline_user_args()
	var no_ota: bool = OS.get_environment("PURGATORY_NO_OTA") == "1" \
			or "--no-ota" in user_args or "--no-ota" in OS.get_cmdline_args()
	if hooks_allowed:
		for a in user_args:
			if a.begins_with("--"):
				var kv: PackedStringArray = a.substr(2).split("=", true, 1)
				_args[kv[0]] = kv[1] if kv.size() == 2 else "true"
	platform = str(_args.get("ota-platform", "")) if hooks_allowed and _args.has("ota-platform") else OS.get_name().to_lower()
	runtime_id = Config.runtime_id(platform)
	native_info = Config.native_info()
	channel = str(native_info.get("ota_channel", Config.CHANNEL))
	if hooks_allowed and _args.has("ota-channel"):
		channel = str(_args["ota-channel"])
	if not Config.is_safe_channel(channel):
		channel = Config.CHANNEL
	inert_reason = _inert_reason(no_ota)
	if inert_reason != "":
		# Silent on desktop builds that never had a client; loud where one was expected.
		if no_ota or OS.has_feature(Config.FEATURE) or (hooks_allowed and _args.has("ota-enable")):
			print("[OTA] inactive: ", inert_reason)
		return
	var pem: String = Config.PUBLIC_KEY_PEM
	if hooks_allowed and _args.has("ota-pubkey") and FileAccess.file_exists(str(_args["ota-pubkey"])):
		pem = FileAccess.get_file_as_string(str(_args["ota-pubkey"]))   # end-to-end runs with a throw-away key
	core = OtaCore.new(str(_args.get("ota-root", "user://ota")) if hooks_allowed else "user://ota", runtime_id, channel,
			pem, Config.BOOTSTRAP_VERSION, str(native_info["runtime_fingerprint"]).to_lower(),
			str(native_info["commit"]).to_lower())
	core.save_root = native_save_root()
	var pointer: String = str(_args.get("ota-pointer", "")) if hooks_allowed else ""
	core.allow_local_http = hooks_allowed and pointer.begins_with("http://127.0.0.1:")
	ota_enabled = true
	var action: String = str(_args.get("ota-action", "")) if hooks_allowed else ""
	if action != "":
		# Scriptable equivalents of the recovery buttons (developer / end-to-end runs): change state, quit, mount nothing.
		match action:
			"rollback":
				var r: String = core.rollback()
				print("[OTA] action rollback: ", r if r != "" else "ok")
			"disable":
				core.set_disabled(true)
				print("[OTA] action disable: ok")
			"enable":
				core.set_disabled(false)
				print("[OTA] action enable: ok")
			_:
				print("[OTA] unknown action: ", action)
		_action_done = true
		return
	core.boot(func(path: String) -> bool: return ProjectSettings.load_resource_pack(path, true))
	for line in core.boot_log:
		print("[OTA] ", line)
	if core.restart_required:
		push_error("OTA: post-mount self-check failed; the update was blacklisted. Closing so the next launch runs clean.")
		(Engine.get_main_loop() as SceneTree).quit(0)


## "" when the client may run, else why it is inert. Order: explicit off, feature gate, identity.
func _inert_reason(no_ota: bool) -> String:
	if no_ota:
		return "disabled by --no-ota / PURGATORY_NO_OTA"
	if not (OS.has_feature(Config.FEATURE) or (hooks_allowed and _args.has("ota-enable"))):
		return "this build has no OTA client (export feature '%s' absent)" % Config.FEATURE
	var base: String = str(native_info.get("commit", "")).to_lower()
	var fp: String = str(native_info.get("runtime_fingerprint", "")).to_lower()
	if not _hex(base, 40):
		return "no native identity: res://build_info.json has no valid commit (not a CI-built APK); running the embedded baseline"
	if not _hex(fp, 64):
		return "no native identity: res://build_info.json has no runtime_fingerprint; running the embedded baseline"
	if str(native_info.get("runtime_id", "")) != runtime_id:
		return "native identity mismatch: build info says runtime '%s', the native layer is '%s'; running the embedded baseline" % [
				str(native_info.get("runtime_id", "")), runtime_id]
	return ""


static func _hex(s: String, n: int) -> bool:
	if s.length() != n:
		return false
	for c in s:
		if not "0123456789abcdef".contains(c):
			return false
	return true


## Where the save folder lives. A deliberate native MIRROR of StoragePaths.root() (a test keeps them equal):
## the native layer must not load game scripts before the pack is mounted.
static func native_save_root() -> String:
	var o: String = OS.get_environment("PURGATORY_SAVE_ROOT")
	if o != "":
		return o
	if OS.has_feature("mobile") or OS.get_environment("PURGATORY_FORCE_TOUCH") == "1" \
			or OS.has_feature("android") or OS.has_feature("ios"):
		return OS.get_user_data_dir().path_join("PurgetoryDungeon")
	var docs: String = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs == "":
		docs = OS.get_user_data_dir()
	return docs.path_join("PurgetoryDungeon")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if _action_done:
		get_tree().quit.call_deferred()
		return
	set_process(false)
	# The hidden recovery gesture (F9 / five corner taps) exists only where OTA can exist: an Android build
	# (feature `ota`), a running client, or a developer run. A shipped Windows build gets no input hook at all.
	set_process_input(ota_enabled or hooks_allowed or OS.has_feature(Config.FEATURE))
	if ota_enabled:
		updater = OtaUpdater.new()
		updater.core = core
		var ptr: String = str(_args.get("ota-pointer", "")) if hooks_allowed else ""
		updater.pointer_url = ptr if ptr != "" else Config.pointer_url(channel)
		updater.bundled_source_sha = core.base_source_sha
		updater.finished.connect(_on_update_finished)
		updater.status_changed.connect(_on_status_changed)
		add_child(updater)
		if core.first_run:
			_show_panel()


# --- boot health ---------------------------------------------------------------------------

## Called by the game layer once its entry scene and first menu are built. The run is healthy after it
## then keeps running for HEALTHY_AFTER_MS. An OTA whose game never calls this (or crashes first) is
## abandoned after OtaCore.MAX_UNHEALTHY_STARTS starts.
func report_ready() -> void:
	if _ready_at_ms < 0:
		_ready_at_ms = Time.get_ticks_msec()
		set_process(true)


func _process(_dt: float) -> void:
	var now: int = Time.get_ticks_msec()
	if _panel != null:
		var age: int = now - _panel_since_ms
		if age >= PANEL_MAX_MS or (_ready_at_ms >= 0 and age >= PANEL_MIN_MS):
			_hide_panel()
	if not healthy and _ready_at_ms >= 0:
		_ready_frames += 1
		if now - _ready_at_ms >= HEALTHY_AFTER_MS and _ready_frames >= HEALTHY_MIN_FRAMES:
			_become_healthy()
	if _panel == null and (healthy or _ready_at_ms < 0):
		set_process(false)


func _become_healthy() -> void:
	healthy = true
	if ota_enabled:
		core.running_save_schema = _game_save_schema()
		core.mark_healthy()
		print("[OTA] boot healthy: ", str(core.active.get("ota_id", "embedded baseline")))
		_tick = Timer.new()
		_tick.wait_time = AUTO_CHECK_TICK_S
		_tick.one_shot = false
		_tick.process_mode = Node.PROCESS_MODE_ALWAYS
		_tick.timeout.connect(_on_tick)
		add_child(_tick)
		_tick.start()
		auto_check("start")
	status_changed.emit()
	# Developer / end-to-end hook: report and quit when no check is running (disabled, --ota-no-autocheck, inert).
	if hooks_allowed and _args.has("ota-quit-after-check") and not (updater != null and updater.busy):
		print("OTA_IDENTITY_JSON " + JSON.stringify(identity()))
		get_tree().quit()


## SAVE_SCHEMA of the game that is mounted NOW (embedded or OTA); 0 when unreadable.
static func _game_save_schema() -> int:
	if not ResourceLoader.exists(SAVE_SCHEMA_PATH):
		return 0
	var s: Script = load(SAVE_SCHEMA_PATH)
	return int(s.get_script_constant_map().get("SAVE_SCHEMA", 0)) if s != null else 0


func _on_tick() -> void:
	auto_check("periodic")


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED or what == NOTIFICATION_APPLICATION_FOCUS_IN:
		auto_check("resume")


## Pure policy: may an automatic check for `reason` run now? "start" may once per launch (no earlier attempt);
## "resume" needs AUTO_CHECK_MIN_GAP_S since the last attempt and "periodic" AUTO_CHECK_PERIOD_S. Failed attempts
## count as attempts, so an offline device is not hammered.
static func auto_check_due(reason: String, now_ms: int, last_ms: int) -> bool:
	if reason == "start":
		return last_ms < 0
	if last_ms < 0:
		return false
	var gap: int = AUTO_CHECK_PERIOD_S if reason == "periodic" else AUTO_CHECK_MIN_GAP_S
	return now_ms - last_ms >= gap * 1000


## Starts a background check (and download of a verified update) if the policy allows it.
## Returns immediately; the result arrives through the updater's `finished` signal.
func auto_check(reason: String) -> bool:
	if not ota_enabled or not healthy or updater == null or updater.busy or bool(core.state["disabled"]):
		return false
	if _args.has("ota-no-autocheck"):
		return false
	var now: int = Time.get_ticks_msec()
	if not auto_check_due(reason, now, _last_auto_check_ms):
		return false
	_last_auto_check_ms = now
	print("[OTA] automatic check (%s)" % reason)
	updater.check(true)
	return true


func _on_status_changed() -> void:
	status_changed.emit()
	if _overlay != null and _overlay.visible:
		_overlay.refresh()


func _on_update_finished(result: String) -> void:
	print("[OTA] ", result)
	if result.contains("restart to run"):
		toast(result)
	if _args.has("ota-quit-after-check"):
		print("OTA_IDENTITY_JSON " + JSON.stringify(identity()))
		get_tree().quit()


# --- identity, status and diagnostics ----------------------------------------------------------

func native_version() -> String:
	return str(native_info.get("public_version", ProjectSettings.get_setting("application/config/version", "?")))


## Machine-readable snapshot (printed by --ota-quit-after-check for end-to-end runs). No secrets.
func identity() -> Dictionary:
	var act: Dictionary = core.active if ota_enabled else {}
	return {
		"ota_enabled": ota_enabled,
		"inert_reason": inert_reason,
		"native_version": native_version(),
		"runtime_id": runtime_id,
		"runtime_fingerprint": str(native_info.get("runtime_fingerprint", "")),
		"baseline_source_sha": str(native_info.get("commit", "")),
		"channel": channel,
		"active_ota_id": str(act.get("ota_id", "")),
		"active_seq": int(act.get("seq", 0)),
		"active_source_sha": str(act.get("source_sha", "")),
		"active_pck_sha256": str(act.get("pck_sha256", "")),
		"current": core.slot_id("current") if ota_enabled else "",
		"previous": core.slot_id("previous") if ota_enabled else "",
		"pending": core.slot_id("pending") if ota_enabled else "",
		"ready": core.slot_id("ready") if ota_enabled else "",
		"bad": (core.state["bad"] as Array).duplicate() if ota_enabled else [],
		"rollback_count": int(core.state["rollback_count"]) if ota_enabled else 0,
		"disabled": bool(core.state["disabled"]) if ota_enabled else false,
		"status": status_word(),
		"healthy": healthy,
	}


## " · update 3" when an OTA is running, plus the staged one waiting for a restart. "" when OTA is inert
## or the embedded baseline runs with nothing staged (the release footer must stay unchanged then).
func footer_suffix() -> String:
	if not ota_enabled:
		return ""
	var s := ""
	var act_seq: int = int(core.active.get("seq", 0))
	if act_seq > 0:
		s += " · update %d" % act_seq
	var pend: Dictionary = core.slot("pending")
	if not pend.is_empty() and int(pend.get("seq", 0)) != act_seq:
		s += " · restart to apply update %d" % int(pend.get("seq", 0))
	return s


## The update client's state as one word: unchecked | checking | offline | up_to_date | available | downloading |
## downloaded | incompatible | rejected | failed, or "inactive" when no client runs in this build/launch.
func status_word() -> String:
	if not ota_enabled:
		return "inactive"
	return updater.status if updater != null else "unchecked"


## One line that says whether the game is current. Never guesses: "Not checked yet" until a check completed.
func ota_status() -> String:
	if not ota_enabled:
		return "OTA is off: %s" % inert_reason
	if bool(core.state["disabled"]):
		return "OTA disabled: running the embedded baseline (Re-enable OTA to resume updates)"
	var pend: Dictionary = core.slot("pending")
	if not pend.is_empty() and pend.get("ota_id", "") != core.active.get("ota_id", ""):
		return "Update downloaded: %s runs after the app restarts" % pend["ota_id"]
	var rdy: Dictionary = core.slot("ready")
	if not rdy.is_empty():
		return "Update downloaded: %s (press Activate on restart)" % rdy["ota_id"]
	var st: String = updater.status if updater != null else "unchecked"
	var rid: String = str(updater.remote.get("ota_id", "?")) if updater != null else "?"
	match st:
		"checking":
			return "Checking the %s channel..." % channel
		"downloading":
			return "Downloading %s..." % rid
		"available":
			return "Update available: %s" % rid
		"up_to_date":
			return "Up to date"
		"offline":
			return "Offline: update channel not reachable; playing the current game"
		"incompatible":
			return "Incompatible: latest OTA %s cannot run on this app; playing the current game" % rid
		"rejected":
			return "Rejected: latest OTA %s was not accepted; playing the current game" % rid
		"failed":
			return "Update failed (%s); playing the current game" % updater.status_detail
		"downloaded":
			return "Update downloaded"
	return "Not checked yet"


func _slot_text(name: String) -> String:
	var m: Dictionary = core.slot(name)
	if m.is_empty():
		return "none"
	return "%s (game %s, source %s)" % [str(m.get("ota_id", "?")), str(m.get("game_version", "?")), str(m.get("source_sha", "")).left(12)]


func _event_text(kind: String) -> String:
	var e: Dictionary = (core.state["events"] as Dictionary).get(kind, {})
	if e.is_empty():
		return "none"
	return "%s  %s" % [str(e.get("result", "")), str(e.get("time", ""))]


func _compat_text() -> String:
	var c: String = updater.latest_compat if updater != null else ""
	if c == "":
		return "not checked yet"
	return "compatible" if c == "compatible" else "NOT compatible: " + c


## Alias of diagnostics_text() (docs/OTA.md section 10 calls it Boot.diagnostics()).
func diagnostics() -> String:
	return diagnostics_text()


func diagnostics_text() -> String:
	var L: Array[String] = []
	L.append("PURGATORY DUNGEON OTA DIAGNOSTICS")
	L.append("")
	L.append("Native")
	L.append("  Version: %s" % native_version())
	L.append("  Godot: %s" % Config.engine_version())
	L.append("  Platform: %s" % platform)
	L.append("  Bootstrap: v%d" % Config.BOOTSTRAP_VERSION)
	L.append("  Runtime: %s" % runtime_id)
	L.append("  Runtime fingerprint: %s" % str(native_info.get("runtime_fingerprint", "none")))
	L.append("  Embedded baseline source: %s" % str(native_info.get("commit", "none")))
	L.append("")
	L.append("OTA")
	L.append("  Client: %s" % ("on" if ota_enabled else "off"))
	L.append("  Channel: %s" % (channel if ota_enabled else "none"))
	L.append("  Status: %s" % ota_status())
	if not ota_enabled:
		L.append("  Reason: %s" % inert_reason)
		L.append("  Running: embedded baseline")
		L.append("  This run healthy: %s" % ("yes" if healthy else "not yet"))
		return "\n".join(L)
	var act: Dictionary = core.active
	L.append("  Running: %s" % (("OTA %s (seq %d, source %s)" % [str(act["ota_id"]), int(act.get("seq", 0)), str(act.get("source_sha", "")).left(12)]) if not act.is_empty() else "embedded baseline"))
	if not act.is_empty():
		L.append("  Running package SHA-256: %s" % str(act.get("pck_sha256", "")))
	L.append("  Latest on channel: %s" % (("%s (checked %s)" % [str(updater.remote.get("ota_id", "?")), updater.checked_at]) if updater != null and not updater.remote.is_empty() else "not checked yet"))
	L.append("  Latest OTA compatibility: %s" % _compat_text())
	L.append("  Pending (runs after restart): %s" % _slot_text("pending"))
	L.append("  Downloaded, not activated: %s" % _slot_text("ready"))
	L.append("  Current (known good): %s" % _slot_text("current"))
	L.append("  Previous (known good): %s" % _slot_text("previous"))
	L.append("  Last check: %s" % _event_text("check"))
	for k in [["download", "Last download"], ["verify", "Last verification"], ["load", "Last load"], ["health", "Boot health"], ["rollback", "Last rollback"], ["rejected", "Last rejection"], ["backup", "Last save backup"]]:
		L.append("  %s: %s" % [k[1], _event_text(k[0])])
	L.append("  This run healthy: %s" % ("yes" if healthy else "not yet"))
	L.append("  Rollback count: %d" % int(core.state["rollback_count"]))
	L.append("  OTA disabled (baseline mode): %s" % ("yes" if bool(core.state["disabled"]) else "no"))
	var bad: Array = core.state["bad"]
	L.append("  Rejected OTAs: %s" % (", ".join(PackedStringArray(bad)) if not bad.is_empty() else "none"))
	L.append("  Save schema: device %d, running game %d" % [core.device_save_schema, core.running_save_schema])
	L.append("")
	L.append("Recent events (this launch)")
	var start: int = maxi(0, core.boot_log.size() - 12)
	for i in range(start, core.boot_log.size()):
		L.append("  " + core.boot_log[i])
	if core.boot_log.is_empty():
		L.append("  none")
	return "\n".join(L)


# --- "Applying update" panel ---------------------------------------------------------------------

## A restrained dark scrim with one line of text, built in code: no game-layer fonts, theme or scripts.
func _show_panel() -> void:
	_panel = CanvasLayer.new()
	_panel.layer = 127
	_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	var scrim: ColorRect = ColorRect.new()
	scrim.color = Color(0.035, 0.03, 0.03, 0.96)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(scrim)
	var label: Label = Label.new()
	label.text = "Applying update"
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 30)
	label.add_theme_color_override("font_color", Color(0.85, 0.8, 0.72))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(label)
	add_child(_panel)
	_panel_since_ms = Time.get_ticks_msec()
	set_process(true)


func _hide_panel() -> void:
	if _panel != null:
		_panel.queue_free()
		_panel = null


## True while the "Applying update" panel is up (tests).
func panel_visible() -> bool:
	return _panel != null


# --- diagnostics overlay ---------------------------------------------------------------------------

func show_diagnostics() -> void:
	if _overlay == null:
		_overlay = Overlay.new()
		_overlay.boot = self
		add_child(_overlay)
	_overlay.open()


## F9 and the corner gesture toggle the overlay.
func toggle_diagnostics() -> void:
	if _overlay != null and _overlay.is_open():
		_overlay.close()
	else:
		show_diagnostics()


func toast(msg: String) -> void:
	if _overlay == null:
		_overlay = Overlay.new()
		_overlay.boot = self
		add_child(_overlay)
	_overlay.toast(msg)


## Pure tap detector for the hidden gesture: five quick taps in the top-left corner. Touch and its emulated
## mouse click arrive together and count once. Returns true on the tap that completes the gesture.
func register_tap(pos: Vector2, viewport_size: Vector2, now_ms: int) -> bool:
	if pos.x < 0.0 or pos.y < 0.0 or pos.x > viewport_size.x * TAP_ZONE.x or pos.y > viewport_size.y * TAP_ZONE.y:
		return false
	if now_ms - _last_tap_ms < TAP_DEBOUNCE_MS:
		return false
	_last_tap_ms = now_ms
	# Ring of the last TAPS_NEEDED taps: no allocation per tap.
	_tap_times[_tap_count % TAPS_NEEDED] = now_ms
	_tap_count += 1
	if _tap_count >= TAPS_NEEDED:
		var oldest: int = _tap_times[_tap_count % TAPS_NEEDED]
		if now_ms - oldest <= TAP_WINDOW_MS:
			_tap_count = 0
			return true
	return false


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k: InputEventKey = event
		if k.pressed and not k.echo and k.keycode == KEY_F9:
			toggle_diagnostics()
		return
	var pos: Vector2 = Vector2(-1.0, -1.0)
	if event is InputEventScreenTouch:
		var t: InputEventScreenTouch = event
		if t.pressed:
			pos = t.position
	elif event is InputEventMouseButton:
		var b: InputEventMouseButton = event
		if b.pressed and b.button_index == MOUSE_BUTTON_LEFT:
			pos = b.position
	if pos.x < 0.0:
		return
	if register_tap(pos, get_viewport().get_visible_rect().size, Time.get_ticks_msec()):
		toggle_diagnostics()
