extends Node
## v7 OTA native layer (scripts/boot/*, docs/OTA.md sections 5 and 7-10). Pure logic over scratch storage with
## throw-away RSA keys, fake mounters and a loopback HTTP stub: never touches the real user://ota, never the
## network. One real ProjectSettings.load_resource_pack mount of a pack built with PCKPacker. Runs headless; must
## run with PURGATORY_SAVE_ROOT set (see run_tests.sh).

const OtaCore := preload("res://scripts/boot/ota_core.gd")
const OtaUpdater := preload("res://scripts/boot/ota_updater.gd")
const Protected := preload("res://scripts/boot/ota_protected.gd")
const Config := preload("res://scripts/boot/ota_config.gd")
const BootScript := preload("res://scripts/boot/boot.gd")
const HttpStub := preload("res://tests/ota_http_stub.gd")

const RUNTIME := "android-godot-4.6.0-r1"
const FP := "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
const BASE := "0123456789abcdef0123456789abcdef01234567"

var _fails := 0
var _checks := 0
var _key: CryptoKey
var _other: CryptoKey
var _pem := ""
var _scratch := ""
var _save := ""
var _n := 0
var _clock := 1800000000.0
var _mounted: Array[String] = []
var _fail_mount: Array[String] = []
var _frames := 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _has(text: String, needle: String, label: String) -> void:
	_check(text.contains(needle), "%s (got '%s')" % [label, text])


func _process(_dt: float) -> void:
	_frames += 1


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	_scratch = OS.get_user_data_dir().path_join("ota_core_test_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_scratch)
	_key = Crypto.new().generate_rsa(2048)
	_other = Crypto.new().generate_rsa(2048)
	_pem = _key.save_to_string(true)
	_make_save_folder()
	_t_protected_and_config()
	_t_manifest_matrix()
	_t_signature_and_json()
	_t_package_verify_and_staging()
	_t_state_machine()
	_t_corruption()
	_t_identity_changes()
	_t_manual_actions()
	_t_save_schema()
	_t_saves_untouched_and_backups()
	_t_real_mount()
	await _t_updater()
	await _t_boot_node()
	_t_policy_and_taps()
	_t_boot_gating()
	_t_save_root_mirror()
	_t_boundary_mirror()
	_remove_tree(_scratch)
	print("test_ota_core: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


# --- helpers ---------------------------------------------------------------------------------

func _new_root() -> String:
	_n += 1
	var r: String = _scratch.path_join("root%d" % _n)
	DirAccess.make_dir_recursive_absolute(r)
	return r


func _tick() -> float:
	_clock += 1.0
	return _clock


## A device: OtaCore over `root` with the test identity. Calling it again on the same root is a restart.
func _core(root: String, runtime: String = RUNTIME, fp: String = FP, base: String = BASE) -> OtaCore:
	var c: OtaCore = OtaCore.new(root, runtime, "dev", _pem, 1, fp, base)
	c.save_root = _save
	c.now_fn = _tick
	return c


func _write(path: String, data: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(data)
	f.close()


func _payload(seq: int, size: int = 3000) -> PackedByteArray:
	var p: PackedByteArray = PackedByteArray()
	p.resize(size)
	for i in size:
		p[i] = (i * 31 + seq * 7) % 251
	return p


func _manifest(seq: int, payload: PackedByteArray, over: Dictionary = {}) -> Dictionary:
	var m: Dictionary = {"schema": 1, "channel": "dev", "ota_id": "dev-%06d" % seq, "seq": seq,
			"source_sha": "%040x" % (seq + 0xabc), "runtime_id": RUNTIME, "runtime_fingerprint": FP,
			"minimum_bootstrap_version": 1, "game_version": "7.%d" % seq, "app_minor": seq, "save_schema": 1, "min_save_schema": 1,
			"pck_url": "https://example.invalid/%d.pck" % seq, "pck_sha256": OtaCore.sha256_bytes(payload).hex_encode(),
			"pck_size": payload.size(), "created_at": "2026-10-06T00:00:00Z",
			"build_run": {"id": str(1000 + seq), "number": "", "attempt": "", "url": ""},
			"payload_kind": "patch", "base_source_sha": BASE, "platform": "android", "native_version": 7,
			"files": [{"path": "godot/scripts/example.gd", "op": "replace"}, {"path": "godot/old/gone.tscn", "op": "remove"}]}
	m.merge(over, true)
	return m


func _sign(m: Dictionary, key: CryptoKey = null) -> Array:
	var bytes: PackedByteArray = JSON.stringify(m, "  ", true).to_utf8_buffer()
	return [bytes, _sign_bytes(bytes, key)]


func _sign_bytes(bytes: PackedByteArray, key: CryptoKey = null) -> String:
	var k: CryptoKey = key if key != null else _key
	return Marshalls.raw_to_base64(Crypto.new().sign(HashingContext.HASH_SHA256, OtaCore.sha256_bytes(bytes), k))


## Writes the finished download to .incoming and stages it. Returns {m, why, bytes, sig}.
func _stage(c: OtaCore, seq: int, over: Dictionary = {}, payload: PackedByteArray = PackedByteArray()) -> Dictionary:
	var pl: PackedByteArray = payload if not payload.is_empty() else _payload(seq)
	var m: Dictionary = _manifest(seq, pl, over)
	var s: Array = _sign(m)
	_write(c.incoming_path(m["ota_id"]), pl)
	var why: String = c.stage_incoming(s[0], s[1])
	return {"m": m, "why": why, "bytes": s[0], "sig": s[1]}


## Stages seq, restarts, boots it and reports healthy: it becomes CURRENT. Returns the new core (the running device).
func _make_current(root: String, seq: int, over: Dictionary = {}) -> OtaCore:
	var c: OtaCore = _core(root)
	var r: Dictionary = _stage(c, seq, over)
	_check(r["why"] == "", "staging seq %d works (%s)" % [seq, r["why"]])
	c = _core(root)
	c.boot(_fake_mount)
	c.mark_healthy()
	return c


func _fake_mount(path: String) -> bool:
	_mounted.append(path)
	return not (path.get_file().get_basename() in _fail_mount)


func _list_files(dir: String, prefix: String = "") -> Array[String]:
	var out: Array[String] = []
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return out
	d.include_hidden = true
	for f in d.get_files():
		out.append(prefix + f)
	for sub in d.get_directories():
		out.append_array(_list_files(dir.path_join(sub), prefix + sub + "/"))
	out.sort()
	return out


func _tree_hash(dir: String) -> String:
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for rel in _list_files(dir):
		ctx.update(rel.to_utf8_buffer())
		ctx.update(FileAccess.get_file_as_bytes(dir.path_join(rel)))
	return ctx.finish().hex_encode()


func _make_save_folder() -> void:
	_save = _scratch.path_join("fake_saves")
	_write(_save.path_join("settings.json"), '{"music": 0.5}'.to_utf8_buffer())
	_write(_save.path_join("saves/slot_1.json"), '{"name": "Brunhild", "runs": 3}'.to_utf8_buffer())
	_write(_save.path_join("saves/deep/x.bin"), _payload(9, 777))
	_write(_save.path_join(".hidden_profile"), "keep me".to_utf8_buffer())


static func _remove_tree(path: String) -> void:
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	for sub in d.get_directories():
		_remove_tree(path.path_join(sub))
	DirAccess.remove_absolute(path)


func _incoming_files(c: OtaCore) -> Array[String]:
	var out: Array[String] = []
	for f in _list_files(c.root.path_join("packages")):
		if f.begins_with(".incoming-"):
			out.append(f)
	return out


# --- 1. protected paths mirror, config -----------------------------------------------------------

func _t_protected_and_config() -> void:
	for p in ["project.godot", "project.binary", "export_presets.cfg", "VERSION", "build_info.json", "scripts/boot/boot.gd",
			"scripts/boot/ota_core.gd.remap", "scripts/boot/ota_core.gdc", "android/build/x.gradle", "addons/a/b.gdextension",
			"libx.so", "x.dll", "a/b.dylib", "godot/project.godot", "godot/scripts/boot/boot.gd", "res://project.godot",
			"./project.godot", "godot/extension_list.cfg", ".godot/extension_list.cfg", "scripts\\boot\\boot.gd"]:
		_check(Protected.is_protected(p), "protected path: " + p)
	for p in ["scripts/enemy_manager.gd", "godot/scripts/enemy_manager.gd", "scenes/MainMenu.tscn", "godot/assets/x.png",
			"scripts/save_schema.gd", "scripts/bootstrap_helper.gd", "data/buffs.json", "scripts/boot_menu.gd", "Project.godot"]:
		_check(not Protected.is_protected(p), "game-layer path is not protected: " + p)
	for p in ["", "../x.gd", "a/../b.gd", "/abs.gd", "a//b.gd", "c:/x.gd", "dir/", "a\u0001b.gd"]:
		_check(Protected.is_unsafe(p), "unsafe path: '%s'" % p.c_escape())
	_check(not Protected.is_unsafe("godot/scripts/a b.gd"), "ordinary relative path is safe")
	_check(Config.runtime_id("android") == "android-godot-%s-r%d" % [Config.engine_version(), Config.RUNTIME_REVISION], "runtime_id format")
	_check(Config.runtime_id("android").begins_with("android-godot-4.6."), "runtime id names the engine (%s)" % Config.runtime_id("android"))
	_check(Config.REPO == "verbal76/Purgatory-Dungeon", "transport repo is this public source repo's own Releases")
	_check(Config.pointer_url("dev") == "https://github.com/verbal76/Purgatory-Dungeon/releases/download/ota-channel-dev/latest.json", "pointer url")
	_check(Config.release_url("ota-dev-000003", "purgatory-dev-000003.pck") == "https://github.com/verbal76/Purgatory-Dungeon/releases/download/ota-dev-000003/purgatory-dev-000003.pck", "release asset url")
	_check(Config.channel_tag("x") == "ota-channel-x" and Config.ota_tag("dev", 3) == "ota-dev-000003", "channel and OTA release tags")
	var cmap: Dictionary = (Config as Script).get_script_constant_map()
	_check(not cmap.has("BASE_URL") and not Config.pointer_url("dev").contains("github.io"), "no Pages transport left")
	_check(OtaCore.base_of(Config.pointer_url("dev") + "?t=5") == "https://github.com/verbal76/Purgatory-Dungeon/releases/download/", "base_of the real pointer is the Releases download base")
	_check(OtaCore.base_of("http://127.0.0.1:18500/releases/download/ota-channel-dev/latest.json") == "http://127.0.0.1:18500/releases/download/", "base_of the hook pointer in the Releases layout")
	_check(OtaCore.base_of("http://127.0.0.1:18500/dev/latest.json?t=1") == "http://127.0.0.1:18500/dev/", "a pointer without /releases/download/ is anchored to its own directory")
	_check(Config.is_safe_channel("dev") and Config.is_safe_channel("stable-2") and not Config.is_safe_channel("a/b")
			and not Config.is_safe_channel("") and not Config.is_safe_channel("A") and not Config.is_safe_channel("x".repeat(40)), "channel names are URL safe")
	_check(Config.FEATURE == "ota" and Config.BOOTSTRAP_VERSION == 1 and Config.CHANNEL == "dev", "config constants")


# --- 2. manifest validation matrix (one failing rule per case) --------------------------------------

func _t_manifest_matrix() -> void:
	var c: OtaCore = _core(_new_root())
	var good: Dictionary = _manifest(5, _payload(5))
	_check(c.validate_manifest(good) == "", "a complete manifest validates (%s)" % c.validate_manifest(good))
	for k in OtaCore.REQUIRED:
		var m: Dictionary = good.duplicate(true)
		m.erase(k)
		_has(c.validate_manifest(m), "missing '%s'" % k, "missing key " + k)
	var cases: Array = [
		["schema 2", {"schema": 2}, "unknown schema"],
		["schema string", {"schema": "1"}, "unknown schema"],
		["wrong channel", {"channel": "stable"}, "channel 'stable'"],
		["channel not a string", {"channel": 4}, "channel"],
		["runtime of a newer revision", {"runtime_id": "android-godot-4.6.0-r2"}, "native update required"],
		["runtime of another engine", {"runtime_id": "android-godot-4.7.0-r1"}, "native update required"],
		["runtime of another platform", {"runtime_id": "windows-godot-4.6.0-r1"}, "native update required"],
		["fingerprint differs", {"runtime_fingerprint": "1".repeat(64)}, "incompatible runtime"],
		["fingerprint malformed", {"runtime_fingerprint": "xyz"}, "runtime_fingerprint is not"],
		["fingerprint uppercase", {"runtime_fingerprint": FP.to_upper()}, "runtime_fingerprint is not"],
		["wrong base_source_sha", {"base_source_sha": "e".repeat(40)}, "native update required: OTA patches native baseline"],
		["base_source_sha malformed", {"base_source_sha": "abc"}, "base_source_sha is not"],
		["platform windows", {"platform": "windows"}, "platform"],
		["payload_kind full", {"payload_kind": "full"}, "payload_kind"],
		["bootstrap too new", {"minimum_bootstrap_version": 2}, "native update required: OTA needs bootstrap"],
		["bootstrap zero", {"minimum_bootstrap_version": 0}, "minimum_bootstrap_version"],
		["source_sha short", {"source_sha": "abc123"}, "source_sha"],
		["source_sha uppercase", {"source_sha": "A".repeat(40)}, "source_sha"],
		["pck_sha256 short", {"pck_sha256": "abc"}, "pck_sha256"],
		["pck_size zero", {"pck_size": 0}, "pck_size"],
		["pck_size negative", {"pck_size": -5}, "pck_size"],
		["pck_size above the cap", {"pck_size": 536870913}, "pck_size"],
		["pck_size fractional", {"pck_size": 1.5}, "pck_size"],
		["pck_size a string", {"pck_size": "12"}, "pck_size"],
		["http package url", {"pck_url": "http://example.com/a.pck"}, "HTTPS"],
		["local http without the test hook", {"pck_url": "http://127.0.0.1:9/a.pck"}, "HTTPS"],
		["ftp package url", {"pck_url": "ftp://example.com/a.pck"}, "HTTPS"],
		["package url not a string", {"pck_url": 5}, "HTTPS"],
		["ota_id with a slash", {"ota_id": "../x"}, "ota_id"],
		["ota_id hidden", {"ota_id": ".hidden"}, "ota_id"],
		["ota_id empty", {"ota_id": ""}, "ota_id"],
		["ota_id with a space", {"ota_id": "dev 1"}, "ota_id"],
		["seq zero", {"seq": 0}, "seq"],
		["seq negative", {"seq": -1}, "seq"],
		["seq fractional", {"seq": 2.5}, "seq"],
		["native_version zero", {"native_version": 0}, "native_version"],
		["created_at missing type", {"created_at": 3}, "created_at"],
		["game_version three parts (the old form)", {"game_version": "7.5.0"}, "game_version is not MAJOR.MINOR"],
		["game_version one part", {"game_version": "7"}, "game_version is not MAJOR.MINOR"],
		["game_version letters", {"game_version": "a.b"}, "game_version is not MAJOR.MINOR"],
		["game_version four parts", {"game_version": "7.3.0.1"}, "game_version is not MAJOR.MINOR"],
		["game_version differs from app_minor", {"game_version": "7.4"}, "does not match native_version.app_minor (7.5)"],
		["app_minor differs from game_version", {"app_minor": 4}, "does not match native_version.app_minor (7.4)"],
		["native_version differs from game_version", {"native_version": 8}, "does not match native_version.app_minor (8.5)"],
		["app_minor zero", {"app_minor": 0, "game_version": "7.0"}, "app_minor"],
		["app_minor negative", {"app_minor": -1, "game_version": "7.-1"}, "app_minor"],
		["app_minor fractional", {"app_minor": 1.5, "game_version": "7.1.5"}, "app_minor"],
		["app_minor a string", {"app_minor": "5"}, "app_minor"],
		["game_version number", {"game_version": 7}, "game_version"],
		["save_schema below min", {"save_schema": 1, "min_save_schema": 2}, "save_schema"],
		["min_save_schema zero", {"min_save_schema": 0}, "save_schema"],
		["files not a list", {"files": "x"}, "files must be a list"],
		["files entry without path", {"files": [{"op": "add"}]}, "without a path"],
		["files entry not a dict", {"files": ["a.gd"]}, "without a path"],
		["files bad op", {"files": [{"path": "a.gd", "op": "patch"}]}, "op for"],
		["files path escapes", {"files": [{"path": "../outside.gd", "op": "add"}]}, "unsafe path"],
		["files absolute path", {"files": [{"path": "/etc/x", "op": "add"}]}, "unsafe path"],
	]
	for pc in Protected.EXACT:
		cases.append(["protected exact " + pc, {"files": [{"path": "godot/x.gd", "op": "replace"}, {"path": pc, "op": "replace"}]}, "protected path"])
	for pc in ["scripts/boot/boot.gd", "godot/scripts/boot/ota_core.gd", "godot/android/build.gradle", "godot/lib/native.so",
			"addons/x/y.gdextension", "libs/z.dll", "libs/z.dylib", "scripts/boot/boot.gd.remap", "godot/project.godot", "godot/project.binary"]:
		cases.append(["protected " + pc, {"files": [{"path": pc, "op": "remove"}]}, "protected path"])
	for cs in cases:
		var m2: Dictionary = _manifest(5, _payload(5), cs[1])
		var why: String = c.validate_manifest(m2)
		_check(why != "" and why.contains(cs[2]), "rejects: %s -> '%s' (got '%s')" % [cs[0], cs[2], why])
	# Allowed variations
	var okf: Dictionary = _manifest(5, _payload(5), {"files": [{"path": "godot/scripts/a.gd", "op": "add"}, {"path": "godot/scenes/b.tscn", "op": "replace"}, {"path": "godot/x.png", "op": "remove"}]})
	_check(c.validate_manifest(okf) == "", "game-layer files[] are fine")
	_check(c.validate_manifest(_manifest(5, _payload(5), {"files": []})) == "", "an empty files[] is fine")
	_check(c.validate_manifest(_manifest(5, _payload(5), {"pck_size": 536870912})) == "", "pck_size at the cap is fine")
	_check(c.validate_manifest(_manifest(5, _payload(5), {"seq": 7.0})) == "", "whole-number floats (JSON) are fine for seq")
	# The same manifest, but newer-revision runtime on the device: the OTA targets an OLDER revision.
	var c2: OtaCore = _core(_new_root(), "android-godot-4.6.0-r2")
	_has(c2.validate_manifest(good), "incompatible runtime: OTA targets older runtime", "older-revision runtime is 'incompatible runtime'")
	var c3: OtaCore = _core(_new_root())
	c3.allow_local_http = true
	_check(c3.validate_manifest(_manifest(5, _payload(5), {"pck_url": "http://127.0.0.1:18500/a.pck"})) == "", "local http allowed only with the desktop test hook")
	_has(c3.validate_manifest(_manifest(5, _payload(5), {"pck_url": "http://localhost:18500/a.pck"})), "HTTPS", "only 127.0.0.1 is allowed, not localhost")
	_has(c3.validate_manifest(_manifest(5, _payload(5), {"pck_url": "http://127.0.0.1.evil.com/a.pck"})), "HTTPS", "http host must be exactly 127.0.0.1:port")
	# URL anchoring: pck_url must be an OTA release asset inside the Releases download base (set by the updater).
	var ca: OtaCore = _core(_new_root())
	ca.url_base = OtaCore.base_of(Config.pointer_url("dev"))
	var gb: String = ca.url_base
	_check(ca.url_base == "https://github.com/verbal76/Purgatory-Dungeon/releases/download/", "setup: download base")
	_check(ca.validate_manifest(_manifest(5, _payload(5), {"pck_url": Config.release_url(Config.ota_tag("dev", 5), "purgatory-dev-000005.pck")})) == "", "the real OTA asset URL is accepted")
	for bad in [["another repository on github.com", "https://github.com/evil/x/releases/download/ota-dev-000005/p.pck"],
			["another host", "https://evil.example/verbal76/Purgatory-Dungeon/releases/download/ota-dev-000005/p.pck"],
			["host prefix trick", "https://github.com.evil.com/verbal76/Purgatory-Dungeon/releases/download/ota-dev-000005/p.pck"],
			["repo prefix trick", "https://github.com/verbal76/Purgatory-Dungeon-evil/releases/download/ota-dev-000005/p.pck"],
			["the pointer release is not an OTA", gb + "ota-channel-dev/p.pck"],
			["a non-OTA release tag", gb + "v7/Purgatory-Dungeon-v7.apk"],
			["tag without an asset", gb + "ota-dev-000005"],
			["tag with a nested asset", gb + "ota-dev-000005/a/b.pck"],
			["parent traversal", gb + "ota-dev-000005/../v7/x.pck"],
			["encoded traversal", gb + "ota-dev-000005/%2e%2e/x.pck"],
			["userinfo", gb + "ota-dev-000005/a@evil/x.pck"],
			["query smuggling", gb + "ota-dev-000005/x.pck?https://evil"],
			["plain http", "http://github.com/verbal76/Purgatory-Dungeon/releases/download/ota-dev-000005/p.pck"],
			["the base itself", gb],
			["site root", "https://github.com/"]]:
		var why_a: String = ca.validate_manifest(_manifest(5, _payload(5), {"pck_url": bad[1]}))
		_check(why_a != "" and (why_a.contains("download base") or why_a.contains("HTTPS")), "pck_url rejected: %s (%s)" % [bad[0], why_a])
	var local_a: OtaCore = _core(_new_root())
	local_a.allow_local_http = true
	local_a.url_base = OtaCore.base_of("http://127.0.0.1:18500/releases/download/ota-channel-dev/latest.json")
	_check(local_a.validate_manifest(_manifest(5, _payload(5), {"pck_url": "http://127.0.0.1:18500/releases/download/ota-dev-000005/p.pck"})) == "", "loopback OTA asset inside the loopback Releases layout is accepted")
	_has(local_a.validate_manifest(_manifest(5, _payload(5), {"pck_url": "http://127.0.0.1:18501/releases/download/ota-dev-000005/p.pck"})), "download base", "another loopback port is refused")
	_has(local_a.validate_manifest(_manifest(5, _payload(5), {"pck_url": "http://127.0.0.1:18500/other/ota-dev-000005/p.pck"})), "download base", "loopback outside /releases/download/ is refused")
	var flat_a: OtaCore = _core(_new_root())
	flat_a.allow_local_http = true
	flat_a.url_base = OtaCore.base_of("http://127.0.0.1:18500/dev/latest.json")
	_check(flat_a.validate_manifest(_manifest(5, _payload(5), {"pck_url": "http://127.0.0.1:18500/dev/p.pck"})) == "", "flat test layout: its own directory is accepted")
	_has(flat_a.validate_manifest(_manifest(5, _payload(5), {"pck_url": "http://127.0.0.1:18500/dev-evil/p.pck"})), "download base", "flat layout: path-prefix trick refused")
	var off: OtaCore = _core(_new_root())
	_check(off.validate_manifest(_manifest(5, _payload(5), {"pck_url": "https://anywhere.example/a.pck"})) == "", "anchoring is only enforced once a download base is set (stored manifests are signed)")
	# Device without an identity can never accept anything (baseline-only).
	var bare: OtaCore = OtaCore.new(_new_root(), RUNTIME, "dev", _pem, 1)
	_check(bare.validate_manifest(good) != "", "no native identity -> nothing validates")


# --- 3. signature, JSON ---------------------------------------------------------------------------------

func _t_signature_and_json() -> void:
	var c: OtaCore = _core(_new_root())
	var m: Dictionary = _manifest(1, _payload(1))
	var s: Array = _sign(m)
	var r: Array = c.check_manifest(s[0], s[1])
	_check(r[1] == "" and (r[0] as Dictionary)["ota_id"] == "dev-000001", "a correctly signed manifest passes")
	var tampered: PackedByteArray = (s[0] as PackedByteArray).duplicate()
	tampered.append(32)
	_has(c.check_manifest(tampered, s[1])[1], "signature verification failed", "tampered manifest bytes")
	var tampered2: PackedByteArray = JSON.stringify(_manifest(1, _payload(1), {"pck_size": 3001}), "  ", true).to_utf8_buffer()
	_has(c.check_manifest(tampered2, s[1])[1], "signature verification failed", "manifest changed after signing")
	var wrong: Array = _sign(m, _other)
	_has(c.check_manifest(wrong[0], wrong[1])[1], "signature verification failed", "signed with another key")
	_has(c.check_manifest(s[0], "")[1], "signature verification failed", "empty signature")
	_has(c.check_manifest(s[0], "!!!not base64!!!")[1], "signature verification failed", "garbage signature")
	_has(c.check_manifest(s[0], Marshalls.raw_to_base64(PackedByteArray([1, 2, 3])))[1], "signature verification failed", "short signature")
	var nj: PackedByteArray = "this is not json".to_utf8_buffer()
	_has(c.check_manifest(nj, _sign_bytes(nj))[1], "not a JSON object", "signed non-JSON")
	var arr: PackedByteArray = "[1, 2, 3]".to_utf8_buffer()
	_has(c.check_manifest(arr, _sign_bytes(arr))[1], "not a JSON object", "signed JSON array")
	var empty: PackedByteArray = PackedByteArray()
	_has(c.check_manifest(empty, _sign_bytes(empty))[1], "not a JSON object", "signed empty manifest")
	var sig_bad_manifest: Array = _sign({"schema": 1})
	_has(c.check_manifest(sig_bad_manifest[0], sig_bad_manifest[1])[1], "invalid manifest: missing", "signed but incomplete manifest")
	var big: PackedByteArray = PackedByteArray()
	big.resize(OtaCore.MAX_MANIFEST_BYTES + 1)
	_has(c.check_manifest(big, "x")[1], "too large", "oversized manifest")
	# The shipped placeholder key can never verify anything: nothing is ever mounted by an unconfigured build.
	var placeholder: OtaCore = OtaCore.new(_new_root(), RUNTIME, "dev", Config.PUBLIC_KEY_PEM, 1, FP, BASE)
	_has(placeholder.check_manifest(s[0], s[1])[1], "signature verification failed", "placeholder public key verifies nothing")
	# Rejected manifests carry the right reason for the updater's classification.
	var wrong_rt: Array = _sign(_manifest(1, _payload(1), {"runtime_id": "android-godot-4.7.0-r1"}))
	_check((c.check_manifest(wrong_rt[0], wrong_rt[1])[1] as String).begins_with("native update required"), "runtime mismatch reason is classified")


# --- 4. package verification and staging ---------------------------------------------------------------------

func _t_package_verify_and_staging() -> void:
	var root: String = _new_root()
	var c: OtaCore = _core(root)
	var pl: PackedByteArray = _payload(1)
	var m: Dictionary = _manifest(1, pl)
	_write(root.path_join("p.bin"), pl)
	_check(c.verify_package(m, root.path_join("p.bin")) == "", "intact package verifies")
	_has(c.verify_package(m, root.path_join("nope.bin")), "package missing", "missing package")
	_write(root.path_join("short.bin"), pl.slice(0, 100))
	_has(c.verify_package(m, root.path_join("short.bin")), "size mismatch", "short package")
	var longer: PackedByteArray = pl.duplicate()
	longer.append(1)
	_write(root.path_join("long.bin"), longer)
	_has(c.verify_package(m, root.path_join("long.bin")), "size mismatch", "oversized package")
	var flipped: PackedByteArray = pl.duplicate()
	flipped[10] = (flipped[10] + 1) % 256
	_write(root.path_join("flip.bin"), flipped)
	_has(c.verify_package(m, root.path_join("flip.bin")), "SHA-256 mismatch", "wrong SHA-256")

	# Good staging: promoted only after full verification, signed manifest stored, PENDING set.
	var id: String = "dev-000001"
	_check(not FileAccess.file_exists(c.package_path(id)), "nothing in packages/ before staging")
	var r: Dictionary = _stage(c, 1)
	_check(r["why"] == "", "staging a good download works (%s)" % r["why"])
	_check(FileAccess.file_exists(c.package_path(id)) and not FileAccess.file_exists(c.incoming_path(id)), "package promoted, temp file gone")
	_check(FileAccess.file_exists(c.manifest_path(id)) and FileAccess.file_exists(c.manifest_path(id) + ".sig"), "signed manifest stored beside it")
	_check(c.slot_id("pending") == id and c.slot("ready").is_empty(), "READY went straight to PENDING (auto-activate)")
	_check(c.verify_installed(c.slot("pending")) == "", "stored package re-verifies")
	var again: OtaCore = _core(root)
	_check(again.slot_id("pending") == id, "state survives a restart")

	# Interrupted / short download: temp deleted, nothing changes, retry works.
	var root2: String = _new_root()
	var c2: OtaCore = _core(root2)
	var pl2: PackedByteArray = _payload(2)
	var m2: Dictionary = _manifest(2, pl2)
	var s2: Array = _sign(m2)
	_write(c2.incoming_path("dev-000002"), pl2.slice(0, pl2.size() / 2))
	var why2: String = c2.stage_incoming(s2[0], s2[1])
	_has(why2, "size mismatch", "interrupted download is rejected")
	_check(not FileAccess.file_exists(c2.incoming_path("dev-000002")) and not FileAccess.file_exists(c2.package_path("dev-000002")), "temp deleted, nothing promoted")
	_check(c2.slot("pending").is_empty() and c2.slot("ready").is_empty() and not c2.is_bad("dev-000002"), "state unchanged and the id is NOT blacklisted (retryable)")
	_write(c2.incoming_path("dev-000002"), pl2)
	_check(c2.stage_incoming(s2[0], s2[1]) == "" and c2.slot_id("pending") == "dev-000002", "retry after an interrupted download works")

	# Oversized body.
	var root3: String = _new_root()
	var c3: OtaCore = _core(root3)
	var pl3: PackedByteArray = _payload(3)
	var s3: Array = _sign(_manifest(3, pl3))
	var big3: PackedByteArray = pl3.duplicate()
	big3.append_array(_payload(4, 500))
	_write(c3.incoming_path("dev-000003"), big3)
	_has(c3.stage_incoming(s3[0], s3[1]), "size mismatch", "oversized download is rejected")
	_check(_incoming_files(c3).is_empty() and c3.slot("pending").is_empty(), "oversized: temp deleted, state unchanged")

	# Wrong SHA at full size: immutable release, so blacklisted; never staged again.
	var root4: String = _new_root()
	var c4: OtaCore = _core(root4)
	var pl4: PackedByteArray = _payload(4)
	var s4: Array = _sign(_manifest(4, pl4))
	var wrong4: PackedByteArray = pl4.duplicate()
	wrong4[5] = (wrong4[5] + 1) % 256
	_write(c4.incoming_path("dev-000004"), wrong4)
	_has(c4.stage_incoming(s4[0], s4[1]), "SHA-256 mismatch", "wrong content is rejected")
	_check(c4.is_bad("dev-000004") and _incoming_files(c4).is_empty() and c4.slot("pending").is_empty(), "SHA mismatch: blacklisted, temp deleted")
	_write(c4.incoming_path("dev-000004"), pl4)
	_has(c4.stage_incoming(s4[0], s4[1]), "not staging it again", "a blacklisted id is never staged, even with correct bytes")
	_check(c4.slot("pending").is_empty() and _incoming_files(c4).is_empty(), "blacklisted id: nothing staged, temp deleted")
	_check(_core(root4).is_bad("dev-000004"), "blacklist survives a restart")

	# Stale / non-newer seq is not an update.
	var root5: String = _new_root()
	var c5: OtaCore = _core(root5)
	_check(_stage(c5, 3)["why"] == "", "stage seq 3")
	var st: Dictionary = _stage(c5, 2)
	_has(st["why"], "stale", "an older seq is not an update")
	var st2: Dictionary = _stage(c5, 3, {"ota_id": "dev-000003b"})
	_has(st2["why"], "stale", "the same seq is not an update")
	_check(c5.slot_id("pending") == "dev-000003" and _incoming_files(c5).is_empty(), "stale: pending unchanged, temp deleted")
	_check(_stage(c5, 4)["why"] == "" and c5.slot_id("pending") == "dev-000004", "a newer seq replaces the pending one")
	_check(c5.known_seq() == 4, "known_seq follows the newest slot")

	# Bad signature / protected path at staging: nothing changes.
	var root6: String = _new_root()
	var c6: OtaCore = _core(root6)
	var pl6: PackedByteArray = _payload(6)
	var m6: Dictionary = _manifest(6, pl6)
	var s6: Array = _sign(m6, _other)
	_write(c6.incoming_path("dev-000006"), pl6)
	_has(c6.stage_incoming(s6[0], s6[1]), "signature verification failed", "staging with a wrong-key signature")
	_check(c6.slot("pending").is_empty() and not FileAccess.file_exists(c6.package_path("dev-000006")), "bad signature: nothing promoted")
	var prot: Dictionary = _stage(c6, 7, {"files": [{"path": "godot/project.godot", "op": "replace"}]})
	_has(prot["why"], "protected path", "staging a payload that touches the native boundary")
	_check(c6.slot("pending").is_empty() and not FileAccess.file_exists(c6.package_path("dev-000007")), "protected path: nothing promoted")

	# auto_activate off: READY, then activate_ready -> PENDING.
	var root7: String = _new_root()
	var c7: OtaCore = _core(root7)
	c7.state["auto_activate"] = false
	_check(_stage(c7, 1)["why"] == "" and c7.slot_id("ready") == "dev-000001" and c7.slot("pending").is_empty(), "READY without auto-activate")
	_check(c7.activate_ready() == "" and c7.slot_id("pending") == "dev-000001" and c7.slot("ready").is_empty(), "activate_ready moves READY to PENDING")
	_has(c7.activate_ready(), "nothing downloaded", "activate with nothing downloaded")


# --- 5. state machine ---------------------------------------------------------------------------------

func _t_state_machine() -> void:
	# PENDING -> start 1 -> start 2 -> third start blacklists and falls back to the embedded baseline.
	var root: String = _new_root()
	var c: OtaCore = _core(root)
	_check(_stage(c, 1)["why"] == "", "stage seq 1")
	_mounted.clear()
	c = _core(root)
	var observed: Array = []
	var peek: Callable = func(path: String) -> bool:
		# The attempt must already be on disk when the mount runs (a crash during load counts).
		var st: Variant = JSON.parse_string(FileAccess.get_file_as_string(root.path_join("state.json")))
		observed.append(int(((st as Dictionary)["boot"] as Dictionary)["starts"]))
		return _fake_mount(path)
	var act: Dictionary = c.boot(peek)
	_check(act.get("ota_id", "") == "dev-000001" and c.active_slot == "pending", "start 1 mounts the pending package")
	_check(observed == [1], "attempt 1 was persisted BEFORE mounting (%s)" % str(observed))
	_check(c.first_run, "first start of a never-run package is flagged (shows the Applying update panel)")
	_check(int(c.state["boot"]["starts"]) == 1, "starts == 1")
	c = _core(root)
	act = c.boot(_fake_mount)
	_check(act.get("ota_id", "") == "dev-000001" and int(c.state["boot"]["starts"]) == 2 and not c.first_run, "start 2 mounts it again, not first-run")
	var mounts_before: int = _mounted.size()
	c = _core(root)
	act = c.boot(_fake_mount)
	_check(act.is_empty() and c.is_bad("dev-000001") and c.slot("pending").is_empty(), "third start blacklists it and runs the embedded baseline")
	_check(_mounted.size() == mounts_before, "the abandoned package was not mounted a third time")
	_has(c.boot_log.back() if not c.boot_log.is_empty() else "", "embedded baseline", "boot log says baseline")
	_check(not FileAccess.file_exists(c.package_path("dev-000001")), "blacklisted package file is deleted")

	# Health promotion: PENDING -> CURRENT, old CURRENT -> PREVIOUS.
	var root2: String = _new_root()
	var a: OtaCore = _make_current(root2, 1)
	_check(a.slot_id("current") == "dev-000001" and a.slot("pending").is_empty() and a.slot("previous").is_empty(), "first healthy OTA becomes CURRENT")
	_check(int(a.state["boot"]["starts"]) == 0 and a.state["boot"]["healthy_id"] == "dev-000001", "health resets the start counter")
	a = _core(root2)
	_check(_stage(a, 2)["why"] == "", "stage seq 2")
	a = _core(root2)
	act = a.boot(_fake_mount)
	_check(act["ota_id"] == "dev-000002" and a.slot_id("current") == "dev-000001", "pending runs while the old one is still CURRENT")
	a.mark_healthy()
	_check(a.slot_id("current") == "dev-000002" and a.slot_id("previous") == "dev-000001" and a.slot("pending").is_empty(), "health: PENDING -> CURRENT, old CURRENT -> PREVIOUS")
	_check(_core(root2).slot_id("previous") == "dev-000001", "promotion is persisted")
	# A newer download staged while the unconfirmed one runs does not lose the running one.
	var root2b: String = _new_root()
	var b: OtaCore = _core(root2b)
	_stage(b, 1)
	b = _core(root2b)
	b.boot(_fake_mount)
	_check(_stage(b, 2)["why"] == "", "stage seq 2 while seq 1 runs unconfirmed")
	b.mark_healthy()
	_check(b.slot_id("current") == "dev-000001" and b.slot_id("pending") == "dev-000002", "running one is promoted, the newer one stays pending")

	# Current crash loop falls back to PREVIOUS (restoration of the previous known good).
	var root3: String = _new_root()
	var d: OtaCore = _make_current(root3, 1)
	d = _core(root3)
	_stage(d, 2)
	d = _core(root3)
	d.boot(_fake_mount)
	d.mark_healthy()
	_check(d.slot_id("current") == "dev-000002" and d.slot_id("previous") == "dev-000001", "setup: 2 current, 1 previous")
	_mounted.clear()
	d = _core(root3)
	d.boot(_fake_mount)
	d = _core(root3)
	act = d.boot(_fake_mount)
	_check(act["ota_id"] == "dev-000002" and int(d.state["boot"]["starts"]) == 2, "current gets two unhealthy starts")
	d = _core(root3)
	act = d.boot(_fake_mount)
	_check(act.get("ota_id", "") == "dev-000001" and d.is_bad("dev-000002"), "third unhealthy start of CURRENT falls back to PREVIOUS")
	_check(d.slot_id("current") == "dev-000001" and d.slot("previous").is_empty() and int(d.state["rollback_count"]) == 1, "PREVIOUS is now CURRENT, rollback counted")
	d.mark_healthy()
	_check(d.slot_id("current") == "dev-000001" and int(d.state["boot"]["starts"]) == 0, "restored previous known good becomes healthy again")

	# Failed mount: dropped in the same boot, next candidate used.
	var root4: String = _new_root()
	var e: OtaCore = _make_current(root4, 1)
	e = _core(root4)
	_stage(e, 2)
	_fail_mount = ["dev-000002"]
	_mounted.clear()
	e = _core(root4)
	act = e.boot(_fake_mount)
	_check(act.get("ota_id", "") == "dev-000001" and e.is_bad("dev-000002") and e.slot("pending").is_empty(), "failed mount of PENDING: blacklisted, CURRENT mounted in the same boot")
	_check(_mounted.size() == 2 and _mounted[0].contains("dev-000002") and _mounted[1].contains("dev-000001"), "mount order: pending then current (%s)" % str(_mounted))
	_fail_mount = ["dev-000001"]
	e = _core(root4)
	_stage(e, 3)
	e = _core(root4)
	act = e.boot(_fake_mount)
	_check(act.get("ota_id", "") == "dev-000003" and e.slot_id("pending") == "dev-000003", "next pending mounts (current is broken but not tried)")
	_fail_mount = []

	# Current fails to mount, previous used.
	var root5: String = _new_root()
	var f: OtaCore = _make_current(root5, 1)
	f = _core(root5)
	_stage(f, 2)
	f = _core(root5)
	f.boot(_fake_mount)
	f.mark_healthy()
	_fail_mount = ["dev-000002"]
	f = _core(root5)
	act = f.boot(_fake_mount)
	_check(act.get("ota_id", "") == "dev-000001" and f.is_bad("dev-000002") and f.slot_id("current") == "dev-000001" and int(f.state["rollback_count"]) == 1, "current fails to mount: previous runs, rollback counted")
	_fail_mount = []

	# Embedded baseline when current AND previous are unusable.
	var root6: String = _new_root()
	var g: OtaCore = _make_current(root6, 1)
	g = _core(root6)
	_stage(g, 2)
	g = _core(root6)
	g.boot(_fake_mount)
	g.mark_healthy()
	_write(g.package_path("dev-000001"), _payload(99))
	_write(g.package_path("dev-000002"), _payload(98))
	_mounted.clear()
	g = _core(root6)
	act = g.boot(_fake_mount)
	_check(act.is_empty() and _mounted.is_empty(), "current and previous both corrupt: embedded baseline, nothing mounted")
	_check(g.is_bad("dev-000001") and g.is_bad("dev-000002") and g.slot("current").is_empty() and g.slot("previous").is_empty(), "both corrupt packages are blacklisted")
	g.mark_healthy()
	_check(g.state["boot"]["ota_id"] == "" and g.state["boot"]["healthy_id"] == "", "baseline health recorded")

	# Post-mount self-check failure: blacklisted, clean restart requested.
	var root7: String = _new_root()
	var h: OtaCore = _core(root7)
	_stage(h, 1)
	h = _core(root7)
	h.canary = func() -> bool: return false
	act = h.boot(_fake_mount)
	_check(act.is_empty() and h.restart_required and h.is_bad("dev-000001"), "failed post-mount self-check: blacklisted and restart required")
	h = _core(root7)
	act = h.boot(_fake_mount)
	_check(act.is_empty() and not h.restart_required, "the clean restart runs the embedded baseline")
	var h2: OtaCore = _core(_new_root())
	_stage(h2, 1)
	h2 = _core(h2.root)
	h2.canary = func() -> bool: return true
	_check(not h2.boot(_fake_mount).is_empty() and not h2.restart_required, "passing self-check keeps the mount")
	var h3: OtaCore = _core(_new_root())
	_check(h3._default_canary(), "the real key resources resolve (default self-check)")

	# Update-loop prevention: the blacklist survives restarts and stage refuses the id.
	var root8: String = _new_root()
	var i: OtaCore = _core(root8)
	_stage(i, 1)
	_fail_mount = ["dev-000001"]
	i = _core(root8)
	i.boot(_fake_mount)
	_fail_mount = []
	_check(i.is_bad("dev-000001"), "failed mount blacklists")
	for k in 3:
		i = _core(root8)
		i.boot(_fake_mount)
		_check(i.is_bad("dev-000001"), "still blacklisted after restart %d" % k)
	var again: Dictionary = _stage(i, 1)
	_check(again["why"] != "" and i.slot("pending").is_empty(), "a blacklisted id cannot be staged again")

	# No network anywhere in the core: boot from stored packages only.
	var root9: String = _new_root()
	_make_current(root9, 4)
	var j: OtaCore = _core(root9)
	act = j.boot(_fake_mount)
	_check(act.get("ota_id", "") == "dev-000004", "cold start with no network mounts the stored CURRENT")
	_check(j.boot_verify_ms >= 0.0 and j.boot_mount_ms >= 0.0, "boot timings recorded")


# --- 6. corruption ------------------------------------------------------------------------------------

func _t_corruption() -> void:
	# state.json garbage / wrong shapes
	for blob in ["{{{ not json", "[1, 2, 3]", "", "null", "12"]:
		var root: String = _new_root()
		_write(root.path_join("state.json"), blob.to_utf8_buffer())
		var c: OtaCore = _core(root)
		_check(c.slot("current").is_empty() and c.slot("pending").is_empty() and not bool(c.state["disabled"]), "corrupt state.json (%s): clean state" % blob.c_escape())
		_has(str((c.state["events"] as Dictionary).get("state", {}).get("result", "")), "unreadable", "corrupt state is reported")
		var act: Dictionary = c.boot(_fake_mount)
		_check(act.is_empty(), "corrupt state.json boots the embedded baseline")
		_check(JSON.parse_string(FileAccess.get_file_as_string(root.path_join("state.json"))) is Dictionary, "a valid state.json is written back")
	var shaped: String = JSON.stringify({"current": "x", "pending": 5, "previous": {"ota_id": "../../etc/passwd"}, "ready": {"nope": 1},
			"bad": 5, "disabled": "yes", "auto_activate": 3, "rollback_count": "many", "boot": 7, "events": [], "backups": ["ok", "../bad", 4]})
	var root2: String = _new_root()
	_write(root2.path_join("state.json"), shaped.to_utf8_buffer())
	var c2: OtaCore = _core(root2)
	_check(c2.slot("current").is_empty() and c2.slot("pending").is_empty() and c2.slot("previous").is_empty() and c2.slot("ready").is_empty(), "damaged slots are cleared")
	_check(c2.state["bad"] == [] and c2.state["disabled"] == false and c2.state["auto_activate"] == true and int(c2.state["rollback_count"]) == 0, "wrong-typed fields reset to defaults")
	_check(c2.state["boot"] is Dictionary and c2.state["events"] is Dictionary and c2.state["backups"] == ["ok"], "boot/events/backups sanitized")
	_check(c2.boot(_fake_mount).is_empty(), "shape-damaged state boots the baseline without errors")

	# corrupt stored package, tampered/missing manifest, missing package
	var root3: String = _new_root()
	var base: OtaCore = _make_current(root3, 1)
	base = _core(root3)
	_stage(base, 2)
	base = _core(root3)
	base.boot(_fake_mount)
	base.mark_healthy()
	var pk: PackedByteArray = FileAccess.get_file_as_bytes(base.package_path("dev-000002"))
	pk[3] = (pk[3] + 1) % 256
	_write(base.package_path("dev-000002"), pk)
	var c3: OtaCore = _core(root3)
	_mounted.clear()
	var act3: Dictionary = c3.boot(_fake_mount)
	_check(act3.get("ota_id", "") == "dev-000001" and c3.is_bad("dev-000002"), "corrupt stored CURRENT: blacklisted, PREVIOUS runs")
	_has(str((c3.state["events"] as Dictionary).get("rejected", {}).get("result", "")), "SHA-256 mismatch", "corruption reason recorded")
	# tampered stored manifest (signature no longer matches)
	var root4: String = _new_root()
	var c4: OtaCore = _core(root4)
	_stage(c4, 1)
	var mb: PackedByteArray = FileAccess.get_file_as_bytes(c4.manifest_path("dev-000001"))
	mb.append(32)
	_write(c4.manifest_path("dev-000001"), mb)
	c4 = _core(root4)
	_check(c4.boot(_fake_mount).is_empty() and c4.is_bad("dev-000001"), "tampered stored manifest: rejected, baseline")
	var root5: String = _new_root()
	var c5: OtaCore = _core(root5)
	_stage(c5, 1)
	DirAccess.remove_absolute(c5.manifest_path("dev-000001") + ".sig")
	c5 = _core(root5)
	_check(c5.boot(_fake_mount).is_empty() and c5.is_bad("dev-000001"), "missing stored signature: rejected, baseline")
	var root6: String = _new_root()
	var c6: OtaCore = _core(root6)
	_stage(c6, 1)
	DirAccess.remove_absolute(c6.package_path("dev-000001"))
	c6 = _core(root6)
	_check(c6.boot(_fake_mount).is_empty() and c6.is_bad("dev-000001"), "missing stored package: rejected, baseline")
	# state slot that disagrees with the signed manifest on disk
	var root7: String = _new_root()
	var c7: OtaCore = _core(root7)
	_stage(c7, 1)
	var forged: Dictionary = c7.slot("pending").duplicate()
	forged["pck_sha256"] = "0".repeat(64)
	c7.state["pending"] = forged
	c7.save_state()
	c7 = _core(root7)
	_check(c7.boot(_fake_mount).is_empty() and c7.is_bad("dev-000001"), "state edited to disagree with the signed manifest: rejected")
	# leftover temp files are cleaned when the device becomes healthy
	var root8: String = _new_root()
	var c8: OtaCore = _make_current(root8, 1)
	_write(c8.incoming_path("dev-000009"), _payload(9))
	_write(c8.package_path("dev-000009"), _payload(9))
	c8.mark_healthy()
	_check(_incoming_files(c8).is_empty() and not FileAccess.file_exists(c8.package_path("dev-000009")), "healthy prunes temp and orphaned packages")
	_check(FileAccess.file_exists(c8.package_path("dev-000001")), "healthy keeps the packages in use")


# --- 7. identity changes at boot --------------------------------------------------------------------------

func _t_identity_changes() -> void:
	var root: String = _new_root()
	_make_current(root, 1)
	_mounted.clear()
	# a newer revision of the same runtime (APK updated): stored OTA is permanently incompatible: dropped, not blacklisted
	var c: OtaCore = _core(root, "android-godot-4.6.0-r2")
	var act: Dictionary = c.boot(_fake_mount)
	_check(act.is_empty() and c.slot("current").is_empty() and not c.is_bad("dev-000001") and _mounted.is_empty(), "newer runtime revision: stored OTA dropped, nothing mounted")
	_has(str((c.state["events"] as Dictionary).get("load", {}).get("result", "")), "baseline", "baseline chosen")
	# fingerprint changed
	var root2: String = _new_root()
	_make_current(root2, 1)
	_mounted.clear()
	var c2: OtaCore = _core(root2, RUNTIME, "9".repeat(64))
	act = c2.boot(_fake_mount)
	_check(act.is_empty() and c2.slot("current").is_empty() and not c2.is_bad("dev-000001") and _mounted.is_empty(), "runtime fingerprint changed: stored OTA dropped")
	# baseline commit changed (new APK, same native inputs)
	var root3: String = _new_root()
	_make_current(root3, 1)
	_mounted.clear()
	var c3: OtaCore = _core(root3, RUNTIME, FP, "7".repeat(40))
	act = c3.boot(_fake_mount)
	_check(act.is_empty() and c3.slot("current").is_empty() and _mounted.is_empty(), "native baseline changed: stored patch dropped")
	_has(c3.boot_log[0] if not c3.boot_log.is_empty() else "", "incompatible baseline", "reason names the baseline")
	# a different runtime family (not older): skipped but kept
	var root4: String = _new_root()
	_make_current(root4, 1)
	_mounted.clear()
	var c4: OtaCore = _core(root4, "android-godot-4.7.0-r1")
	act = c4.boot(_fake_mount)
	_check(act.is_empty() and c4.slot_id("current") == "dev-000001" and not c4.is_bad("dev-000001") and _mounted.is_empty(), "runtime of another engine: skipped, kept")
	# the unchanged identity mounts normally
	var root5: String = _new_root()
	_make_current(root5, 1)
	_check(not _core(root5).boot(_fake_mount).is_empty(), "same identity mounts normally")


# --- 8. manual actions ---------------------------------------------------------------------------------

func _t_manual_actions() -> void:
	var root: String = _new_root()
	var c: OtaCore = _make_current(root, 1)
	c.set_disabled(true)
	_mounted.clear()
	c = _core(root)
	_check(bool(c.state["disabled"]), "disabled persists")
	_check(c.boot(_fake_mount).is_empty() and _mounted.is_empty(), "disabled: embedded baseline, nothing mounted")
	_check(c.slot_id("current") == "dev-000001", "disabling keeps the stored OTA")
	c.set_disabled(false)
	c = _core(root)
	_check(not c.boot(_fake_mount).is_empty() and _mounted.size() == 1, "re-enabled: the stored OTA mounts again")
	# Manual rollback to previous
	var root2: String = _new_root()
	var a: OtaCore = _make_current(root2, 1)
	a = _core(root2)
	_stage(a, 2)
	a = _core(root2)
	a.boot(_fake_mount)
	a.mark_healthy()
	_check(a.rollback() == "", "rollback succeeds")
	_check(a.slot_id("current") == "dev-000001" and a.slot("previous").is_empty() and a.is_bad("dev-000002") and int(a.state["rollback_count"]) == 1, "rollback: CURRENT=previous, rolled back one blacklisted")
	a = _core(root2)
	var act: Dictionary = a.boot(_fake_mount)
	_check(act.get("ota_id", "") == "dev-000001", "next start runs the previous known good")
	_check(a.rollback() == "" and a.slot("current").is_empty(), "rolling back the last OTA leaves only the baseline")
	a = _core(root2)
	_check(a.boot(_fake_mount).is_empty(), "then the embedded baseline runs")
	_has(a.rollback(), "no OTA to roll back from", "nothing left to roll back")
	# rollback of an unconfirmed pending OTA (cancel)
	var root3: String = _new_root()
	var b: OtaCore = _core(root3)
	_stage(b, 1)
	_check(b.rollback() == "" and b.slot("pending").is_empty() and b.is_bad("dev-000001"), "rollback discards an unconfirmed pending OTA")
	_check(_core(root3).boot(_fake_mount).is_empty(), "and the baseline runs")
	# a rolled-back id is not staged again
	_check(_stage(b, 1)["why"] != "", "rolled-back id is not staged again")


# --- 9. save schema ------------------------------------------------------------------------------------

func _t_save_schema() -> void:
	var c: OtaCore = _core(_new_root())
	c.device_save_schema = 2
	_has(c.validate_manifest(_manifest(1, _payload(1), {"save_schema": 1})), "save incompatible: save schema 2 is newer", "device newer than the OTA understands")
	c.device_save_schema = 1
	_has(c.validate_manifest(_manifest(1, _payload(1), {"save_schema": 2, "min_save_schema": 2})), "no longer reads save schema 1", "OTA that no longer reads the device schema")
	_check(c.validate_manifest(_manifest(1, _payload(1), {"save_schema": 2, "min_save_schema": 1})) == "", "OTA that migrates forward but still reads the device schema is fine")
	c.device_save_schema = 0
	_check(c.validate_manifest(_manifest(1, _payload(1), {"save_schema": 3, "min_save_schema": 3})) == "", "no save on the device: any schema is fine")
	# staging refuses it, nothing changes
	var root: String = _new_root()
	var s: OtaCore = _core(root)
	s.device_save_schema = 2
	var r: Dictionary = _stage(s, 1)
	_has(r["why"], "save incompatible", "stage_incoming refuses an incompatible OTA")
	_check(s.slot("pending").is_empty() and s.slot("ready").is_empty(), "nothing staged")
	# health records the schema of the running game and it survives restarts
	var root2: String = _new_root()
	var h: OtaCore = _core(root2)
	h.running_save_schema = 1
	h.boot(_fake_mount)
	h.mark_healthy()
	_check(h.device_save_schema == 1 and int(h.state["device_save_schema"]) == 1, "healthy baseline records the save schema")
	_check(_core(root2).device_save_schema == 1, "recorded schema is loaded on the next start")
	h.running_save_schema = 0
	h.mark_healthy()
	_check(h.device_save_schema == 1, "an unknown running schema never erases the recorded one")
	# boot skips a stored OTA that can no longer read the device's saves (kept, not blacklisted)
	var root3: String = _new_root()
	var p: OtaCore = _core(root3)
	_stage(p, 1)
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(root3.path_join("state.json")))
	(raw as Dictionary)["device_save_schema"] = 2
	_write(root3.path_join("state.json"), JSON.stringify(raw).to_utf8_buffer())
	_mounted.clear()
	p = _core(root3)
	var act: Dictionary = p.boot(_fake_mount)
	_check(act.is_empty() and _mounted.is_empty() and not p.is_bad("dev-000001") and p.slot_id("pending") == "dev-000001", "boot skips an OTA the saves are too new for (kept, not blacklisted)")
	_has(str((p.state["events"] as Dictionary).get("load", {}).get("result", "")), "baseline", "baseline runs instead")
	# rollback past a deliberate migration is refused
	var root4: String = _new_root()
	var m: OtaCore = _make_current(root4, 1)
	m = _core(root4)
	_stage(m, 2, {"save_schema": 2, "min_save_schema": 1})
	m = _core(root4)
	m.boot(_fake_mount)
	m.running_save_schema = 2
	m.mark_healthy()
	_check(m.device_save_schema == 2 and m.slot_id("previous") == "dev-000001", "setup: migration OTA running, device on schema 2")
	_has(m.rollback(), "save incompatible", "rollback to an OTA that cannot read the migrated saves is refused")
	_check(m.slot_id("current") == "dev-000002" and not m.is_bad("dev-000002"), "refused rollback changes nothing")
	_check(m.activate_ready() == "nothing downloaded", "activate_ready is unaffected")


# --- 10. saves untouched, backups ----------------------------------------------------------------------------

func _t_saves_untouched_and_backups() -> void:
	var before: String = _tree_hash(_save)
	var root: String = _new_root()
	var c: OtaCore = _core(root)
	_stage(c, 1)
	c = _core(root)
	c.boot(_fake_mount)
	c.mark_healthy()
	c = _core(root)
	_stage(c, 2)
	c = _core(root)
	c.boot(_fake_mount)
	c = _core(root)
	c.boot(_fake_mount)
	c = _core(root)
	c.boot(_fake_mount)   # third start of the unhealthy 2: falls back
	c.rollback()
	c.set_disabled(true)
	c = _core(root)
	c.boot(_fake_mount)
	_check(_tree_hash(_save) == before, "save folder is byte-identical after stage/activate/boot/rollback/fallback/disable")

	# backups: made before a never-run package first loads, equal to the saves, once per package
	var root2: String = _new_root()
	var b: OtaCore = _core(root2)
	_stage(b, 1)
	b = _core(root2)
	_check((b.state["backups"] as Array).is_empty(), "no backup before the first activation")
	b.boot(_fake_mount)
	var names: Array = b.state["backups"]
	_check(names.size() == 1, "one backup before the never-run package first loads")
	if names.size() == 1:
		var dir: String = root2.path_join("backups").path_join(str(names[0]))
		_check(DirAccess.dir_exists_absolute(dir) and _tree_hash(dir) == before, "the backup equals the save folder (hidden files and sub-folders included)")
		_check(str(names[0]).begins_with("dev-000001_"), "backup is named after the package")
	b = _core(root2)
	b.boot(_fake_mount)
	_check((b.state["backups"] as Array).size() == 1, "second start of the same package: no new backup")
	b.mark_healthy()
	b = _core(root2)
	b.boot(_fake_mount)
	_check((b.state["backups"] as Array).size() == 1, "booting a confirmed CURRENT: no backup")
	# cap at 3, oldest removed
	var root3: String = _new_root()
	var cap: OtaCore = _core(root3)
	for seq in range(1, 7):
		cap = _core(root3)
		_stage(cap, seq)
		cap = _core(root3)
		cap.boot(_fake_mount)
		cap.mark_healthy()
	cap = _core(root3)
	_check((cap.state["backups"] as Array).size() == OtaCore.MAX_BACKUPS, "backups are capped at %d" % OtaCore.MAX_BACKUPS)
	var dirs: DirAccess = DirAccess.open(root3.path_join("backups"))
	_check(dirs != null and dirs.get_directories().size() == OtaCore.MAX_BACKUPS, "only %d backup folders remain on disk" % OtaCore.MAX_BACKUPS)
	_check(str((cap.state["backups"] as Array)[2]).begins_with("dev-000006_") and str((cap.state["backups"] as Array)[0]).begins_with("dev-000004_"), "the newest three are kept")
	_check(_tree_hash(_save) == before, "save folder still byte-identical after many activations")
	# no save folder configured / missing: no backup, no error
	var root4: String = _new_root()
	var n: OtaCore = _core(root4)
	n.save_root = ""
	_stage(n, 1)
	n = _core(root4)
	n.save_root = _scratch.path_join("does_not_exist")
	_check(not n.boot(_fake_mount).is_empty() and (n.state["backups"] as Array).is_empty(), "no save folder yet: mounts without a backup")


# --- 11. a REAL mount ------------------------------------------------------------------------------------------

func _t_real_mount() -> void:
	var marker_src: String = _scratch.path_join("marker.txt")
	_write(marker_src, "ota-real-mount-v1".to_utf8_buffer())
	var pck: String = _scratch.path_join("real.pck")
	var packer: PCKPacker = PCKPacker.new()
	_check(packer.pck_start(pck) == OK, "PCKPacker starts")
	_check(packer.add_file("res://ota_core_test_payload/marker.txt", marker_src) == OK, "PCKPacker adds a file")
	_check(packer.flush(false) == OK, "PCKPacker flushes")
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(pck)
	_check(bytes.size() > 0, "a real pack was written (%d bytes)" % bytes.size())
	_check(not FileAccess.file_exists("res://ota_core_test_payload/marker.txt"), "marker not visible before the mount")
	var root: String = _new_root()
	var c: OtaCore = _core(root)
	var r: Dictionary = _stage(c, 1, {}, bytes)
	_check(r["why"] == "", "the real pack stages (%s)" % r["why"])
	c = _core(root)
	var act: Dictionary = c.boot(func(path: String) -> bool: return ProjectSettings.load_resource_pack(path, true))
	_check(act.get("ota_id", "") == "dev-000001", "real load_resource_pack mount succeeded")
	_check(FileAccess.file_exists("res://ota_core_test_payload/marker.txt") and FileAccess.get_file_as_string("res://ota_core_test_payload/marker.txt") == "ota-real-mount-v1", "the packed file is visible through res:// after the mount")
	_check(c.canary.is_valid() == false and c._default_canary(), "key resources still resolve after the real mount")
	# a package with valid hash/size that is not a pack: the engine refuses to mount it -> dropped in the same boot
	var garbage: PackedByteArray = _payload(5, 4096)
	var root2: String = _new_root()
	var g: OtaCore = _core(root2)
	_check(_stage(g, 2, {}, garbage)["why"] == "", "garbage pack stages (hash and size are right)")
	g = _core(root2)
	var act2: Dictionary = g.boot(func(path: String) -> bool: return ProjectSettings.load_resource_pack(path, true))
	_check(act2.is_empty() and g.is_bad("dev-000002"), "an unmountable pack is blacklisted and the baseline runs")


# --- 12. updater over loopback HTTP --------------------------------------------------------------------------------

func _stub() -> HttpStub:
	var s: HttpStub = HttpStub.new()
	add_child(s)
	_check(s.start() != 0, "stub server listens on loopback")
	return s


func _make_updater(c: OtaCore, s: HttpStub) -> OtaUpdater:
	var u: OtaUpdater = OtaUpdater.new()
	u.core = c
	u.pointer_url = s.url("/dev/latest.json")
	u.bundled_source_sha = BASE
	add_child(u)
	c.allow_local_http = true
	return u


## Publishes manifest `m` (signed by `key`) with `payload` under /dev/ on the stub.
func _publish(s: HttpStub, m: Dictionary, payload: PackedByteArray, key: CryptoKey = null, pointer_over: Dictionary = {}) -> void:
	var id: String = m["ota_id"]
	var sg: Array = _sign(m, key)
	var ptr: Dictionary = {"channel": m["channel"], "ota_id": id, "seq": m["seq"], "runtime_id": m["runtime_id"],
			"manifest_url": s.url("/dev/%s.json" % id), "signature_url": s.url("/dev/%s.json.sig" % id), "published_at": "2026-10-06T00:00:00Z",
			# extra keys the producer adds (the client must tolerate them): owner-facing identity of the OTA
			"native_version": m["native_version"], "app_minor": m["app_minor"], "future_field": {"x": [1, 2]}}
	ptr.merge(pointer_over, true)
	s.routes["/dev/latest.json"] = JSON.stringify(ptr).to_utf8_buffer()
	s.routes["/dev/%s.json" % id] = sg[0]
	s.routes["/dev/%s.json.sig" % id] = (sg[1] as String).to_utf8_buffer()
	s.routes["/dev/%s.pck" % id] = payload


func _published(s: HttpStub, seq: int, over: Dictionary = {}, payload: PackedByteArray = PackedByteArray(), key: CryptoKey = null) -> Dictionary:
	var pl: PackedByteArray = payload if not payload.is_empty() else _payload(seq)
	var m: Dictionary = _manifest(seq, pl, {"pck_url": s.url("/dev/dev-%06d.pck" % seq)})
	m.merge(over, true)
	_publish(s, m, pl, key)
	return m


func _t_updater() -> void:
	var stub: HttpStub = _stub()
	var root: String = _new_root()
	var c: OtaCore = _core(root)
	var u: OtaUpdater = _make_updater(c, stub)
	var changed: Array = [0]
	u.status_changed.connect(func() -> void: changed[0] += 1)
	_check(u.status == "unchecked" and not u.busy, "updater starts unchecked")

	# happy path: check (no download) -> available -> download -> verified -> PENDING
	var m1: Dictionary = _published(stub, 1)
	var r: String = await u.check(false)
	_check(r == "available" and u.status == "available" and u.has_available() and c.slot("pending").is_empty(), "check(false) finds the update without downloading it (%s)" % r)
	_check(u.remote.has("app_minor") and u.remote.has("native_version") and u.remote.has("future_field"), "a pointer with extra keys is accepted")
	_has(c.boot_log.back() if not c.boot_log.is_empty() else "", "update available: v7.1 (dev-000001, source", "event names the owner-facing version")
	_check(stub.hit_count("/dev/dev-000001.pck") == 0 and changed[0] > 0, "no package request before Download; status_changed fired")
	r = await u.download_available()
	_check(u.status == "downloaded" and c.slot_id("pending") == "dev-000001" and _incoming_files(c).is_empty(), "download -> verified -> PENDING, no temp file left (%s)" % r)
	_has(r, "restart to run it", "download result says to restart")
	_check(FileAccess.file_exists(c.package_path("dev-000001")), "package stored")
	_has(await u.download_available(), "nothing to download", "nothing left to download")
	# up to date
	r = await u.check(true)
	_check(u.status == "up_to_date" and u.latest_compat == "compatible", "same OTA again: up to date (%s)" % r)
	var hits_before: int = stub.hit_count("/dev/dev-000001.pck")
	# Pointer for the same channel but an older seq
	await u.check(true)
	_check(stub.hit_count("/dev/dev-000001.pck") == hits_before, "an up-to-date device never downloads the package again")

	# redirects are followed
	var root_r: String = _new_root()
	var cr: OtaCore = _core(root_r)
	var ur: OtaUpdater = _make_updater(cr, stub)
	stub.modes["/dev/redirected.json"] = "redirect"
	stub.redirects["/dev/redirected.json"] = "/dev/latest.json"
	ur.pointer_url = stub.url("/dev/redirected.json")
	await ur.check(false)
	_check(ur.status == "available" and ur.remote.get("ota_id", "") == "dev-000001", "pointer served through a redirect is followed (%s)" % ur.status)
	ur.queue_free()

	# new OTA, interrupted download, retry
	var m2: Dictionary = _published(stub, 2)
	stub.modes["/dev/dev-000002.pck"] = "truncate"
	await u.check(false)
	_check(u.status == "available", "seq 2 available")
	r = await u.download_available()
	_check(u.status == "failed" and _incoming_files(c).is_empty() and c.slot_id("pending") == "dev-000001" and not c.is_bad("dev-000002"), "interrupted download: failed, temp deleted, pending unchanged, not blacklisted (%s)" % r)
	_check(u.has_available(), "the update stays available for a retry")
	stub.modes["/dev/dev-000002.pck"] = "ok"
	r = await u.download_available()
	_check(u.status == "downloaded" and c.slot_id("pending") == "dev-000002", "retry after an interrupted download works (%s)" % r)

	# oversized body (longer than the manifest's pck_size + 1)
	var pl3: PackedByteArray = _payload(3)
	var m3: Dictionary = _manifest(3, pl3, {"pck_url": stub.url("/dev/dev-000003.pck")})
	var big: PackedByteArray = pl3.duplicate()
	big.append_array(_payload(8, 4000))
	_publish(stub, m3, big)
	await u.check(true)
	_check(u.status == "failed" and _incoming_files(c).is_empty() and c.slot_id("pending") == "dev-000002", "oversized body: cut off, failed, temp deleted (%s)" % u.status_detail)
	# not-found package
	stub.modes["/dev/dev-000003.pck"] = "404"
	await u.check(true)
	_check(u.status == "failed" and _incoming_files(c).is_empty(), "package 404: failed, nothing left behind")
	stub.modes["/dev/dev-000003.pck"] = "ok"

	# wrong content at full size: rejected + blacklisted, never fetched again
	var pl4: PackedByteArray = _payload(4)
	var wrong4: PackedByteArray = pl4.duplicate()
	wrong4[7] = (wrong4[7] + 1) % 256
	var m4: Dictionary = _manifest(4, pl4, {"pck_url": stub.url("/dev/dev-000004.pck")})
	_publish(stub, m4, wrong4)
	await u.check(true)
	_check(u.status == "rejected" and c.is_bad("dev-000004") and _incoming_files(c).is_empty(), "wrong SHA-256: rejected and blacklisted (%s)" % u.status_detail)
	var pck_hits: int = stub.hit_count("/dev/dev-000004.pck")
	for k in 3:
		await u.check(true)
	_check(u.status == "rejected" and stub.hit_count("/dev/dev-000004.pck") == pck_hits, "blacklisted id is never downloaded again (%d package requests)" % stub.hit_count("/dev/dev-000004.pck"))
	_has(u.status_detail, "not re-downloading", "status says why")
	# ... also across a restart
	var c_re: OtaCore = _core(root)
	var u_re: OtaUpdater = _make_updater(c_re, stub)
	await u_re.check(true)
	_check(u_re.status == "rejected" and stub.hit_count("/dev/dev-000004.pck") == pck_hits, "update-loop prevention survives a restart")
	u_re.queue_free()

	# wrong size in the manifest vs file
	var pl5: PackedByteArray = _payload(5)
	var m5: Dictionary = _manifest(5, pl5, {"pck_url": stub.url("/dev/dev-000005.pck"), "pck_size": pl5.size() + 10})
	_publish(stub, m5, pl5)
	await u.check(true)
	_check(u.status == "rejected" and _incoming_files(c).is_empty() and c.slot_id("pending") == "dev-000002", "size in manifest does not match the download: rejected (%s)" % u.status_detail)

	# bad signature / wrong key
	_published(stub, 6, {}, PackedByteArray(), _other)
	await u.check(true)
	_check(u.status == "rejected" and u.latest_compat.contains("signature"), "manifest signed with another key: rejected (%s)" % u.status_detail)
	_check(stub.hit_count("/dev/dev-000006.pck") == 0, "a manifest that does not verify never triggers a package download")

	# incompatible: runtime, fingerprint (incompatible runtime), baseline, bootstrap, save schema
	for case in [["runtime", {"runtime_id": "android-godot-4.7.0-r1"}, "native update required"],
			["fingerprint", {"runtime_fingerprint": "2".repeat(64)}, "incompatible runtime"],
			["baseline", {"base_source_sha": "c".repeat(40)}, "native update required"],
			["bootstrap", {"minimum_bootstrap_version": 9}, "native update required"]]:
		_published(stub, 7, case[1])
		await u.check(true)
		_check(u.status == "incompatible" and u.latest_compat.contains(case[2]), "%s mismatch -> incompatible (%s)" % [case[0], u.status_detail])
	_check(stub.hit_count("/dev/dev-000007.pck") == 0, "an incompatible OTA is never downloaded")
	var dsc: OtaCore = _core(_new_root())
	dsc.device_save_schema = 5
	var usc: OtaUpdater = _make_updater(dsc, stub)
	_published(stub, 8)
	await usc.check(true)
	_check(usc.status == "incompatible" and usc.latest_compat.begins_with("save incompatible"), "device saves newer than the OTA understands -> incompatible (%s)" % usc.status_detail)
	usc.queue_free()
	# protected path in files[]
	_published(stub, 9, {"files": [{"path": "godot/scripts/boot/boot.gd", "op": "replace"}]})
	await u.check(true)
	_check(u.status == "rejected" and u.status_detail.contains("protected path") and stub.hit_count("/dev/dev-000009.pck") == 0, "payload touching the native boundary: rejected before any download (%s)" % u.status_detail)

	# a stale (older) pointer never downgrades and never even fetches the old manifest
	_published(stub, 1)
	var old_manifest_hits: int = stub.hit_count("/dev/dev-000001.json")
	await u.check(true)
	_check(u.status == "up_to_date" and stub.hit_count("/dev/dev-000001.json") == old_manifest_hits and c.slot_id("pending") == "dev-000002", "a stale CDN pointer (older seq) is not an update and fetches nothing (%s)" % u.status_detail)

	# URL anchoring: the unsigned pointer and the manifest must stay inside the download base
	var m10: Dictionary = _published(stub, 10)
	for case in [["manifest_url on another host", {"manifest_url": "https://evil.example/dev/dev-000010.json"}, "https://evil.example/dev/dev-000010.json"],
			["signature_url in another directory", {"signature_url": stub.url("/other/dev-000010.json.sig")}, "/other/dev-000010.json.sig"],
			["manifest_url path-prefix trick", {"manifest_url": stub.url("/dev-evil/dev-000010.json")}, "/dev-evil/dev-000010.json"],
			["manifest_url with traversal", {"manifest_url": stub.url("/dev/../other/m.json")}, "/other/m.json"]]:
		_publish(stub, m10, _payload(10), null, case[1])
		await u.check(true)
		_check(u.status == "rejected" and u.status_detail.contains("outside the release download base"), "%s: rejected (%s)" % [case[0], u.status_detail])
		_check(stub.hit_count(case[2]) == 0 and stub.hit_count("/dev/dev-000010.pck") == 0, "%s: nothing fetched from there" % case[0])
	_published(stub, 10, {"pck_url": stub.url("/elsewhere/p.pck")})
	await u.check(true)
	_check(u.status == "rejected" and u.status_detail.contains("download base") and stub.hit_count("/elsewhere/p.pck") == 0, "manifest whose pck_url leaves the channel directory: rejected, never downloaded (%s)" % u.status_detail)
	_published(stub, 10, {"pck_url": "https://evil.example/dev/p.pck"})
	await u.check(true)
	_check(u.status == "rejected" and u.status_detail.contains("download base"), "pck_url on another host: rejected (%s)" % u.status_detail)
	_check(u.core.url_base == stub.url("/dev/"), "a flat pointer anchors on its own directory (%s)" % u.core.url_base)

	# the GitHub Releases layout end to end (loopback): pointer release + one immutable OTA release per update
	var cr2: OtaCore = _core(_new_root())
	var ur2: OtaUpdater = _make_updater(cr2, stub)
	ur2.pointer_url = stub.url("/releases/download/ota-channel-dev/latest.json")
	var pl_r: PackedByteArray = _payload(21)
	var tag_r: String = Config.ota_tag("dev", 21)
	var m_r: Dictionary = _manifest(21, pl_r, {"pck_url": stub.url("/releases/download/%s/purgatory-dev-000021.pck" % tag_r)})
	var sg_r: Array = _sign(m_r)
	stub.routes["/releases/download/%s/manifest.json" % tag_r] = sg_r[0]
	stub.routes["/releases/download/%s/manifest.json.sig" % tag_r] = (sg_r[1] as String).to_utf8_buffer()
	stub.routes["/releases/download/%s/purgatory-dev-000021.pck" % tag_r] = pl_r
	var ptr_r: Dictionary = {"channel": "dev", "ota_id": "dev-000021", "seq": 21, "manifest_url": stub.url("/releases/download/%s/manifest.json" % tag_r),
			"signature_url": stub.url("/releases/download/%s/manifest.json.sig" % tag_r), "native_version": 7, "app_minor": 21}
	stub.routes["/releases/download/ota-channel-dev/latest.json"] = JSON.stringify(ptr_r).to_utf8_buffer()
	await ur2.check(true)
	_check(ur2.status == "downloaded" and cr2.slot_id("pending") == "dev-000021" and cr2.url_base == stub.url("/releases/download/"), "Releases layout: pointer -> manifest -> package -> PENDING (%s)" % ur2.status_detail)
	for bad_ptr in [["the pointer release as manifest source", {"manifest_url": stub.url("/releases/download/ota-channel-dev/manifest.json")}],
			["a non-OTA release", {"manifest_url": stub.url("/releases/download/v7/manifest.json")}],
			["signature outside /releases/download/", {"signature_url": stub.url("/elsewhere/manifest.json.sig")}]]:
		var cr3: OtaCore = _core(_new_root())
		var ur3: OtaUpdater = _make_updater(cr3, stub)
		ur3.pointer_url = ur2.pointer_url
		var p2: Dictionary = ptr_r.duplicate()
		p2.merge(bad_ptr[1], true)
		stub.routes["/releases/download/ota-channel-dev/latest.json"] = JSON.stringify(p2).to_utf8_buffer()
		await ur3.check(true)
		_check(ur3.status == "rejected" and ur3.status_detail.contains("download base") and cr3.slot("pending").is_empty(), "%s: rejected (%s)" % [bad_ptr[0], ur3.status_detail])
		ur3.queue_free()
	ur2.queue_free()

	# pointer problems
	_published(stub, 10)
	stub.routes["/dev/latest.json"] = JSON.stringify({"channel": "stable", "ota_id": "dev-000010", "seq": 10, "manifest_url": stub.url("/dev/dev-000010.json"), "signature_url": stub.url("/dev/dev-000010.json.sig")}).to_utf8_buffer()
	await u.check(true)
	_check(u.status == "failed" and u.status_detail.contains("channel 'stable'"), "pointer for another channel: failed (%s)" % u.status_detail)
	stub.routes["/dev/latest.json"] = "not json at all".to_utf8_buffer()
	await u.check(true)
	_check(u.status == "failed" and u.status_detail.contains("invalid channel pointer"), "garbage pointer: failed (%s)" % u.status_detail)
	stub.routes["/dev/latest.json"] = JSON.stringify({"channel": "dev"}).to_utf8_buffer()
	await u.check(true)
	_check(u.status == "failed", "pointer without fields: failed")
	var mm: Dictionary = _manifest(11, _payload(11), {"ota_id": "dev-000012", "pck_url": stub.url("/dev/dev-000012.pck")})
	var sgm: Array = _sign(mm)
	stub.routes["/dev/mm.json"] = sgm[0]
	stub.routes["/dev/mm.json.sig"] = (sgm[1] as String).to_utf8_buffer()
	stub.routes["/dev/latest.json"] = JSON.stringify({"channel": "dev", "ota_id": "dev-000011", "seq": 11, "manifest_url": stub.url("/dev/mm.json"), "signature_url": stub.url("/dev/mm.json.sig")}).to_utf8_buffer()
	await u.check(true)
	_check(u.status == "rejected" and u.status_detail.contains("mismatch"), "pointer/manifest id mismatch: rejected (%s)" % u.status_detail)
	_check(c.slot_id("pending") == "dev-000002", "after all of that the staged update is untouched")
	# stale manifest behind a pointer that claims a newer seq
	var stale_m: Dictionary = _manifest(1, _payload(1), {"ota_id": "dev-000001b", "pck_url": stub.url("/dev/old.pck")})
	var sg_stale: Array = _sign(stale_m)
	stub.routes["/dev/latest.json"] = JSON.stringify({"channel": "dev", "ota_id": "dev-000001b", "seq": 99, "manifest_url": stub.url("/dev/stale.json"), "signature_url": stub.url("/dev/stale.json.sig")}).to_utf8_buffer()
	stub.routes["/dev/stale.json"] = sg_stale[0]
	stub.routes["/dev/stale.json.sig"] = (sg_stale[1] as String).to_utf8_buffer()
	await u.check(true)
	_check(u.status == "up_to_date" and stub.hit_count("/dev/old.pck") == 0, "a pointer that overstates seq cannot make an old manifest an update (%s)" % u.status_detail)

	# bundled baseline sha equal => up to date (nothing staged/running)
	var root_b: String = _new_root()
	var cb: OtaCore = _core(root_b)
	var ub: OtaUpdater = _make_updater(cb, stub)
	_published(stub, 12, {"source_sha": BASE})
	await ub.check(true)
	_check(ub.status == "up_to_date" and ub.status_detail.contains("embedded in this app") and stub.hit_count("/dev/dev-000012.pck") == 0, "an OTA built from the embedded baseline commit is 'up to date' (%s)" % ub.status_detail)
	ub.queue_free()

	# 404 / dropped connection / hang
	var root_o: String = _new_root()
	var co: OtaCore = _core(root_o)
	var uo: OtaUpdater = _make_updater(co, stub)
	stub.modes["/dev/latest.json"] = "404"
	await uo.check(true)
	_check(uo.status == "offline" and uo.status_detail.contains("HTTP 404"), "pointer 404: offline (%s)" % uo.status_detail)
	stub.modes["/dev/latest.json"] = "drop"
	await uo.check(true)
	_check(uo.status == "offline", "dropped connection: offline (%s)" % uo.status_detail)
	stub.modes["/dev/latest.json"] = "hang"
	uo.timeout = 1.0
	var frames0: int = _frames
	var t0: int = Time.get_ticks_msec()
	await uo.check(true)
	var elapsed: int = Time.get_ticks_msec() - t0
	_check(uo.status == "offline" and elapsed < 8000 and not uo.busy, "hanging server: gives up after the timeout, offline (%d ms, %s)" % [elapsed, uo.status_detail])
	_check(_frames - frames0 > 20, "the main loop kept running while the server hung (%d frames)" % (_frames - frames0))
	stub.modes["/dev/latest.json"] = "ok"
	# manifest fetch hangs too
	_published(stub, 13)
	stub.modes["/dev/dev-000013.json"] = "hang"
	await uo.check(true)
	_check(uo.status == "offline" and not uo.busy and co.slot("pending").is_empty(), "hanging manifest: offline, nothing staged")
	stub.modes["/dev/dev-000013.json"] = "ok"
	# happy again after all those failures (the client recovers by itself)
	uo.timeout = 15.0
	await uo.check(true)
	_check(uo.status == "downloaded" and co.slot_id("pending") == "dev-000013", "the client recovers after failures (%s)" % uo.status_detail)

	# concurrent calls are refused, not queued
	var root_c: String = _new_root()
	var cc: OtaCore = _core(root_c)
	var uc: OtaUpdater = _make_updater(cc, stub)
	var pending_check: Array = [""]
	var kick: Callable = func() -> void: pending_check[0] = await uc.check(false)
	kick.call()
	_check(uc.busy and await uc.check(false) == "busy", "a second check while one runs returns 'busy'")
	while uc.busy:
		await get_tree().process_frame
	uc.queue_free()

	# unreachable channel (connection refused): offline, game keeps running (core boots from the store)
	var root_u: String = _new_root()
	var cu: OtaCore = _make_current(root_u, 1)
	cu = _core(root_u)
	var uu: OtaUpdater = _make_updater(cu, stub)
	stub.stop()
	stub.queue_free()
	uu.pointer_url = "http://127.0.0.1:%d/dev/latest.json" % stub.port
	await get_tree().process_frame
	await uu.check(true)
	_check(uu.status == "offline" and uu.status_detail.contains("unreachable"), "connection refused: offline (%s)" % uu.status_detail)
	_check(cu.slot_id("current") == "dev-000001" and not uu.busy, "offline leaves the stored OTA untouched")
	var restarted: OtaCore = _core(root_u)
	_check(restarted.boot(_fake_mount).get("ota_id", "") == "dev-000001", "boot with no network at all runs the stored OTA")
	_check(_incoming_files(cu).is_empty(), "no temp files after an unreachable channel")
	for node in [u, uo, uu]:
		node.queue_free()


# --- 13. Boot node: diagnostics, panel, health, overlay ---------------------------------------------------------

func _fake_boot(c: OtaCore) -> Node:
	var b: Node = BootScript.new()
	b.ota_enabled = true
	b.inert_reason = ""
	b.core = c
	b.channel = "dev"
	b.platform = "android"
	b.runtime_id = RUNTIME
	b.native_info = {"commit": BASE, "runtime_fingerprint": FP, "runtime_id": RUNTIME, "public_version": 7}
	b._args = {"ota-no-autocheck": "true"}
	return b


func _t_boot_node() -> void:
	# The real autoload is inert in the unit suite.
	var real: Node = get_node_or_null("/root/Boot")
	_check(real != null, "Boot is an autoload")
	if real != null:
		_check(not real.ota_enabled and real.footer_suffix() == "", "inert Boot: no footer suffix")
		_has(real.diagnostics_text(), "Client: off", "inert diagnostics say the client is off")
		_has(real.diagnostics_text(), "Reason:", "inert diagnostics give the reason")
		_check(not BuildInfo.display_string().contains("running v") and not BuildInfo.display_string().contains("restart to apply"), "footer unchanged when inert (%s)" % BuildInfo.display_string())
		_check(real.running_version() == str(BuildInfo.public_version()) and real.app_minor() == 0, "inert Boot runs the bare native version (%s)" % real.running_version())
		_check(BuildInfo.running_version() == real.running_version(), "BuildInfo.running_version() follows Boot")
		_has(BuildInfo.diagnostics(), "OTA", "BuildInfo.diagnostics() includes the OTA lines")
		real.report_ready()
		real.report_ready()
		var ov: Node = null
		real.show_diagnostics()
		ov = real._overlay
		_check(ov != null and ov.is_open(), "diagnostics overlay opens when inert")
		_check(ov._buttons.has("copy") and ov._buttons.has("close") and not ov._buttons.has("check"), "inert overlay offers Copy and Close only")
		ov._on_button("close")
		_check(not ov.is_open(), "Close closes it")
		real._overlay.queue_free()
		real._overlay = null
		var ev: InputEventKey = InputEventKey.new()
		ev.keycode = KEY_F9
		ev.pressed = true
		real._input(ev)
		_check(real._overlay != null and real._overlay.is_open(), "F9 opens the overlay")
		real._input(ev)
		_check(not real._overlay.is_open(), "F9 again closes it (toggle)")
		_check(real.status_word() == "inactive", "inert Boot reports status 'inactive'")
		_check(real.diagnostics() == real.diagnostics_text(), "diagnostics() is the same text as diagnostics_text()")
		real._overlay.queue_free()
		real._overlay = null
		real._ready_at_ms = -1
		real.set_process(false)

	# Enabled Boot over a scratch core
	var root: String = _new_root()
	var c: OtaCore = _make_current(root, 3)
	c = _core(root)
	_stage(c, 4)
	c = _core(root)
	c.boot(_fake_mount)   # runs 4 (first run)
	var b: Node = _fake_boot(c)
	_check(c.first_run, "setup: unconfirmed first run")
	add_child(b)
	_check(b.panel_visible(), "Applying update panel is shown for a never-run package")
	_check((b._panel.get_child(1) as Label).text == "Applying update v7.4", "the panel names the owner-facing version, not an update number (%s)" % (b._panel.get_child(1) as Label).text)
	_check(b.running_version() == "7.4" and b.app_minor() == 4 and b.native_version() == "7", "running version is the owner-facing 7.4 (%s), native stays 7" % b.running_version())
	_check(b.footer_suffix() == "", "nothing staged: no footer suffix (%s)" % b.footer_suffix())
	_check(BuildInfo.compose_display(true, 7, b.running_version(), "", b.footer_suffix()) == "Purgatory Dungeon v7.4", "release footer reads Purgatory Dungeon v7.4")
	_has(b.ota_status(), "Not checked yet", "status before any check")
	var d: String = b.diagnostics_text()
	for needle in ["Runtime: " + RUNTIME, "Runtime fingerprint: " + FP, "Embedded baseline source: " + BASE, "Channel: dev", "Running: OTA v7.4 (dev-000004, #000004",
			"Current (known good): v7.3 (dev-000003", "Pending (runs after restart): v7.4 (dev-000004", "Rollback count: 0", "This run healthy: not yet", "OTA disabled (baseline mode): no", "Bootstrap: v1"]:
		_has(d, needle, "diagnostics include '%s'" % needle)
	_check(not d.contains("PRIVATE") and not d.contains("BEGIN"), "diagnostics never print key material")
	var dl: PackedStringArray = d.split("\n")
	_check(dl[0] == "Purgatory Dungeon v7.4" and dl[1] == "Native APK: v7" and dl[2] == "Application layer: v7.4" and dl[3] == "OTA: #000004 (dev-000004)" \
			and dl[4] == "Runtime: %s  fingerprint %s" % [RUNTIME, FP], "diagnostics open with the three identities (%s)" % str(dl.slice(0, 5)))
	_check(not d.contains("update 4") and not d.contains("· update"), "no 'update K' wording in diagnostics")
	# health: report_ready + HEALTHY_AFTER_MS, panel removed
	b.report_ready()
	await get_tree().create_timer(1.0).timeout
	_check(not b.panel_visible(), "the Applying update panel goes away once the game reported ready")
	_check(not b.healthy, "not healthy before HEALTHY_AFTER_MS")
	b._ready_at_ms -= BootScript.HEALTHY_AFTER_MS + 100
	b._ready_frames = 100
	b.set_process(true)
	b._process(0.0)
	_check(b.healthy and c.slot_id("current") == "dev-000004" and c.slot_id("previous") == "dev-000003", "healthy: PENDING promoted (%s)" % c.slot_id("current"))
	_check(c.device_save_schema == 1 and int(c.state["device_save_schema"]) == 1, "healthy records the running game's save schema (SAVE_SCHEMA)")
	_check(b._tick != null and not b.is_processing(), "after health Boot stops polling _process (periodic checks use a timer)")
	_check(b.footer_suffix() == "" and b.running_version() == "7.4", "footer still shows the running version")
	# panel max time
	b._show_panel()
	b._panel_since_ms -= BootScript.PANEL_MAX_MS + 100
	b._ready_at_ms = -1
	b._process(0.0)
	_check(not b.panel_visible(), "the panel never stays longer than %d ms" % BootScript.PANEL_MAX_MS)
	# overlay with an enabled client
	b.show_diagnostics()
	var ov2: Node = b._overlay
	_check(ov2.is_open() and ov2._text.text == b.diagnostics_text(), "overlay shows the diagnostics text")
	for id in ["check", "download", "activate", "rollback", "baseline", "copy", "close"]:
		_check(ov2._buttons.has(id), "overlay has the %s button" % id)
	_check((ov2._buttons["download"] as Button).disabled and (ov2._buttons["activate"] as Button).disabled and not (ov2._buttons["rollback"] as Button).disabled, "buttons enabled according to state")
	_check((ov2._buttons["check"] as Button).custom_minimum_size.y >= 48, "buttons are large enough to hit")
	ov2._on_button("baseline")
	_check(bool(c.state["disabled"]) and (ov2._buttons["baseline"] as Button).text == "Re-enable OTA", "Boot baseline disables OTA, button becomes Re-enable OTA")
	_has(b.ota_status(), "OTA disabled", "status says OTA is disabled")
	ov2._on_button("baseline")
	_check(not bool(c.state["disabled"]) and (ov2._buttons["baseline"] as Button).text == "Boot baseline", "Re-enable OTA works")
	ov2._on_button("rollback")
	_check(c.slot_id("current") == "dev-000003" and c.is_bad("dev-000004") and int(c.state["rollback_count"]) == 1, "Roll back button rolls back")
	_has(b.diagnostics_text(), "Rollback count: 1", "diagnostics count the rollback")
	_has(b.diagnostics_text(), "Rejected OTAs: dev-000004", "diagnostics list the rejected OTA")
	ov2._on_button("copy")
	if DisplayServer.get_name() != "headless":
		_check(DisplayServer.clipboard_get() == b.diagnostics_text(), "Copy diagnostics puts the text on the clipboard")
	ov2._on_button("close")
	_check(not ov2.is_open(), "Close closes the overlay")
	# status texts for each updater state
	var up: OtaUpdater = b.updater
	_check(up != null, "Boot built an updater")
	up.remote = {"ota_id": "dev-000009"}
	var statuses: Array = [["unchecked", "Not checked yet"], ["checking", "Checking the dev channel"], ["downloading", "Downloading dev-000009"],
			["available", "Update available: dev-000009"], ["up_to_date", "Up to date"], ["offline", "Offline"],
			["incompatible", "Incompatible: latest OTA dev-000009 cannot run"], ["rejected", "Rejected: latest OTA dev-000009"],
			["failed", "Update failed (boom)"], ["downloaded", "Update downloaded"]]
	up.status_detail = "boom"
	for pair in statuses:
		up.status = pair[0]
		_has(b.ota_status(), pair[1], "status '%s' reads '%s'" % [pair[0], pair[1]])
		_has(b.diagnostics_text(), "Status: " + b.ota_status(), "diagnostics carry the status line for " + pair[0])
	up.status = "incompatible"
	up.latest_compat = "native update required: x"
	_has(b.diagnostics_text(), "NOT compatible: native update required: x", "diagnostics show incompatibility reason")
	up.latest_compat = "compatible"
	_has(b.diagnostics_text(), "Latest OTA compatibility: compatible", "diagnostics show compatibility")
	# staged update shows 'restart' in status and footer
	c.state["auto_activate"] = true
	_stage(c, 5)
	_has(b.ota_status(), "Update downloaded: v7.5 (dev-000005) runs after the app restarts", "pending update is reported")
	_check(b.footer_suffix() == " · v7.5 ready, restart to apply" and b.staged_version() == "7.5", "footer names the staged owner-facing version and says restart (%s)" % b.footer_suffix())
	_check(BuildInfo.compose_display(true, 7, b.running_version(), "", b.footer_suffix()) == "Purgatory Dungeon v7.4 · v7.5 ready, restart to apply", "release footer with a staged update")
	c.state["pending"] = {}
	# 'ready' (downloaded, not activated)
	c.state["ready"] = _manifest(6, _payload(6))
	_has(b.ota_status(), "press Activate on restart", "READY is reported")
	c.state["ready"] = {}
	# identity json
	var idj: Dictionary = b.identity()
	_check(idj["runtime_id"] == RUNTIME and idj["baseline_source_sha"] == BASE and idj["ota_enabled"] == true and idj["channel"] == "dev", "identity() exposes the runtime identity")
	_check(JSON.parse_string(JSON.stringify(idj)) is Dictionary, "identity() is JSON serialisable")
	# footer for a baseline run with nothing staged
	var cb: OtaCore = _core(_new_root())
	cb.boot(_fake_mount)
	var bb: Node = _fake_boot(cb)
	_check(bb.footer_suffix() == "", "baseline running, nothing staged: no footer suffix")
	_has(bb.diagnostics_text(), "Running: embedded baseline (v7)", "baseline diagnostics")
	var bl: PackedStringArray = bb.diagnostics_text().split("\n")
	_check(bl[0] == "Purgatory Dungeon v7" and bl[1] == "Native APK: v7" and bl[2] == "Application layer: v7" and bl[3] == "OTA: none (embedded baseline)", "baseline diagnostics open with v7 (%s)" % str(bl.slice(0, 4)))
	_check(bb.running_version() == "7" and bb.app_minor() == 0 and bb.staged_version() == "", "baseline running version is 7, minor 0")
	_check(BuildInfo.compose_display(true, 7, "7", "", "") == "Purgatory Dungeon v7", "release baseline footer is exactly Purgatory Dungeon v7")
	_check(BuildInfo.compose_display(false, 7, "7", " · abc1234", "") == "Purgatory Dungeon · development build after v7 · abc1234", "development baseline footer")
	_check(BuildInfo.compose_display(false, 7, "7.1", " · abc1234", "") == "Purgatory Dungeon · development build after v7 · abc1234 · running v7.1", "development footer names the running OTA version")
	for fb in [BuildInfo.compose_display(true, 7, "7.1", "", " · v7.2 ready, restart to apply"), b.diagnostics_text()]:
		_check(not (fb as String).contains("update 1") and not (fb as String).contains("· update"), "no 'update K' wording anywhere")
	bb.free()
	b.queue_free()


# --- 14. check policy and tap gesture (pure logic) ---------------------------------------------------------------------

func _t_policy_and_taps() -> void:
	var due: Callable = BootScript.auto_check_due
	var min_ms: int = BootScript.AUTO_CHECK_MIN_GAP_S * 1000
	var hour_ms: int = BootScript.AUTO_CHECK_PERIOD_S * 1000
	_check(min_ms == 15 * 60 * 1000 and hour_ms == 60 * 60 * 1000, "policy constants are 15 minutes and 1 hour")
	_check(due.call("start", 5000, -1), "start: due once per launch, right after boot health")
	_check(not due.call("start", 999999999, 5000), "start: never twice in a launch")
	_check(not due.call("resume", 5000, -1), "resume before any attempt: not due")
	_check(not due.call("periodic", 5000, -1), "periodic before any attempt: not due")
	_check(not due.call("resume", 5000 + min_ms - 1, 5000), "resume < 15 min after the last attempt: not due")
	_check(due.call("resume", 5000 + min_ms, 5000), "resume exactly 15 min after the last attempt: due")
	_check(due.call("resume", 5000 + min_ms * 3, 5000), "resume long after: due")
	_check(not due.call("periodic", 5000 + hour_ms - 1, 5000), "periodic < 1 h after the last attempt: not due")
	_check(due.call("periodic", 5000 + hour_ms, 5000), "periodic after 1 h: due")
	_check(not due.call("resume", 10, 5000), "clock before the last attempt: not due")
	_check(due.call("bogus", 5000 + min_ms, 5000) and not due.call("bogus", 5000 + min_ms - 1, 5000), "unknown reasons use the 15 minute gap")
	# attempts count even when they failed: auto_check on a real (inert) Boot never fires without a client
	var b: Node = BootScript.new()
	_check(not b.auto_check("start"), "no automatic check without a running client")
	# tap gesture
	var vp: Vector2 = Vector2(1280, 720)
	var t: int = 100000
	var done: bool = false
	for i in 5:
		done = b.register_tap(Vector2(20, 20), vp, t + i * 200)
	_check(done, "five taps in the top-left corner open diagnostics")
	_check(not b.register_tap(Vector2(20, 20), vp, t + 1200), "the counter restarts after opening")
	var b2: Node = BootScript.new()
	for i in 4:
		_check(not b2.register_tap(Vector2(20, 20), vp, t + i * 200), "tap %d alone does nothing" % (i + 1))
	_check(not b2.register_tap(Vector2(900, 20), vp, t + 900), "taps outside the corner do not count")
	_check(not b2.register_tap(Vector2(20, 500), vp, t + 950), "taps below the corner do not count")
	_check(b2.register_tap(Vector2(20, 20), vp, t + 1000), "the fifth corner tap completes it despite stray taps")
	var b3: Node = BootScript.new()
	for i in 5:
		done = b3.register_tap(Vector2(20, 20), vp, t + i * 1000)
	_check(not done, "five slow taps (4 s apart overall) do not")
	_check(b3.register_tap(Vector2(20, 20), vp, t + 5000) == false, "...and the window slides: a sixth slow tap still does not")
	var fast: bool = false
	for i in 5:
		fast = b3.register_tap(Vector2(20, 20), vp, t + 20000 + i * 300)
	_check(fast, "after slow taps, five quick ones still work (sliding window)")
	var b4: Node = BootScript.new()
	var pairs_done: bool = false
	for i in 4:
		b4.register_tap(Vector2(20, 20), vp, t + i * 300)
		_check(not b4.register_tap(Vector2(21, 21), vp, t + i * 300 + 5), "the emulated mouse click of the same tap is ignored")
	pairs_done = b4.register_tap(Vector2(20, 20), vp, t + 1200)
	_check(pairs_done, "touch + emulated mouse pairs count once each (5th real tap opens)")
	for n in [b, b2, b3, b4]:
		n.free()


# --- 15. feature gate ---------------------------------------------------------------------------------------------

func _t_boot_gating() -> void:
	var good: Dictionary = {"commit": BASE, "runtime_fingerprint": FP, "runtime_id": RUNTIME}
	var b: Node = BootScript.new()
	b.platform = "android"
	b.runtime_id = RUNTIME
	b.hooks_allowed = true
	b._args = {}
	b.native_info = good
	_has(b._inert_reason(false), "no OTA client", "no `ota` feature and no --ota-enable: inert")
	b._args = {"ota-enable": "true"}
	_check(b._inert_reason(false) == "", "--ota-enable in a non-template build with a native identity: runs")
	_has(b._inert_reason(true), "disabled by --no-ota", "PURGATORY_NO_OTA / --no-ota wins")
	b.hooks_allowed = false
	_has(b._inert_reason(false), "no OTA client", "a template (shipped) build ignores --ota-enable")
	b.hooks_allowed = true
	b.native_info = {}
	_has(b._inert_reason(false), "no native identity", "no build_info identity: baseline mode")
	b.native_info = {"commit": "short", "runtime_fingerprint": FP, "runtime_id": RUNTIME}
	_has(b._inert_reason(false), "no native identity", "invalid baseline commit: baseline mode")
	b.native_info = {"commit": BASE, "runtime_id": RUNTIME}
	_has(b._inert_reason(false), "runtime_fingerprint", "missing fingerprint: baseline mode")
	b.native_info = {"commit": BASE, "runtime_fingerprint": FP, "runtime_id": "android-godot-4.6.0-r9"}
	_has(b._inert_reason(false), "native identity mismatch", "build info runtime id differs from the native layer's: baseline mode")
	b.native_info = {"commit": BASE.to_upper(), "runtime_fingerprint": FP.to_upper(), "runtime_id": RUNTIME}
	_check(b._inert_reason(false) == "", "identity hex is case-insensitive (normalised)")
	b.free()
	# the unit-suite Boot (real autoload) is inert, and a hostile environment cannot change the template rule
	_check(not OS.has_feature(Config.FEATURE), "the test run itself has no `ota` feature")
	_check(BootScript._hex(FP, 64) and not BootScript._hex("zz", 2) and not BootScript._hex(FP, 63), "hex helper")


# --- 16. save root mirror ----------------------------------------------------------------------------------------------

func _t_save_root_mirror() -> void:
	_check(BootScript.native_save_root() == StoragePaths.root(), "native save root mirrors StoragePaths.root() (env override: %s)" % BootScript.native_save_root())
	var saved_env: String = OS.get_environment(StoragePaths.ENV_OVERRIDE)
	var saved_touch: String = OS.get_environment("PURGATORY_FORCE_TOUCH")
	OS.unset_environment(StoragePaths.ENV_OVERRIDE)
	OS.unset_environment("PURGATORY_FORCE_TOUCH")
	_check(BootScript.native_save_root() == StoragePaths.root(), "mirror equals StoragePaths.root() on desktop (%s)" % BootScript.native_save_root())
	_check(BootScript.native_save_root().ends_with("PurgetoryDungeon"), "desktop save folder keeps the compatibility name")
	OS.set_environment("PURGATORY_FORCE_TOUCH", "1")
	_check(BootScript.native_save_root() == StoragePaths.root(), "mirror equals StoragePaths.root() on a touch platform (%s)" % BootScript.native_save_root())
	_check(BootScript.native_save_root() == OS.get_user_data_dir().path_join("PurgetoryDungeon"), "touch platforms keep saves in the app data folder")
	OS.unset_environment("PURGATORY_FORCE_TOUCH")
	if saved_touch != "":
		OS.set_environment("PURGATORY_FORCE_TOUCH", saved_touch)
	if saved_env != "":
		OS.set_environment(StoragePaths.ENV_OVERRIDE, saved_env)


# --- 17. boundary mirror (enforced once ota/boundary.json exists) ----------------------------------------------------

func _t_boundary_mirror() -> void:
	var path: String = "res://ota/boundary.json"
	if not FileAccess.file_exists(path):
		print("test_ota_core: ota/boundary.json not present yet; protected-path mirror check skipped")
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(parsed is Dictionary, "boundary.json parses")
	if not (parsed is Dictionary):
		return
	var bj: Dictionary = parsed
	var prot: Dictionary = bj.get("payload_protected", bj.get("protected", {}))
	for pair in [["exact", Protected.EXACT], ["prefixes", Protected.PREFIXES], ["suffixes", Protected.SUFFIXES]]:
		var want: Array = (prot.get(pair[0], []) as Array).duplicate()
		var have: Array = (pair[1] as Array).duplicate()
		want.sort()
		have.sort()
		_check(want == have, "ota_protected.gd %s equals ota/boundary.json (%s vs %s)" % [pair[0], str(have), str(want)])
