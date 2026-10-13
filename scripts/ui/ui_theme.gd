# ==============================================================================
# File Name: ui_theme.gd
# Path: res://scripts/ui/ui_theme.gd
# Autoload Name: UiTheme
# Description: Applies the Purgatory UI theme (see PUI) to the root window so every scene, dialog and
#              popup inherits one interface language.
#
#              A CanvasLayer is not a Control, so a Control whose direct parent is a CanvasLayer (HUDs, overlays,
#              pause menu...) does NOT inherit the root window's theme and would render as default engine UI.
#              Such top-level controls get the shared theme assigned as they enter the tree.
# ==============================================================================
extends Node


func _enter_tree() -> void:
	var tree := get_tree()
	tree.root.theme = PUI.theme()
	tree.node_added.connect(_on_node_added)


func _on_node_added(n: Node) -> void:
	if n is Control and n.get_parent() is CanvasLayer and (n as Control).theme == null:
		(n as Control).theme = PUI.theme()


# ── Scene arrival wipe ───────────────────────────────────────────────────────────
# Every scene change (menu -> character select -> dungeon -> menu) used to cut hard. A black cover now clears over a quarter of a second
# when a new scene arrives. Detected here, so no caller of change_scene_to_file() needs to know. Skips the very first scene (the studio
# splash does its own fade) and honours reduced motion (Screen Shake 0 = no wipe).
const WIPE_SECONDS := 0.26
var _wipe_layer : CanvasLayer = null
var _wipe : ColorRect = null
var _last_scene : Node = null
var _wipe_tween : Tween = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_wipe_layer = CanvasLayer.new()
	_wipe_layer.layer = 120   # above everything but the loading screen's own layer is irrelevant: it is a child of the new scene
	_wipe_layer.name = "SceneWipe"
	add_child(_wipe_layer)
	_wipe = ColorRect.new()
	_wipe.color = Color(0.03, 0.02, 0.02, 1.0)
	_wipe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_wipe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wipe.modulate.a = 0.0
	_wipe.visible = false
	_wipe_layer.add_child(_wipe)


func _process(_delta: float) -> void:
	var cs : Node = get_tree().current_scene
	if cs == _last_scene:
		return
	var first : bool = _last_scene == null
	_last_scene = cs
	if first or cs == null:
		return
	var s : float = 1.0
	if has_node("/root/SettingsManager"):
		s = float(get_node("/root/SettingsManager").get_setting("ShakeSlider", 50.0))
	if s <= 0.0 or OS.get_environment("PURGATORY_NO_WIPE") == "1":
		return
	if _wipe_tween != null and _wipe_tween.is_valid():
		_wipe_tween.kill()
	_wipe.visible = true
	_wipe.modulate.a = 1.0
	_wipe_tween = create_tween()
	_wipe_tween.tween_property(_wipe, "modulate:a", 0.0, WIPE_SECONDS).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_wipe_tween.tween_callback(_wipe.hide)
