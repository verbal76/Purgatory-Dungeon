extends Node
## OTA client: signature + compatibility verification, update application, restart behaviour, crash-loop
## rollback, remote revocation, failure handling and save preservation (docs/OTA.md). Pure logic with a fake
## mounter, so it runs headless anywhere. Must run with PURGATORY_SAVE_ROOT set (see run_tests.sh).

var _fails: int = 0
var _checks: int = 0
var _crypto := Crypto.new()
var _key: CryptoKey
var _other_key: CryptoKey
var _pem: String
var _base: String
var _ident: Dictionary = {}
var _mounted: Array[String] = []
var _mount_ok: bool = true


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _fake_mount(path: String) -> bool:
	_mounted.append(path)
	return _mount_ok


func _sign(data: PackedByteArray, key: CryptoKey) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return Marshalls.raw_to_base64(_crypto.sign(HashingContext.HASH_SHA256, ctx.finish(), key))


func _new_root(tag: String) -> String:
	var r: String = _base.path_join(tag)
	OtaStore.remove_tree(r)
	DirAccess.make_dir_recursive_absolute(r)
	return r


## Writes slots/<seq>/ with a signed manifest and payload. `tweak` may modify the manifest dict before signing.
func _make_slot(root: String, seq: int, tweak: Callable = Callable(), key: CryptoKey = null) -> void:
	var payload := PackedByteArray()
	for i in 4096:
		payload.append((i * 31 + seq) % 251)
	var m: Dictionary = {
		"format": 1, "product": "purgatory-dungeon", "platform": _ident["platform"], "native_version": _ident["native_version"],
		"base_commit": _ident["base_commit"], "engine": _ident["engine"], "ota_api": _ident["ota_api"],
		"payload_seq": seq, "label": "Purgatory Dungeon v%d update %d" % [_ident["native_version"], seq],
		"source_commit": "b".repeat(40), "created_utc": "2026-10-05T19:00:00Z",
		"payload": {"file": "payload.pck", "size": payload.size(), "sha256": OtaCrypto.sha256_bytes(payload)},
		"files": [{"path": "scripts/example.gdc", "op": "replace"}],
	}
	if tweak.is_valid():
		tweak.call(m)
	var d: String = OtaStore.slot_dir(root, seq)
	DirAccess.make_dir_recursive_absolute(d)
	var f := FileAccess.open(d.path_join("payload.pck"), FileAccess.WRITE)
	f.store_buffer(payload)
	f.close()
	var mtext: String = JSON.stringify(m, "  ")
	var mb: PackedByteArray = mtext.to_utf8_buffer()
	var mf := FileAccess.open(d.path_join("manifest.json"), FileAccess.WRITE)
	mf.store_buffer(mb)
	mf.close()
	var sf := FileAccess.open(d.path_join("manifest.sig"), FileAccess.WRITE)
	sf.store_string(_sign(mb, key if key != null else _key))
	sf.close()


func _stage(root: String, seq: int) -> void:
	var st: Dictionary = OtaStore.load_state(root)
	st["pending"] = seq
	OtaStore.save_state(root, st)


func _boot(root: String, save_root: String = "") -> Dictionary:
	_mounted.clear()
	return OtaCore.boot(root, _ident, _pem, _fake_mount, save_root)


func _hash_tree(dir_path: String) -> String:
	var parts: PackedStringArray = []
	for f in DirAccess.get_files_at(dir_path):
		parts.append(f + ":" + OtaCrypto.sha256_file(dir_path.path_join(f)))
	for d in DirAccess.get_directories_at(dir_path):
		parts.append(d + "/" + _hash_tree(dir_path.path_join(d)))
	return ",".join(parts)


func _flip_byte(path: String, at: int) -> void:
	var b: PackedByteArray = FileAccess.get_file_as_bytes(path)
	b[at] = b[at] ^ 0xff
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(b)
	f.close()


func _ready() -> void:
	var save_env: String = OS.get_environment(StoragePaths.ENV_OVERRIDE)
	if save_env == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	_base = save_env.get_base_dir().path_join("ota_unit")
	_key = _crypto.generate_rsa(2048)
	_other_key = _crypto.generate_rsa(2048)
	_pem = _key.save_to_string(true)
	_ident = {"platform": "android", "native_version": 5, "base_commit": "a".repeat(40),
			"engine": "4.6.stable.official.89cea1439", "ota_api": OtaConst.OTA_API}

	_test_crypto()
	_test_manifest_rules()
	_test_protected_paths()
	_test_constants_match_rules_file()
	_test_boot_basic()
	_test_boot_failures()
	_test_crash_loop_and_rollback()
	_test_revocation_and_plan()
	_test_save_preservation()
	_test_diagnostics()
	OtaStore.remove_tree(_base)
	print("test_ota_client: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _test_crypto() -> void:
	var data: PackedByteArray = "hello update".to_utf8_buffer()
	var sig: String = _sign(data, _key)
	_check(OtaCrypto.verify(data, sig, _pem), "a good signature verifies")
	_check(OtaCrypto.verify(data, sig + "\n", _pem), "trailing newline in the signature file is tolerated")
	_check(not OtaCrypto.verify("hello updatf".to_utf8_buffer(), sig, _pem), "a changed document fails verification")
	_check(not OtaCrypto.verify(data, _sign(data, _other_key), _pem), "a signature from another key fails")
	_check(not OtaCrypto.verify(data, "", _pem), "empty signature fails")
	_check(not OtaCrypto.verify(data, "not base64 !!!", _pem), "garbage signature fails")
	_check(not OtaCrypto.verify(data, sig, ""), "no trust anchor fails closed")
	_check(not OtaCrypto.verify(data, sig, "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----"), "a malformed trust anchor fails closed")
	_check(not OtaCrypto.verify(PackedByteArray(), sig, _pem), "empty document fails")
	_check(OtaCrypto.sha256_bytes("abc".to_utf8_buffer()) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 of 'abc' is the standard vector")
	_check(OtaCrypto.sha256_file("/nonexistent/file") == "", "sha256_file of a missing file is empty")


func _manifest(tweak: Callable = Callable()) -> Dictionary:
	var root: String = _new_root("manifest_probe")
	_make_slot(root, 1, tweak)
	return OtaVerify.slot_manifest(root, 1)


func _test_manifest_rules() -> void:
	_check(OtaManifest.check(_manifest(), _ident) == "", "a matching manifest is accepted")
	var cases := {
		"wrong format": func(m): m["format"] = 2,
		"wrong product": func(m): m["product"] = "other",
		"wrong platform": func(m): m["platform"] = "windows",
		"wrong native version": func(m): m["native_version"] = 6,
		"wrong base commit": func(m): m["base_commit"] = "c".repeat(40),
		"short base commit": func(m): m["base_commit"] = "abc",
		"wrong engine": func(m): m["engine"] = "4.7.stable.official.deadbeef0",
		"wrong ota api": func(m): m["ota_api"] = 2,
		"zero seq": func(m): m["payload_seq"] = 0,
		"oversized payload": func(m): m["payload"]["size"] = OtaConst.MAX_PAYLOAD_BYTES + 1,
		"bad sha": func(m): m["payload"]["sha256"] = "xyz",
		"other payload name": func(m): m["payload"]["file"] = "evil.pck",
		"no source commit": func(m): m["source_commit"] = "",
		"empty files": func(m): m["files"] = [],
		"unknown op": func(m): m["files"] = [{"path": "a.gd", "op": "chmod"}],
		"protected file": func(m): m["files"] = [{"path": "project.binary", "op": "replace"}],
		"traversal": func(m): m["files"] = [{"path": "../../etc/passwd", "op": "add"}],
	}
	for name in cases:
		# Build the (tweaked) manifest straight from a fresh valid one so each case breaks exactly one rule.
		var m: Dictionary = _manifest()
		(cases[name] as Callable).call(m)
		_check(OtaManifest.check(m, _ident) != "", "manifest rejected: %s" % name)
	_check(OtaManifest.check({}, _ident) != "", "empty manifest rejected")


func _test_protected_paths() -> void:
	for p in ["project.godot", "project.binary", "export_presets.cfg", "ota_trust.pem", "ota_channel.json", "build_info.json",
			"VERSION", "scripts/ota/ota_core.gd", "scripts/ota/ota_core.gdc", "android/build/x", "addons/foo/foo.gdextension",
			"addons/foo/bin/libfoo.so", "bin/foo.dll", "x/foo.dylib", ".godot/extension_list.cfg", "/etc/passwd", "res://a.gd",
			"user://x", "a/../b", "C:/x", "a//b", "", "Scripts/OTA/x.gd"]:
		_check(OtaManifest.is_protected_path(p), "protected: '%s'" % p)
	for p in ["scripts/enemy_manager.gdc", "data/buffs.json", ".godot/imported/a.png-1234.ctex", "scenes/MainMenu.tscn", "scripts/ota_like.gd"]:
		_check(not OtaManifest.is_protected_path(p), "ordinary content allowed: '%s'" % p)


func _test_constants_match_rules_file() -> void:
	var path := "res://tools/ota/ota_rules.json"
	if not FileAccess.file_exists(path):
		print("  (tools/ota/ota_rules.json not in this build; drift check skipped)")
		return
	var rules: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(rules is Dictionary and (rules as Dictionary).has("protected"), "ota_rules.json has a protected section")
	if not (rules is Dictionary) or not (rules as Dictionary).has("protected"):
		return
	var prot: Dictionary = (rules as Dictionary)["protected"]
	var ex: Array = prot.get("exact", [])
	var pre: Array = prot.get("prefixes", [])
	var suf: Array = prot.get("suffixes", [])
	for want in OtaConst.PROTECTED_EXACT:
		_check(ex.has(want), "rules file lists exact path %s" % want)
	for want in OtaConst.PROTECTED_PREFIXES:
		_check(pre.has(want), "rules file lists prefix %s" % want)
	for want in OtaConst.PROTECTED_SUFFIXES:
		_check(suf.has(want), "rules file lists suffix %s" % want)
	_check(ex.size() == OtaConst.PROTECTED_EXACT.size() and pre.size() == OtaConst.PROTECTED_PREFIXES.size() \
			and suf.size() == OtaConst.PROTECTED_SUFFIXES.size(), "client constants and rules file have the same number of protected entries")


func _test_boot_basic() -> void:
	var saves: String = _new_root("saves_basic")
	var root: String = _new_root("basic")
	# Nothing stored: native build, nothing mounted.
	var r: Dictionary = _boot(root, saves)
	_check(int(r["active_seq"]) == 0 and _mounted.is_empty(), "no update stored -> native build, nothing mounted")

	# Stage update 1 (as the updater would) and restart.
	_make_slot(root, 1)
	_stage(root, 1)
	r = _boot(root, saves)
	_check(int(r["active_seq"]) == 1 and _mounted.size() == 1, "a staged update is mounted at the next launch")
	_check(_mounted[0].ends_with("slots/1/payload.pck"), "the verified slot payload is what gets mounted")
	_check(str(r["active_source_commit"]) == "b".repeat(40) and str(r["active_payload_id"]).length() == 64, "update identity is reported")
	var st: Dictionary = OtaStore.load_state(root)
	_check(int(st["active"]) == 1 and int(st["pending"]) == 0 and int(st["boot_attempts"]) == 1 and int(st["known_good"]) == 0,
			"state after first activation: active=1, attempts=1, not yet known-good")

	# Healthy -> confirmed.
	OtaCore.apply_result(r)
	_check(not OtaRuntime.confirmed, "not confirmed before the healthy window")
	OtaCore.confirm_health(root)
	st = OtaStore.load_state(root)
	_check(OtaRuntime.confirmed and int(st["known_good"]) == 1 and int(st["boot_attempts"]) == 0, "confirm_health marks the update known-good")

	# Confirmed updates mount on every launch without burning attempts.
	for i in 3:
		r = _boot(root, saves)
		_check(int(r["active_seq"]) == 1, "confirmed update mounts again (launch %d)" % (i + 2))
	st = OtaStore.load_state(root)
	_check(int(st["boot_attempts"]) == 0, "confirmed update never accumulates attempts")

	# A newer update supersedes it and the old one stays as rollback target until the new one is confirmed.
	_make_slot(root, 2)
	_stage(root, 2)
	r = _boot(root, saves)
	_check(int(r["active_seq"]) == 2, "update 2 replaces update 1")
	_check(DirAccess.dir_exists_absolute(OtaStore.slot_dir(root, 1)), "update 1 is kept as the rollback target while 2 is unconfirmed")
	OtaCore.apply_result(r)
	OtaCore.confirm_health(root)
	_check(not DirAccess.dir_exists_absolute(OtaStore.slot_dir(root, 1)), "update 1 is deleted once update 2 is confirmed")
	_check(int(OtaStore.load_state(root)["known_good"]) == 2, "update 2 is now known-good")


func _test_boot_failures() -> void:
	var saves: String = _new_root("saves_fail")
	# Corrupt payload.
	var root: String = _new_root("fail_payload")
	_make_slot(root, 1)
	_flip_byte(OtaStore.slot_dir(root, 1).path_join("payload.pck"), 100)
	_stage(root, 1)
	var r: Dictionary = _boot(root, saves)
	_check(int(r["active_seq"]) == 0 and _mounted.is_empty(), "corrupt payload is never mounted")
	_check(int(r["rolled_back_seq"]) == 1 and "hash" in str(r["rolled_back_reason"]), "corrupt payload reported: %s" % r["rolled_back_reason"])
	_check(DirAccess.dir_exists_absolute(root.path_join("quarantine")) and not DirAccess.dir_exists_absolute(OtaStore.slot_dir(root, 1)), "corrupt slot is quarantined")
	_check((OtaStore.load_state(root)["failed"] as Array).has(1), "failed update is remembered")

	# Truncated payload (the engine's load_resource_pack would still return true for this).
	root = _new_root("fail_trunc")
	_make_slot(root, 1)
	var p: String = OtaStore.slot_dir(root, 1).path_join("payload.pck")
	var b: PackedByteArray = FileAccess.get_file_as_bytes(p).slice(0, 1000)
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_buffer(b)
	f.close()
	_stage(root, 1)
	r = _boot(root, saves)
	_check(int(r["active_seq"]) == 0 and "size" in str(r["rolled_back_reason"]), "truncated payload rejected by size: %s" % r["rolled_back_reason"])

	# Tampered manifest, bad signature, wrong key.
	root = _new_root("fail_manifest")
	_make_slot(root, 1)
	_flip_byte(OtaStore.slot_dir(root, 1).path_join("manifest.json"), 20)
	_stage(root, 1)
	r = _boot(root, saves)
	_check(int(r["active_seq"]) == 0 and "signature" in str(r["rolled_back_reason"]), "tampered manifest rejected: %s" % r["rolled_back_reason"])
	root = _new_root("fail_wrongkey")
	_make_slot(root, 1, Callable(), _other_key)
	_stage(root, 1)
	r = _boot(root, saves)
	_check(int(r["active_seq"]) == 0 and "signature" in str(r["rolled_back_reason"]), "update signed by another key rejected")

	# Missing pieces.
	root = _new_root("fail_missing")
	_make_slot(root, 1)
	DirAccess.remove_absolute(OtaStore.slot_dir(root, 1).path_join("payload.pck"))
	_stage(root, 1)
	r = _boot(root, saves)
	_check(int(r["active_seq"]) == 0, "missing payload -> native build")
	root = _new_root("fail_nosig")
	_make_slot(root, 1)
	DirAccess.remove_absolute(OtaStore.slot_dir(root, 1).path_join("manifest.sig"))
	_stage(root, 1)
	r = _boot(root, saves)
	_check(int(r["active_seq"]) == 0, "missing signature -> native build")

	# Built for another native build (a new APK was installed): obsolete, deleted not quarantined, game unaffected.
	root = _new_root("fail_base")
	_make_slot(root, 1, func(m): m["base_commit"] = "d".repeat(40))
	_stage(root, 1)
	r = _boot(root, saves)
	_check(int(r["active_seq"]) == 0 and _mounted.is_empty(), "update for a different native build is not applied")
	_check(not DirAccess.dir_exists_absolute(OtaStore.slot_dir(root, 1)) and not DirAccess.dir_exists_absolute(root.path_join("quarantine")),
			"obsolete update is deleted (not kept as a failure)")

	# Engine mismatch, native version mismatch.
	root = _new_root("fail_engine")
	_make_slot(root, 1, func(m): m["engine"] = "4.7.stable.official.abcdef123")
	_stage(root, 1)
	_check(int(_boot(root, saves)["active_seq"]) == 0, "update for another engine build is not applied")

	# The engine refuses the pack: quarantine and run native.
	root = _new_root("fail_mount")
	_make_slot(root, 1)
	_stage(root, 1)
	_mount_ok = false
	r = _boot(root, saves)
	_mount_ok = true
	_check(int(r["active_seq"]) == 0 and str(r["rolled_back_reason"]) == "mount failed", "a pack the engine refuses falls back to the native build")
	_check(int(OtaStore.load_state(root)["boot_attempts"]) == 0, "no attempts are left pending after a refused mount")

	# Corrupt state.json: reset, game starts.
	root = _new_root("fail_state")
	var sf := FileAccess.open(root.path_join("state.json"), FileAccess.WRITE)
	sf.store_string("{ this is not json")
	sf.close()
	r = _boot(root, saves)
	_check(int(r["active_seq"]) == 0, "corrupt state.json does not stop the game")
	_check(typeof(OtaStore.load_state(root)["failed"]) == TYPE_ARRAY, "state is rebuilt with defaults")

	# Failed numbers are never retried even if the slot reappears.
	root = _new_root("fail_retry")
	_make_slot(root, 1)
	_flip_byte(OtaStore.slot_dir(root, 1).path_join("payload.pck"), 5)
	_stage(root, 1)
	_boot(root, saves)
	_make_slot(root, 1)   # a "fixed" copy with the same number
	_stage(root, 1)
	r = _boot(root, saves)
	_check(int(r["active_seq"]) == 0, "a number that failed is never tried again")


func _test_crash_loop_and_rollback() -> void:
	var saves: String = _new_root("saves_crash")
	var root: String = _new_root("crash")
	# Update 1 healthy and confirmed.
	_make_slot(root, 1)
	_stage(root, 1)
	var r: Dictionary = _boot(root, saves)
	OtaCore.apply_result(r)
	OtaCore.confirm_health(root)
	# Update 2 staged; launches crash before the healthy window.
	_make_slot(root, 2)
	_stage(root, 2)
	r = _boot(root, saves)
	_check(int(r["active_seq"]) == 2 and int(r["boot_attempts"]) == 1, "crash loop: launch 1 of update 2")
	r = _boot(root, saves)   # no confirm_health: the previous launch crashed
	_check(int(r["active_seq"]) == 2 and int(r["boot_attempts"]) == 2, "crash loop: launch 2 of update 2")
	r = _boot(root, saves)
	_check(int(r["active_seq"]) == 1, "crash loop: launch 3 rolls back to the last known-good update (1)")
	_check(int(r["rolled_back_seq"]) == 2 and "crash loop" in str(r["rolled_back_reason"]), "rollback reason is recorded: %s" % r["rolled_back_reason"])
	_check(int(OtaStore.load_state(root)["boot_attempts"]) == 0, "known-good update runs with attempts reset")
	r = _boot(root, saves)
	_check(int(r["active_seq"]) == 1 and int(r["rolled_back_seq"]) == 0, "rollback is sticky and quiet afterwards")

	# Same loop with no known-good update: falls back to the native build.
	root = _new_root("crash_native")
	_make_slot(root, 1)
	_stage(root, 1)
	_boot(root, saves)
	_boot(root, saves)
	r = _boot(root, saves)
	_check(int(r["active_seq"]) == 0 and _mounted.is_empty() and int(r["rolled_back_seq"]) == 1, "crash loop with no known-good update -> native build")

	# A launch that reaches the healthy window resets everything (no false rollback).
	root = _new_root("crash_ok")
	_make_slot(root, 1)
	_stage(root, 1)
	_boot(root, saves)
	r = _boot(root, saves)
	OtaCore.apply_result(r)
	OtaCore.confirm_health(root)
	for i in 4:
		r = _boot(root, saves)
		_check(int(r["active_seq"]) == 1, "healthy update survives launch %d" % i)


func _test_revocation_and_plan() -> void:
	var saves: String = _new_root("saves_rev")
	var root: String = _new_root("revoke")
	_make_slot(root, 1)
	_stage(root, 1)
	var r: Dictionary = _boot(root, saves)
	OtaCore.apply_result(r)
	OtaCore.confirm_health(root)
	# The channel withdraws update 1 (kill switch): next launch runs the native build.
	var st: Dictionary = OtaStore.load_state(root)
	st["revoked"] = [1]
	OtaStore.save_state(root, st)
	r = _boot(root, saves)
	_check(int(r["active_seq"]) == 0 and _mounted.is_empty(), "revoked update is not mounted")
	_check("revoked" in str(r["rolled_back_reason"]), "revocation is reported")

	# plan(): picks the highest applicable update, ignores other builds, revoked and failed numbers, replays.
	var ch: Dictionary = {"format": 1, "product": "purgatory-dungeon", "generation": 7, "updates": [
		{"native_version": 5, "platform": "android", "base_commit": _ident["base_commit"], "seq": 1},
		{"native_version": 5, "platform": "android", "base_commit": _ident["base_commit"], "seq": 3},
		{"native_version": 5, "platform": "android", "base_commit": _ident["base_commit"], "seq": 2},
		{"native_version": 6, "platform": "android", "base_commit": _ident["base_commit"], "seq": 9},
		{"native_version": 5, "platform": "windows", "base_commit": _ident["base_commit"], "seq": 9},
		{"native_version": 5, "platform": "android", "base_commit": "e".repeat(40), "seq": 9}], "revoked": []}
	var s0: Dictionary = OtaStore.default_state()
	var plan: Dictionary = OtaCore.plan(ch, _ident, s0)
	_check(int(plan["entry"].get("seq", 0)) == 3, "plan picks the highest update for this exact build (ignores other builds/platforms)")
	var s1: Dictionary = OtaStore.default_state()
	s1["known_good"] = 3
	_check((OtaCore.plan(ch, _ident, s1)["entry"] as Dictionary).is_empty(), "plan: nothing newer than what we have")
	var s2: Dictionary = OtaStore.default_state()
	s2["failed"] = [3]
	_check(int(OtaCore.plan(ch, _ident, s2)["entry"].get("seq", 0)) == 2, "plan skips a failed update number")
	var ch2: Dictionary = ch.duplicate(true)
	ch2["revoked"] = [{"native_version": 5, "platform": "android", "base_commit": _ident["base_commit"], "seq": 3},
			{"native_version": 5, "platform": "android", "base_commit": "e".repeat(40), "seq": 2}]
	var p2: Dictionary = OtaCore.plan(ch2, _ident, s0)
	_check(int(p2["entry"].get("seq", 0)) == 2 and (p2["revoked"] as Array) == [3], "plan honours revocations for this build only")
	var s3: Dictionary = OtaStore.default_state()
	s3["generation"] = 8
	_check(OtaCore.plan(ch, _ident, s3).has("error"), "plan rejects a replayed (older generation) channel index")
	var bad: Dictionary = ch.duplicate()
	bad["format"] = 2
	_check(OtaCore.plan(bad, _ident, s0).has("error"), "plan rejects an unknown channel format")


func _test_save_preservation() -> void:
	# The OTA client only ever READS the save folder (for a backup copy).
	var saves: String = _new_root("saves_real")
	DirAccess.make_dir_recursive_absolute(saves.path_join("saves"))
	for i in 3:
		var f := FileAccess.open(saves.path_join("saves").path_join("slot_%d.json" % i), FileAccess.WRITE)
		f.store_string(JSON.stringify({"name": "Hero%d" % i, "meta_currency": 7 * i}))
		f.close()
	var sf := FileAccess.open(saves.path_join("settings.json"), FileAccess.WRITE)
	sf.store_string("{\"volume\": 0.5}")
	sf.close()
	var before: String = _hash_tree(saves)
	var root: String = _new_root("save_flow")
	_make_slot(root, 1)
	_stage(root, 1)
	var r: Dictionary = _boot(root, saves)
	_check(_hash_tree(saves) == before, "activating an update leaves saves and settings byte-identical")
	var backups: Array = DirAccess.get_directories_at(root.path_join("backups"))
	_check(backups.size() == 1, "a backup of the saves is made before the first activation")
	if backups.size() == 1:
		_check(_hash_tree(root.path_join("backups").path_join(backups[0])) == before, "the backup equals the saves it was taken from")
	# Crash loop + rollback + quarantine never touch saves either.
	OtaCore.apply_result(r)
	OtaCore.confirm_health(root)
	_make_slot(root, 2)
	_stage(root, 2)
	_boot(root, saves)
	_boot(root, saves)
	_boot(root, saves)
	_check(_hash_tree(saves) == before, "crash-loop rollback leaves saves byte-identical")
	var st: Dictionary = OtaStore.load_state(root)
	st["revoked"] = [1]
	OtaStore.save_state(root, st)
	_boot(root, saves)
	_check(_hash_tree(saves) == before, "revocation leaves saves byte-identical")
	# Backups are bounded.
	for seq in range(10, 16):
		_make_slot(root, seq)
		_stage(root, seq)
		_boot(root, saves)
	_check(DirAccess.get_directories_at(root.path_join("backups")).size() <= OtaConst.KEEP_BACKUPS, "backups are capped at %d" % OtaConst.KEEP_BACKUPS)
	_check(DirAccess.get_directories_at(root.path_join("quarantine")).size() <= OtaConst.KEEP_QUARANTINE, "quarantine is capped")
	_check(_hash_tree(saves) == before, "saves still byte-identical after many updates")
	# Nothing was written outside the OTA root next to the saves.
	_check(not FileAccess.file_exists(saves.path_join("state.json")), "no OTA files are written into the save folder")


func _test_diagnostics() -> void:
	OtaRuntime.reset()
	_check(OtaIdentity.footer_suffix() == "", "plain native build: no footer suffix")
	OtaRuntime.enabled = true
	OtaRuntime.active_seq = 2
	OtaRuntime.confirmed = true
	_check(OtaIdentity.footer_suffix() == " · update 2", "footer shows the running update")
	OtaRuntime.pending_seq = 3
	_check("restart to apply" in OtaIdentity.footer_suffix() and "update 3" in OtaIdentity.footer_suffix(), "footer shows a downloaded update")
	OtaRuntime.pending_seq = 0
	OtaRuntime.active_seq = 0
	OtaRuntime.rolled_back_seq = 2
	OtaRuntime.rolled_back_reason = "crash loop"
	_check("update 2 rolled back" in OtaIdentity.footer_suffix(), "footer shows a rollback")
	var lines: String = "\n".join(OtaIdentity.diagnostic_lines())
	for want in ["Native build: v", "Native base commit:", "OTA: API 1", "OTA rolled back: update 2 (crash loop)", "OTA update: none"]:
		_check(want in lines, "diagnostics contain '%s'" % want)
	var vi: Dictionary = Engine.get_version_info()
	var want_engine: String = "%d.%d.%s.%s.%s" % [int(vi["major"]), int(vi["minor"]), str(vi["status"]), str(vi["build"]), str(vi["hash"]).left(9)]
	_check(OtaIdentity.engine_string() == want_engine, "engine string has the 'godot --version' shape (%s)" % OtaIdentity.engine_string())
	_check(OtaIdentity.off_reason({"platform": "", "base_commit": "x"}, "pem") != "", "unsupported platform disables OTA")
	_check(OtaIdentity.off_reason({"platform": "android", "base_commit": ""}, "pem") == "not a CI build", "a non-CI build disables OTA")
	_check(OtaIdentity.off_reason({"platform": "android", "base_commit": "a".repeat(40)}, "") == "no trust anchor in this build", "no trust anchor disables OTA")
	_check(OtaIdentity.off_reason({"platform": "android", "base_commit": "a".repeat(40)}, "pem") == "", "a CI build with a trust anchor enables OTA")
	OtaRuntime.reset()
