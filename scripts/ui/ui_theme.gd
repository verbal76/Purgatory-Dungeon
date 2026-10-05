# ==============================================================================
# File Name: ui_theme.gd
# Path: res://scripts/ui/ui_theme.gd
# Autoload Name: UiTheme
# Description: Applies the Purgatory UI theme (see PUI) to the root window so every scene, dialog and
#              popup inherits one interface language. Nothing else happens here.
# ==============================================================================
extends Node


func _enter_tree() -> void:
	get_tree().root.theme = PUI.theme()
