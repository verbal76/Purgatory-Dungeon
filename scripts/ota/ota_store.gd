# ==============================================================================
# File Name: ota_store.gd
# Path: res://scripts/ota/ota_store.gd
#
# Description:
#   On-device storage of the OTA client: state.json, update slots, staging, quarantine and save backups,
#   all under one root (user://ota/). It NEVER writes outside that root except to READ the save folder
#   when making a backup copy. Writes of state.json are atomic (temp file + rename).
# ==============================================================================
class_name OtaStore
extends RefCounted


## Absolute path of the OTA root. Tests may redirect it (non-template builds only).
static func root() -> String:
	if not OS.has_feature("template"):
		var o: String = OS.get_environment(OtaConst.ENV_ROOT)
		if o != "":
			return o
	return OS.get_user_data_dir().path_join("ota")


static func default_state() -> Dictionary:
	return {
		"v": 1,
		"active": 0,          # update number mounted (or being tried) at the last launch; 0 = native build
		"pending": 0,         # staged and verified, becomes active at the next launch
		"known_good": 0,      # last update that was confirmed healthy
		"boot_attempts": 0,   # launches of the current unconfirmed update
		"failed": [],         # update numbers that must never be tried again
		"revoked": [],        # update numbers the channel withdrew
		"generation": 0,      # highest channel.json generation seen (replay protection)
		"last_check_utc": 0,  # unix seconds of the last channel check
		"last_error": "",
		"history": [],        # short event strings, newest last (capped)
	}


static func load_state(root_dir: String) -> Dictionary:
	var st: Dictionary = default_state()
	var path: String = root_dir.path_join("state.json")
	if not FileAccess.file_exists(path):
		return st
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		st["last_error"] = "state.json was unreadable and was reset"
		return st
	for k in st.keys():
		if (parsed as Dictionary).has(k):
			var v: Variant = (parsed as Dictionary)[k]
			if typeof(v) == typeof(st[k]) or (typeof(st[k]) == TYPE_INT and typeof(v) == TYPE_FLOAT):
				st[k] = v
	for k in ["active", "pending", "known_good", "boot_attempts", "generation", "last_check_utc"]:
		st[k] = int(st[k])
	for k in ["failed", "revoked"]:
		var ints: Array = []
		for x in st[k]:
			ints.append(int(x))
		st[k] = ints
	return st


static func save_state(root_dir: String, st: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(root_dir)
	var h: Array = st.get("history", [])
	if h.size() > 30:
		st["history"] = h.slice(h.size() - 30)
	return write_text_atomic(root_dir.path_join("state.json"), JSON.stringify(st, "  ") + "\n")


static func note(st: Dictionary, text: String) -> void:
	var h: Array = st.get("history", [])
	h.append("%s %s" % [Time.get_datetime_string_from_system(true), text])
	st["history"] = h


static func write_text_atomic(path: String, text: String) -> bool:
	var tmp: String = path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	return DirAccess.rename_absolute(tmp, path) == OK


static func slot_dir(root_dir: String, seq: int) -> String:
	return root_dir.path_join("slots").path_join(str(seq))


static func staging_dir(root_dir: String) -> String:
	return root_dir.path_join("staging")


static func read_bytes(path: String) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(path)


## Recursively deletes a directory (no-op if absent). Only ever called with paths under the OTA root.
static func remove_tree(dir_path: String) -> void:
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	for f in DirAccess.get_files_at(dir_path):
		DirAccess.remove_absolute(dir_path.path_join(f))
	for d in DirAccess.get_directories_at(dir_path):
		remove_tree(dir_path.path_join(d))
	DirAccess.remove_absolute(dir_path)


static func copy_tree(src: String, dst: String) -> bool:
	if not DirAccess.dir_exists_absolute(src):
		return true
	DirAccess.make_dir_recursive_absolute(dst)
	var ok: bool = true
	for f in DirAccess.get_files_at(src):
		var data: PackedByteArray = FileAccess.get_file_as_bytes(src.path_join(f))
		var out := FileAccess.open(dst.path_join(f), FileAccess.WRITE)
		if out == null:
			ok = false
			continue
		out.store_buffer(data)
		out.close()
	for d in DirAccess.get_directories_at(src):
		ok = copy_tree(src.path_join(d), dst.path_join(d)) and ok
	return ok


static func clean_staging(root_dir: String) -> void:
	remove_tree(staging_dir(root_dir))


## Moves a slot out of the way (kept for diagnosis, newest KEEP_QUARANTINE only).
static func quarantine(root_dir: String, seq: int, reason: String) -> void:
	var src: String = slot_dir(root_dir, seq)
	if not DirAccess.dir_exists_absolute(src):
		return
	var q: String = root_dir.path_join("quarantine")
	DirAccess.make_dir_recursive_absolute(q)
	var safe: String = ""
	for i in mini(reason.length(), 40):
		var c: String = reason[i]
		safe += c if (c.to_lower() != c.to_upper() or c.is_valid_int()) else "-"
	var dst: String = q.path_join("%d-%s-%d" % [seq, safe, int(Time.get_unix_time_from_system())])
	if DirAccess.rename_absolute(src, dst) != OK:
		remove_tree(src)
	_prune_dir(q, OtaConst.KEEP_QUARANTINE)


## Deletes every slot except the listed update numbers.
static func prune_slots(root_dir: String, keep: Array) -> void:
	var slots: String = root_dir.path_join("slots")
	if not DirAccess.dir_exists_absolute(slots):
		return
	for d in DirAccess.get_directories_at(slots):
		if not keep.has(int(d)):
			remove_tree(slots.path_join(d))


## Copies the save folder (saves + settings) into backups/ before an update is activated for the first time.
## READS save_root, writes only under the OTA root. Returns the backup directory ("" if nothing to back up).
static func backup_saves(root_dir: String, seq: int, save_root: String) -> String:
	if save_root == "" or not DirAccess.dir_exists_absolute(save_root):
		return ""
	var b: String = root_dir.path_join("backups")
	var dst: String = b.path_join("update-%d-%d" % [seq, int(Time.get_unix_time_from_system())])
	if not copy_tree(save_root, dst):
		return ""
	_prune_dir(b, OtaConst.KEEP_BACKUPS)
	return dst


## Keeps the newest `keep` sub-directories (by name's trailing timestamp / mtime) of a folder.
static func _prune_dir(dir_path: String, keep: int) -> void:
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	var dirs: Array = []
	for d in DirAccess.get_directories_at(dir_path):
		dirs.append({"name": d, "t": FileAccess.get_modified_time(dir_path.path_join(d))})
	dirs.sort_custom(func(a, b): return a["t"] > b["t"] or (a["t"] == b["t"] and String(a["name"]) > String(b["name"])))
	for i in range(keep, dirs.size()):
		remove_tree(dir_path.path_join(dirs[i]["name"]))
