# ==============================================================================
# File Name: glyph_prompt.gd
# Path: res://scripts/glyph_prompt.gd
#
# Description:
#   One prompt line with a button in it ("Press [A] to stop"). On a controller the button is its art (original glyphs, in the Xbox or
#   Steam Deck / Steam Controller label set of the pad in use); on keyboard / mouse it is the key's name; on touch the on-screen
#   control's name. It follows InputManager live, so switching input device swaps the line without rebuilding the screen.
#
#   Usage (the template's "%g" marks where the button goes):
#       var line: HBoxContainer = GlyphPromptScript.new()
#       line.setup("Press %g to stop", "ui_accept", "SecondaryLabel")
#       parent.add_child(line)
# ==============================================================================
extends HBoxContainer

const Glyphs := preload("res://scripts/controller_glyphs.gd")

var action: String = ""
var bracket_keys: bool = false   # keyboard: show "[E]" instead of "E"
var icon_px: float = 30.0

var _before: Label = null
var _icon: TextureRect = null
var _key: Label = null
var _after: Label = null


## `template` has one "%g"; text before it and after it become labels, the button goes between them.
func setup(template: String, p_action: String, variation: String = "SecondaryLabel", p_icon_px: float = 30.0, p_bracket_keys: bool = false) -> void:
	action = p_action
	icon_px = p_icon_px
	bracket_keys = p_bracket_keys
	alignment = BoxContainer.ALIGNMENT_CENTER
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", int(PUI.S2))
	var parts: PackedStringArray = template.split("%g", true, 1)
	_before = PUI.label(parts[0].strip_edges(), variation)
	_icon = TextureRect.new()
	_icon.custom_minimum_size = Vector2(icon_px, icon_px)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_key = PUI.label("", variation)
	_after = PUI.label(parts[1].strip_edges() if parts.size() > 1 else "", variation)
	for l: Label in [_before, _key, _after]:
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_before.visible = _before.text != ""
	_after.visible = _after.text != ""
	add_child(_before)
	add_child(_icon)
	add_child(_key)
	add_child(_after)
	_refresh()


func _ready() -> void:
	InputManager.input_method_changed.connect(_on_changed)
	InputManager.controller_style_changed.connect(_on_changed)


func _on_changed(_v: Variant = null) -> void:
	_refresh()


## Which of the two forms is showing (read by tests): "icon" or "text".
func form() -> String:
	return "icon" if _icon != null and _icon.visible else "text"


func _refresh() -> void:
	if _icon == null:
		return
	var tex: Texture2D = null
	if InputManager.is_gamepad():
		tex = Glyphs.texture(Glyphs.token_for_action(action), InputManager.controller_style)
	_icon.texture = tex
	_icon.visible = tex != null
	_key.visible = tex == null
	if tex == null:
		var name_text: String = InputManager.glyph(action)
		_key.text = "[%s]" % name_text if bracket_keys and not InputManager.is_touch() else name_text
