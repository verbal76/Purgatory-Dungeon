# ==============================================================================
# File Name: hud_kit.gd
# Path: res://scripts/ui/hud_kit.gd
# Description: Shared layout constants and tiny factories for the in-run HUD, so the pieces that live in
#   different CanvasLayers (vitals in the player, kills in the main scene, heading in the minimap layer, day counter
#   in GameClock, wallet in PlayerWallet) line up as ONE cluster without a shared container.
#
#   Top-left cluster, rows from the top (see HudVitals):
#       health bar + value     ROW_HEALTH_H
#       ability bar + caption  ROW_ABILITY_H
#       kills + heading plate  at kills_row_top()
#   Top-right: day counter (GameClock), wallet under it on phones (PlayerWallet).
#
#   HUD elements are outline text + small iron/brass pieces. No big opaque boxes: the dungeon stays dominant.
# ==============================================================================
class_name HudKit
extends RefCounted

const EDGE := PUI.S5                 # distance from the screen edge (plus the phone safe-area inset)
const ROW_HEALTH_H := 32
const ROW_ABILITY_H := 24
const ROW_KILLS_H := 32
const ROW_GAP := PUI.S1
const CLUSTER_GAP := PUI.S2
const BAR_W := 240.0
const COMPASS_W := 72.0              # fits the widest heading ("NW") in the display face on a phone, plus the plate margins
const HEALTH_BAR_H := 22.0
const ABILITY_BAR_H := 12.0


## Safe-area insets (left, top, right, bottom) in virtual px. Phones only: on a desktop window the OS "safe area"
## is the work area (taskbar excluded) and must not shift the HUD.
static func insets(vp: Viewport) -> Vector4:
	if vp == null or not TouchControls.is_touch_platform():
		return Vector4.ZERO
	return TouchControls.insets_from_safe_area(Vector2(DisplayServer.screen_get_size()),
		Rect2(DisplayServer.get_display_safe_area()), vp.get_visible_rect().size)


## Top-left corner of the left cluster.
static func origin(vp: Viewport) -> Vector2:
	var ins: Vector4 = insets(vp)
	return Vector2(EDGE + ins.x, EDGE + ins.y)


## Distance from the cluster's top to the kills / heading row.
static func kills_row_top() -> float:
	return float(ROW_HEALTH_H + ROW_GAP + ROW_ABILITY_H + CLUSTER_GAP)


## Offset of the top-right anchor: x = distance from the right edge, y = distance from the top.
static func top_right(vp: Viewport) -> Vector2:
	var ins: Vector4 = insets(vp)
	return Vector2(EDGE + ins.z, EDGE + ins.y)


## Icon edge length that matches a HudValue line.
static func icon_px() -> float:
	return float(int(round(float(PUI.fs("hud_value")) * 1.2)))


static func value_label(text: String = "") -> Label:
	var l: Label = PUI.label(text, "HudValue")
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func caption_label(text: String = "") -> Label:
	var l: Label = PUI.label(text, "HudLabel")
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## A Label that wears the HUD plate: small iron plate with a brass edge (the heading letter).
static func plate_style() -> StyleBoxTexture:
	var sb: StyleBoxTexture = PUI.box(Color(PUI.IRON.r, PUI.IRON.g, PUI.IRON.b, 0.82), PUI.EDGE_BRASS.darkened(0.2),
		PUI.IRON_DEEP, 0.08, 0.3, 0.015)
	sb.content_margin_left = PUI.S3
	sb.content_margin_right = PUI.S3
	sb.content_margin_top = PUI.S1
	sb.content_margin_bottom = PUI.S1
	return sb


## Make a whole subtree click-through (HUD never eats input).
static func ignore_mouse(c: Control) -> void:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for ch in c.get_children():
		if ch is Control:
			ignore_mouse(ch as Control)
