extends SceneTree
## Builds the OTA manifest (docs/OTA.md section 5, schema 1) for a patch pack. Deterministic: same inputs and the same
## created_at produce the same bytes (sorted keys, 2-space indent, trailing newline). Signing is a separate step.
##
## Usage (user args after `--`, all key=value):
##   godot --headless --path . -s tools/ota_make_manifest.gd -- pck=payload.pck out=manifest.json seq=3 \
##       sha=<40-hex source commit> url=<https pck url> files=files.json build_info=<baseline build_info.json> \
##       [base_sha=<40-hex native baseline commit>] [channel=dev] [platform=android] [native_version=7] \
##       [runtime_id=...] [runtime_fingerprint=<64-hex>] [save_schema=1] [min_save_schema=1] [created_at=<UTC>] \
##       [run_id=.. run_number=.. run_attempt=.. run_url=..]
## The native identity (runtime_id, runtime_fingerprint, base_sha = `commit`, native_version = `public_version`,
## channel = `ota_channel`) comes from the SHIPPED baseline's build_info.json (`build_info=`); explicit arguments
## override it but a conflicting value is refused. The tree's own scripts/boot/ota_config.gd must agree with it
## (same runtime id, channel). SAVE_SCHEMA / MIN_SAVE_SCHEMA come from res://scripts/save_schema.gd (game layer).
## Prints `MANIFEST OK ...` and exits 0, or `MANIFEST FAIL <reason>` and exits 1.

const CoreScript := preload("res://scripts/boot/ota_core.gd")
const HEX40 := "^[0-9a-f]{40}$"
const HEX64 := "^[0-9a-f]{64}$"


func _re(pattern: String, text: String) -> bool:
	var r := RegEx.new()
	r.compile(pattern)
	return r.search(text) != null


## JSON numbers arrive as floats: 6.0 must read back as "6".
func _s(v: Variant) -> String:
	if v is float and v == floorf(v):
		return str(int(v))
	return str(v)


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _init() -> void:
	var why: String = _run()
	if why != "":
		print("MANIFEST FAIL ", why)
		quit(1)
	else:
		quit(0)


## Returns "" on success (after printing MANIFEST OK) or the reason the manifest cannot be built.
func _run() -> String:
	var a := {}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			a[kv[0]] = kv[1]
	for need in ["pck", "out", "seq", "sha", "url", "files"]:
		if not a.has(need) or str(a[need]) == "":
			return ("missing argument %s=" % need)
	var cfg: Script = load("res://scripts/boot/ota_config.gd")
	if cfg == null:
		return ("res://scripts/boot/ota_config.gd cannot be loaded")
	var consts: Dictionary = cfg.get_script_constant_map()
	var platform: String = a.get("platform", "android")

	# --- native identity: the shipped baseline's build_info.json, overridable but never contradicted
	var bi: Dictionary = {}
	if a.has("build_info"):
		var parsed: Variant = _read_json(a["build_info"])
		if not (parsed is Dictionary):
			return ("build_info=%s is missing or not a JSON object" % a["build_info"])
		bi = parsed
	var ident := {}
	var sources := {"runtime_id": "runtime_id", "runtime_fingerprint": "runtime_fingerprint", "base_sha": "commit",
			"channel": "ota_channel", "native_version": "public_version"}
	for key in sources:
		var from_bi: String = _s(bi.get(sources[key], ""))
		var from_arg: String = str(a.get(key, ""))
		if from_bi != "" and from_arg != "" and from_bi != from_arg:
			return ("%s=%s contradicts the baseline's build_info.json (%s)" % [key, from_arg, from_bi])
		ident[key] = from_arg if from_arg != "" else from_bi
	if ident["channel"] == "":
		ident["channel"] = str(consts.get("CHANNEL", ""))
	for key in ["runtime_id", "runtime_fingerprint", "base_sha", "native_version", "channel"]:
		if ident[key] == "":
			return ("%s unknown: pass build_info=<shipped baseline build_info.json> or %s=" % [key, key])
	if str(ident["channel"]) != str(consts.get("CHANNEL", "")):
		return ("channel %s differs from CHANNEL %s in scripts/boot/ota_config.gd" % [ident["channel"], consts.get("CHANNEL", "")])
	if str(ident["runtime_id"]) != str(cfg.runtime_id(platform)):
		return ("baseline runtime_id %s differs from the one this tree computes (%s): different engine or RUNTIME_REVISION" % [ident["runtime_id"], cfg.runtime_id(platform)])

	# --- validation of the inputs
	if not _re(HEX64, ident["runtime_fingerprint"]):
		return ("runtime_fingerprint is not 64 lowercase hex characters")
	for k in ["sha", "base_sha"]:
		var v: String = a["sha"] if k == "sha" else ident["base_sha"]
		if not _re(HEX40, v):
			return ("%s is not a 40-hex commit id" % k)
	if not str(a["seq"]).is_valid_int() or int(a["seq"]) < 1:
		return ("seq must be a positive integer")
	if not str(ident["native_version"]).is_valid_int() or int(ident["native_version"]) < 1:
		return ("native_version must be a positive integer")
	if not str(a["url"]).begins_with("https://") and not str(a["url"]).begins_with("http://127.0.0.1"):
		return ("url must be https:// (http://127.0.0.1 is allowed for local tests only)")
	if not FileAccess.file_exists(a["pck"]):
		return ("pck=%s not found" % a["pck"])
	var files_in: Variant = _read_json(a["files"])
	if not (files_in is Array) or (files_in as Array).is_empty():
		return ("files=%s must be a non-empty JSON array of {path, op}" % a["files"])
	var files: Array = []
	var seen := {}
	for e in files_in:
		if not (e is Dictionary) or not (e as Dictionary).has("path") or not (e as Dictionary).has("op"):
			return ("every files[] entry needs path and op")
		var p: String = str(e["path"])
		var op: String = str(e["op"])
		if op not in ["add", "replace", "remove"]:
			return ("files[] entry %s has the unknown op %s" % [p, op])
		if p == "" or seen.has(p):
			return ("files[] has an empty or duplicate path: %s" % p)
		seen[p] = true
		files.append({"path": p, "op": op})
	files.sort_custom(func(x, y): return x["path"] < y["path"])

	var save_schema: int = int(a["save_schema"]) if a.has("save_schema") else -1
	var min_save_schema: int = int(a["min_save_schema"]) if a.has("min_save_schema") else -1
	if save_schema < 0 or min_save_schema < 0:
		var ss: Script = load("res://scripts/save_schema.gd")
		if ss == null:
			return ("res://scripts/save_schema.gd (SAVE_SCHEMA / MIN_SAVE_SCHEMA) not found and save_schema= not given")
		var sc: Dictionary = ss.get_script_constant_map()
		if not sc.has("SAVE_SCHEMA") or not sc.has("MIN_SAVE_SCHEMA"):
			return ("scripts/save_schema.gd must define SAVE_SCHEMA and MIN_SAVE_SCHEMA")
		if save_schema < 0:
			save_schema = int(sc["SAVE_SCHEMA"])
		if min_save_schema < 0:
			min_save_schema = int(sc["MIN_SAVE_SCHEMA"])
	if min_save_schema > save_schema:
		return ("min_save_schema %d is above save_schema %d" % [min_save_schema, save_schema])

	var seq: int = int(a["seq"])
	var native_version: int = int(ident["native_version"])
	var channel: String = ident["channel"]
	var f := FileAccess.open(a["pck"], FileAccess.READ)
	var size: int = f.get_length()
	f.close()
	var m := {
		"schema": 1,
		"channel": channel,
		"ota_id": "%s-%06d" % [channel, seq],
		"seq": seq,
		"source_sha": a["sha"],
		"runtime_id": ident["runtime_id"],
		"runtime_fingerprint": ident["runtime_fingerprint"],
		"minimum_bootstrap_version": int(consts.get("BOOTSTRAP_VERSION", 1)),
		"game_version": "%d.%d.0" % [native_version, seq],
		"save_schema": save_schema,
		"min_save_schema": min_save_schema,
		"pck_url": a["url"],
		"pck_sha256": CoreScript.file_sha256(a["pck"]),
		"pck_size": size,
		"created_at": a.get("created_at", Time.get_datetime_string_from_system(true) + "Z"),
		"build_run": {"id": a.get("run_id", ""), "number": a.get("run_number", ""),
				"attempt": a.get("run_attempt", ""), "url": a.get("run_url", "")},
		"payload_kind": "patch",
		"base_source_sha": ident["base_sha"],
		"platform": platform,
		"native_version": native_version,
		"files": files,
	}
	var out := FileAccess.open(a["out"], FileAccess.WRITE)
	if out == null:
		return ("cannot write out=%s" % a["out"])
	out.store_string(JSON.stringify(m, "  ", true) + "\n")
	out.close()
	print("MANIFEST OK id=%s game=%s sha256=%s size=%d files=%d runtime=%s" % [m["ota_id"], m["game_version"], m["pck_sha256"], size, files.size(), m["runtime_id"]])
	return ""
