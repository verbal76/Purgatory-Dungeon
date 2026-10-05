# Dev utility for tools/ui_shot.gd: shows the Options screen on a chosen tab (env OPTIONS_TAB = tab title or index),
# optionally embedded in the pause menu (OPTIONS_EMBEDDED=1) or with a key-binding row in the "listening" state
# (OPTIONS_LISTEN=1). Not part of the game.
extends Control

func _ready() -> void:
	# ui_shot.gd scales every scene to a 1280x720 canvas; the real desktop game does not stretch, so undo
	# that on the desktop shape to review true desktop pixel sizes.
	if not TouchControls.is_touch_platform():
		get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	if OS.get_environment("OPTIONS_PAUSE") == "1":
		var bgp := ColorRect.new()
		bgp.color = Color(0.25, 0.2, 0.15)
		bgp.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(bgp)
		var pz: Node = (load("res://scenes/pause_menu_function.tscn") as PackedScene).instantiate()
		add_child(pz)
		await get_tree().process_frame
		pz.call("open_menu")
		return
	var embedded := OS.get_environment("OPTIONS_EMBEDDED") == "1"
	var options: Control
	if embedded:
		# a dim stand-in for the paused dungeon behind the overlay
		var bg := ColorRect.new()
		bg.color = Color(0.25, 0.2, 0.15)
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(bg)
		var pause: Node = (load("res://scenes/pause_menu_function.tscn") as PackedScene).instantiate()
		add_child(pause)
		await get_tree().process_frame
		pause.call("open_menu")
		pause.call("_on_options_button_pressed")
		await get_tree().process_frame
		options = pause.get_node("OptionsOverlay").get_child(0)
	else:
		options = (load("res://scenes/OptionsScreen.tscn") as PackedScene).instantiate()
		add_child(options)
	for i in 4:
		await get_tree().process_frame
	var tabs := options.find_children("*", "TabContainer", true, false)[0] as TabContainer
	var want := OS.get_environment("OPTIONS_TAB")
	for i in tabs.get_tab_count():
		if tabs.get_tab_title(i) == want or str(i) == want:
			tabs.current_tab = i
	if OS.get_environment("OPTIONS_LISTEN") == "1":
		var btns := options.find_children("*", "Button", true, false)
		for b in btns:
			if (b as Button).text == "Z" or (b as Button).text == "S":
				options._start_listen("move_back", "keyboard", b)
				break
