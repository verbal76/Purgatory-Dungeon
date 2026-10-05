# ==============================================================================
# File Name: ui_theme.gd
# Path: res://scripts/ui/ui_theme.gd
# Autoload Name: UiTheme
# Description: Applies the Purgatory UI theme (see PUI) to the root window so every scene, dialog and
#              popup inherits one interface language.
#
#              A CanvasLayer is not a Control, so a Control whose direct parent is a CanvasLayer (HUDs, overlays,
#              pause menu...) does NOT inherit the root window's theme and would render as default engine UI.
#              Such top-level controls get the shared theme assigned as they enter the tree.
# ==============================================================================
extends Node


func _enter_tree() -> void:
	var tree := get_tree()
	tree.root.theme = PUI.theme()
	tree.node_added.connect(_on_node_added)


func _on_node_added(n: Node) -> void:
	if n is Control and n.get_parent() is CanvasLayer and (n as Control).theme == null:
		(n as Control).theme = PUI.theme()
