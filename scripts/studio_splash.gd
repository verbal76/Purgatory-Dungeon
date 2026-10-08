# ==============================================================================
# File Name: studio_splash.gd
# Path: res://scripts/studio_splash.gd
# Description: Hot Attic Games studio splash. This is the project's MAIN SCENE, so it runs on
#   every cold launch and only then (returning to the main menu loads MainMenu.tscn directly):
#
#       app start -> HOT ATTIC GAMES splash -> MainMenu (the game's own title) -> normal game
#
#   STANDING STUDIO REQUIREMENT (see CLAUDE.md): the artwork is the owner-supplied
#   Hot_Attic_Games_Master_Logo_ALPHA_FINAL.png, shown as-is: never redrawn, cropped, stretched or
#   replaced. It is looked up by that exact file name in LOGO_DIRS.
#
#   The card fades in, holds, fades out (TOTAL_SECONDS, 2-3 s) while the next scene loads on a
#   background thread, so it masks real start-up work instead of adding dead time. It can never
#   strand the player: a missing logo skips the card, a failed or slow scene load falls back to a
#   plain scene change, and a failsafe timer ends the card regardless.
# ==============================================================================
class_name StudioSplash
extends Control

signal finished

const LOGO_FILENAME : String = "Hot_Attic_Games_Master_Logo_ALPHA_FINAL.png"
# Where the file may live (project root first). Searched in order, by the exact file name.
const LOGO_DIRS : Array[String] = ["", "branding/", "assets/", "Music & background images/"]
const NEXT_SCENE : String = "res://scenes/MainMenu.tscn"
const UpdateGate = preload("res://scripts/update_gate.gd")

const FADE_IN_SECONDS  : float = 0.5
const HOLD_SECONDS     : float = 1.4
const FADE_OUT_SECONDS : float = 0.5
const TOTAL_SECONDS    : float = FADE_IN_SECONDS + HOLD_SECONDS + FADE_OUT_SECONDS
const FAILSAFE_SECONDS : float = 10.0   # leave the card no matter what after this long
const SAFE_MARGIN      : float = 0.08   # fraction of each side kept clear around the logo
# Near-black, warm: the same colour is used for the engine boot screen (project.godot) so there is
# no flash between the OS window appearing and the card.
const BACKGROUND : Color = Color(0.035, 0.03, 0.03, 1.0)

## True once the card has been shown in this process (cold launch only, never replayed).
static var shown_this_launch : bool = false

# Test hooks. Production leaves them at their defaults.
var next_scene_path       : String    = NEXT_SCENE
var change_scene_on_finish : bool     = true
var logo_override         : Texture2D = null
var logo_path_override    : String    = ""   # use this logo path instead of the canonical lookup
var navigate              : Callable  = Callable()   # called with (PackedScene or null, path) instead of changing scene
var update_gate           : Node      = null         # the automatic update at cold launch (null: off, e.g. tests and desktop)

var logo_rect      : TextureRect = null
var skipped        : bool        = false   # no logo available: the card was skipped
var _done          : bool        = false
var _tween         : Tween       = null


## The res:// path of the canonical logo, or "" if it is not in the project.
static func resolve_logo_path() -> String:
	for dir in LOGO_DIRS:
		var path : String = "res://" + dir + LOGO_FILENAME
		if ResourceLoader.exists(path):
			return path
	return ""


## Largest rect with the artwork's aspect ratio that fits inside `area`, centred. Never crops
## or stretches: the whole image is always visible.
static func fit_rect(tex_size: Vector2, area: Rect2) -> Rect2:
	if tex_size.x <= 0.0 or tex_size.y <= 0.0 or area.size.x <= 0.0 or area.size.y <= 0.0:
		return Rect2(area.position, Vector2.ZERO)
	var s : float = minf(area.size.x / tex_size.x, area.size.y / tex_size.y)
	var size : Vector2 = tex_size * s
	return Rect2(area.position + (area.size - size) * 0.5, size)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Cold launch only: if the card was already shown in this process, go straight on.
	if change_scene_on_finish and shown_this_launch:
		skipped = true
		_finish.call_deferred()
		return

	if change_scene_on_finish:
		_start_update_check()   # cold launch: the check starts now and runs behind the card

	var tex : Texture2D = logo_override
	if tex == null:
		var path : String = logo_path_override if logo_path_override != "" else resolve_logo_path()
		if path != "" and ResourceLoader.exists(path):
			tex = load(path) as Texture2D
	if tex == null:
		push_warning("StudioSplash: %s not found in the project - skipping the studio card." % LOGO_FILENAME)
		skipped = true
		_finish.call_deferred()
		return

	var bg := ColorRect.new()
	bg.name = "Background"
	bg.color = BACKGROUND
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	logo_rect = TextureRect.new()
	logo_rect.name = "Logo"
	logo_rect.texture = tex
	logo_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo_rect.stretch_mode = TextureRect.STRETCH_SCALE   # the rect is already the right aspect
	logo_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	logo_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	logo_rect.modulate.a = 0.0
	add_child(logo_rect)
	resized.connect(_layout_logo)
	_layout_logo()

	if change_scene_on_finish:
		shown_this_launch = true
		# Start-up work behind the card: load the next scene on a background thread.
		ResourceLoader.load_threaded_request(next_scene_path)

	_tween = create_tween()
	_tween.tween_property(logo_rect, "modulate:a", 1.0, FADE_IN_SECONDS)
	_tween.tween_interval(HOLD_SECONDS)
	_tween.tween_property(logo_rect, "modulate:a", 0.0, FADE_OUT_SECONDS)
	_tween.tween_callback(_finish)

	get_tree().create_timer(FAILSAFE_SECONDS).timeout.connect(_finish)


## Cold launch: the update check starts now, in the background, while the card plays (the existing OTA client; no-op where
## there is none). See update_gate.gd.
func _start_update_check() -> void:
	var gate : Node = UpdateGate.new()
	gate.name = "UpdateGate"
	add_child(gate)
	if gate.start():
		update_gate = gate
	else:
		gate.queue_free()


func _layout_logo() -> void:
	if logo_rect == null or logo_rect.texture == null:
		return
	var margin : Vector2 = size * SAFE_MARGIN
	var area := Rect2(margin, size - margin * 2.0)
	var r : Rect2 = fit_rect(logo_rect.texture.get_size(), area)
	logo_rect.position = r.position
	logo_rect.size = r.size


func _finish() -> void:
	if _done:
		return
	_done = true
	if _tween != null and _tween.is_valid():
		_tween.kill()
	finished.emit()
	if not change_scene_on_finish or not is_inside_tree():
		return
	if update_gate != null:
		await update_gate.settle(self)   # tells the player about a found update and restarts for it; otherwise returns at once
	_go_to_next_scene()


# Hands over to the next scene. Prefers the copy already loaded behind the card; if that load is
# missing, failed or still running it falls back to a normal scene change, so the player is never
# left on the splash.
func _go_to_next_scene() -> void:
	var packed : PackedScene = null
	if ResourceLoader.load_threaded_get_status(next_scene_path) == ResourceLoader.THREAD_LOAD_LOADED:
		packed = ResourceLoader.load_threaded_get(next_scene_path) as PackedScene
	if navigate.is_valid():
		navigate.call(packed, next_scene_path)
		return
	var tree := get_tree()
	if packed != null:
		tree.change_scene_to_packed(packed)
	else:
		tree.change_scene_to_file(next_scene_path)
