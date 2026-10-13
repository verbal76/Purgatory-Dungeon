# ==============================================================================
# File Name: pui_icon.gd
# Path: res://scripts/ui/pui_icon.gd
# Description: A Control that draws one icon of the Purgatory icon family (TouchIcons.KINDS) at its size.
#   Use for HUD/menus instead of emoji, font glyphs or image files:
#       var ic := PUIIcon.make("potion", 28.0)
# ==============================================================================
class_name PUIIcon
extends Control

var kind: String = "potion":
	set(v):
		kind = v
		queue_redraw()
var tint: Color = PUI.BONE:
	set(v):
		tint = v
		queue_redraw()


static func make(p_kind: String, px: float = 28.0, p_tint: Color = PUI.BONE) -> PUIIcon:
	var ic := PUIIcon.new()
	ic.kind = p_kind
	ic.tint = p_tint
	ic.custom_minimum_size = Vector2(px, px)
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return ic


func _draw() -> void:
	var r: float = minf(size.x, size.y) * 0.5
	TouchIcons.draw_icon(self, kind, size * 0.5, r, tint)
