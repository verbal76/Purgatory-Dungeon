extends Node

var character_name  : String = ""
var seed_text       : String = ""
var seed_hash       : int    = 0
var is_random_run   : bool   = true
var character_class : String = "barbarian"  # "barbarian" or "mage"
var difficulty      : String = "medium"     # "easy" | "medium" | "hardcore"

# ── Debug toggles (set from CharacterSelection debug panel) ───────────────────
# These are NOT reset by clear() — they persist across scene changes intentionally.
var debug_no_brutes       : bool = false
var debug_no_mages        : bool = false
var debug_no_health_orbs  : bool = false
var debug_no_demonic_orbs : bool = false
var debug_no_buffs        : bool = false
var debug_no_traps        : bool = false


func clear() -> void:
	character_name  = ""
	seed_text       = ""
	seed_hash       = 0
	is_random_run   = true
	character_class = "barbarian"
	difficulty      = "medium"
