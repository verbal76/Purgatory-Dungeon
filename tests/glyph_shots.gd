extends Node
## MANUAL TOOL (not part of run_tests.sh): renders the controller prompts for a visual check (software Vulkan works):
##   export PURGATORY_SAVE_ROOT=$(mktemp -d)/PurgetoryDungeon
##   GLYPH_OUT=/tmp/glyph_shots xvfb-run -a -s "-screen 0 1280x800x24" godot --rendering-driver vulkan --rendering-method mobile \
##     --resolution 1280x800 --path . res://tests/glyph_shots.tscn

const Glyphs := preload("res://scripts/controller_glyphs.gd")
const GlyphPromptScript := preload("res://scripts/glyph_prompt.gd")


func _ready() -> void:
	var out: String = OS.get_environment("GLYPH_OUT")
	if out == "":
		out = ProjectSettings.globalize_path("user://glyph_shots")
	DirAccess.make_dir_recursive_absolute(out)
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.08, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(root)
	PUI.adopt(root)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.add_theme_constant_override("separation", 22)
	root.add_child(box)
	for pair in [["Press %g to stop", "ui_accept"], ["Press %g to view character stats", "ui_menu"], ["%g  Use Bronze Key", "equip"],
			["Press %g to start a new run", "restart"], ["Kick with %g", "kick"], ["Slide with %g", "jump"], ["Attack with %g", "attack"], ["Block with %g", "block"]]:
		var line: HBoxContainer = GlyphPromptScript.new()
		line.setup(pair[0], pair[1], "SecondaryLabel", 34.0)
		box.add_child(line)
	for scheme_name in ["xbox", "deck", "keyboard"]:
		if scheme_name == "keyboard":
			InputManager._set_scheme(InputManager.Scheme.KEYBOARD)
		else:
			InputManager._set_controller_style(Glyphs.Style.XBOX if scheme_name == "xbox" else Glyphs.Style.DECK)
			InputManager._set_scheme(InputManager.Scheme.GAMEPAD)
		for i in 4:
			await get_tree().process_frame
		RenderingServer.force_draw()
		get_viewport().get_texture().get_image().save_png("%s/%s.png" % [out, scheme_name])
		print("saved ", scheme_name)
	get_tree().quit()
