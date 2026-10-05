# ==============================================================================
# File Name: ota_manifest.gd
# Path: res://scripts/ota/ota_manifest.gd
#
# Description:
#   Parsing and compatibility rules for an update manifest (docs/OTA.md "Compatibility rules").
#   Pure functions: given a manifest and the device identity they answer "may this update be applied?"
#   with an empty string (yes) or the reason (no). Nothing here touches the disk or the network.
# ==============================================================================
class_name OtaManifest
extends RefCounted


## Parses JSON bytes into a Dictionary; {} for anything that is not a JSON object.
static func parse(bytes: PackedByteArray) -> Dictionary:
	if bytes.is_empty() or bytes.size() > OtaConst.MAX_META_BYTES:
		return {}
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


## True for a path the pack must never carry (and for anything that could escape res://).
static func is_protected_path(path: String) -> bool:
	var p: String = path.strip_edges()
	if p == "" or p.begins_with("/") or p.begins_with("res://") or p.begins_with("user://") or p.contains("\\") \
			or p.contains("..") or p.contains(":") or p.contains("//"):
		return true
	var lower: String = p.to_lower()
	if OtaConst.PROTECTED_EXACT.has(p) or OtaConst.PROTECTED_EXACT.has(lower):
		return true
	for pre in OtaConst.PROTECTED_PREFIXES:
		if lower.begins_with(pre):
			return true
	for suf in OtaConst.PROTECTED_SUFFIXES:
		if lower.ends_with(suf):
			return true
	return false


static func _is_hex(s: String, n: int) -> bool:
	if s.length() != n:
		return false
	for i in s.length():
		var c: String = s[i]
		if not "0123456789abcdef".contains(c):
			return false
	return true


## "" when the manifest may be applied to this device, otherwise the first rule that fails.
## identity = {platform, native_version, base_commit, engine, ota_api}.
static func check(m: Dictionary, identity: Dictionary) -> String:
	if m.is_empty():
		return "manifest is not a JSON object"
	if int(m.get("format", -1)) != OtaConst.FORMAT:
		return "unsupported manifest format %s" % str(m.get("format"))
	if str(m.get("product", "")) != OtaConst.PRODUCT:
		return "wrong product"
	if int(m.get("ota_api", -1)) != int(identity.get("ota_api", OtaConst.OTA_API)):
		return "OTA API mismatch (update %s, client %s)" % [str(m.get("ota_api")), str(identity.get("ota_api"))]
	if str(m.get("platform", "")) != str(identity.get("platform", "?")):
		return "wrong platform (%s)" % str(m.get("platform"))
	if int(m.get("native_version", -1)) != int(identity.get("native_version", -2)):
		return "built for native build v%s, this is v%s" % [str(m.get("native_version")), str(identity.get("native_version"))]
	var base: String = str(m.get("base_commit", ""))
	if not _is_hex(base, 40) or base != str(identity.get("base_commit", "")):
		return "built for a different native build (base commit mismatch)"
	if str(m.get("engine", "")) != str(identity.get("engine", "?")):
		return "built for a different engine build"
	var seq: int = int(m.get("payload_seq", 0))
	if seq < 1 or seq > 1000000:
		return "invalid update number"
	var payload: Variant = m.get("payload")
	if not (payload is Dictionary):
		return "payload description missing"
	var size: int = int((payload as Dictionary).get("size", -1))
	if size <= 0 or size > OtaConst.MAX_PAYLOAD_BYTES:
		return "payload size out of range"
	if not _is_hex(str((payload as Dictionary).get("sha256", "")), 64):
		return "payload sha256 missing"
	if str((payload as Dictionary).get("file", "")) != "payload.pck":
		return "payload file name not allowed"
	if not _is_hex(str(m.get("source_commit", "")), 40):
		return "source commit missing"
	var files: Variant = m.get("files")
	if not (files is Array) or (files as Array).is_empty():
		return "file list missing"
	for entry in files:
		if not (entry is Dictionary):
			return "malformed file list"
		var path: String = str((entry as Dictionary).get("path", ""))
		var op: String = str((entry as Dictionary).get("op", ""))
		if op != "add" and op != "replace" and op != "remove":
			return "unknown file operation '%s'" % op
		if is_protected_path(path):
			return "update touches a protected path (%s): that needs a new APK" % path
	return ""
