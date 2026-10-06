# ==============================================================================
# File Name: PlayerWallet.gd
# Path: res://autoloads/PlayerWallet.gd
# Description: Links HUD to SaveManager persistent meta-currency and the
#              across-runs key inventory (bronze / silver / gold).
# ==============================================================================
extends Node

signal wallet_changed(new_count: int)

const KEY_COLORS : Array[String] = ["bronze", "silver", "gold"]

var _hud_layer : CanvasLayer = null
var _grid : GridContainer = null
var _potion_text : Label = null     # potion count (HudValue)
var _key_labels : Dictionary = {}   # color → Label (key count, HudValue)
var _rows : Dictionary = {}         # "potions" | color → [icon, name label, count label]
var _shown : Dictionary = {}        # row id → count currently displayed (text is only rewritten on change)

func _ready() -> void:
	_build_hud()
	# Listen for the SaveManager to finish loading before updating the HUD
	SaveManager.connect("profile_loaded", Callable(self, "refresh_hud"))

# Compact rows, no box: [icon] [name] [count] in outlined HUD type. A key icon is tinted with its metal
# (PUI.key_tint); a count of zero dims the row. Desktop: bottom-right, gold on top, potions last.
func _build_hud() -> void:
	_hud_layer = CanvasLayer.new()
	_hud_layer.layer = 5
	add_child(_hud_layer)

	_grid = GridContainer.new()
	_grid.name = "WalletRows"
	_grid.columns = 3
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid.add_theme_constant_override("h_separation", PUI.S2)
	_grid.add_theme_constant_override("v_separation", PUI.S1)
	_hud_layer.add_child(_grid)

	_add_row("potions", "potion", PUI.BONE, "Potions")
	for color in KEY_COLORS:
		_add_row(color, "key", PUI.key_tint(color), "%s key" % color.capitalize())
	_potion_text = _rows["potions"][2]
	for color in KEY_COLORS:
		_key_labels[color] = _rows[color][2]

	_apply_layout(TouchControls.is_touch_platform())
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_view_changed):
		vp.size_changed.connect(_on_view_changed)

	# SURGICAL ADD: Hide by default. Only the dungeon scene calls show_hud().
	# Menus have their own potion displays and don't need this overlay.
	_hud_layer.visible = false


func _add_row(id: String, icon_kind: String, tint: Color, caption: String) -> void:
	var icon := PUIIcon.make(icon_kind, HudKit.icon_px(), tint)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var name_lbl := HudKit.caption_label(caption)
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var count := HudKit.value_label("0")
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	count.custom_minimum_size = Vector2(PUI.S6 + PUI.S2, HudKit.ROW_KILLS_H)
	_grid.add_child(icon)
	_grid.add_child(name_lbl)
	_grid.add_child(count)
	_rows[id] = [icon, name_lbl, count]


func _on_view_changed() -> void:
	_apply_layout(TouchControls.is_touch_platform())


# Desktop: bottom-right corner, the order gold, silver, bronze, potions (top to bottom).
# Phones: the lower-right corner belongs to the action cluster, so potions and keys sit top-right,
# left of the pause/map buttons and under the day counter (order: potions, bronze, silver, gold).
func _apply_layout(phone: bool) -> void:
	if _grid == null:
		return
	var order: Array = ["gold", "silver", "bronze", "potions"]
	if phone:
		order = ["potions", "bronze", "silver", "gold"]
	var idx := 0
	for id in order:
		for node in _rows[id]:
			_grid.move_child(node as Node, idx)
			idx += 1
	var vp := get_viewport()
	var ins: Vector4 = HudKit.insets(vp)
	_grid.anchor_left = 1.0
	_grid.anchor_right = 1.0
	_grid.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	if phone:
		_grid.anchor_top = 0.0
		_grid.anchor_bottom = 0.0
		_grid.grow_vertical = Control.GROW_DIRECTION_END
		_grid.offset_right = -(150.0 + ins.z)    # clear of the pause / map buttons
		_grid.offset_left = _grid.offset_right
		_grid.offset_top = HudKit.EDGE + ins.y + HudKit.ROW_HEALTH_H + PUI.S2   # under the day counter
		_grid.offset_bottom = _grid.offset_top
	else:
		_grid.anchor_top = 1.0
		_grid.anchor_bottom = 1.0
		_grid.grow_vertical = Control.GROW_DIRECTION_BEGIN
		_grid.offset_right = -HudKit.EDGE
		_grid.offset_left = _grid.offset_right
		_grid.offset_top = -HudKit.EDGE
		_grid.offset_bottom = _grid.offset_top


# Kept for callers and tests that force the phone placement.
func _move_for_phone() -> void:
	_apply_layout(true)


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

# save = false lets a caller that changes more of the profile in the same step (the Alchemist
# also bumps a perk) write it once, after both changes, instead of twice.
func spend_potions(amount: int, save: bool = true) -> bool:
	var current = SaveManager.current_profile.get("meta_currency", 0)
	if current < amount: return false
	SaveManager.current_profile["meta_currency"] = current - amount
	if save:
		SaveManager.save_profile()
	_update_hud()
	emit_signal("wallet_changed", SaveManager.current_profile["meta_currency"])
	return true

func _update_hud() -> void:
	if _potion_text:
		var count = 0
		if not SaveManager.current_profile.is_empty():
			count = SaveManager.current_profile.get("meta_currency", 0)
		_set_row("potions", int(count))

	for color in KEY_COLORS:
		if _key_labels.has(color):
			_set_row(color, get_key_count(color))


# Rewrites a row only when its count changed; a zero count dims the row (icon + number).
func _set_row(id: String, count: int) -> void:
	if _shown.get(id, -1) == count:
		return
	_shown[id] = count
	var row: Array = _rows[id]
	(row[2] as Label).text = str(count)
	var has: bool = count > 0
	(row[0] as Control).modulate.a = 1.0 if has else 0.45
	var lbl := row[2] as Label
	if has:
		lbl.remove_theme_color_override("font_color")
	else:
		lbl.add_theme_color_override("font_color", PUI.BONE_FAINT)

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
