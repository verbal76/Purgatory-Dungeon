# ==============================================================================
# File Name: mobile_ui.gd
# Path: res://scripts/touch/mobile_ui.gd
#
# Description:
#   Phone legibility pass for every menu and HUD, installed only on touch platforms (the desktop UI is
#   untouched). The layouts were drawn for a mouse on a 1920x1080 monitor; on a 6.8" phone the same 14-16 px
#   text is about 4 pt and the 40 px buttons are thumb-hostile. Rather than fork every screen this
#   node sets a larger default theme font on the root window and, as nodes enter the tree, raises
#   any font override below the minimum and gives buttons a thumb-sized minimum height.
#
#   Screens that must keep an exact size (the touch layer itself, custom-drawn HUD) opt out with the
#   "no_mobile_ui" group on the node or any ancestor.
# ==============================================================================
class_name MobileUi
extends Node

const GROUP_OPT_OUT := "no_mobile_ui"
const DEFAULT_FONT := 24
const MIN_FONT_LABEL := 22
const MIN_FONT_BUTTON := 26
const MIN_BUTTON_HEIGHT := 72.0
const MIN_SLIDER_HEIGHT := 56.0

var min_font_label: int = MIN_FONT_LABEL
var min_font_button: int = MIN_FONT_BUTTON
var min_button_height: float = MIN_BUTTON_HEIGHT


static func install(tree: SceneTree) -> Node:
	var ui: Node = (load("res://scripts/touch/mobile_ui.gd") as GDScript).new()
	ui.name = "MobileUi"
	ui.process_mode = Node.PROCESS_MODE_ALWAYS
	tree.root.add_child.call_deferred(ui)
	return ui


func _ready() -> void:
	var t := Theme.new()
	t.default_font_size = DEFAULT_FONT
	get_tree().root.theme = t
	get_tree().node_added.connect(_on_node_added)
	# Nodes that entered before this node did (the scene that is already loading).
	_scan(get_tree().root)


func _scan(n: Node) -> void:
	for c in n.get_children():
		_on_node_added(c)
		_scan(c)


func _on_node_added(n: Node) -> void:
	if not (n is Control):
		return
	if n.is_node_ready():
		_adapt.call_deferred(n)
	else:
		n.ready.connect(_adapt.bind(n), CONNECT_ONE_SHOT | CONNECT_DEFERRED)


func _opted_out(n: Node) -> bool:
	var p: Node = n
	while p != null:
		if p.is_in_group(GROUP_OPT_OUT):
			return true
		p = p.get_parent()
	return false


func _adapt(c: Control) -> void:
	if not is_instance_valid(c) or not c.is_inside_tree() or _opted_out(c):
		return
	adapt_control(c)


## Applies the minimums to one control (public so tests can drive it on a detached tree).
func adapt_control(c: Control) -> void:
	if c is BaseButton or c is OptionButton:
		_raise_font(c, "font_size", min_font_button)
		if c.custom_minimum_size.y < min_button_height and not (c is TextureButton):
			c.custom_minimum_size.y = min_button_height
	elif c is Label:
		_raise_font(c, "font_size", min_font_label)
	elif c is RichTextLabel:
		for key in ["normal_font_size", "bold_font_size", "italics_font_size", "mono_font_size"]:
			_raise_font(c, key, min_font_label)
	elif c is LineEdit or c is TextEdit:
		_raise_font(c, "font_size", min_font_button)
		if c is LineEdit and c.custom_minimum_size.y < min_button_height:
			c.custom_minimum_size.y = min_button_height
	elif c is Slider:
		if c.custom_minimum_size.y < MIN_SLIDER_HEIGHT and c is HSlider:
			c.custom_minimum_size.y = MIN_SLIDER_HEIGHT
	elif c is TabContainer or c is TabBar:
		_raise_font(c, "font_size", min_font_button)
	elif c is ItemList:
		_raise_font(c, "font_size", min_font_button)


func _raise_font(c: Control, key: String, minimum: int) -> void:
	var cur: int = c.get_theme_font_size(key)
	if cur > 0 and cur < minimum:
		c.add_theme_font_size_override(key, minimum)
