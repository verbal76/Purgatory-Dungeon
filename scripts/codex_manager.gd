# ==============================================================================
#  FILE:        codex_manager.gd
#  PATH:        res://scripts/codex_manager.gd
#  AUTOLOAD:    CodexManager   (add after SettingsManager in Project → Autoloads)
#
#  DEPENDENCIES: None — builds its own OS path independently.
#
#  DESCRIPTION:
#    Global lore-codex manager for Purgetory Dungeon.
#    Tracks the total number of run-end events (death or day-30 finish)
#    across ALL characters on this machine and derives how many lore
#    entries to reveal in the Codex screen.
#
#    Lore source:
#      res://data/codex_lore.txt
#        • One lore entry per line.
#        • Lines beginning with # are comments — ignored.
#        • Blank lines are ignored.
#        • Add entries by appending new lines at the bottom.
#        • Editing existing lines updates all players immediately on
#          the next Codex Screen open — no migration required.
#
#    Global save file:
#      Documents/PurgetoryDungeon/codex.json
#        {"total_completions": N}
#        • total_completions is a monotonic counter across all characters.
#        • It is NEVER decremented.
#        • To wipe codex progress on a machine: delete codex.json.
#
#    Unlocked entry count = min(total_completions, lore_file_line_count)
#    This means adding new lines to the lore file is all that is needed
#    to extend the codex. The existing completion count correctly
#    determines how many new entries become visible.
#
#  ADJUSTABLE SETTINGS:
#    LORE_FILE_PATH  — path to lore text file inside the project
#    GAME_FOLDER     — parent folder in Documents (must match SaveManager)
#    CODEX_FILE_NAME — filename for the global counter JSON
#
#  MOD NOTES:
#    • To add lore: append lines to codex_lore.txt and redistribute.
#    • To change existing lore: edit the lines freely. Players see the
#      new text for already-unlocked slots on next Codex Screen open.
#    • increment_completions() is called by you_died_screen.gd (_ready)
#      and should be called by any future day-30 completion screen too.
#    • get_unlocked_entries() reloads the lore file on every call so
#      live edits during a session are always reflected.
# ==============================================================================
extends Node

# ── Configurable paths ─────────────────────────────────────────────────────────
const LORE_FILE_PATH  : String = "res://data/codex_lore.txt"
const GAME_FOLDER     : String = StoragePaths.GAME_FOLDER   # Must match SaveManager
const CODEX_FILE_NAME : String = "codex.json"

# ── Runtime state ──────────────────────────────────────────────────────────────
# Lore lines loaded from the file. Rebuilt whenever get_unlocked_entries() is
# called so edits to codex_lore.txt take effect without restarting the game.
var _lore_lines        : Array[String] = []

# Total run-end events (death or day-30 finish) across ALL characters.
var _total_completions : int = 0

# Absolute path to codex.json — built once in _ready().
var _codex_path : String = ""


# ══════════════════════════════════════════════════════════════════════════════
#  BOOT
# ══════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	_build_path()
	_load_codex_data()
	_load_lore_file()


# Resolves Documents/PurgetoryDungeon/codex.json and creates the directory
# if it does not yet exist.
func _build_path() -> void:
	var game_dir : String = StoragePaths.ensure_root()
	_codex_path = game_dir.path_join(CODEX_FILE_NAME)


# ══════════════════════════════════════════════════════════════════════════════
#  LORE FILE
# ══════════════════════════════════════════════════════════════════════════════

# Reads codex_lore.txt and populates _lore_lines.
# Empty lines and lines starting with # are skipped.
# Safe to call multiple times — clears and rebuilds from scratch each time.
func _load_lore_file() -> void:
	_lore_lines.clear()

	if not FileAccess.file_exists(LORE_FILE_PATH):
		push_warning("CodexManager: lore file not found at " + LORE_FILE_PATH)
		return

	var file := FileAccess.open(LORE_FILE_PATH, FileAccess.READ)
	if file == null:
		push_warning("CodexManager: could not open lore file.")
		return

	while not file.eof_reached():
		var line : String = file.get_line().strip_edges()
		# Skip blank lines and comment lines.
		if line == "" or line.begins_with("#"):
			continue
		_lore_lines.append(line)

	file.close()


# ══════════════════════════════════════════════════════════════════════════════
#  PERSISTENCE
# ══════════════════════════════════════════════════════════════════════════════

# Reads _total_completions from codex.json.
# If the file does not exist, completions start at zero (correct for a fresh install).
func _load_codex_data() -> void:
	_total_completions = 0

	if not FileAccess.file_exists(_codex_path):
		return   # First ever launch — no file yet, start at zero.

	var file := FileAccess.open(_codex_path, FileAccess.READ)
	if file == null:
		push_warning("CodexManager: could not read codex.json")
		return

	var parsed = JSON.parse_string(file.get_as_text())
	file.close()

	if parsed is Dictionary:
		_total_completions = int(parsed.get("total_completions", 0))


# Writes _total_completions to codex.json.
func _save_codex_data() -> void:
	var file := FileAccess.open(_codex_path, FileAccess.WRITE)
	if file == null:
		push_warning("CodexManager: could not write codex.json — progress not saved.")
		return
	file.store_string(JSON.stringify({"total_completions": _total_completions}))
	file.close()


# ══════════════════════════════════════════════════════════════════════════════
#  PUBLIC API
# ══════════════════════════════════════════════════════════════════════════════

# Call once at the end of every run — death screen or day-30 finish screen.
# Increments the global completion counter and persists it immediately.
# Safe to call multiple times per session if needed (e.g. quick-restart);
# each call adds exactly one more unlocked entry.
func increment_completions() -> void:
	_total_completions += 1
	_save_codex_data()


# Returns the lore lines that have been unlocked so far.
# Re-reads the lore file before returning so any edits to codex_lore.txt
# (e.g. a mod update or in-development content addition) take effect
# immediately on the next Codex Screen open.
#
# unlocked_count = min(total_completions, lore_file_line_count)
# This automatically handles lore file updates:
#   • More lines added  → new runs unlock new entries.
#   • Existing lines changed → already-unlocked slots show new text.
#   • Lines removed → unlocked count clamps to what the file now contains.
func get_unlocked_entries() -> Array[String]:
	_load_lore_file()   # Always fresh — handles live edits and mod updates.
	var count  : int           = mini(_total_completions, _lore_lines.size())
	var result : Array[String] = []
	for i in range(count):
		result.append(_lore_lines[i])
	return result


# Returns the total number of lore entries in the current file.
# Used by the Codex Screen to display the "X / Y revealed" progress line.
func get_total_lore_count() -> int:
	_load_lore_file()
	return _lore_lines.size()


# Returns the raw total_completions counter.
# The Codex Screen uses this for the progress display.
func get_total_completions() -> int:
	return _total_completions


# Returns true when every lore entry has been unlocked.
# Useful for showing a "Codex Complete" flourish or achievement trigger.
func is_codex_complete() -> bool:
	_load_lore_file()
	return (not _lore_lines.is_empty()) and (_total_completions >= _lore_lines.size())
