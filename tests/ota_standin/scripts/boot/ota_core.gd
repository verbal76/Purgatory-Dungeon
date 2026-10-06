extends RefCounted
## STAND-IN for scripts/boot/ota_core.gd (class OtaCore): implements only the contract the tooling uses
## (check_manifest, validate_manifest, verify_package, sha256_bytes, file_sha256) with the manifest rules of
## docs/OTA.md section 5. The real core is stricter; it replaces this file automatically in the tests once it exists.

var root: String
var runtime_id: String
var channel: String
var pubkey_pem: String
var bootstrap_version: int
var runtime_fingerprint: String
var base_source_sha: String


func _init(p_root: String = "", p_runtime_id: String = "", p_channel: String = "", p_pubkey_pem: String = "",
		p_bootstrap_version: int = 1, p_runtime_fingerprint: String = "", p_base_source_sha: String = "") -> void:
	root = p_root
	runtime_id = p_runtime_id
	channel = p_channel
	pubkey_pem = p_pubkey_pem
	bootstrap_version = p_bootstrap_version
	runtime_fingerprint = p_runtime_fingerprint
	base_source_sha = p_base_source_sha


static func sha256_bytes(b: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(b)
	return ctx.finish().hex_encode()


static func file_sha256(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while not f.eof_reached():
		var chunk := f.get_buffer(1 << 20)
		if chunk.is_empty():
			break
		ctx.update(chunk)
	return ctx.finish().hex_encode()


## [manifest_or_{}, reason]
func check_manifest(manifest_bytes: PackedByteArray, sig_b64: String) -> Array:
	var key := CryptoKey.new()
	if key.load_from_string(pubkey_pem, true) != OK:
		return [{}, "bad public key"]
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(manifest_bytes)
	var sig := Marshalls.base64_to_raw(sig_b64.strip_edges())
	if sig.is_empty() or not Crypto.new().verify(HashingContext.HASH_SHA256, ctx.finish(), sig, key):
		return [{}, "signature does not verify"]
	var parsed: Variant = JSON.parse_string(manifest_bytes.get_string_from_utf8())
	if not (parsed is Dictionary):
		return [{}, "manifest is not a JSON object"]
	var why := validate_manifest(parsed)
	if why != "":
		return [{}, why]
	return [parsed, ""]


func validate_manifest(m: Dictionary) -> String:
	for k in ["schema", "channel", "ota_id", "seq", "source_sha", "runtime_id", "runtime_fingerprint", "minimum_bootstrap_version",
			"game_version", "save_schema", "min_save_schema", "pck_url", "pck_sha256", "pck_size", "created_at", "build_run",
			"payload_kind", "base_source_sha", "platform", "native_version", "files"]:
		if not m.has(k):
			return "manifest field missing: " + k
	if int(m["schema"]) != 1:
		return "unsupported manifest schema"
	if str(m["channel"]) != channel:
		return "manifest is for channel %s, not %s" % [m["channel"], channel]
	if str(m["runtime_id"]) != runtime_id:
		return "runtime mismatch: manifest %s, device %s" % [m["runtime_id"], runtime_id]
	if str(m["runtime_fingerprint"]) != runtime_fingerprint:
		return "runtime fingerprint mismatch"
	if str(m["base_source_sha"]) != base_source_sha:
		return "base source sha mismatch"
	if int(m["minimum_bootstrap_version"]) > bootstrap_version:
		return "needs a newer bootstrap"
	if str(m["ota_id"]) != "%s-%06d" % [m["channel"], int(m["seq"])]:
		return "ota_id does not match channel/seq"
	if str(m["payload_kind"]) != "patch":
		return "unsupported payload kind"
	if int(m["pck_size"]) <= 0 or str(m["pck_sha256"]).length() != 64:
		return "bad package size or hash"
	for e in m["files"]:
		var p: String = str(e.get("path", ""))
		if p.begins_with("scripts/boot/") or p == "project.binary" or p == "project.godot" or ".." in p or p.begins_with("/"):
			return "manifest lists a protected or illegal path: " + p
	return ""


func verify_package(m: Dictionary, path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "package unreadable"
	var size: int = f.get_length()
	f.close()
	if size != int(m["pck_size"]):
		return "package size %d != manifest %d" % [size, int(m["pck_size"])]
	if file_sha256(path) != str(m["pck_sha256"]):
		return "package SHA-256 mismatch"
	return ""
