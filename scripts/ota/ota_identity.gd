# ==============================================================================
# File Name: ota_identity.gd
# Path: res://scripts/ota/ota_identity.gd
#
# Description:
#   Who is this device running? The native build identity that updates are matched against, the trust
#   anchor and channel configuration, and the device-visible diagnostics (menu footer + startup log).
# ==============================================================================
class_name OtaIdentity
extends RefCounted


static func platform() -> String:
	match OS.get_name():
		"Android":
			return "android"
		"Windows":
			return "windows"
	return ""


## The same string `godot --version` prints, e.g. "4.6.stable.official.89cea1439".
static func engine_string() -> String:
	var v: Dictionary = Engine.get_version_info()
	var s: String = "%d.%d" % [int(v.get("major", 0)), int(v.get("minor", 0))]
	if int(v.get("patch", 0)) > 0:
		s += ".%d" % int(v.get("patch", 0))
	return "%s.%s.%s.%s" % [s, str(v.get("status", "")), str(v.get("build", "")), str(v.get("hash", "")).left(9)]


static func base_commit() -> String:
	var c: String = BuildInfo.commit().to_lower()
	return c if c.length() == 40 else ""


static func current() -> Dictionary:
	return {
		"platform": platform(),
		"native_version": BuildInfo.public_version(),
		"base_commit": base_commit(),
		"engine": engine_string(),
		"ota_api": OtaConst.OTA_API,
	}


static func trust_pem() -> String:
	if not FileAccess.file_exists(OtaConst.TRUST_PATH):
		return ""
	return FileAccess.get_file_as_string(OtaConst.TRUST_PATH)


## "https://host/path/" or "" (not configured). Plain http is accepted only outside shipped builds (tests).
static func channel_url() -> String:
	var url: String = ""
	if not OS.has_feature("template"):
		url = OS.get_environment(OtaConst.ENV_CHANNEL)
	if url == "" and FileAccess.file_exists(OtaConst.CHANNEL_CONFIG_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(OtaConst.CHANNEL_CONFIG_PATH))
		if parsed is Dictionary:
			url = str((parsed as Dictionary).get("channel_url", "")).strip_edges()
	if url == "":
		return ""
	var ok: bool = url.begins_with("https://") or (not OS.has_feature("template") and url.begins_with("http://"))
	if not ok:
		return ""
	return url if url.ends_with("/") else url + "/"


## "" when OTA may run on this launch, else the reason it is off.
static func off_reason(identity: Dictionary, pem: String) -> String:
	if OS.get_environment(OtaConst.ENV_DISABLE) == "1" or OS.get_cmdline_user_args().has(OtaConst.ARG_DISABLE) \
			or OS.get_cmdline_args().has(OtaConst.ARG_DISABLE):
		return "disabled by --no-ota"
	if str(identity.get("platform", "")) == "":
		return "unsupported platform"
	if str(identity.get("base_commit", "")) == "":
		return "not a CI build"
	if pem.strip_edges() == "":
		return "no trust anchor in this build"
	return ""


static func short_id(id: String) -> String:
	return id.left(10)


## Footer text appended to the build name; "" for the plain native build.
static func footer_suffix() -> String:
	if OtaRuntime.pending_seq > 0:
		return " · update %d downloaded - restart to apply" % OtaRuntime.pending_seq
	if OtaRuntime.rolled_back_seq > 0 and OtaRuntime.active_seq == 0:
		return " · update %d rolled back" % OtaRuntime.rolled_back_seq
	if OtaRuntime.active_seq > 0:
		var s: String = " · update %d" % OtaRuntime.active_seq
		if OtaRuntime.rolled_back_seq > 0:
			s += " (update %d rolled back)" % OtaRuntime.rolled_back_seq
		return s
	return ""


static func status_word() -> String:
	if not OtaRuntime.enabled:
		return "disabled:" + OtaRuntime.disabled_reason
	if OtaRuntime.pending_seq > 0:
		return "pending"
	if OtaRuntime.active_seq > 0:
		return "active" if OtaRuntime.confirmed else "active (unconfirmed)"
	if OtaRuntime.rolled_back_seq > 0:
		return "rolled_back:" + OtaRuntime.rolled_back_reason
	return "none"


## Lines for BuildInfo.diagnostics() (startup log / adb logcat).
static func diagnostic_lines() -> PackedStringArray:
	var id: Dictionary = current()
	var lines: PackedStringArray = []
	lines.append("Native build: v%d · %s · %s" % [int(id["native_version"]), str(id["platform"]) if str(id["platform"]) != "" else "unsupported", str(id["engine"])])
	lines.append("Native base commit: %s" % (str(id["base_commit"]) if str(id["base_commit"]) != "" else "unknown"))
	lines.append("OTA: API %d · trust anchor %s · channel %s · %s" % [OtaConst.OTA_API,
			"present" if trust_pem().strip_edges() != "" else "absent",
			"configured" if OtaRuntime.channel_configured else "not configured", status_word()])
	if OtaRuntime.active_seq > 0:
		lines.append("OTA update: %d (source %s, payload %s, launches %d%s)" % [OtaRuntime.active_seq,
				OtaRuntime.active_source_commit.left(7), short_id(OtaRuntime.active_payload_id), OtaRuntime.boot_attempts,
				", confirmed" if OtaRuntime.confirmed else ", unconfirmed"])
	else:
		lines.append("OTA update: none (native build only)")
	if OtaRuntime.pending_seq > 0:
		lines.append("OTA pending: update %d (applies at next launch)" % OtaRuntime.pending_seq)
	if OtaRuntime.rolled_back_seq > 0:
		lines.append("OTA rolled back: update %d (%s)" % [OtaRuntime.rolled_back_seq, OtaRuntime.rolled_back_reason])
	if OtaRuntime.last_check_utc > 0:
		lines.append("OTA last check: %s" % Time.get_datetime_string_from_unix_time(OtaRuntime.last_check_utc, true))
	if OtaRuntime.last_error != "":
		lines.append("OTA last error: %s" % OtaRuntime.last_error)
	return lines
