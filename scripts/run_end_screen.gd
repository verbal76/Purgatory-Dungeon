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
var _first_button   : Button    = null
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
	# Full-screen fade rect - starts transparent, ends opaque near-black.
	_fade_rect           = ColorRect.new()
	_fade_rect.color     = Color(PUI.VOID, 0.0)
	_fade_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade_rect)

	# Choice panel - hidden until fade completes.
	_choice_root = Control.new()
	_choice_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_choice_root.visible = false
	add_child(_choice_root)

	_choice_root.add_child(PUI.background("void"))

	var touch: bool = TouchControls.is_touch_platform()
	if touch:
		# The touch layer must not sit over the two choices.
		get_tree().call_group(TouchControls.GROUP, "set_enabled", false)

	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_choice_root.add_child(centre)

	var panel := PUI.panel("veil")
	panel.name = "ChoicePanel"
	panel.custom_minimum_size = Vector2(680.0, 0.0)
	centre.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", PUI.S3 if touch else PUI.S4)
	panel.add_child(vbox)

	# Title.
	var title := PUI.label("You have survived the Purgatory.", "ScreenTitle")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(title)

	# Flavour text.
	var flavour := PUI.label("The way out stands before you \u2014 a tear in the dark.\nBut the depths below whisper of greater power yet.", "SecondaryLabel")
	flavour.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	flavour.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(flavour)

	vbox.add_child(PUI.divider())

	# Leave: the main action.
	var leave_btn := PUI.button("Return to your old life", "primary")
	leave_btn.name = "LeaveButton"
	leave_btn.pressed.connect(_on_leave_pressed)
	vbox.add_child(leave_btn)
	vbox.add_child(_desc_label("Complete this run and return to the Alchemist's Lab."))

	# Legendary: the alternative.
	var legend_btn := PUI.button("Stay Below \u2014 Legendary Mode")
	legend_btn.name = "LegendaryButton"
	legend_btn.pressed.connect(_on_legendary_pressed)
	vbox.add_child(legend_btn)
	vbox.add_child(_desc_label("No more portals. Farm deeper. Survive as long as you can."))

	_first_button = leave_btn
	_wire_button_clicks()


func _desc_label(text: String) -> Label:
	var l := PUI.label(text, "MetaLabel")
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


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
	if is_instance_valid(_first_button):
		_first_button.grab_focus()


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
