# ==============================================================================
# File Name: run_lifecycle.gd
# Path: res://scripts/run_lifecycle.gd
#
# Description:
#   Shared run start/end bookkeeping so every route into or out of a run leaves the
#   same state behind. Before this, each screen (character select, death screen,
#   run-end screen, Alchemist, pause menu) reset a different subset of autoloads:
#   a Mage profile started from the Alchemist ran as a Barbarian, hardcore/easy
#   difficulty was lost, globes kept ticking in menus, and "Exit to main menu" left
#   the day clock and buff timers live.
# ==============================================================================
class_name RunLifecycle
extends RefCounted


## Copies the active profile's identity into GlobalRunData (what the dungeon reads).
## No-op if no valid character is loaded.
static func sync_run_data_from_profile() -> void:
	if not SaveManager.current_profile_is_valid():
		return
	GlobalRunData.character_name  = SaveManager.get_character_name()
	GlobalRunData.character_class = SaveManager.get_character_class()
	GlobalRunData.difficulty      = SaveManager.get_character_difficulty()


## Stops and clears every run-scoped autoload. Safe to call repeatedly.
static func end_run_cleanup() -> void:
	GameClock.hide_hud()
	BuffManager.reset()
	GlobeManager.reset()
	PlayerWallet.hide_hud()
