# ==============================================================================
# File Name: about_info.gd
# Path: res://scripts/about_info.gd
#
# Description:
#   Data behind Options > About: what the player may read about the build and its update state, and the
#   "Copy diagnostics" text. Pure functions over a status snapshot, so every state is unit-testable with a
#   mocked snapshot (tests/test_about.gd) and nothing here touches the network.
#
#   The only source of OTA facts is the native layer: the `Boot` autoload (scripts/boot/boot.gd) answers
#   status_snapshot() / check_now() / can_check_now(). When Boot is absent (tools, tests without autoloads)
#   or inert (desktop, editor) everything degrades to a calm "Updates are delivered through the Android app".
#
#   Nothing here ever includes secrets: no key material, signing data, tokens or file contents, and the
#   finished diagnostics string is passed through redact() as a last line of defence.
# ==============================================================================
class_name AboutInfo
extends RefCounted

const PRODUCT := "Purgatory Dungeon"
## Developer tools (performance readout, OTA diagnostics overlay) unlock after this many quick taps on the version.
const DEV_TAPS := 7
const DEV_TAP_WINDOW_MS := 2000

# Status kinds drive the colour of the status line (the words always carry the meaning too).
const KIND_OK := "ok"
const KIND_INFO := "info"
const KIND_BUSY := "busy"
const KIND_WARN := "warn"
const KIND_ERROR := "error"


## The native OTA client, or null. `override` lets a test hand in a stub with the same methods.
static func boot_node(override: Node = null) -> Node:
	if override != null:
		return override
	var loop: MainLoop = Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("Boot")
	return null


## Status snapshot from Boot when it can give one, else the same shape built from what the game layer knows.
static func snapshot(override: Node = null) -> Dictionary:
	var b: Node = boot_node(override)
	if b != null and b.has_method("status_snapshot"):
		var s: Variant = b.call("status_snapshot")
		if s is Dictionary:
			return s as Dictionary
	return fallback_snapshot()


static func fallback_snapshot() -> Dictionary:
	return {
		"client": false, "inert_reason": "no OTA client", "state": "inactive", "busy": false,
		"native_version": str(BuildInfo.public_version()), "running_version": BuildInfo.running_version(),
		"app_minor": 0, "ota_id": "", "ota_seq": 0, "staged_version": "", "staged_ota_id": "", "latest_ota_id": "",
		"checked_at": "", "runtime_id": "", "runtime_fingerprint": "", "channel": "",
		"engine": engine_version(), "platform": OS.get_name().to_lower(), "bootstrap": 0, "baseline_source": "",
		"healthy": false, "rollback_count": 0, "disabled": false, "rejected": [], "last_error": "",
	}


static func engine_version() -> String:
	var v: Dictionary = Engine.get_version_info()
	return "%d.%d.%d" % [int(v["major"]), int(v["minor"]), int(v["patch"])]


# --- the About model -----------------------------------------------------------------------------------------------

## "v7.2 (OTA #000002)" while an OTA runs, "" on the bare app.
static func ota_label(snap: Dictionary) -> String:
	var id: String = str(snap.get("ota_id", ""))
	if id == "":
		return ""
	var seq: int = int(snap.get("ota_seq", 0))
	if seq <= 0 and id.contains("-"):
		seq = int(id.get_slice("-", id.get_slice_count("-") - 1))
	return "v%s (OTA #%06d)" % [str(snap.get("running_version", "?")), seq]


## "abcdef012345..." : the first 12 hex digits of a fingerprint, enough to compare two builds by eye.
static func short_fingerprint(fp: String) -> String:
	if fp.length() <= 12:
		return fp if fp != "" else "none"
	return fp.left(12) + "…"


## status text + kind for one update state. `desktop` = the platform has no OTA at all.
static func status_for(state: String, snap: Dictionary, desktop: bool) -> Dictionary:
	var staged: String = str(snap.get("staged_version", ""))
	match state:
		"checking":
			return {"text": "Checking for updates…", "kind": KIND_BUSY}
		"downloading":
			return {"text": "Update available — downloading…", "kind": KIND_BUSY}
		"up_to_date":
			return {"text": "You are up to date", "kind": KIND_OK}
		"pending_restart":
			return {"text": "Update ready — restart to apply", "kind": KIND_WARN,
					"detail": ("Version %s starts the next time you close and reopen the game." % staged) if staged != "" else
							"The new version starts the next time you close and reopen the game."}
		"downloaded":
			return {"text": "Update downloaded", "kind": KIND_INFO, "detail": "It is not ready to apply yet. Try again later."}
		"offline":
			return {"text": "Can't reach the update server. Check your connection and try again.", "kind": KIND_WARN}
		"incompatible":
			return {"text": "A newer update is available, but it needs a newer version of the app.", "kind": KIND_WARN}
		"rejected":
			return {"text": "The update could not be verified, so it was not installed. Your game is unchanged.", "kind": KIND_ERROR}
		"failed":
			return {"text": "The update could not be completed. Please try again later.", "kind": KIND_ERROR}
		"disabled":
			return {"text": "Updates are paused on this device.", "kind": KIND_INFO}
		"unchecked":
			return {"text": "Not checked yet", "kind": KIND_INFO}
	# inactive / anything unknown
	if desktop:
		return {"text": "Updates are delivered through the Android app.", "kind": KIND_INFO}
	return {"text": "Updates are not available in this build.", "kind": KIND_INFO}


## Everything the About tab draws, from one snapshot. `checking_locally` = the screen itself started a check that has
## not returned yet (so the button locks even before the client reports "checking").
## Returns {title, rows (player), tech (technical rows), state, status {text, kind, detail?}, can_check, check_label}.
static func build_model(snap: Dictionary, checking_locally: bool = false) -> Dictionary:
	var state: String = str(snap.get("state", "inactive"))
	if checking_locally and state not in ["checking", "downloading"]:
		state = "checking"
	var platform: String = str(snap.get("platform", ""))
	var desktop: bool = platform != "android" and not bool(snap.get("client", false))
	var running: String = str(snap.get("running_version", "?"))
	var native: String = str(snap.get("native_version", running))
	var ota: String = ota_label(snap)
	var rows: Array = [
		{"key": "version", "label": "Game version", "value": "v%s" % running},
		{"key": "app", "label": "App version", "value": "v%s" % native},
		{"key": "update", "label": "Update", "value": ota if ota != "" else "None (original v%s)" % native},
	]
	var staged: String = str(snap.get("staged_version", ""))
	if staged != "":
		rows.append({"key": "staged", "label": "Waiting to start", "value": "v%s (restart to apply)" % staged})
	var tech: Array = [
		{"key": "runtime", "label": "Runtime", "value": str(snap.get("runtime_id", "")) if str(snap.get("runtime_id", "")) != "" else "none"},
		{"key": "fingerprint", "label": "Runtime fingerprint", "value": short_fingerprint(str(snap.get("runtime_fingerprint", "")))},
		{"key": "channel", "label": "Update channel", "value": str(snap.get("channel", "")) if str(snap.get("channel", "")) != "" else "none"},
		{"key": "engine", "label": "Engine", "value": "Godot %s" % str(snap.get("engine", engine_version()))},
		{"key": "platform", "label": "Platform", "value": platform if platform != "" else OS.get_name().to_lower()},
		{"key": "checked", "label": "Last check", "value": str(snap.get("checked_at", "")) if str(snap.get("checked_at", "")) != "" else "not yet"},
	]
	var busy: bool = state in ["checking", "downloading"]
	var can: bool = bool(snap.get("client", false)) and not busy and state != "disabled"
	return {
		"title": "%s v%s" % [PRODUCT, running],
		"rows": rows, "tech": tech, "state": state,
		"status": status_for(state, snap, desktop),
		"can_check": can,
		"check_label": "Checking…" if busy else "Check for updates",
		"desktop": desktop,
	}


# --- developer tap gesture ------------------------------------------------------------------------------------------

## Tap counter for the hidden developer unlock (tap the version DEV_TAPS times quickly). Returns the new count; the
## caller unlocks when it reaches DEV_TAPS. A pause longer than DEV_TAP_WINDOW_MS starts over.
static func dev_tap(taps: int, last_ms: int, now_ms: int) -> int:
	if last_ms < 0 or now_ms - last_ms > DEV_TAP_WINDOW_MS:
		return 1
	return taps + 1


# --- diagnostics --------------------------------------------------------------------------------------------------

## Device facts for troubleshooting. No identifiers beyond what a bug report needs (no serials, no accounts).
static func device_info() -> Dictionary:
	var screen: Vector2i = DisplayServer.screen_get_size()
	var win: Vector2i = DisplayServer.window_get_size()
	var safe: Rect2i = DisplayServer.get_display_safe_area()
	var renderer: String = ""
	if RenderingServer.has_method("get_current_rendering_method"):
		renderer = str(RenderingServer.call("get_current_rendering_method"))
	return {
		"os": OS.get_name(),
		"os_version": OS.get_version(),
		"model": OS.get_model_name(),
		"locale": OS.get_locale(),
		"gpu": RenderingServer.get_video_adapter_name(),
		"gpu_vendor": RenderingServer.get_video_adapter_vendor(),
		"renderer": renderer,
		"screen": "%dx%d" % [screen.x, screen.y],
		"window": "%dx%d" % [win.x, win.y],
		"safe_area": "%d,%d %dx%d" % [safe.position.x, safe.position.y, safe.size.x, safe.size.y],
		"dpi": DisplayServer.screen_get_dpi(),
		"touch": DisplayServer.is_touchscreen_available(),
		"touch_platform": TouchControls.is_touch_platform(),
	}


## The text "Copy diagnostics" puts on the clipboard. `boot_text` = Boot.diagnostics_text() (or "").
static func diagnostics_text(snap: Dictionary, device: Dictionary, boot_text: String = "") -> String:
	var L: Array[String] = []
	L.append("%s diagnostics" % PRODUCT)
	L.append("Game version: v%s" % str(snap.get("running_version", "?")))
	L.append("App (native) version: v%s" % str(snap.get("native_version", "?")))
	var ota: String = ota_label(snap)
	L.append("OTA: %s" % (ota if ota != "" else "none (original app)"))
	L.append("Update state: %s" % str(snap.get("state", "inactive")))
	if str(snap.get("staged_version", "")) != "":
		L.append("Staged update: v%s (%s), starts after restart" % [str(snap["staged_version"]), str(snap.get("staged_ota_id", ""))])
	if str(snap.get("latest_ota_id", "")) != "":
		L.append("Latest on channel: %s (checked %s)" % [str(snap["latest_ota_id"]), str(snap.get("checked_at", ""))])
	L.append("Last error: %s" % (str(snap.get("last_error", "")) if str(snap.get("last_error", "")) != "" else "none"))
	L.append("Update client: %s" % ("on" if bool(snap.get("client", false)) else "off (%s)" % str(snap.get("inert_reason", ""))))
	L.append("Channel: %s" % (str(snap.get("channel", "")) if str(snap.get("channel", "")) != "" else "none"))
	L.append("Runtime id: %s" % str(snap.get("runtime_id", "")))
	L.append("Runtime fingerprint: %s" % str(snap.get("runtime_fingerprint", "")))
	L.append("Baseline source: %s" % str(snap.get("baseline_source", "")))
	L.append("Boot healthy: %s" % ("yes" if bool(snap.get("healthy", false)) else "not yet"))
	L.append("Rollbacks: %d" % int(snap.get("rollback_count", 0)))
	var bad: Array = snap.get("rejected", []) as Array
	L.append("Rejected updates: %s" % (", ".join(PackedStringArray(bad)) if not bad.is_empty() else "none"))
	L.append("Engine: Godot %s" % str(snap.get("engine", engine_version())))
	L.append("Platform: %s" % str(snap.get("platform", "")))
	L.append("")
	L.append("Device")
	L.append("  OS: %s %s" % [str(device.get("os", "")), str(device.get("os_version", ""))])
	L.append("  Model: %s" % str(device.get("model", "")))
	L.append("  GPU: %s (%s)" % [str(device.get("gpu", "")), str(device.get("gpu_vendor", ""))])
	L.append("  Renderer: %s" % str(device.get("renderer", "")))
	L.append("  Screen: %s, window %s, safe area %s, dpi %s" % [str(device.get("screen", "")), str(device.get("window", "")),
			str(device.get("safe_area", "")), str(device.get("dpi", ""))])
	L.append("  Touch screen: %s (touch platform: %s)" % [str(device.get("touch", false)), str(device.get("touch_platform", false))])
	L.append("  Locale: %s" % str(device.get("locale", "")))
	if boot_text != "":
		L.append("")
		L.append("Update client log")
		L.append(boot_text)
	return redact("\n".join(L))


## Last line of defence: strips anything shaped like key material or a token, even though none is ever put in.
static func redact(text: String) -> String:
	var out: String = text
	var pem: RegEx = RegEx.new()
	pem.compile("-----BEGIN[^-]*-----[\\s\\S]*?-----END[^-]*-----")
	out = pem.sub(out, "[removed]", true)
	for rx in ["-----(BEGIN|END)[^\\n]*", "(?i)(ghp|gho|ghs|github_pat)_[A-Za-z0-9_]{16,}", "(?i)bearer\\s+[A-Za-z0-9._~+/=-]{16,}",
			"[A-Za-z0-9+/=]{200,}"]:
		var r: RegEx = RegEx.new()
		r.compile(rx)
		out = r.sub(out, "[removed]", true)
	return out
