# ==============================================================================
# File Name: hud_status_panel.gd
# Path: res://scripts/ui/hud_status_panel.gd
# Description: The active trap effects list (bottom centre, hidden while nothing is active): a small translucent
#   iron plate sized to its text, with the lines in the warning role (muted blood - these are harmful statuses).
#   The players keep a reference to `label` and toggle `visible`, exactly as with the old ColorRect + Label.
# ==============================================================================
class_name HudStatusPanel
extends PanelContainer

var label: Label = null


func _init() -> void:
	name = "StatusPanel"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = 0.0
	offset_right = 0.0
	offset_top = -80.0
	offset_bottom = -80.0
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BEGIN

	var sb: StyleBoxTexture = PUI.box(Color(0.06, 0.05, 0.04, 0.72), PUI.EDGE.darkened(0.2),
		Color(0.04, 0.03, 0.03, 0.80), 0.05, 0.25, 0.02)
	sb.content_margin_left = PUI.S4
	sb.content_margin_right = PUI.S4
	sb.content_margin_top = PUI.S2
	sb.content_margin_bottom = PUI.S2
	add_theme_stylebox_override("panel", sb)

	label = PUI.label("", "WarningLabel")
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_constant_override("outline_size", 4)
	add_child(label)
