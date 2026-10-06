extends SceneTree
## Independent inspection of a built or published OTA with the SAME verification code the phone runs
## (scripts/boot/ota_core.gd: OtaCore.check_manifest + OtaCore.verify_package), plus checks the client cannot make:
## the manifest's files[] against the pack's own directory, protected / escaping paths against ota/boundary.json, and
## game_version / save schema against the source tree this workflow runs from. Docs: docs/OTA.md sections 4, 5, 11.
##
## Usage (user args after `--`, all key=value):
##   godot --headless --path . -s tools/ota_inspect_pack.gd -- manifest=manifest.json sig=manifest.json.sig pck=payload.pck \
##       build_info=<shipped baseline build_info.json> [files=files.json] [pubkey=<PEM file>] [platform=android] \
##       [expect_source_sha=<40-hex>] [boundary=res://ota/boundary.json] [version_file=res://VERSION]
## Device identity (what the installed app would hold): from build_info= (commit, runtime_id, runtime_fingerprint,
## ota_channel, public_version) or runtime_id= runtime_fingerprint= base_sha= channel= native_version=;
## self_identity=1 instead takes it from the manifest itself (offline smoke test only, proves consistency not compatibility).
## The public key is the one baked into scripts/boot/ota_config.gd (PUBLIC_KEY_PEM) unless pubkey= overrides it.
## Prints `INSPECT <key=value ...>` then one `INSPECT FAIL <reason>` per problem and finally `INSPECT OK` (exit 0)
## or `INSPECT FAILED` (exit 1).

const CoreScript := preload("res://scripts/boot/ota_core.gd")


func _init() -> void:
	var fails: Array[String] = _run()
	for f in fails:
		print("INSPECT FAIL ", f)
	print("INSPECT ", "OK" if fails.is_empty() else "FAILED")
	quit(0 if fails.is_empty() else 1)


func _args() -> Dictionary:
	var a := {}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			a[kv[0]] = kv[1]
	return a


func _glob_to_regex(pattern: String) -> RegEx:
	var out := "^"
	var i := 0
	while i < pattern.length():
		var c := pattern[i]
		if pattern.substr(i, 2) == "**":
			out += ".*"
			i += 2
			continue
		if c == "*":
			out += "[^/]*"
		elif c == "?":
			out += "[^/]"
		elif c in ".^$+(){}|[]\\":
			out += "\\" + c
		else:
			out += c
		i += 1
	var r := RegEx.new()
	r.compile(out + "$")
	return r


func _names(rules: Dictionary, path: String) -> Array[String]:
	var names: Array[String] = [path]
	var al: Dictionary = rules.get("pack_aliases", {})
	for suf in al.get("strip_suffixes", []):
		if path.ends_with(suf) and path.length() > suf.length():
			names.append(path.left(path.length() - suf.length()))
	var ms: Dictionary = al.get("map_suffixes", {})
	for suf in ms:
		if path.ends_with(suf) and path.length() > suf.length():
			names.append(path.left(path.length() - suf.length()) + str(ms[suf]))
	return names


func _section_match(sec: Dictionary, p: String) -> String:
	if p in sec.get("exact", []):
		return "exact " + p
	for x in sec.get("prefixes", []):
		if p.begins_with(x):
			return "prefix " + x
	for x in sec.get("suffixes", []):
		if p.ends_with(x):
			return "suffix " + x
	return ""


## "" when the pack path is fine, else why it must not be in an OTA payload.
func _violation(rules: Dictionary, path: String) -> String:
	if path == "" or path.begins_with("/") or ":" in path or "\\" in path:
		return "illegal path"
	for seg in path.split("/"):
		if seg in ["", ".", ".."]:
			return "path escapes res:// (empty, '.' or '..' segment)"
	for n in _names(rules, path):
		var why := _section_match(rules.get("payload_protected", {}), n)
		if why != "":
			return "protected (%s)" % why
	for n in _names(rules, path):
		for pat in rules.get("native_inputs", []):
			if _glob_to_regex(pat).search(n) != null:
				return "native input (%s)" % pat
	return ""


## The pack's OWN directory, read without the engine: {path: removal(bool)}; "" error text in key "__error__".
func _pck_directory(path: String) -> Dictionary:
	var out := {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"__error__": "cannot open the pack"}
	if f.get_length() < 112 or f.get_buffer(4).get_string_from_ascii() != "GDPC":
		return {"__error__": "not a PCK (bad magic)"}
	var fmt := f.get_32()
	if fmt != 3:
		return {"__error__": "unsupported PCK format %d" % fmt}
	f.get_32(); f.get_32(); f.get_32()   # engine major, minor, patch
	var flags := f.get_32()
	f.get_64()                           # file_base
	var dir_off := f.get_64()
	if flags & 1:
		return {"__error__": "encrypted pack directory"}
	if dir_off < 112 or dir_off + 4 > f.get_length():
		return {"__error__": "directory offset outside the file"}
	f.seek(dir_off)
	var count := f.get_32()
	if count > 5000000:
		return {"__error__": "implausible file count"}
	for i in count:
		var plen := f.get_32()
		var raw := f.get_buffer(plen)
		var name := raw.get_string_from_utf8()
		if name.begins_with("res://"):
			name = name.substr(6)
		f.get_64(); f.get_64(); f.get_buffer(16)
		var fflags := f.get_32()
		if out.has(name):
			return {"__error__": "duplicate path %s" % name}
		out[name] = (fflags & 2) != 0
	return out


func _run() -> Array[String]:
	var fails: Array[String] = []
	var a := _args()
	for need in ["manifest", "sig", "pck"]:
		if not a.has(need):
			fails.append("missing argument %s=" % need)
	if not fails.is_empty():
		return fails
	var cfg: Script = load("res://scripts/boot/ota_config.gd")
	if cfg == null:
		return ["res://scripts/boot/ota_config.gd cannot be loaded"]
	var consts: Dictionary = cfg.get_script_constant_map()
	var platform: String = a.get("platform", "android")
	var manifest_bytes: PackedByteArray = FileAccess.get_file_as_bytes(a["manifest"])
	var sig_text: String = FileAccess.get_file_as_string(a["sig"])
	if manifest_bytes.is_empty():
		return ["manifest %s is missing or empty" % a["manifest"]]
	var parsed: Variant = JSON.parse_string(manifest_bytes.get_string_from_utf8())
	var claimed: Dictionary = parsed if parsed is Dictionary else {}

	# --- the identity of the installed device the update must fit
	var bi: Dictionary = {}
	if a.has("build_info"):
		var bj: Variant = JSON.parse_string(FileAccess.get_file_as_string(a["build_info"]))
		if not (bj is Dictionary):
			return ["build_info=%s is missing or not a JSON object" % a["build_info"]]
		bi = bj
	var runtime_id: String = a.get("runtime_id", str(bi.get("runtime_id", "")))
	var fingerprint: String = a.get("runtime_fingerprint", str(bi.get("runtime_fingerprint", "")))
	var base_sha: String = a.get("base_sha", str(bi.get("commit", "")))
	var channel: String = a.get("channel", str(bi.get("ota_channel", consts.get("CHANNEL", ""))))
	var native_version: String = a.get("native_version", str(bi.get("public_version", "")))
	if a.get("self_identity", "") == "1":
		runtime_id = str(claimed.get("runtime_id", ""))
		fingerprint = str(claimed.get("runtime_fingerprint", ""))
		base_sha = str(claimed.get("base_source_sha", ""))
		channel = str(claimed.get("channel", ""))
		native_version = str(claimed.get("native_version", ""))
	for pair in [["runtime_id", runtime_id], ["runtime_fingerprint", fingerprint], ["base_sha", base_sha], ["channel", channel]]:
		if pair[1] == "":
			fails.append("device identity unknown (%s): pass build_info=<shipped baseline build_info.json> or self_identity=1" % pair[0])
	if not fails.is_empty():
		return fails

	# --- the client's own verification
	var pem: String = str(consts.get("PUBLIC_KEY_PEM", ""))
	if a.has("pubkey"):
		pem = FileAccess.get_file_as_string(a["pubkey"])
	if pem.strip_edges() == "":
		return ["no public key: ota_config.gd PUBLIC_KEY_PEM is empty and pubkey= was not given"]
	var tmp := OS.get_user_data_dir().path_join("ota_inspect")
	DirAccess.make_dir_recursive_absolute(tmp)
	var core = CoreScript.new(tmp, runtime_id, channel, pem, int(consts.get("BOOTSTRAP_VERSION", 1)), fingerprint, base_sha)
	var res: Array = core.check_manifest(manifest_bytes, sig_text)
	var m: Dictionary = res[0]
	if str(res[1]) != "":
		fails.append("client check_manifest: " + str(res[1]))
	if not m.is_empty():
		var why: String = core.verify_package(m, a["pck"])
		if why != "":
			fails.append("client verify_package: " + why)
	if m.is_empty():
		m = claimed   # keep going on the claimed content so the report lists every problem

	# --- the manifest against the pack's own directory
	var dir: Dictionary = _pck_directory(a["pck"])
	var rules: Dictionary = {}
	var bpath: String = a.get("boundary", "res://ota/boundary.json")
	var bj2: Variant = JSON.parse_string(FileAccess.get_file_as_string(bpath)) if FileAccess.file_exists(bpath) else null
	if bj2 is Dictionary:
		rules = bj2
	else:
		fails.append("boundary %s cannot be read: protected paths were NOT checked" % bpath)
	if dir.has("__error__"):
		fails.append("pack directory: " + str(dir["__error__"]))
	else:
		var listed := {}
		for e in m.get("files", []):
			if not (e is Dictionary):
				fails.append("files[] entry is not an object")
				continue
			var p: String = str(e.get("path", ""))
			var op: String = str(e.get("op", ""))
			if listed.has(p):
				fails.append("files[] lists %s twice" % p)
			listed[p] = op
			if not dir.has(p):
				fails.append("files[] lists %s which the pack does not contain" % p)
			elif (op == "remove") != bool(dir[p]):
				fails.append("files[] says %s for %s but the pack entry %s a removal marker" % [op, p, "is" if dir[p] else "is not"])
		for p in dir:
			if not listed.has(p):
				fails.append("the pack contains %s which files[] does not list" % p)
			if not rules.is_empty():
				var v := _violation(rules, p)
				if v != "":
					fails.append("pack path %s: %s" % [p, v])
		if dir.is_empty():
			fails.append("the pack is empty")
	if a.has("files"):
		var fj: Variant = JSON.parse_string(FileAccess.get_file_as_string(a["files"]))
		if not (fj is Array):
			fails.append("files=%s is not a JSON array" % a["files"])
		else:
			var want := {}
			for e in fj:
				want[str(e["path"])] = str(e["op"])
			var have := {}
			for e in m.get("files", []):
				if e is Dictionary:
					have[str(e.get("path", ""))] = str(e.get("op", ""))
			if want != have:
				fails.append("manifest files[] differs from files.json built from the independent PCK parser")

	# --- game_version / identity against the source tree
	var seq: int = int(m.get("seq", 0))
	var nv: int = int(m.get("native_version", 0))
	if str(m.get("game_version", "")) != "%d.%d.0" % [nv, seq]:
		fails.append("game_version %s is not <native_version>.<seq>.0 (%d.%d.0)" % [m.get("game_version", ""), nv, seq])
	if str(m.get("ota_id", "")) != "%s-%06d" % [m.get("channel", ""), seq]:
		fails.append("ota_id %s does not match channel/seq" % m.get("ota_id", ""))
	if str(m.get("payload_kind", "")) != "patch":
		fails.append("payload_kind must be patch")
	if str(m.get("platform", "")) != platform:
		fails.append("manifest platform %s != %s" % [m.get("platform", ""), platform])
	if native_version != "" and str(nv) != native_version:
		fails.append("manifest native_version %d != the installed build's %s" % [nv, native_version])
	var vfile: String = a.get("version_file", "res://VERSION")
	if FileAccess.file_exists(vfile) and a.get("self_identity", "") != "1":
		var src_v: String = FileAccess.get_file_as_string(vfile).strip_edges()
		if str(nv) != src_v:
			fails.append("manifest native_version %d != VERSION %s of the source tree" % [nv, src_v])
	if a.has("expect_source_sha") and str(m.get("source_sha", "")) != a["expect_source_sha"]:
		fails.append("manifest source_sha %s != the expected %s" % [m.get("source_sha", ""), a["expect_source_sha"]])
	var ss: Script = load("res://scripts/save_schema.gd")
	if ss != null:
		var sc: Dictionary = ss.get_script_constant_map()
		if sc.has("SAVE_SCHEMA") and int(m.get("save_schema", -1)) != int(sc["SAVE_SCHEMA"]):
			fails.append("manifest save_schema %s != SAVE_SCHEMA %s in the source" % [m.get("save_schema", ""), sc["SAVE_SCHEMA"]])
		if sc.has("MIN_SAVE_SCHEMA") and int(m.get("min_save_schema", -1)) != int(sc["MIN_SAVE_SCHEMA"]):
			fails.append("manifest min_save_schema %s != MIN_SAVE_SCHEMA %s in the source" % [m.get("min_save_schema", ""), sc["MIN_SAVE_SCHEMA"]])
	print("INSPECT ota_id=%s game=%s runtime=%s source=%s pck_sha256=%s pack_files=%d" % [m.get("ota_id", "?"), m.get("game_version", "?"),
			m.get("runtime_id", "?"), str(m.get("source_sha", "?")).left(12), str(m.get("pck_sha256", "?")).left(16), dir.size() if not dir.has("__error__") else -1])
	return fails
