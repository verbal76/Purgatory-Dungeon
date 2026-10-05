# Dev scene: every design-system component on one screen (screenshot it with tools/ui_shot.gd).
extends Control


func _ready() -> void:
	add_child(PUI.background("void"))
	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, PUI.S5)
	add_child(m)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", PUI.S5)
	m.add_child(cols)

	var a := VBoxContainer.new()
	a.add_theme_constant_override("separation", PUI.S3)
	a.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(a)
	a.add_child(PUI.label("PURGATORY", "GameTitle"))
	a.add_child(PUI.label("Screen Title", "ScreenTitle"))
	a.add_child(PUI.label("Section Heading", "SectionHeading"))
	a.add_child(PUI.label("Body text reads like this on every screen.", ""))
	a.add_child(PUI.label("Secondary body text, quieter.", "SecondaryLabel"))
	a.add_child(PUI.label("Metadata - runs 2, deaths 1", "MetaLabel"))
	a.add_child(PUI.label("Warning: Hardcore is unforgiving", "WarningLabel"))
	a.add_child(PUI.divider())
	a.add_child(PUI.button("Secondary action"))
	a.add_child(PUI.button("Start Run", "primary"))
	a.add_child(PUI.button("Delete Soul", "danger"))
	a.add_child(PUI.button("Back", "nav"))
	var dis := PUI.button("Disabled")
	dis.disabled = true
	a.add_child(dis)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", PUI.S3)
	var grp := ButtonGroup.new()
	for n in ["Barbarian", "Mage"]:
		var b := PUI.button(n, "selector")
		b.button_group = grp
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
	(row.get_child(0) as Button).button_pressed = true
	a.add_child(row)

	var b2 := VBoxContainer.new()
	b2.add_theme_constant_override("separation", PUI.S3)
	b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(b2)
	var tabs := TabContainer.new()
	for tn in ["Sound", "Video", "Gameplay"]:
		var pc := VBoxContainer.new()
		pc.name = tn
		if tn == "Sound":
			pc.add_child(PUI.label("Volume", "SectionHeading"))
			var sl := HSlider.new()
			sl.value = 65
			sl.custom_minimum_size.y = 44
			pc.add_child(sl)
			var cb := CheckBox.new()
			cb.text = "Screen shake"
			cb.button_pressed = true
			pc.add_child(cb)
			var cb2 := CheckBox.new()
			cb2.text = "Vibration"
			pc.add_child(cb2)
			var le := LineEdit.new()
			le.placeholder_text = "Enter name..."
			pc.add_child(le)
			var ob := OptionButton.new()
			ob.add_item("Windowed")
			ob.add_item("Fullscreen")
			pc.add_child(ob)
		tabs.add_child(pc)
	b2.add_child(tabs)
	var card := PUI.panel("card")
	var cv := VBoxContainer.new()
	cv.add_child(PUI.label("Bob", "CardTitle"))
	cv.add_child(PUI.label("Barbarian", "SecondaryLabel"))
	cv.add_child(PUI.label("Runs 2   Deaths 1", "MetaLabel"))
	card.add_child(cv)
	b2.add_child(card)
	var parch := PUI.panel("parchment")
	var pv := VBoxContainer.new()
	pv.add_child(PUI.label("Magnitude", "ParchmentCardTitle"))
	pv.add_child(PUI.label("Dome Radius +10%", "ParchmentBody"))
	pv.add_child(PUI.label("Lv. 0", "ParchmentMeta"))
	pv.add_child(PUI.button("Trade 1 Potion", "primary"))
	parch.add_child(pv)
	b2.add_child(parch)
