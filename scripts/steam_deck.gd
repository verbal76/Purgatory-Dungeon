# ==============================================================================
# File Name: steam_deck.gd
# Path: res://scripts/steam_deck.gd
#
# Description:
#   Is this a Steam Deck? Steam sets the environment variable SteamDeck=1 for every game it starts on a Deck, including games run through
#   Proton, so the Windows build can tell. PURGATORY_FORCE_DECK=1 pretends (tests, and trying the Deck defaults on a PC). Static helper, no
#   node, no class_name: use through `const SteamDeck := preload("res://scripts/steam_deck.gd")`.
#
#   What changes on a Deck (docs/STEAM_DECK.md): the Graphics Quality default is Medium instead of High (graphics_quality.gd); the screen is
#   the Deck's own 1280x800 panel, which the default borderless-fullscreen mode already fills.
# ==============================================================================
extends RefCounted

## The Deck's panel (and the 800p Valve measures performance at).
const PANEL := Vector2i(1280, 800)


static func is_deck() -> bool:
	return OS.get_environment("SteamDeck") == "1" or OS.get_environment("PURGATORY_FORCE_DECK") == "1"
