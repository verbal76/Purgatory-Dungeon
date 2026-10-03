# ==============================================================================
# File Name: storage_paths.gd
# Path: res://scripts/storage_paths.gd
#
# Description:
#   Single place that decides where persistent game data lives, shared by
#   SaveManager, SettingsManager and CodexManager.
#
#   Desktop (Windows/macOS/Linux): <Documents>/PurgetoryDungeon/
#     The misspelled "PurgetoryDungeon" folder name is an established
#     compatibility path for existing player saves. Do not rename it without
#     a migration.
#
#   Fallbacks (keep data off the working directory and usable on platforms
#   that have no Documents folder, e.g. Android or minimal Linux):
#     1. PURGATORY_SAVE_ROOT environment variable (used by automated tests)
#     2. OS Documents folder
#     3. OS.get_user_data_dir()
# ==============================================================================
class_name StoragePaths
extends RefCounted

const GAME_FOLDER := "PurgetoryDungeon"
const ENV_OVERRIDE := "PURGATORY_SAVE_ROOT"


## Absolute path of the game data folder (not guaranteed to exist yet).
static func root() -> String:
	var override_root: String = OS.get_environment(ENV_OVERRIDE)
	if override_root != "":
		return override_root
	var docs: String = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs == "":
		docs = OS.get_user_data_dir()
	return docs.path_join(GAME_FOLDER)


## root() with the directory created if needed.
static func ensure_root() -> String:
	var r := root()
	if not DirAccess.dir_exists_absolute(r):
		DirAccess.make_dir_recursive_absolute(r)
	return r


## Writes text to path via a temp file + rename so a crash mid-write cannot
## leave a truncated file behind. Returns true on success.
static func write_text_atomic(path: String, text: String) -> bool:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	if DirAccess.rename_absolute(tmp, path) != OK:
		# Some filesystems refuse to rename over an existing file.
		DirAccess.remove_absolute(path)
		if DirAccess.rename_absolute(tmp, path) != OK:
			DirAccess.remove_absolute(tmp)
			return false
	return true
