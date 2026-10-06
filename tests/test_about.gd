extends Node
## Options > About (scripts/about_info.gd + the About tab in scripts/options_screen.gd).
##   - AboutInfo's status model for every update state (mocked snapshots: no OTA / desktop, current, running OTA, pending,
##     error flavours, checking), the short fingerprint, the developer tap counter
##   - the tab itself: tab order (About is last: 5th on a phone, where there is no Controls tab), content per state,
##     Check for updates goes through the native client's check_now() (a stub stands in for Boot), double presses are
##     ignored, progress and result texts, friendly failure text, the desktop "delivered through the Android app" state
##   - Copy diagnostics: expected fields, nothing that looks like key material or a token
##   - no network code in the options screen or AboutInfo
##   - developer tools hidden by default, unlocked by the version tap gesture, performance readout not a player option
## Runs on desktop and (PURGATORY_FORCE_TOUCH=1) as a phone; must run with PURGATORY_SAVE_ROOT set (run_tests.sh does).

const FP := "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

var _fails := 0
var _checks := 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


## Stands in for the Boot autoload: same methods and signal as the real client, scripted outcomes, call counters.
class StubBoot extends Node:
	signal status_changed
	var snap: Dictionary = {}
	var check_calls := 0
	var diag_calls := 0
	var script_states: Array = []     # states check_now() walks through, one per step
	var step_delay := 0.05

	func status_snapshot() -> Dictionary:
		return snap.duplicate(true)

	func can_check_now() -> bool:
		return str(snap.get("state", "")) not in ["checking", "downloading", "inactive", "disabled"]

	func check_now() -> String:
		check_calls += 1
		for st in script_states:
			snap["state"] = st
			status_changed.emit()
			await get_tree().create_timer(step_delay).timeout
		return str(snap["state"])

	func diagnostics_text() -> String:
		return "Update client log\n  Last check: ok"

	func show_diagnostics() -> void:
		diag_calls += 1


static func snap(over: Dictionary = {}) -> Dictionary:
	var s: Dictionary = {
		"client": true, "inert_reason": "", "state": "up_to_date", "busy": false, "native_version": "7", "running_version": "7.2",
		"app_minor": 2, "ota_id": "dev-000002", "ota_seq": 2, "staged_version": "", "staged_ota_id": "", "latest_ota_id": "dev-000002",
		"checked_at": "2026-10-06T10:00:00Z", "runtime_id": "android-godot-4.6.0-r2", "runtime_fingerprint": FP, "channel": "dev",
		"engine": "4.6.0", "platform": "android", "bootstrap": 1, "baseline_source": "0123456789abcdef0123456789abcdef01234567",
		"healthy": true, "rollback_count": 0, "disabled": false, "rejected": [], "last_error": "",
	}
	s.merge(over, true)
	return s


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	_t_model()
	_t_pure_helpers()
	_t_no_network_code()
	await _t_tab_structure()
	await _t_tab_states()
	await _t_check_flow()
	await _t_desktop_real_boot()
	await _t_diagnostics()
	await _t_developer_tools()
	print("test_about: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


# --- the pure status model ---------------------------------------------------------------------------------------

func _t_model() -> void:
	# No OTA client on a desktop build.
	var desktop: Dictionary = AboutInfo.build_model(snap({"client": false, "state": "inactive", "platform": "windows", "channel": "",
			"ota_id": "", "ota_seq": 0, "running_version": "7", "runtime_id": "", "runtime_fingerprint": ""}))
	_check(desktop["status"]["text"] == "Updates are delivered through the Android app.", "desktop: calm Android-app note (%s)" % desktop["status"]["text"])
	_check(desktop["status"]["kind"] == AboutInfo.KIND_INFO and not desktop["can_check"], "desktop: informational, Check disabled")
	_check(_row(desktop, "update") == "None (original v7)", "desktop: no OTA row text (%s)" % _row(desktop, "update"))
	_check(_row(desktop, "version") == "Purgatory Dungeon v7" and _row(desktop, "app") == "v7", "desktop: version rows")
	# An Android build whose client is off (not a CI-built APK).
	var inert_android: Dictionary = AboutInfo.build_model(snap({"client": false, "state": "inactive", "platform": "android"}))
	_check(inert_android["status"]["text"] == "Updates are not available in this build." and not inert_android["can_check"], "android without a client: not available, no check")

	# Current (running OTA 7.2, up to date).
	var cur: Dictionary = AboutInfo.build_model(snap())
	_check(cur["status"]["text"] == "You are up to date" and cur["status"]["kind"] == AboutInfo.KIND_OK and cur["can_check"], "current: up to date, check allowed")
	_check(_row(cur, "update") == "v7.2 (OTA #000002)", "current: OTA label (%s)" % _row(cur, "update"))
	_check(_row(cur, "version") == "Purgatory Dungeon v7.2" and _row(cur, "app") == "v7", "current: game 7.2 on app v7")
	_check(cur["title"] == "Purgatory Dungeon v7.2", "current: title")
	_check(_tech(cur, "runtime") == "android-godot-4.6.0-r2" and _tech(cur, "channel") == "dev", "current: runtime and channel")
	_check(_tech(cur, "fingerprint") == "abcdef012345…" and not _tech(cur, "fingerprint").contains(FP), "current: fingerprint shortened (%s)" % _tech(cur, "fingerprint"))
	_check(_tech(cur, "engine") == "Godot 4.6.0" and _tech(cur, "platform") == "android", "current: engine and platform")
	_check(not cur["rows"].any(func(r: Dictionary) -> bool: return r["key"] == "staged"), "current: no 'waiting to start' row")

	# Baseline (no OTA applied, client on).
	var base: Dictionary = AboutInfo.build_model(snap({"state": "unchecked", "ota_id": "", "ota_seq": 0, "running_version": "7", "app_minor": 0}))
	_check(_row(base, "update") == "None (original v7)" and base["status"]["text"] == "Not checked yet", "baseline: no OTA, not checked yet")

	# Pending: an update is staged, restart to apply.
	var pend: Dictionary = AboutInfo.build_model(snap({"state": "pending_restart", "staged_version": "7.3", "staged_ota_id": "dev-000003"}))
	_check(pend["status"]["text"] == "Update ready — restart to apply" and pend["status"]["kind"] == AboutInfo.KIND_WARN, "pending: restart to apply")
	_check(str(pend["status"].get("detail", "")).contains("7.3"), "pending: names the staged version")
	_check(_row(pend, "staged") == "v7.3 (restart to apply)" and _row(pend, "update") == "v7.2 (OTA #000002)", "pending: staged row, running row unchanged")
	_check(pend["can_check"], "pending: checking again is allowed")

	# Transient.
	var chk: Dictionary = AboutInfo.build_model(snap({"state": "checking"}))
	_check(chk["status"]["text"] == "Checking for updates…" and not chk["can_check"] and chk["check_label"] == "Checking…", "checking: text, button locked")
	var dl: Dictionary = AboutInfo.build_model(snap({"state": "downloading"}))
	_check(dl["status"]["text"] == "Update available — downloading…" and not dl["can_check"], "downloading: text, button locked")
	var local: Dictionary = AboutInfo.build_model(snap(), true)
	_check(local["state"] == "checking" and not local["can_check"], "a check this screen started locks the button before the client reports it")

	# Errors: friendly text, no technical words, and the raw reason stays out of the player text.
	var errs: Dictionary = {
		"offline": "Can't reach the update server. Check your connection and try again.",
		"rejected": "The update could not be verified, so it was not installed. Your game is unchanged.",
		"failed": "The update could not be completed. Please try again later.",
		"incompatible": "A newer update is available, but it needs a newer version of the app.",
	}
	for st in errs.keys():
		var m: Dictionary = AboutInfo.build_model(snap({"state": st, "last_error": "HTTP 503 at https://example.invalid/x (stack: res://boot.gd:12)"}))
		_check(m["status"]["text"] == errs[st], "%s: friendly text (%s)" % [st, m["status"]["text"]])
		var all_text: String = str(m["status"]["text"]) + str(m["status"].get("detail", ""))
		for bad in ["HTTP", "res://", "stack", "error", "Exception", "signature", "SHA"]:
			_check(not all_text.contains(bad), "%s: player text has no '%s'" % [st, bad])
		_check(m["can_check"], "%s: the player may try again" % st)
	var dis: Dictionary = AboutInfo.build_model(snap({"state": "disabled", "disabled": true}))
	_check(dis["status"]["text"] == "Updates are paused on this device." and not dis["can_check"], "disabled: paused, no check")
	var down2: Dictionary = AboutInfo.build_model(snap({"state": "downloaded"}))
	_check(down2["status"]["text"] == "Update downloaded" and str(down2["status"]["detail"]) != "", "downloaded-not-staged: honest, no restart promise")
	_check(not str(down2["status"]).contains("restart"), "downloaded-not-staged never says restart")


func _row(model: Dictionary, key: String) -> String:
	for r in model["rows"]:
		if r["key"] == key:
			return r["value"]
	return "<missing %s>" % key


func _tech(model: Dictionary, key: String) -> String:
	for r in model["tech"]:
		if r["key"] == key:
			return r["value"]
	return "<missing %s>" % key


func _t_pure_helpers() -> void:
	_check(AboutInfo.short_fingerprint(FP) == "abcdef012345…", "short_fingerprint keeps 12 digits")
	_check(AboutInfo.short_fingerprint("") == "none" and AboutInfo.short_fingerprint("abc") == "abc", "short_fingerprint tolerates empty/short")
	_check(AboutInfo.ota_label(snap({"ota_id": "dev-000002", "ota_seq": 0})) == "v7.2 (OTA #000002)", "ota_label falls back to the id's number")
	_check(AboutInfo.ota_label(snap({"ota_id": ""})) == "", "ota_label empty on the bare app")
	# developer tap counter: fast taps count, a pause starts over
	var taps := 0
	var last := -1
	var t := 1000
	for i in AboutInfo.DEV_TAPS:
		taps = AboutInfo.dev_tap(taps, last, t)
		last = t
		t += 200
	_check(taps == AboutInfo.DEV_TAPS, "seven quick taps reach the threshold (%d)" % taps)
	taps = AboutInfo.dev_tap(taps, last, t + AboutInfo.DEV_TAP_WINDOW_MS + 1)
	_check(taps == 1, "a long pause restarts the count")
	_check(AboutInfo.dev_tap(0, -1, 5) == 1, "first tap counts one")
	# no Boot at all -> a usable fallback snapshot
	var fb: Dictionary = AboutInfo.fallback_snapshot()
	_check(fb["state"] == "inactive" and not fb["client"] and fb["running_version"] == BuildInfo.running_version(), "fallback snapshot is inactive")
	var stub_less: Dictionary = AboutInfo.build_model(fb)
	_check(str(stub_less["status"]["text"]) != "" and not stub_less["can_check"], "fallback model renders")
	# redact removes key-shaped and token-shaped text
	var dirty := "a\n-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n-----END PRIVATE KEY-----\nghp_abcdefghijklmnopqrstuvwxyz0123456789\nBearer abcdefghijklmnopqrstuvwxyz012345\n%s\nz" % "A".repeat(260)
	var clean: String = AboutInfo.redact(dirty)
	for needle in ["BEGIN", "PRIVATE", "MIIE", "ghp_", "Bearer abc", "AAAAAAAAAA"]:
		_check(not clean.contains(needle), "redact removes '%s'" % needle)
	_check(clean.begins_with("a\n") and clean.ends_with("z"), "redact keeps the surrounding text")
	_check(AboutInfo.redact("fingerprint " + FP) == "fingerprint " + FP, "redact keeps a 64-hex fingerprint")


# --- no network code ---------------------------------------------------------------------------------------------

func _t_no_network_code() -> void:
	for path in ["res://scripts/options_screen.gd", "res://scripts/about_info.gd", "res://scripts/main_menu.gd"]:
		var src: String = FileAccess.get_file_as_string(path)
		for needle in ["HTTPRequest", "HTTPClient", "StreamPeerTLS", "TCPServer", "WebSocket", "http://", "https://", "load_resource_pack", "OtaUpdater", "OtaCore"]:
			_check(not src.contains(needle), "%s has no '%s' (updates go through the Boot autoload only)" % [path.get_file(), needle])
	_check(FileAccess.get_file_as_string("res://scripts/options_screen.gd").contains("check_now"), "options screen checks through Boot.check_now")


# --- the tab ----------------------------------------------------------------------------------------------------

func _options(stub: Node = null) -> Control:
	var packed := load("res://scenes/OptionsScreen.tscn") as PackedScene
	var inst: Control = packed.instantiate()
	inst.about_provider = stub
	add_child(inst)
	for i in 4:
		await get_tree().process_frame
	return inst


func _tabs(inst: Node) -> TabContainer:
	return inst.find_child("TabContainer", true, false) as TabContainer


func _t_tab_structure() -> void:
	var inst: Control = await _options()
	var tc: TabContainer = _tabs(inst)
	_check(tc != null, "options has a tab container")
	var titles: Array = []
	for i in tc.get_tab_count():
		titles.append(tc.get_tab_title(i))
	var touch: bool = TouchControls.is_touch_platform()
	var expect: Array = ["Sound", "Video", "Gameplay", "Accessibility"] + ([] if touch else ["Controls"]) + ["About"]
	_check(titles == expect, "tab order %s (got %s)" % [expect, titles])
	_check(titles.back() == "About", "About is the last tab")
	if touch:
		_check(titles.size() == 5 and titles[4] == "About", "on a phone About is the 5th tab")
	var about: Node = inst.find_child("About", true, false)
	_check(about is ScrollContainer, "About scrolls like the other tabs")
	_check((about as ScrollContainer).horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED, "About never scrolls sideways")
	inst.queue_free()
	await get_tree().process_frame


func _show_about(inst: Control) -> void:
	var tc: TabContainer = _tabs(inst)
	for i in tc.get_tab_count():
		if tc.get_tab_title(i) == "About":
			tc.current_tab = i
	for i in 4:
		await get_tree().process_frame


func _status_text(inst: Node) -> String:
	return (inst.find_child("AboutStatus", true, false) as Label).text


func _t_tab_states() -> void:
	var cases: Array = [
		[snap({"state": "up_to_date"}), "You are up to date", true],
		[snap({"state": "pending_restart", "staged_version": "7.3"}), "Update ready — restart to apply", true],
		[snap({"state": "offline", "last_error": "network result 2"}), "Can't reach the update server. Check your connection and try again.", true],
		[snap({"state": "rejected", "last_error": "bad signature"}), "The update could not be verified, so it was not installed. Your game is unchanged.", true],
		[snap({"state": "checking"}), "Checking for updates…", false],
		[snap({"client": false, "state": "inactive", "platform": "windows"}), "Updates are delivered through the Android app.", false],
	]
	for case in cases:
		var stub := StubBoot.new()
		stub.snap = case[0]
		add_child(stub)
		var inst: Control = await _options(stub)
		await _show_about(inst)
		_check(_status_text(inst) == case[1], "tab shows '%s' (got '%s')" % [case[1], _status_text(inst)])
		var btn := inst.find_child("CheckUpdatesButton", true, false) as Button
		_check(btn != null and (not btn.disabled) == case[2], "check button enabled == %s for '%s'" % [case[2], case[1]])
		var title := inst.find_child("AboutTitle", true, false) as Label
		_check(title.text == "Purgatory Dungeon v%s" % str(case[0]["running_version"]), "title shows the running version (%s)" % title.text)
		if touch_check_layout():
			_check_phone_layout(inst, "state '%s'" % case[1])
		inst.queue_free()
		stub.queue_free()
		await get_tree().process_frame
	# the staged row only shows while something is staged
	var s2 := StubBoot.new()
	s2.snap = snap({"state": "pending_restart", "staged_version": "7.3"})
	add_child(s2)
	var i2: Control = await _options(s2)
	await _show_about(i2)
	_check((i2.find_child("AboutRow_staged", true, false) as Control).visible, "staged row visible while an update waits")
	_check((i2.find_child("AboutRow_update", true, false).find_child("Value", true, false) as Label).text == "v7.2 (OTA #000002)", "update row shows the running OTA")
	s2.snap = snap()
	s2.status_changed.emit()
	await get_tree().process_frame
	_check(not (i2.find_child("AboutRow_staged", true, false) as Control).visible, "staged row hides again; the tab follows status_changed")
	i2.queue_free()
	s2.queue_free()
	await get_tree().process_frame


func touch_check_layout() -> bool:
	return TouchControls.is_touch_platform()


## On a phone the About tab's buttons are thumb-sized and its text readable (same bars as tests/test_mobile_ui.gd).
func _check_phone_layout(inst: Node, label: String) -> void:
	for nm in ["CheckUpdatesButton", "CopyDiagnosticsButton"]:
		var b := inst.find_child(nm, true, false) as Button
		_check(b != null and b.get_global_rect().size.y >= 60.0, "%s: %s is thumb-sized" % [label, nm])
		_check(b != null and b.get_theme_font_size("font_size") >= 22, "%s: %s text readable" % [label, nm])
	var st := inst.find_child("AboutStatus", true, false) as Label
	_check(st.get_theme_font_size("font_size") >= 22, "%s: status text readable (%d)" % [label, st.get_theme_font_size("font_size")])


func _t_check_flow() -> void:
	# update found -> downloading -> ready
	var stub := StubBoot.new()
	stub.snap = snap({"state": "up_to_date"})
	stub.script_states = ["checking", "downloading", "pending_restart"]
	stub.step_delay = 0.25
	add_child(stub)
	var inst: Control = await _options(stub)
	await _show_about(inst)
	var btn := inst.find_child("CheckUpdatesButton", true, false) as Button
	_check(not btn.disabled and btn.text == "Check for updates", "idle: button ready")
	btn.pressed.emit()
	_check(stub.check_calls == 1, "pressing Check calls Boot.check_now() once")
	_check(btn.disabled and btn.text == "Checking…", "button locks at once (%s)" % btn.text)
	_check(_status_text(inst) == "Checking for updates…", "status says checking (%s)" % _status_text(inst))
	btn.pressed.emit()
	btn.pressed.emit()
	_check(stub.check_calls == 1, "double presses are ignored (%d calls)" % stub.check_calls)
	await get_tree().create_timer(0.4).timeout
	_check(_status_text(inst) == "Update available — downloading…", "status follows the client: downloading (%s)" % _status_text(inst))
	_check(btn.disabled, "still locked while downloading")
	await get_tree().create_timer(0.9).timeout
	_check(_status_text(inst) == "Update ready — restart to apply", "ends at 'Update ready — restart to apply' (%s)" % _status_text(inst))
	_check(not btn.disabled and btn.text == "Check for updates", "button free again afterwards")
	inst.queue_free()
	stub.queue_free()
	await get_tree().process_frame

	# already current
	var s2 := StubBoot.new()
	s2.snap = snap({"state": "unchecked"})
	s2.script_states = ["checking", "up_to_date"]
	s2.step_delay = 0.1
	add_child(s2)
	var i2: Control = await _options(s2)
	await _show_about(i2)
	(i2.find_child("CheckUpdatesButton", true, false) as Button).pressed.emit()
	await get_tree().create_timer(0.6).timeout
	_check(_status_text(i2) == "You are up to date", "check on a current install: 'You are up to date' (%s)" % _status_text(i2))
	i2.queue_free()
	s2.queue_free()
	await get_tree().process_frame

	# failure: friendly text only
	var s3 := StubBoot.new()
	s3.snap = snap({"state": "unchecked", "last_error": "channel unreachable (network result 2); keeping current package"})
	s3.script_states = ["checking", "offline"]
	s3.step_delay = 0.1
	add_child(s3)
	var i3: Control = await _options(s3)
	await _show_about(i3)
	(i3.find_child("CheckUpdatesButton", true, false) as Button).pressed.emit()
	await get_tree().create_timer(0.6).timeout
	var txt: String = _status_text(i3)
	_check(txt.begins_with("Can't reach the update server") and not txt.contains("network result") and not txt.contains("unreachable"), "offline shows friendly text (%s)" % txt)
	i3.queue_free()
	s3.queue_free()
	await get_tree().process_frame


func _t_desktop_real_boot() -> void:
	# The real Boot autoload is inert in the test run (no OTA client): the tab shows the calm desktop note.
	var boot: Node = get_node_or_null("/root/Boot")
	_check(boot != null, "Boot autoload exists in the suite")
	var inst: Control = await _options()
	await _show_about(inst)
	if boot != null and not bool(boot.get("ota_enabled")):
		_check(_status_text(inst) == "Updates are delivered through the Android app.", "inert Boot on desktop: calm Android-app note (%s)" % _status_text(inst))
		var btn := inst.find_child("CheckUpdatesButton", true, false) as Button
		_check(btn.disabled, "no check button action without a client")
		btn.pressed.emit()   # even if forced, nothing happens and nothing breaks
		await get_tree().process_frame
		_check(_status_text(inst) == "Updates are delivered through the Android app.", "forcing the press on desktop is harmless")
		var r: Variant = await boot.check_now()
		_check(str(r) == "inactive" and str(boot.status_snapshot()["state"]) == "inactive" and not boot.can_check_now(), "inert Boot: check_now() does nothing, snapshot says inactive")
	var title := inst.find_child("AboutTitle", true, false) as Label
	_check(title.text == "Purgatory Dungeon v%s" % BuildInfo.running_version(), "title shows the running version (%s)" % title.text)
	inst.queue_free()
	await get_tree().process_frame


func _t_diagnostics() -> void:
	var stub := StubBoot.new()
	stub.snap = snap({"state": "pending_restart", "staged_version": "7.3", "staged_ota_id": "dev-000003", "last_error": "channel unreachable (network result 2)"})
	add_child(stub)
	var inst: Control = await _options(stub)
	await _show_about(inst)
	(inst.find_child("CopyDiagnosticsButton", true, false) as Button).pressed.emit()
	var d: String = inst.last_copied_text
	_check(d != "", "Copy diagnostics produced text")
	for needle in ["Purgatory Dungeon diagnostics", "Game version: v7.2", "App (native) version: v7", "OTA: v7.2 (OTA #000002)", "Update state: pending_restart",
			"Staged update: v7.3 (dev-000003)", "Last error: channel unreachable", "Update client: on", "Channel: dev", "Runtime id: android-godot-4.6.0-r2",
			"Runtime fingerprint: " + FP, "Baseline source:", "Engine: Godot 4.6.0", "Platform: android", "Device", "  OS: ", "  Model: ", "  GPU: ",
			"  Renderer: ", "  Screen: ", "safe area", "dpi", "Touch screen:", "Update client log", "Last check: ok"]:
		_check(d.contains(needle), "diagnostics contain '%s'" % needle)
	_check((inst.find_child("AboutCopied", true, false) as Label).text == "Copied to the clipboard.", "the player is told it was copied")
	for needle in ["BEGIN", "PRIVATE", "END PUBLIC", "KEY-----", "ghp_", "github_pat_", "Bearer", "password", "secret", "token", ".pem", "keystore"]:
		_check(not d.to_lower().contains(needle.to_lower()), "diagnostics hold no '%s'" % needle)
	var b64 := RegEx.new()
	b64.compile("[A-Za-z0-9+/=]{100,}")
	_check(b64.search(d) == null, "diagnostics hold no long base64-looking blob")
	_check(d.length() < 6000, "diagnostics are compact (%d chars)" % d.length())
	inst.queue_free()
	stub.queue_free()
	await get_tree().process_frame
	var poisoned := StubBoot.new()
	poisoned.snap = snap()
	add_child(poisoned)
	var i2: Control = await _options(poisoned)
	var text: String = AboutInfo.diagnostics_text(poisoned.snap, AboutInfo.device_info(), "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0B\n-----END PRIVATE KEY-----")
	_check(not text.contains("BEGIN") and not text.contains("MIIE"), "key material in an input is stripped from the final text")
	i2.queue_free()
	poisoned.queue_free()
	await get_tree().process_frame
	# without Boot at all the button still works
	var i3: Control = await _options()
	(i3.find_child("CopyDiagnosticsButton", true, false) as Button).pressed.emit()
	_check(i3.last_copied_text.contains("Purgatory Dungeon diagnostics") and i3.last_copied_text.contains("Device"), "diagnostics also work without a client")
	i3.queue_free()
	await get_tree().process_frame


func _t_developer_tools() -> void:
	SettingsManager.gameplay_settings["DeveloperMode"] = false
	SettingsManager.gameplay_settings["ShowPerf"] = false
	var stub := StubBoot.new()
	stub.snap = snap()
	add_child(stub)
	var inst: Control = await _options(stub)
	# not a player option any more: nothing in Gameplay
	var gameplay: Node = inst.find_child("Gameplay", true, false)
	var perf_in_gameplay := false
	for n in gameplay.find_children("*", "Label", true, false):
		if (n as Label).text.to_lower().contains("performance"):
			perf_in_gameplay = true
	_check(not perf_in_gameplay, "Gameplay has no performance readout option")
	var dev := inst.find_child("DeveloperTools", true, false) as Control
	_check(dev != null and not dev.visible, "developer tools are hidden by default")
	await _show_about(inst)
	# six taps are not enough, the seventh unlocks
	var title := inst.find_child("AboutTitle", true, false) as Label
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	for i in AboutInfo.DEV_TAPS - 1:
		title.gui_input.emit(click)
	_check(not dev.visible, "six taps do not unlock the developer tools")
	title.gui_input.emit(click)
	_check(dev.visible and SettingsManager.is_developer_mode(), "the seventh tap unlocks them")
	# the performance readout is a developer switch: on while unlocked, forced off when hidden
	var cb := inst.find_child("DeveloperTools", true, false).find_children("*", "CheckBox", true, false)
	_check(cb.size() == 1, "one checkbox: the performance readout")
	(cb[0] as CheckBox).button_pressed = true
	_check(bool(SettingsManager.gameplay_settings.get(PerfOverlay.KEY, false)), "the checkbox turns the readout on")
	(inst.find_child("OpenDiagnosticsButton", true, false) as Button).pressed.emit()
	_check(stub.diag_calls == 1, "the developer button opens the native diagnostics overlay (Boot.show_diagnostics)")
	(inst.find_child("HideDeveloperToolsButton", true, false) as Button).pressed.emit()
	_check(not dev.visible and not SettingsManager.is_developer_mode(), "Hide developer tools hides them")
	_check(not bool(SettingsManager.gameplay_settings.get(PerfOverlay.KEY, false)), "hiding the tools also turns the readout off")
	inst.queue_free()
	stub.queue_free()
	await get_tree().process_frame
	# a settings file from an older build that left the readout on is not honoured without developer mode
	SettingsManager.gameplay_settings["DeveloperMode"] = false
	SettingsManager.gameplay_settings["ShowPerf"] = true
	SettingsManager.save_settings()
	SettingsManager.gameplay_settings["ShowPerf"] = false
	SettingsManager.load_settings()
	_check(not bool(SettingsManager.gameplay_settings.get("ShowPerf", false)), "a stored ShowPerf=true is ignored while developer mode is off")
	SettingsManager.gameplay_settings["DeveloperMode"] = true
	SettingsManager.gameplay_settings["ShowPerf"] = true
	SettingsManager.save_settings()
	SettingsManager.gameplay_settings["ShowPerf"] = false
	SettingsManager.load_settings()
	_check(bool(SettingsManager.gameplay_settings.get("ShowPerf", false)), "with developer mode on the stored readout setting is kept")
	SettingsManager.gameplay_settings["DeveloperMode"] = false
	SettingsManager.gameplay_settings["ShowPerf"] = false
	SettingsManager.save_settings()
