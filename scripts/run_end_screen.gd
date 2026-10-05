# ==============================================================================
# FILE: run_end_screen.gd
# PATH: res://scripts/run_end_screen.gd
# DESCRIPTION: End-of-run choice screen shown when the player enters the Day 30
#              exit portal after killing all portal guards and remaining enemies.
#
#   Sequence:
#     1. Fade screen to black over FADE_DURATION seconds.
#     2. Show "You have survived the Purgatory" flavour text.
#     3. Present two choices:
#          A) "Return to your old life"
#             — Saves dungeon_completions + 1, calls CodexManager, returns to
#               the main menu (AlchemistStore scene).
#          B) "Stay Below — Legendary Mode"
#             — Calls GameClock.enter_legendary_mode(), frees this screen,
#               tells PortalManager to disable the portal. Run continues.
# ==============================================================================

extends CanvasLayer

const FADE_DURATION     : float  = 1.8
const ALCHEMIST_SCENE   : String = "res://scenes/AlchemistStore.tscn"

var _portal_manager : Node  = null
var _fade_rect      : ColorRect = null
var _choice_root    : Control   = null
var _fade_done      : bool  = false
var _exiting        : bool  = false   # one-shot guard: a second button press must do nothing


func _ready() -> void:
	layer        = 20
	process_mode = Node.PROCESS_MODE_ALWAYS


func setup(portal_mgr: Node) -> void:
	_portal_manager = portal_mgr
	_build_ui()
	_run_fade()


# ── UI construction ───────────────────────────────────────────────────────────

func _build_ui() -> void:
	# Full-screen black fade rect — starts transparent.
	_fade_rect           = ColorRect.new()
	_fade_rect.color     = Color(0.0, 0.0, 0.0, 0.0)
	_fade_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade_rect)

	# Choice panel — hidden until fade completes.
	_choice_root = Control.new()
	_choice_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_choice_root.visible = false
	add_child(_choice_root)

	# Dark semi-transparent background behind text.
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.75)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_choice_root.add_child(bg)

	# Centre container.
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 30)
	vbox.set_anchors_preset(Control.PRESET_CENTER)
	vbox.offset_left   = -360.0
	vbox.offset_right  =  360.0
	vbox.offset_top    = -200.0
	vbox.offset_bottom =  200.0
	_choice_root.add_child(vbox)
	if TouchControls.is_touch_platform():
		# Bigger text and 72-high buttons need the whole 720 canvas, and the touch layer must not
		# sit over the two choices.
		vbox.add_theme_constant_override("separation", 12)
		vbox.offset_top = -310.0
		vbox.offset_bottom = 310.0
		get_tree().call_group(TouchControls.GROUP, "set_enabled", false)

	# Title.
	var title := Label.new()
	title.text = "You have survived the Purgatory."
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Color(1.0, 0.9, 0.6, 1.0))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(title)

	# Flavour text.
	var flavour := Label.new()
	flavour.text = "The way out stands before you — a tear in the dark.\nBut the depths below whisper of greater power yet."
	flavour.add_theme_font_size_override("font_size", 18)
	flavour.add_theme_color_override("font_color", Color(0.75, 0.7, 0.65, 1.0))
	flavour.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	flavour.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(flavour)

	# Spacer.
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, 20.0)
	vbox.add_child(spacer)

	# Leave button.
	var leave_btn := Button.new()
	leave_btn.text = "Return to your old life"
	leave_btn.add_theme_font_size_override("font_size", 22)
	leave_btn.custom_minimum_size = Vector2(320.0, 60.0)
	leave_btn.pressed.connect(_on_leave_pressed)
	vbox.add_child(leave_btn)

	# Legendary button.
	var legend_btn := Button.new()
	legend_btn.text = "Stay Below — Legendary Mode"
	legend_btn.add_theme_font_size_override("font_size", 22)
	legend_btn.custom_minimum_size = Vector2(320.0, 60.0)
	legend_btn.pressed.connect(_on_legendary_pressed)
	vbox.add_child(legend_btn)

	# Description labels under each button.
	var leave_desc := Label.new()
	leave_desc.text = "Complete this run and return to the Alchemist's Lab."
	leave_desc.add_theme_font_size_override("font_size", 13)
	leave_desc.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 1.0))
	leave_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(leave_desc)

	var legend_desc := Label.new()
	legend_desc.text = "No more portals. Farm deeper. Survive as long as you can."
	legend_desc.add_theme_font_size_override("font_size", 13)
	legend_desc.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 1.0))
	legend_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(legend_desc)

	_wire_button_clicks()


func _wire_button_clicks() -> void:
	if has_node("/root/AudioManager"):
		AudioManager.wire_click_sounds(self)


# ── Fade sequence ─────────────────────────────────────────────────────────────

func _run_fade() -> void:
	var elapsed : float = 0.0
	while elapsed < FADE_DURATION:
		elapsed += get_process_delta_time()
		_fade_rect.color.a = clampf(elapsed / FADE_DURATION, 0.0, 1.0)
		await get_tree().process_frame
	_fade_rect.color.a = 1.0
	_fade_done = true
	_choice_root.visible = true
	# Give focus to the first button so gamepad A / Enter works immediately.
	for child in _choice_root.get_children():
		if child is VBoxContainer:
			for node in child.get_children():
				if node is Button:
					node.grab_focus()
					break
			break


# ── Button callbacks ──────────────────────────────────────────────────────────

func _on_leave_pressed() -> void:
	if _exiting:
		return
	_exiting = true
	# Record the completion.
	if SaveManager.current_profile_is_valid():
		var prev : int = int(SaveManager.current_profile.get("dungeon_completions", 0))
		SaveManager.current_profile["dungeon_completions"] = prev + 1
		SaveManager.save_profile()

	if has_node("/root/CodexManager"):
		CodexManager.increment_completions()

	# Clean up run systems (including globes, which used to keep ticking in the Alchemist).
	RunLifecycle.end_run_cleanup()

	get_tree().change_scene_to_file(ALCHEMIST_SCENE)
	# This screen is a child of the root, so it survives the scene change; without this it
	# stayed on top of the Alchemist with live buttons (double-counting completions and, via
	# "Stay Below", restarting the day clock inside a menu).
	queue_free()


func _on_legendary_pressed() -> void:
	if _exiting:
		return
	_exiting = true
	# Enter legendary mode — run continues indefinitely.
	if has_node("/root/GameClock"):
		GameClock.enter_legendary_mode()

	# Reinforcements were stopped when the run ended; Legendary Mode needs them back.
	for spawner in get_tree().get_nodes_in_group("enemy_spawner"):
		if spawner.has_method("resume_spawning"):
			spawner.resume_spawning()

	# Disable the portal so it can't be re-entered.
	if is_instance_valid(_portal_manager) and _portal_manager.has_method("disable_portal"):
		_portal_manager.disable_portal()

	# Unfreeze the scene tree (GameClock.enter_legendary_mode already resumes the clock,
	# but the scene tree may still be paused from run_ended's pause() call).
	get_tree().paused = false

	queue_free()
