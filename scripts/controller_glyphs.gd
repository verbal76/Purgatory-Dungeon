# ==============================================================================
# File Name: controller_glyphs.gd
# Path: res://scripts/controller_glyphs.gd
#
# Description:
#   Which on-screen button art a prompt shows (Steam Deck / Steam Machine requirement: glyphs must match the input in use, and keyboard / mouse glyphs must not show
#   while a controller is). Static helpers, no node, no class_name (use through `const Glyphs := preload("res://scripts/controller_glyphs.gd")`).
#
#   - token_for_action(action): the controller button an input action is bound to RIGHT NOW (read from the InputMap, so a remap in Options is followed), as a token
#     that names the button by POSITION: "a" "b" "x" "y" (south, east, west, north), "lb" "rb" "lt" "rt", "l3" "r3", "view", "menu", "dpad_up" ...
#   - Style: which family of pad is in use. XBOX, PLAYSTATION and SWITCH draw the same position with that pad's own button (south = A / cross / B); DECK is the Steam
#     Deck / Steam Controller: Xbox-layout face buttons with the Deck's own L1 / R1 / L2 / R2 shoulders. style_for_joy_name() picks one from the pad's reported name; the
#     player can fix it in Options > Controls (InputManager.prompt_override).
#   - texture(token, style): the art, from the studio glyph library under assets/ui/glyphs/<family>/ (provenance and license: assets/ui/glyphs/NOTICE.md).
#   - key_texture(action): the keyboard / mouse key cap for an action (assets/ui/glyphs/keyboard/).
#   - text(token, style): the same button as words, for places that cannot show a picture.
# ==============================================================================
extends RefCounted

enum Style { XBOX, DECK, PLAYSTATION, SWITCH }

const DIR := "res://assets/ui/glyphs/"

# Godot's joypad button indices (SDL game-controller layout: positional).
const BUTTON_TOKENS := {
	0: "a", 1: "b", 2: "x", 3: "y", 4: "view", 6: "menu", 7: "l3", 8: "r3", 9: "lb", 10: "rb",
	11: "dpad_up", 12: "dpad_down", 13: "dpad_left", 14: "dpad_right",
}
# Trigger axes (the sticks have no single-button glyph).
const AXIS_TOKENS := {4: "lt", 5: "rt"}

const TEXT := {
	Style.XBOX: {"a": "A", "b": "B", "x": "X", "y": "Y", "lb": "LB", "rb": "RB", "lt": "LT", "rt": "RT", "l3": "L3", "r3": "R3", "view": "View", "menu": "Menu"},
	Style.DECK: {"a": "A", "b": "B", "x": "X", "y": "Y", "lb": "L1", "rb": "R1", "lt": "L2", "rt": "R2", "l3": "L3", "r3": "R3", "view": "View", "menu": "Menu"},
	Style.PLAYSTATION: {"a": "Cross", "b": "Circle", "x": "Square", "y": "Triangle", "lb": "L1", "rb": "R1", "lt": "L2", "rt": "R2", "l3": "L3", "r3": "R3", "view": "Share", "menu": "Options"},
	Style.SWITCH: {"a": "B", "b": "A", "x": "Y", "y": "X", "lb": "L", "rb": "R", "lt": "ZL", "rt": "ZR", "l3": "L Stick Click", "r3": "R Stick Click", "view": "-", "menu": "+"},
}
const DPAD_TEXT := {"dpad_up": "D-pad Up", "dpad_down": "D-pad Down", "dpad_left": "D-pad Left", "dpad_right": "D-pad Right"}
const AXIS_TEXT := {0: "Left Stick %s", 1: "Left Stick %s", 2: "Right Stick %s", 3: "Right Stick %s"}

# The Deck's own shoulders and triggers are drawn with the PlayStation shapes (their labels are L1 / R1 / L2 / R2).
const DECK_FROM_PS := ["lb", "rb", "lt", "rt"]

# Prompt keys that are not simply the first binding in the InputMap: the menu prompt means Escape (the Menu key is the first binding), accept means Enter.
const KEY_FOR_PROMPT := {"ui_menu": "esc", "ui_accept": "enter", "restart": "x"}
const KEY_NAMES := {"Escape": "esc", "Backspace": "backspace", "Control": "ctrl", "Ctrl": "ctrl", "Kp Enter": "enter", "Page Up": "page_up", "Page Down": "page_down"}

static var _cache: Dictionary = {}


## The pad family for a controller's reported name. On a Steam Deck (Steam sets SteamDeck=1) its own controller is the input unless another brand is clearly in use.
static func style_for_joy_name(joy_name: String) -> int:
	var n: String = joy_name.to_lower()
	if n.contains("steam deck") or n.contains("steam controller") or n.contains("neptune") or n.contains("jupiter"):
		return Style.DECK
	if n.contains("dualsense") or n.contains("dualshock") or n.contains("playstation") or n.contains("ps5") or n.contains("ps4") or n.contains("ps3") or n.contains("sony"):
		return Style.PLAYSTATION
	if n.contains("nintendo") or n.contains("switch") or n.contains("joy-con") or n.contains("joycon"):
		return Style.SWITCH
	if OS.get_environment("SteamDeck") == "1" and not (n.contains("xbox") and not n.contains("360")):
		return Style.DECK
	return Style.XBOX


## The controller button token an action is bound to, or "" when it has none (a stick direction, or no joypad event).
static func token_for_action(action: String) -> String:
	if action == "restart":   # the death screen's "start a new run" is the X button (it is not an InputMap action)
		return "x"
	if not InputMap.has_action(action):
		return ""
	for ev: InputEvent in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton:
			var tok: String = BUTTON_TOKENS.get((ev as InputEventJoypadButton).button_index, "")
			if tok != "":
				return tok
		elif ev is InputEventJoypadMotion:
			var axis_tok: String = AXIS_TOKENS.get((ev as InputEventJoypadMotion).axis, "")
			if axis_tok != "":
				return axis_tok
	return ""


## The art for a token in a style, or null.
static func texture(token: String, style: int) -> Texture2D:
	if token == "":
		return null
	var family: String = "xbox"
	match style:
		Style.PLAYSTATION:
			family = "ps5"
		Style.SWITCH:
			family = "switch"
		Style.DECK:
			family = "ps5" if token in DECK_FROM_PS else "xbox"
	return _load(DIR + family + "/" + token + ".png", DIR + "original/" + token + ".png")


## The key cap (or mouse button) for an action on keyboard / mouse, or null when the library has none for it.
static func key_texture(action: String) -> Texture2D:
	var name: String = key_name(action)
	return _load(DIR + "keyboard/" + name + ".png") if name != "" else null


## Library name of the key / mouse button an action uses ("e", "space", "mouse_left"...), "" when unknown.
static func key_name(action: String) -> String:
	if KEY_FOR_PROMPT.has(action):
		return KEY_FOR_PROMPT[action]
	if not InputMap.has_action(action):
		return ""
	for ev: InputEvent in InputMap.action_get_events(action):
		if ev is InputEventKey:
			var k := ev as InputEventKey
			var kc: int = k.keycode if k.keycode != 0 else k.physical_keycode
			var label: String = OS.get_keycode_string(kc as Key)
			return String(KEY_NAMES.get(label, label.to_lower().replace(" ", "_")))
		if ev is InputEventMouseButton:
			match (ev as InputEventMouseButton).button_index:
				MOUSE_BUTTON_LEFT:
					return "mouse_left"
				MOUSE_BUTTON_RIGHT:
					return "mouse_right"
				MOUSE_BUTTON_MIDDLE:
					return "mouse_middle"
	return ""


static func _load(path: String, fallback: String = "") -> Texture2D:
	if not _cache.has(path):
		var found: String = path if ResourceLoader.exists(path) else (fallback if fallback != "" and ResourceLoader.exists(fallback) else "")
		_cache[path] = _trimmed(load(found) as Texture2D) if found != "" else null
	return _cache[path] as Texture2D


## The library's canvases are square with transparent padding, so a wide key cap (Space, Enter) would be tiny at prompt size. Trim to the drawn part once
## (cached), so a prompt can size glyphs by height and let the width follow.
static func _trimmed(tex: Texture2D) -> Texture2D:
	if tex == null:
		return null
	var img: Image = tex.get_image()
	if img == null or img.is_empty():
		return tex
	var used: Rect2i = img.get_used_rect()
	if used.size.x <= 0 or used.size.y <= 0 or used.size == img.get_size():
		return tex
	var pad := Vector2i(1, 1)
	var region := Rect2i(used.position - pad, used.size + pad * 2).intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	var at := AtlasTexture.new()
	at.atlas = tex
	at.region = Rect2(region)
	return at


## The button in words for a style ("A", "R1", "Cross", "D-pad Down"...).
static func text(token: String, style: int) -> String:
	if DPAD_TEXT.has(token):
		return DPAD_TEXT[token]
	var table: Dictionary = TEXT.get(style, TEXT[Style.XBOX])
	return String(table.get(token, token.to_upper()))


## A controller input event in words ("A", "R1", "Left Stick Up", "RT"...): what a binding is called in Options. "" for other events.
static func joy_event_text(ev: InputEvent, style: int) -> String:
	if ev is InputEventJoypadButton:
		var tok: String = BUTTON_TOKENS.get((ev as InputEventJoypadButton).button_index, "")
		return text(tok, style) if tok != "" else "Button %d" % (ev as InputEventJoypadButton).button_index
	if ev is InputEventJoypadMotion:
		var m := ev as InputEventJoypadMotion
		if AXIS_TOKENS.has(m.axis):
			return text(AXIS_TOKENS[m.axis], style)
		if AXIS_TEXT.has(m.axis):
			var horizontal: bool = m.axis == 0 or m.axis == 2
			var dir: String = ("Right" if m.axis_value > 0.0 else "Left") if horizontal else ("Down" if m.axis_value > 0.0 else "Up")
			return AXIS_TEXT[m.axis] % dir
		return "Axis %d" % m.axis
	return ""
