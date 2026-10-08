# ==============================================================================
# File Name: ota_core.gd
# Path: res://scripts/boot/ota_core.gd
#
# Description:
#   NATIVE LAYER (docs/OTA.md sections 5, 7, 8, 9). The OTA state machine, manifest validation
#   and package verification, pure logic over a storage root (user://ota on a device, a scratch
#   directory in tests). Adapted from the Hot Attic Games reference client (Mote) with this
#   game's manifest fields: runtime fingerprint, patch payload kind, native baseline SHA.
#
#   Layout under `root`:
#     state.json                    CURRENT / PREVIOUS / PENDING / READY, bad list, boot health
#     packages/<ota_id>.pck         verified packages (promoted from .incoming-<ota_id>.pck)
#     manifests/<ota_id>.json       exact signed manifest bytes
#     manifests/<ota_id>.json.sig   base64 RSA-SHA256 signature over those bytes
#     backups/<ota_id>_<unix>/      copy of the save folder taken before a never-run package first loads
#
#   A package is only ever mounted after its manifest signature, channel, runtime ID and
#   fingerprint, native baseline, size and SHA-256 all check out. The APK's embedded game is the
#   baseline that is always available. This class never writes into the save folder.
#
#   No game-layer script may be referenced from here (or from anything in scripts/boot): the
#   native layer runs before any pack is mounted, and loading a game script early would pin the
#   baseline version of it in the resource cache.
# ==============================================================================
extends RefCounted

const Config := preload("res://scripts/boot/ota_config.gd")
const Protected := preload("res://scripts/boot/ota_protected.gd")

## Starts of the same OTA that never reached the healthy checkpoint before it is abandoned.
const MAX_UNHEALTHY_STARTS := 2
const MAX_PCK_BYTES := 536870912
const MAX_BACKUPS := 3
const MAX_MANIFEST_BYTES := 8388608
const REQUIRED: Array[String] = ["schema", "channel", "ota_id", "seq", "source_sha", "runtime_id",
		"runtime_fingerprint", "minimum_bootstrap_version", "game_version", "save_schema",
		"min_save_schema", "pck_url", "pck_sha256", "pck_size", "created_at", "payload_kind",
		"base_source_sha", "platform", "native_version", "app_minor", "files"]
const FILE_OPS: Array[String] = ["add", "replace", "remove"]
## The game's own key resources: they must still resolve after a pack is mounted.
const CANARY_RESOURCES: Array[String] = ["res://scenes/StudioSplash.tscn", "res://scenes/MainMenu.tscn",
		"res://scripts/save_schema.gd"]

var root: String
var runtime_id: String
var channel: String
var public_key_pem: String
var bootstrap_version: int
## Content fingerprint of the installed native inputs (build_info.json "runtime_fingerprint").
var runtime_fingerprint: String
## Commit the embedded baseline game was built from (build_info.json "commit"). Every patch is
## relative to exactly this baseline.
var base_source_sha: String
## The save folder (read only: copied to backups/ before a never-run package first loads). "" = no backups.
var save_root := ""
## Save schema recorded on the device when the running package last became healthy; 0 = unknown / no save yet.
var device_save_schema := 0
## Save schema of the game that is running now. Boot reads it from the mounted game; recorded by mark_healthy().
var running_save_schema := 0
## The download base the update client is talking to (set by OtaUpdater for every check): ".../releases/download/" for
## GitHub Releases, else the pointer's own directory. When non-empty, a manifest's pck_url must live inside it (and be
## an OTA release asset). Empty (boot-time re-validation, unit tests of other rules) = not enforced: stored manifests
## were anchored when they were staged and are signed.
var url_base := ""
## Desktop-only local test hook (http://127.0.0.1 pointer). Never set on a device.
var allow_local_http := false
var state: Dictionary = {}
## The manifest actually mounted by this process ({} = embedded baseline).
var active: Dictionary = {}
## "pending" | "current" | "previous" | "" : the slot `active` was chosen from.
var active_slot := ""
## True when `active` was mounted for the first time ever in this boot (shows the "Applying update" panel).
var first_run := false
## A pack was mounted and then judged unsafe: it is blacklisted, the process must restart to run clean.
var restart_required := false
var boot_log: Array[String] = []
var boot_verify_ms := 0.0
var boot_mount_ms := 0.0
## Optional injection: returns the current unix time (seconds, float). Default: the system clock.
var now_fn: Callable = Callable()
## Post-mount self-check; returns true when the game's key resources still resolve.
var canary: Callable = Callable()


func _init(p_root: String = "user://ota", p_runtime_id: String = "", p_channel: String = Config.CHANNEL,
		p_pubkey_pem: String = Config.PUBLIC_KEY_PEM, p_bootstrap_version: int = Config.BOOTSTRAP_VERSION,
		p_runtime_fingerprint: String = "", p_base_source_sha: String = "") -> void:
	root = p_root
	runtime_id = p_runtime_id if p_runtime_id != "" else Config.runtime_id()
	channel = p_channel
	public_key_pem = p_pubkey_pem
	bootstrap_version = p_bootstrap_version
	runtime_fingerprint = p_runtime_fingerprint
	base_source_sha = p_base_source_sha
	DirAccess.make_dir_recursive_absolute(root.path_join("packages"))
	DirAccess.make_dir_recursive_absolute(root.path_join("manifests"))
	load_state()


# --- state ---------------------------------------------------------------------------------

static func empty_state() -> Dictionary:
	return {"version": 1, "current": {}, "previous": {}, "pending": {}, "ready": {}, "bad": [],
			"disabled": false, "auto_activate": true, "rollback_count": 0,
			"boot": {"ota_id": "", "starts": 0, "healthy_id": ""}, "events": {}, "backups": [],
			"device_save_schema": 0}


func load_state() -> void:
	state = empty_state()
	var path: String = root.path_join("state.json")
	if not FileAccess.file_exists(path):
		return
	var parsed: Variant = parse_json(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		var d: Dictionary = parsed
		for k in d:
			state[k] = d[k]
		_sanitize()
		device_save_schema = int(state["device_save_schema"])
	else:
		# A corrupt state file must never brick the install: start from the embedded baseline.
		event("state", "state.json unreadable; reset to the embedded baseline")


## Type-checks every field after loading so a hand-edited or damaged file cannot throw later.
func _sanitize() -> void:
	var fresh: Dictionary = empty_state()
	if not (state["events"] is Dictionary):
		state["events"] = {}
	for s in ["current", "previous", "pending", "ready"]:
		var v: Variant = state[s]
		if not (v is Dictionary):
			state[s] = {}
			continue
		var d: Dictionary = v
		if not d.is_empty() and not _is_safe_id(d.get("ota_id", null)):
			state[s] = {}
			event("state", "slot '%s' was damaged and was cleared" % s)
	var bad_clean: Array = []
	if state["bad"] is Array:
		for b in (state["bad"] as Array):
			if b is String and not bad_clean.has(b):
				bad_clean.append(b)
	state["bad"] = bad_clean
	for k in ["disabled", "auto_activate"]:
		if not (state[k] is bool):
			state[k] = fresh[k]
	for k in ["rollback_count", "device_save_schema"]:
		state[k] = int(state[k]) if _is_whole(state[k]) else 0
	if not (state["boot"] is Dictionary):
		state["boot"] = fresh["boot"]
	var b: Dictionary = state["boot"]
	state["boot"] = {"ota_id": str(b.get("ota_id", "")) if b.get("ota_id", "") is String else "",
			"starts": int(b["starts"]) if _is_whole(b.get("starts", 0)) else 0,
			"healthy_id": str(b.get("healthy_id", "")) if b.get("healthy_id", "") is String else ""}
	var back: Array = []
	if state["backups"] is Array:
		for n in (state["backups"] as Array):
			if n is String and (n as String).is_valid_filename():
				back.append(n)
	state["backups"] = back


## Atomic: write a temp file then rename over the old one.
func save_state() -> void:
	var tmp: String = root.path_join("state.json.tmp")
	var f: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(state, "  ", true))
	f.close()
	var dst: String = root.path_join("state.json")
	if DirAccess.rename_absolute(tmp, dst) != OK:
		# Some filesystems refuse to rename over an existing file.
		DirAccess.remove_absolute(dst)
		if DirAccess.rename_absolute(tmp, dst) != OK:
			DirAccess.remove_absolute(tmp)


func _now() -> float:
	if now_fn.is_valid():
		return float(now_fn.call())
	return Time.get_unix_time_from_system()


func event(kind: String, result: String) -> void:
	var ev: Dictionary = state["events"]
	var line: String = result.left(400)
	ev[kind] = {"time": Time.get_datetime_string_from_unix_time(int(_now()), false) + "Z", "result": line}
	boot_log.append("%s: %s" % [kind, line])


func slot(name: String) -> Dictionary:
	var v: Variant = state.get(name, {})
	return v as Dictionary if v is Dictionary else {}


func slot_id(name: String) -> String:
	return str(slot(name).get("ota_id", ""))


func is_bad(ota_id: String) -> bool:
	return ota_id in (state["bad"] as Array)


func _blacklist(ota_id: String) -> void:
	if ota_id != "" and not is_bad(ota_id):
		(state["bad"] as Array).append(ota_id)


func mark_bad(m: Dictionary, reason: String) -> void:
	var id: String = str(m.get("ota_id", ""))
	_blacklist(id)
	for s in ["pending", "ready"]:
		if slot_id(s) == id:
			state[s] = {}
	if slot_id("current") == id:
		state["current"] = slot("previous")
		state["previous"] = {}
		state["rollback_count"] = int(state["rollback_count"]) + 1
	elif slot_id("previous") == id:
		state["previous"] = {}
	_discard_files(id)
	event("rejected", "%s: %s" % [id, reason])


func package_path(ota_id: String) -> String:
	return root.path_join("packages").path_join(ota_id + ".pck")


func incoming_path(ota_id: String) -> String:
	return root.path_join("packages").path_join(".incoming-%s.pck" % ota_id)


func manifest_path(ota_id: String) -> String:
	return root.path_join("manifests").path_join(ota_id + ".json")


func _discard_files(ota_id: String) -> void:
	if not _is_safe_id(ota_id):
		return
	for p in [package_path(ota_id), incoming_path(ota_id), manifest_path(ota_id), manifest_path(ota_id) + ".sig"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


# --- verification ----------------------------------------------------------------------------

## JSON text -> Variant, null when it does not parse. Unlike JSON.parse_string this never logs an engine error
## for untrusted input (a damaged state file, a hostile manifest).
static func parse_json(text: String) -> Variant:
	var j: JSON = JSON.new()
	if j.parse(text) != OK:
		return null
	return j.data


static func sha256_bytes(data: PackedByteArray) -> PackedByteArray:
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	if not data.is_empty():
		ctx.update(data)
	return ctx.finish()


static func file_sha256(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var total: int = f.get_length()
	while f.get_position() < total:
		ctx.update(f.get_buffer(1 << 20))
	return ctx.finish().hex_encode()


func verify_signature(manifest_bytes: PackedByteArray, sig_b64: String) -> bool:
	var b64: String = sig_b64.strip_edges()
	# RSA-3072 -> 384 bytes -> 512 base64 characters; refuse anything that cannot be a signature
	# before the crypto code sees it (it would log engine errors for hostile input).
	if b64.is_empty() or b64.length() > 2048 or not _is_base64(b64):
		return false
	if public_key_pem.contains("PLACEHOLDER"):
		return false   # the shipped placeholder key verifies nothing: nothing is ever mounted
	var key: CryptoKey = CryptoKey.new()
	if key.load_from_string(public_key_pem, true) != OK:
		return false
	var sig: PackedByteArray = Marshalls.base64_to_raw(b64)
	if sig.is_empty():
		return false
	return Crypto.new().verify(HashingContext.HASH_SHA256, sha256_bytes(manifest_bytes), sig, key)


static func _is_base64(s: String) -> bool:
	if s.length() % 4 != 0:
		return false
	for c in s:
		if not "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".contains(c):
			return false
	return true


static func _is_hex(v: Variant, n: int) -> bool:
	if not (v is String):
		return false
	var s: String = v
	if s.length() != n:
		return false
	for c in s:
		if not "0123456789abcdef".contains(c):
			return false
	return true


static func _is_whole(v: Variant) -> bool:
	if v is int:
		return true
	return v is float and is_finite(v) and v == floorf(v) and absf(v) < 9.0e15


static func _is_safe_id(v: Variant) -> bool:
	if not (v is String):
		return false
	var s: String = v
	if s.is_empty() or s.length() > 64 or s.begins_with("."):
		return false
	for c in s:
		if not "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.".contains(c):
			return false
	return true


## "" when the manifest may be used on this device, otherwise the reason it may not.
## Reasons that start "native update required" / "incompatible runtime" / "save incompatible" mean
## the OTA is fine but not for this install; anything else is a faulty or unwanted manifest.
func validate_manifest(m: Dictionary) -> String:
	for k in REQUIRED:
		if not m.has(k):
			return "invalid manifest: missing '%s'" % k
	if not _is_whole(m["schema"]) or int(m["schema"]) != 1:
		return "invalid manifest: unknown schema %s" % str(m["schema"])
	if not (m["channel"] is String) or m["channel"] != channel:
		return "invalid manifest: channel '%s' (this install follows '%s')" % [str(m["channel"]), channel]
	if not (m["runtime_id"] is String):
		return "invalid manifest: runtime_id"
	if m["runtime_id"] != runtime_id:
		return runtime_mismatch(str(m["runtime_id"]))
	if not _is_hex(m["runtime_fingerprint"], 64):
		return "invalid manifest: runtime_fingerprint is not a SHA-256"
	if m["runtime_fingerprint"] != runtime_fingerprint:
		return "incompatible runtime: native fingerprint %s differs from this app's %s (OTA built from different native inputs)" % [
				str(m["runtime_fingerprint"]).left(12), runtime_fingerprint.left(12)]
	if not _is_hex(m["base_source_sha"], 40):
		return "invalid manifest: base_source_sha is not a 40-character git SHA"
	if m["base_source_sha"] != base_source_sha:
		return "native update required: OTA patches native baseline %s, this app embeds %s" % [
				str(m["base_source_sha"]).left(12), base_source_sha.left(12)]
	if m["platform"] != Config.PLATFORM:
		return "invalid manifest: platform '%s' (OTA is %s only)" % [str(m["platform"]), Config.PLATFORM]
	if m["payload_kind"] != "patch":
		return "invalid manifest: payload_kind '%s' (only 'patch' is supported)" % str(m["payload_kind"])
	if not _is_whole(m["minimum_bootstrap_version"]) or int(m["minimum_bootstrap_version"]) < 1:
		return "invalid manifest: minimum_bootstrap_version"
	if int(m["minimum_bootstrap_version"]) > bootstrap_version:
		return "native update required: OTA needs bootstrap v%d, installed v%d" % [
				int(m["minimum_bootstrap_version"]), bootstrap_version]
	if not _is_hex(m["source_sha"], 40):
		return "invalid manifest: source_sha is not a 40-character git SHA"
	if not _is_hex(m["pck_sha256"], 64):
		return "invalid manifest: pck_sha256 is not a SHA-256"
	if not _is_whole(m["pck_size"]) or int(m["pck_size"]) < 1 or int(m["pck_size"]) > MAX_PCK_BYTES:
		return "invalid manifest: pck_size out of range (1..%d)" % MAX_PCK_BYTES
	var url: Variant = m["pck_url"]
	if not (url is String) or not ((url as String).begins_with("https://") \
			or (allow_local_http and (url as String).begins_with("http://127.0.0.1:"))):
		return "invalid manifest: package URL must be HTTPS"
	if url_base != "" and not url_in_base(str(url), url_base):
		return "invalid manifest: package URL is outside the release download base %s" % url_base
	if not _is_safe_id(m["ota_id"]):
		return "invalid manifest: ota_id"
	if not _is_whole(m["seq"]) or int(m["seq"]) < 1:
		return "invalid manifest: seq must be a positive integer"
	if not _is_whole(m["native_version"]) or int(m["native_version"]) < 1:
		return "invalid manifest: native_version"
	if not (m["created_at"] is String):
		return "invalid manifest: created_at"
	if not _is_whole(m["app_minor"]) or int(m["app_minor"]) < 1:
		return "invalid manifest: app_minor must be a whole number >= 1"
	# Owner-facing version: "<native_version>.<app_minor>" (v7.1 = first OTA on the v7 APK). Independent of seq / ota_id.
	if not (m["game_version"] is String):
		return "invalid manifest: game_version is not MAJOR.MINOR"
	var gv: PackedStringArray = (m["game_version"] as String).split(".")
	if gv.size() != 2 or not (gv[0].is_valid_int() and gv[1].is_valid_int()):
		return "invalid manifest: game_version is not MAJOR.MINOR"
	var want_gv: String = "%d.%d" % [int(m["native_version"]), int(m["app_minor"])]
	if m["game_version"] != want_gv:
		return "invalid manifest: game_version '%s' does not match native_version.app_minor (%s)" % [str(m["game_version"]), want_gv]
	if not _is_whole(m["save_schema"]) or not _is_whole(m["min_save_schema"]) \
			or int(m["min_save_schema"]) < 1 or int(m["save_schema"]) < int(m["min_save_schema"]):
		return "invalid manifest: save_schema / min_save_schema"
	var fwhy: String = _files_reason(m["files"])
	if fwhy != "":
		return fwhy
	return save_compat(m)


const RELEASES_MARK := "/releases/download/"


## The only place a pointer may send the client: ".../releases/download/" for a GitHub Releases pointer
## (".../releases/download/ota-channel-dev/latest.json?t=1" -> ".../releases/download/"); a pointer without that
## segment (desktop test layouts) is anchored to its own directory.
static func base_of(pointer_url: String) -> String:
	var u: String = pointer_url.get_slice("?", 0).get_slice("#", 0)
	var i: int = u.find(RELEASES_MARK)
	if i >= 0:
		return u.substr(0, i + RELEASES_MARK.length())
	return u.substr(0, u.rfind("/") + 1)


## True when `url` lies inside `base` (which ends in "/"): same scheme, host, port and path by plain prefix, and the
## rest is a plain relative path (no "..", "\\", "%", "@", "?" or "#"). Another repository, host or a prefix trick
## ("ota/dev-evil/", "github.io.evil.com") never matches. Under a ".../releases/download/" base the rest must also be
## "<ota release tag>/<asset>": the tag begins "ota-" and is not a channel pointer release ("ota-channel-...").
static func url_in_base(url: String, base: String) -> bool:
	if base == "" or not base.ends_with("/") or not url.begins_with(base):
		return false
	var rest: String = url.substr(base.length())
	if rest.is_empty():
		return false
	for bad in ["..", "\\", "%", "@", "?", "#"]:
		if rest.contains(bad):
			return false
	if base.ends_with(RELEASES_MARK):
		var parts: PackedStringArray = rest.split("/")
		if parts.size() != 2 or parts[1].is_empty() or not parts[0].begins_with("ota-") or parts[0].begins_with("ota-channel-"):
			return false
	return true


## files[] must be a list of {path, op} that never touches the native boundary.
func _files_reason(files: Variant) -> String:
	if not (files is Array):
		return "invalid manifest: files must be a list"
	for e in (files as Array):
		if not (e is Dictionary) or not ((e as Dictionary).get("path", null) is String):
			return "invalid manifest: files[] entry without a path"
		var path: String = (e as Dictionary)["path"]
		if (e as Dictionary).get("op", null) not in FILE_OPS:
			return "invalid manifest: files[] op for '%s' is not add|replace|remove" % path
		if Protected.is_unsafe(path):
			return "invalid manifest: files[] has an unsafe path '%s'" % path
		if Protected.is_protected(path):
			return "invalid manifest: files[] contains protected path '%s' (a native update is required for it)" % path
	return ""


## Why an OTA for `other` cannot run here. An OTA built for an OLDER revision of this same
## runtime is permanently incompatible with this app ("incompatible runtime"); anything else
## needs a newer app ("native update required").
func runtime_mismatch(other: String) -> String:
	var re: RegEx = RegEx.create_from_string("^(.*)-r(\\d+)$")
	var a: RegExMatch = re.search(other)
	var b: RegExMatch = re.search(runtime_id)
	if a != null and b != null and a.get_string(1) == b.get_string(1) and int(a.get_string(2)) < int(b.get_string(2)):
		return "incompatible runtime: OTA targets older runtime %s, this app runs %s (waiting for a compatible OTA)" % [other, runtime_id]
	return "native update required: OTA targets runtime %s, installed runtime is %s" % [other, runtime_id]


## An OTA reads saves from min_save_schema up to save_schema. A save newer than the OTA
## understands (e.g. after rolling back past a migration) blocks activation.
func save_compat(m: Dictionary) -> String:
	if device_save_schema <= 0:
		return ""
	var id: String = str(m.get("ota_id", "?"))
	if device_save_schema > int(m.get("save_schema", 0)):
		return "save incompatible: save schema %d is newer than OTA %s understands (%d)" % [
				device_save_schema, id, int(m.get("save_schema", 0))]
	if device_save_schema < int(m.get("min_save_schema", 0)):
		return "save incompatible: OTA %s no longer reads save schema %d" % [id, device_save_schema]
	return ""


## Signature + manifest checks on exact bytes. Returns [manifest, ""] or [{}, reason].
func check_manifest(manifest_bytes: PackedByteArray, sig_b64: String) -> Array:
	if manifest_bytes.size() > MAX_MANIFEST_BYTES:
		return [{}, "manifest too large"]
	if not verify_signature(manifest_bytes, sig_b64):
		return [{}, "signature verification failed"]
	var parsed: Variant = parse_json(manifest_bytes.get_string_from_utf8())
	if not (parsed is Dictionary):
		return [{}, "invalid manifest: not a JSON object"]
	var m: Dictionary = parsed
	var why: String = validate_manifest(m)
	return [m if why == "" else {}, why]


## Size and hash of a package file against its manifest.
func verify_package(m: Dictionary, path: String) -> String:
	if not FileAccess.file_exists(path):
		return "package missing"
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "package unreadable"
	var size: int = f.get_length()
	f.close()
	if size != int(m["pck_size"]):
		return "size mismatch: %d bytes, manifest says %d" % [size, int(m["pck_size"])]
	var h: String = file_sha256(path)
	if h != str(m["pck_sha256"]):
		return "SHA-256 mismatch: got %s" % h
	return ""


## Re-checks a stored package: the stored signed manifest must still verify, match the state slot
## and describe the stored file.
func verify_installed(m: Dictionary) -> String:
	var id: String = str(m.get("ota_id", ""))
	if not _is_safe_id(id):
		return "invalid manifest: ota_id"
	var mp: String = manifest_path(id)
	if not FileAccess.file_exists(mp) or not FileAccess.file_exists(mp + ".sig"):
		return "stored manifest missing"
	var res: Array = check_manifest(FileAccess.get_file_as_bytes(mp), FileAccess.get_file_as_string(mp + ".sig"))
	if res[1] != "":
		return res[1]
	var sm: Dictionary = res[0]
	if sm.get("pck_sha256") != m.get("pck_sha256") or sm.get("ota_id") != id or int(sm.get("seq", -1)) != int(m.get("seq", -2)):
		return "stored manifest does not match state"
	return verify_package(sm, package_path(id))


# --- download staging --------------------------------------------------------------------------

## "" when `m` is newer than everything installed or staged, else why it is not an update.
func stale_reason(m: Dictionary) -> String:
	var known: int = known_seq()
	if int(m.get("seq", 0)) <= known:
		return "stale: seq %d is not newer than the installed/staged seq %d" % [int(m.get("seq", 0)), known]
	return ""


## Verifies a finished download at incoming_path() and promotes it. Never touches the active
## package. On any failure the temp file is deleted and nothing else changes.
func stage_incoming(manifest_bytes: PackedByteArray, sig_b64: String) -> String:
	var res: Array = check_manifest(manifest_bytes, sig_b64)
	if res[1] != "":
		event("verify", "rejected: " + str(res[1]))
		return res[1]
	var m: Dictionary = res[0]
	var id: String = m["ota_id"]
	var tmp: String = incoming_path(id)
	if is_bad(id):
		DirAccess.remove_absolute(tmp)
		var bw: String = "%s was rejected or rolled back on this device; not staging it again" % id
		event("verify", bw)
		return bw
	var sw: String = stale_reason(m)
	if sw != "":
		DirAccess.remove_absolute(tmp)
		event("verify", "rejected %s: %s" % [id, sw])
		return sw
	var why: String = verify_package(m, tmp)
	if why != "":
		DirAccess.remove_absolute(tmp)
		# Published packages are immutable, so a full-size file with the wrong hash will never
		# become valid: remember it. Short/interrupted downloads stay retryable.
		if why.begins_with("SHA-256 mismatch"):
			_blacklist(id)
		event("verify", "rejected %s: %s (temp file deleted)" % [id, why])
		save_state()
		return why
	if not _write_bytes(manifest_path(id), manifest_bytes) or not _write_bytes(manifest_path(id) + ".sig", sig_b64.strip_edges().to_utf8_buffer()):
		DirAccess.remove_absolute(tmp)
		event("verify", "could not store the manifest of %s" % id)
		return "could not store the manifest"
	DirAccess.remove_absolute(package_path(id))
	if DirAccess.rename_absolute(tmp, package_path(id)) != OK:
		DirAccess.remove_absolute(tmp)
		event("verify", "could not store the package of %s" % id)
		return "could not store the package"
	state["ready"] = m
	event("verify", "verified %s (%d bytes, sha256 %s)" % [id, int(m["pck_size"]), str(m["pck_sha256"]).left(12)])
	if state["auto_activate"]:
		activate_ready()
	save_state()
	return ""


static func _write_bytes(path: String, data: PackedByteArray) -> bool:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	f.close()
	return true


## READY -> PENDING: loaded on the next clean start.
func activate_ready() -> String:
	var r: Dictionary = slot("ready")
	if r.is_empty():
		return "nothing downloaded"
	if is_bad(str(r["ota_id"])):
		return "%s was rejected on this device" % r["ota_id"]
	var why: String = save_compat(r)
	if why != "":
		return why
	state["pending"] = r
	state["ready"] = {}
	event("activate", "%s will load on next start" % r["ota_id"])
	save_state()
	return ""


## Newest known OTA sequence (anything at or below it is not an update).
func known_seq() -> int:
	var best: int = 0
	for s in ["current", "pending", "ready"]:
		best = maxi(best, int(slot(s).get("seq", 0)))
	return best


# --- boot selection ------------------------------------------------------------------------------

func _default_canary() -> bool:
	for p in CANARY_RESOURCES:
		if not ResourceLoader.exists(p):
			return false
	return true


## Chooses and mounts a package before any replaceable game resource is loaded.
## `loader` mounts a verified path and returns success (ProjectSettings.load_resource_pack on a
## device). Every outcome falls back towards CURRENT, PREVIOUS and finally the embedded baseline.
func boot(loader: Callable) -> Dictionary:
	active = {}
	active_slot = ""
	first_run = false
	restart_required = false
	boot_verify_ms = 0.0
	boot_mount_ms = 0.0
	if state["disabled"]:
		event("load", "OTA disabled by user: running the embedded baseline")
		var bd: Dictionary = state["boot"]
		state["boot"] = {"ota_id": "", "starts": 0, "healthy_id": bd.get("healthy_id", "")}
		save_state()
		return active
	# Snapshot first: mark_bad() shifts PREVIOUS into CURRENT while we iterate.
	var candidates: Array = []
	for name in ["pending", "current", "previous"]:
		if not slot(name).is_empty():
			candidates.append([name, slot(name)])
	for c in candidates:
		var name: String = c[0]
		var m: Dictionary = c[1]
		var id: String = str(m["ota_id"])
		if is_bad(id):
			if slot_id(name) == id:
				state[name] = {}
			continue
		if str(m.get("base_source_sha", "")) != base_source_sha:
			# Left over from before a different APK was installed: a patch is only valid on its own baseline.
			if slot_id(name) == id:
				state[name] = {}
			_discard_files(id)
			event("load", "dropped %s: incompatible baseline (patch is for %s, this app embeds %s)" % [
					id, str(m.get("base_source_sha", "")).left(12), base_source_sha.left(12)])
			continue
		var b: Dictionary = state["boot"]
		var attempted: bool = b["ota_id"] == id
		if attempted and int(b["starts"]) >= MAX_UNHEALTHY_STARTS:
			mark_bad(m, "never reached boot health after %d starts" % int(b["starts"]))
			continue
		var t0: int = Time.get_ticks_usec()
		var why: String = validate_manifest(m)
		if why == "":
			why = verify_installed(m)
		boot_verify_ms += (Time.get_ticks_usec() - t0) / 1000.0
		if why != "":
			if why.begins_with("save incompatible") or why.begins_with("native update required"):
				event("load", "skipped %s: %s" % [id, why])
				continue
			if why.begins_with("incompatible runtime"):
				# Not a faulty OTA: it can never run on this app again. Dropped, not blacklisted.
				if slot_id(name) == id:
					state[name] = {}
				_discard_files(id)
				event("load", "dropped %s: %s" % [id, why])
				continue
			mark_bad(m, why)
			continue
		var never_run: bool = name == "pending" and not attempted and b.get("healthy_id", "") != id
		if never_run:
			var bwhy: String = backup_saves(id)
			if bwhy != "":
				event("backup", "save backup before first activation of %s failed: %s" % [id, bwhy])
		# Count the attempt BEFORE mounting, so a crash during load still counts.
		state["boot"] = {"ota_id": id, "starts": (int(b["starts"]) if attempted else 0) + 1, "healthy_id": b.get("healthy_id", "")}
		save_state()
		var t1: int = Time.get_ticks_usec()
		var mounted: bool = bool(loader.call(package_path(id)))
		boot_mount_ms += (Time.get_ticks_usec() - t1) / 1000.0
		if not mounted:
			mark_bad(m, "load_resource_pack failed")
			continue
		# A pack cannot be unmounted: if the game's own key resources are gone after the mount, the only
		# safe move is to blacklist it and have the caller restart clean.
		var ok: bool = bool(canary.call()) if canary.is_valid() else _default_canary()
		if not ok:
			mark_bad(m, "post-mount self-check failed (the game's key resources no longer resolve)")
			restart_required = true
			state["boot"] = {"ota_id": "", "starts": 0, "healthy_id": b.get("healthy_id", "")}
			save_state()
			return {}
		active = m
		active_slot = name
		first_run = never_run
		event("load", "loaded %s (%s) from %s" % [id, name, str(m["source_sha"]).left(12)])
		save_state()
		return active
	state["boot"] = {"ota_id": "", "starts": 0, "healthy_id": (state["boot"] as Dictionary).get("healthy_id", "")}
	event("load", "no OTA selected: running the embedded baseline")
	save_state()
	return active


## The game reached its boot-health checkpoint with `active` mounted (or the baseline running).
func mark_healthy() -> void:
	var id: String = str(active.get("ota_id", ""))
	state["boot"] = {"ota_id": id, "starts": 0, "healthy_id": id}
	if id != "" and active_slot == "pending":
		if slot_id("current") != id:
			state["previous"] = slot("current")
		state["current"] = active
		if slot_id("pending") == id:
			state["pending"] = {}
		active_slot = "current"
	if running_save_schema > 0:
		state["device_save_schema"] = running_save_schema
		device_save_schema = running_save_schema
	event("health", "healthy: %s" % (id if id != "" else "embedded baseline"))
	_prune()
	save_state()


## CURRENT (else an unconfirmed PENDING) is abandoned on the next start and never downloaded again;
## PREVIOUS (else the embedded baseline) runs instead.
func rollback() -> String:
	var prev: Dictionary = slot("previous")
	var cur: Dictionary = slot("current")
	var from_slot: String = "current"
	if cur.is_empty():
		cur = slot("pending")
		from_slot = "pending"
	if cur.is_empty():
		return "no OTA to roll back from"
	if from_slot == "current" and not prev.is_empty():
		var why: String = save_compat(prev)
		if why != "":
			return why
	var cid: String = str(cur["ota_id"])
	_blacklist(cid)
	if from_slot == "current":
		state["current"] = prev
		state["previous"] = {}
	else:
		state["pending"] = {}
	if slot_id("pending") == cid:
		state["pending"] = {}
	state["ready"] = {}
	state["rollback_count"] = int(state["rollback_count"]) + 1
	var to: String = slot_id("current") if slot_id("current") != "" else "embedded baseline"
	event("rollback", "rolled back from %s to %s on next start" % [cid, to])
	save_state()
	return ""


func set_disabled(on: bool) -> void:
	state["disabled"] = on
	event("baseline", "OTA disabled: next start uses the embedded baseline" if on else "OTA re-enabled")
	save_state()


## Remove packages and manifests no slot refers to (never the active one) and stale temp files.
func _prune() -> void:
	var keep: Dictionary = {}
	for s in ["current", "previous", "pending", "ready"]:
		var id: String = slot_id(s)
		if id != "":
			keep[id] = true
	keep[str(active.get("ota_id", ""))] = true
	var pdir: String = root.path_join("packages")
	for f in _list(pdir, false):
		if f.begins_with(".incoming-"):
			DirAccess.remove_absolute(pdir.path_join(f))
		elif f.ends_with(".pck") and not keep.has(f.get_basename()):
			DirAccess.remove_absolute(pdir.path_join(f))
	var mdir: String = root.path_join("manifests")
	for f in _list(mdir, false):
		var base: String = f.trim_suffix(".sig").trim_suffix(".json")
		if not keep.has(base):
			DirAccess.remove_absolute(mdir.path_join(f))


# --- save backups ----------------------------------------------------------------------------------

## Copies the save folder (read only) to backups/<ota_id>_<unix>/ and keeps the newest MAX_BACKUPS.
## Returns "" on success (or when there is nothing to back up), else the reason.
func backup_saves(ota_id: String) -> String:
	if save_root == "" or not DirAccess.dir_exists_absolute(save_root):
		return ""
	var name: String = "%s_%d" % [ota_id, int(_now())]
	var n: int = 1
	var base: String = name
	while DirAccess.dir_exists_absolute(root.path_join("backups").path_join(name)):
		n += 1
		name = "%s_%d" % [base, n]
	var dst: String = root.path_join("backups").path_join(name)
	DirAccess.make_dir_recursive_absolute(dst)
	var ok: bool = _copy_tree(save_root, dst)
	var list: Array = state["backups"]
	list.append(name)
	while list.size() > MAX_BACKUPS:
		_remove_tree(root.path_join("backups").path_join(str(list.pop_front())))
	event("backup", "saves copied to backups/%s%s" % [name, "" if ok else " (incomplete)"])
	save_state()
	return "" if ok else "copy incomplete"


## Files or sub-directories of `dir`, INCLUDING hidden (dot) entries: the static DirAccess helpers skip them.
static func _list(dir: String, dirs: bool) -> PackedStringArray:
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return PackedStringArray()
	d.include_hidden = true
	return d.get_directories() if dirs else d.get_files()


static func _copy_tree(src: String, dst: String) -> bool:
	var ok: bool = true
	for f in _list(src, false):
		var data: PackedByteArray = FileAccess.get_file_as_bytes(src.path_join(f))
		if data.is_empty() and FileAccess.get_open_error() != OK:
			ok = false
			continue
		ok = _write_bytes(dst.path_join(f), data) and ok
	for d in _list(src, true):
		DirAccess.make_dir_recursive_absolute(dst.path_join(d))
		ok = _copy_tree(src.path_join(d), dst.path_join(d)) and ok
	return ok


static func _remove_tree(path: String) -> void:
	for f in _list(path, false):
		DirAccess.remove_absolute(path.path_join(f))
	for d in _list(path, true):
		_remove_tree(path.path_join(d))
	DirAccess.remove_absolute(path)
