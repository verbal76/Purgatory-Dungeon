# ==============================================================================
# File Name: save_manager.gd
# Path: res://scripts/save_manager.gd
# Autoload Name: SaveManager
#
# Dependencies: None (standalone autoload)
#
# Description:
#   Handles 10-slot profile persistence with identity locking.
#   A character's name and class are written once via create_initial_identity()
#   and can never be changed after that. All other progression data (perks,
#   potions, run count, death count, unlocks) accumulates on top of the
#   locked identity across runs.
#
# Adjustable Settings:
#   MAX_NAME_LENGTH  — maximum characters allowed in a character name
#   MAX_SEED_LENGTH  — maximum characters allowed in a seed string
#   SLOT_COUNT       — total number of save slots available
#
# Mod Notes:
#   - "initialized" flag added to profile schema. This flips to true only
#     when create_initial_identity() succeeds. It is the master lock.
#   - "character_class" added to profile schema. Persists across all runs.
#   - Three-tier slot checking replaces the old has_character() approach:
#       slot_has_file()            — does a file exist on disk?
#       slot_has_valid_character() — does the file contain a complete identity?
#       current_profile_is_valid() — is the loaded profile a complete identity?
#   - Old has_character() still works but now wraps current_profile_is_valid().
#   - get_slot_state() returns "empty", "valid", or "broken" for UI decisions.
# ==============================================================================
extends Node

signal profile_loaded

# ══════════════════════════════════════════════════════════════
#  CONSTANTS
# ══════════════════════════════════════════════════════════════

# Save files go into the player's Documents folder so they persist
# across reinstalls, are easy to back up, and appear in a sensible
# location on Windows. The same path resolves in the Godot editor
# (on your machine) and in exported builds on any player's PC.
#   Windows: C:/Users/<name>/Documents/PurgetoryDungeon/saves/
#   macOS:   ~/Documents/PurgetoryDungeon/saves/
#   Linux:   ~/Documents/PurgetoryDungeon/saves/
const GAME_FOLDER    := StoragePaths.GAME_FOLDER
const MAX_NAME_LENGTH := 20
const MAX_SEED_LENGTH := 20
const SLOT_COUNT := 10

const VALID_CLASSES      := ["barbarian", "mage"]
const VALID_DIFFICULTIES := ["easy", "medium", "hardcore"]

# Computed at runtime from the OS Documents path — set in _ready().
var SAVE_DIR     : String = ""   # …/Documents/PurgetoryDungeon/saves/
var SETTINGS_PATH: String = ""   # …/Documents/PurgetoryDungeon/settings.json


# ══════════════════════════════════════════════════════════════
#  RUNTIME STATE
# ══════════════════════════════════════════════════════════════

# The currently loaded profile dictionary. Empty dict means nothing loaded.
var current_profile: Dictionary = {}

# Which slot index (0–9) is currently active.
var active_slot_index: int = 0


# ══════════════════════════════════════════════════════════════
#  LIFECYCLE
# ══════════════════════════════════════════════════════════════

func _ready() -> void:
	_build_paths()
	_ensure_save_dir()
	# Auto-load the last played character so every menu entry point
	# immediately shows the right profile without extra navigation.
	var last_slot : int = _load_last_slot_pref()
	if last_slot >= 0 and last_slot < SLOT_COUNT:
		active_slot_index = last_slot
		load_slot(active_slot_index)


func _build_paths() -> void:
	# OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS) returns the real Documents
	# folder on Windows/macOS/Linux regardless of whether you are running
	# inside the Godot editor or from an exported build.
	var game_dir : String = StoragePaths.root()
	SAVE_DIR      = game_dir.path_join("saves") + "/"
	SETTINGS_PATH = game_dir.path_join("settings.json")
	print("SaveManager: save dir → ", SAVE_DIR)


func _ensure_save_dir() -> void:
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		DirAccess.make_dir_recursive_absolute(SAVE_DIR)


# ── Last-slot preference ────────────────────────────────────────────────────
# A tiny JSON sidecar in the game folder remembers which slot was last used.
# This is separate from the settings file so a wipe of settings doesn't
# cause the wrong character to appear.

func _last_slot_pref_path() -> String:
	return StoragePaths.root().path_join("last_slot.json")


func _save_last_slot_pref() -> void:
	StoragePaths.write_text_atomic(_last_slot_pref_path(),
		JSON.stringify({"slot": active_slot_index}))


func _load_last_slot_pref() -> int:
	var path : String = _last_slot_pref_path()
	if not FileAccess.file_exists(path):
		return 0   # Default to slot 0 on first ever launch
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary:
		return int(parsed.get("slot", 0))
	return 0


# ══════════════════════════════════════════════════════════════
#  FILE PATHS
# ══════════════════════════════════════════════════════════════

# Returns the full save path for a given slot index.
func get_file_path(slot: int) -> String:
	return SAVE_DIR + "profile_" + str(slot) + ".save"


# ══════════════════════════════════════════════════════════════
#  DEFAULT PROFILE
# ══════════════════════════════════════════════════════════════

# Returns a blank profile with all expected keys present.
# "initialized" starts false — it only becomes true when
# create_initial_identity() commits the name and class together.
# "character_class" starts empty — set once during identity creation.
func get_default_profile() -> Dictionary:
	return {
		"character_name":  "",
		"character_class": "",
		"difficulty":      "medium",
		"initialized":     false,
		"last_seed_text": "",
		"last_seed_hash": 0,
		"created_at_unix": Time.get_unix_time_from_system(),
		"updated_at_unix": Time.get_unix_time_from_system(),
		"meta_currency": 0,
		"unlocks": [],
		"perks": {"potency": 0, "volatility": 0, "distillation": 0},
		"keys": {"bronze": 0, "silver": 0, "gold": 0},
		"run_count": 0,
		"death_count": 0,
		"dungeon_completions": 0
	}


# ══════════════════════════════════════════════════════════════
#  SLOT LOADING / SAVING / DELETING
# ══════════════════════════════════════════════════════════════

# Reads a slot file and returns its profile dictionary (missing keys backfilled).
# Returns an empty Dictionary if the file is absent, unreadable or not valid JSON.
# Has NO side effects: it does not change the active slot, the last-slot
# preference, current_profile, or emit signals. Use this to inspect slots.
func peek_slot(slot_index: int) -> Dictionary:
	var path := get_file_path(slot_index)
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	file.close()
	if err != OK or typeof(json.data) != TYPE_DICTIONARY:
		return {}
	var profile: Dictionary = json.data
	var defaults := get_default_profile()
	for key in defaults.keys():
		if not profile.has(key):
			profile[key] = defaults[key]
	return profile


# Loads a slot into current_profile. If the file does not exist or
# is corrupt, a fresh default profile is loaded instead.
func load_slot(slot_index: int) -> void:
	active_slot_index = slot_index
	# Persist the choice so the next launch pre-selects this character.
	_save_last_slot_pref()

	var profile := peek_slot(slot_index)
	if profile.is_empty():
		current_profile = get_default_profile()
	else:
		current_profile = profile

	emit_signal("profile_loaded")


# Successful profile writes this session (lets tests assert how many writes an action costs).
var save_count : int = 0


# Writes the current profile to disk. Returns true on success.
func save_profile() -> bool:
	if current_profile.is_empty():
		return false

	current_profile["updated_at_unix"] = Time.get_unix_time_from_system()

	var path = get_file_path(active_slot_index)
	if not StoragePaths.write_text_atomic(path, JSON.stringify(current_profile, "\t")):
		return false
	save_count += 1
	# Always keep the last-slot preference in sync.
	_save_last_slot_pref()
	return true


# Deletes a slot file from disk. If the deleted slot was the active
# one, current_profile resets to a blank default.
func delete_slot(slot_index: int) -> void:
	var path = get_file_path(slot_index)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		if active_slot_index == slot_index:
			current_profile = get_default_profile()


# ══════════════════════════════════════════════════════════════
#  THREE-TIER SLOT CHECKING
# ══════════════════════════════════════════════════════════════

# Tier 1: Does a save file physically exist on disk for this slot?
# Does not read or parse the file — just checks existence.
func slot_has_file(slot_index: int) -> bool:
	return FileAccess.file_exists(get_file_path(slot_index))


# Tier 2: Does the slot contain a fully initialized character?
# Reads the slot via peek_slot(), so nothing else is disturbed.
func slot_has_valid_character(slot_index: int) -> bool:
	return _profile_is_valid(peek_slot(slot_index))


# Tier 3: Is the currently loaded profile a complete, valid character?
# Checks all three identity fields: name, class, and initialized flag.
func current_profile_is_valid() -> bool:
	return _profile_is_valid(current_profile)


func _profile_is_valid(profile: Dictionary) -> bool:
	if profile.is_empty():
		return false
	if not bool(profile.get("initialized", false)):
		return false
	if str(profile.get("character_name", "")).strip_edges() == "":
		return false
	if str(profile.get("character_class", "")) not in VALID_CLASSES:
		return false
	return true


# Backward-compatible wrapper. Old code that calls has_character()
# now gets the full three-field check instead of just name length.
func has_character() -> bool:
	return current_profile_is_valid()


# ══════════════════════════════════════════════════════════════
#  SLOT STATE HELPER
# ══════════════════════════════════════════════════════════════

# Returns the state of a slot as a simple string for UI decisions.
#   "empty"  — no file on disk, slot is available for a new character
#   "valid"  — file exists with a complete locked identity
#   "broken" — file exists but identity is incomplete (ghost/corrupt)
func get_slot_state(slot_index: int) -> String:
	if not slot_has_file(slot_index):
		return "empty"
	if slot_has_valid_character(slot_index):
		return "valid"
	return "broken"


# ══════════════════════════════════════════════════════════════
#  IDENTITY LOCK — CREATION
# ══════════════════════════════════════════════════════════════

# Creates the initial character identity. This is the ONE function
# that writes name, class, and the initialized flag together.
# Returns true if the identity was saved successfully.
# Returns false and writes nothing if:
#   - the name is blank after sanitization
#   - the class is not in VALID_CLASSES
#   - the profile is already initialized (identity already locked)
#   - the disk write fails
#
# After this succeeds, name and class are permanent for this slot.
func create_initial_identity(char_name: String, char_class: String,
		char_difficulty: String = "medium") -> bool:
	# Block if identity is already locked.
	if bool(current_profile.get("initialized", false)):
		push_warning("SaveManager: Attempted to re-initialize an already locked character.")
		return false

	# Validate name.
	var clean_name := sanitize_name(char_name)
	if not is_valid_name(clean_name):
		push_warning("SaveManager: Blank name rejected.")
		return false

	# Validate class.
	if char_class not in VALID_CLASSES:
		push_warning("SaveManager: Invalid class '" + char_class + "' rejected.")
		return false

	# Validate difficulty — fall back to medium if an unknown value is passed.
	var locked_difficulty : String = char_difficulty \
		if char_difficulty in VALID_DIFFICULTIES else "medium"

	# Write all identity fields in one atomic operation.
	current_profile["character_name"]  = clean_name
	current_profile["character_class"] = char_class
	current_profile["difficulty"]      = locked_difficulty
	current_profile["initialized"]     = true
	current_profile["created_at_unix"] = Time.get_unix_time_from_system()

	return save_profile()


# ══════════════════════════════════════════════════════════════
#  IDENTITY LOCK — RETRIEVAL
# ══════════════════════════════════════════════════════════════

# Returns the locked character name from the current profile.
func get_character_name() -> String:
	return str(current_profile.get("character_name", "")).strip_edges()


# Returns the locked character class from the current profile.
# Falls back to empty string if not set.
func get_character_class() -> String:
	return str(current_profile.get("character_class", ""))


# Returns the locked difficulty from the current profile.
# Falls back to "medium" so pre-difficulty saves behave as Medium.
func get_character_difficulty() -> String:
	var d : String = str(current_profile.get("difficulty", "medium"))
	return d if d in VALID_DIFFICULTIES else "medium"


# ══════════════════════════════════════════════════════════════
#  NAME VALIDATION
# ══════════════════════════════════════════════════════════════

# Returns true if the name is valid for character creation.
# A valid name is non-empty after stripping whitespace.
func is_valid_name(n: String) -> bool:
	return n.strip_edges() != ""


# Strips whitespace and truncates to MAX_NAME_LENGTH.
func sanitize_name(v: String) -> String:
	return v.strip_edges().left(MAX_NAME_LENGTH)


# Strips whitespace and truncates to MAX_SEED_LENGTH.
func sanitize_seed(v: String) -> String:
	return v.strip_edges().left(MAX_SEED_LENGTH)


# ══════════════════════════════════════════════════════════════
#  SEED MANAGEMENT
# ══════════════════════════════════════════════════════════════

# Writes the seed for the upcoming run and increments run_count.
# This is called every time a run starts, for both new and
# existing characters.
func set_last_seed(s: String, h: int) -> bool:
	current_profile["last_seed_text"] = sanitize_seed(s)
	current_profile["last_seed_hash"] = h
	current_profile["run_count"] = int(current_profile.get("run_count", 0)) + 1
	return save_profile()


# Convenience wrapper for set_last_seed.
func commit_run_seed(s: String, h: int) -> bool:
	return set_last_seed(s, h)


# Generates a random alphanumeric seed string.
func build_unique_random_seed_text(l: int = 12, _m: int = 50) -> String:
	var chars := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var out := ""
	for i in l:
		out += chars[randi() % chars.length()]
	return out


# ══════════════════════════════════════════════════════════════
#  SLOT SEARCH
# ══════════════════════════════════════════════════════════════

# Returns the index of the first save slot that has no file on disk.
# If all slots are occupied (valid or broken), returns -1.
func find_first_empty_slot() -> int:
	for i in range(SLOT_COUNT):
		if not slot_has_file(i):
			return i
	return -1


# ══════════════════════════════════════════════════════════════
#  LEGACY SETTER — KEPT FOR SAFETY
# ══════════════════════════════════════════════════════════════

# Sets the character name directly. Only works if the profile is
# NOT yet initialized (pre-lock). After initialization, name
# changes are blocked. Existing code that calls this during
# first creation will still work, but create_initial_identity()
# is the preferred path.
func set_character_name(n: String) -> bool:
	if bool(current_profile.get("initialized", false)):
		push_warning("SaveManager: Cannot rename an initialized character.")
		return false
	current_profile["character_name"] = sanitize_name(n)
	return save_profile()


# ══════════════════════════════════════════════════════════════
#  INTERNAL HELPERS
# ══════════════════════════════════════════════════════════════

# Backfills any keys from get_default_profile() that are missing
# in an older save file. This keeps the game forward-compatible
# when new fields are added to the schema without breaking
# existing saves.
func _backfill_missing_keys() -> void:
	var defaults := get_default_profile()
	for key in defaults.keys():
		if not current_profile.has(key):
			current_profile[key] = defaults[key]
