# ==============================================================================
# File Name: PlayerWallet.gd
# Path: res://autoloads/PlayerWallet.gd
# Description: Links HUD to SaveManager persistent meta-currency and the
#              across-runs key inventory (bronze / silver / gold).
# ==============================================================================
extends Node

signal wallet_changed(new_count: int)

const KEY_COLORS : Array[String] = ["bronze", "silver", "gold"]
const _KEY_LABEL_COLORS : Dictionary = {
	"bronze": Color(0.85, 0.55, 0.30),
	"silver": Color(0.85, 0.85, 0.90),
	"gold":   Color(1.00, 0.85, 0.20),
}

var _hud_layer : CanvasLayer = null
var _potion_text : Label = null
var _key_labels : Dictionary = {}   # color → Label

func _ready() -> void:
	_build_hud()
	# Listen for the SaveManager to finish loading before updating the HUD
	SaveManager.connect("profile_loaded", Callable(self, "refresh_hud"))

func _build_hud() -> void:
	_hud_layer = CanvasLayer.new()
	_hud_layer.layer = 5
	add_child(_hud_layer)

	_potion_text = Label.new()
	_potion_text.add_theme_font_size_override("font_size", 22)
	_potion_text.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	_potion_text.add_theme_constant_override("outline_size", 4)
	_potion_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_potion_text.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_potion_text.offset_left = -250.0
	_potion_text.offset_right = -20.0
	_potion_text.offset_top = -60.0
	_hud_layer.add_child(_potion_text)

	# Three key counters stacked above the potions line, colour-coded.
	var y_offset : float = -90.0
	for color in KEY_COLORS:
		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 18)
		lbl.add_theme_color_override("font_color", _KEY_LABEL_COLORS[color])
		lbl.add_theme_constant_override("outline_size", 4)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		lbl.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		lbl.offset_left  = -250.0
		lbl.offset_right = -20.0
		lbl.offset_top   = y_offset
		_hud_layer.add_child(lbl)
		_key_labels[color] = lbl
		y_offset -= 24.0

	# SURGICAL ADD: Hide by default. Only the dungeon scene calls show_hud().
	# Menus have their own potion displays and don't need this overlay.
	_hud_layer.visible = false


# Shows the wallet overlay. Call from the dungeon main game file after player spawns.
func show_hud() -> void:
	if _hud_layer != null:
		_update_hud()
		_hud_layer.visible = true


# Hides the wallet overlay. Call from main menu and any non-dungeon scene.
func hide_hud() -> void:
	if _hud_layer != null:
		_hud_layer.visible = false

func add_potions(amount: int) -> void:
	var current = SaveManager.current_profile.get("meta_currency", 0)
	SaveManager.current_profile["meta_currency"] = current + amount
	SaveManager.save_profile()
	_update_hud()
	emit_signal("wallet_changed", SaveManager.current_profile["meta_currency"])

func spend_potions(amount: int) -> bool:
	var current = SaveManager.current_profile.get("meta_currency", 0)
	if current < amount: return false
	SaveManager.current_profile["meta_currency"] = current - amount
	SaveManager.save_profile()
	_update_hud()
	emit_signal("wallet_changed", SaveManager.current_profile["meta_currency"])
	return true

func _update_hud() -> void:
	if _potion_text:
		var count = 0
		if not SaveManager.current_profile.is_empty():
			count = SaveManager.current_profile.get("meta_currency", 0)
		_potion_text.text = "Potions: %d" % count

	for color in KEY_COLORS:
		if _key_labels.has(color):
			var lbl : Label = _key_labels[color]
			lbl.text = "%s Key × %d" % [color.capitalize(), get_key_count(color)]

# Call this when the save slot changes or a new run starts
# so the HUD re-reads from the current profile.
func refresh_hud() -> void:
	_update_hud()


# ══════════════════════════════════════════════════════════════
#  KEY INVENTORY (persistent across runs)
# ══════════════════════════════════════════════════════════════

# Ensures the "keys" subdict exists on the current profile (older saves may
# predate the field — SaveManager backfills the top-level key, but we guard
# against a malformed or partial dict too).
func _ensure_keys_dict() -> Dictionary:
	if SaveManager.current_profile.is_empty():
		return {}
	if not SaveManager.current_profile.has("keys") \
			or typeof(SaveManager.current_profile["keys"]) != TYPE_DICTIONARY:
		SaveManager.current_profile["keys"] = {"bronze": 0, "silver": 0, "gold": 0}
	var keys_dict : Dictionary = SaveManager.current_profile["keys"]
	for c in KEY_COLORS:
		if not keys_dict.has(c):
			keys_dict[c] = 0
	return keys_dict


func add_key(color: String) -> void:
	if not KEY_COLORS.has(color):
		return
	var keys_dict := _ensure_keys_dict()
	keys_dict[color] = int(keys_dict.get(color, 0)) + 1
	SaveManager.save_profile()
	_update_hud()
	emit_signal("wallet_changed", SaveManager.current_profile.get("meta_currency", 0))


func spend_key(color: String) -> bool:
	if not KEY_COLORS.has(color):
		return false
	var keys_dict := _ensure_keys_dict()
	var current : int = int(keys_dict.get(color, 0))
	if current <= 0:
		return false
	keys_dict[color] = current - 1
	SaveManager.save_profile()
	_update_hud()
	emit_signal("wallet_changed", SaveManager.current_profile.get("meta_currency", 0))
	return true


func get_key_count(color: String) -> int:
	if SaveManager.current_profile.is_empty():
		return 0
	var keys_dict = SaveManager.current_profile.get("keys", {})
	if typeof(keys_dict) != TYPE_DICTIONARY:
		return 0
	return int(keys_dict.get(color, 0))


func has_any_key() -> bool:
	for c in KEY_COLORS:
		if get_key_count(c) > 0:
			return true
	return false
