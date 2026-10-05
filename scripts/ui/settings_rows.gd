# ==============================================================================
# File Name: settings_rows.gd
# Path: res://scripts/ui/settings_rows.gd
#
# Description:
#   Row components shared by the Options screen and the pause menu so a setting looks the same
#   wherever it appears: label on the left, control on the right, value read-out in the HudValue
#   style, section headings with a brass divider, secondary explanatory text. Everything is the
#   theme (scripts/ui/pui.gd) - no colours or sizes of its own.
# ==============================================================================
class_name SettingsRows
extends RefCounted

const LABEL_W: float = 300.0          # label column: controls of every row start at the same x
const VALUE_W: float = 84.0           # numeric read-out column on the right of a slider
const ROW_H: float = 56.0             # a row is at least a comfortable thumb target high
const SLIDER_H: float = 44.0          # slider hit area


## SectionHeading (Cinzel, ember) over a brass divider. `note` is a quiet qualifier on the right.
static func section(parent: Control, text: String, note: String = "", space_above: bool = true) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", PUI.S2)
	if space_above and parent.get_child_count() > 0:
		var gap := Control.new()
		gap.custom_minimum_size.y = PUI.S3   # + the parent's separation = SECTION_GAP
		parent.add_child(gap)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", PUI.S4)
	box.add_child(head)
	var lbl := PUI.label(text, "SectionHeading")
	lbl.size_flags_vertical = Control.SIZE_SHRINK_END
	head.add_child(lbl)
	if note != "":
		var n := PUI.label(note, "MetaLabel")
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		n.size_flags_vertical = Control.SIZE_SHRINK_END
		head.add_child(n)
	box.add_child(brass_line())
	parent.add_child(box)


## One settings row: [label (+ optional quiet note)] [control...]. Returns the row HBox.
static func row(parent: Control, label_text: String, note: String = "") -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", PUI.S4)
	r.custom_minimum_size.y = ROW_H
	parent.add_child(r)
	var cell := VBoxContainer.new()
	cell.custom_minimum_size.x = LABEL_W
	cell.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cell.add_theme_constant_override("separation", 0)
	r.add_child(cell)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cell.add_child(lbl)
	if note != "":
		cell.add_child(PUI.label(note, "MetaLabel"))
	return r


## The numeric read-out that sits right of a slider.
static func value_label() -> Label:
	var v := PUI.label("", "HudValue")
	v.custom_minimum_size.x = VALUE_W
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return v


## Slider sized for touch, filling the control column.
static func prepare_slider(sl: HSlider) -> void:
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sl.custom_minimum_size.y = maxf(sl.custom_minimum_size.y, SLIDER_H)


## Secondary explanatory text under a group of rows.
static func hint(parent: Control, text: String) -> Label:
	var lbl := PUI.label(text, "SecondaryLabel")
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(lbl)
	return lbl


## A 2 px brass line (the BrassDivider look). Drawn as a rect: the theme's HSeparator renders nothing in 4.6
## with a border-less StyleBoxFlat, so the shared screens use this until PUI.divider() is fixed.
static func brass_line() -> ColorRect:
	var line := ColorRect.new()
	line.color = PUI.EDGE_BRASS
	line.custom_minimum_size.y = 2.0
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line
