# ==============================================================================
# File Name: controller_glyphs.gd
# Path: res://scripts/controller_glyphs.gd
#
# Description:
#   Which on-screen button art a gamepad prompt shows (Steam Deck / Steam Machine requirement: glyphs must match the input in use,
#   and keyboard / mouse glyphs must not show while a controller is). Static helpers, no node, no class_name (use through
#   `const Glyphs := preload("res://scripts/controller_glyphs.gd")`).
#
#   - token_for_action(action): the controller button an input action is bound to RIGHT NOW (read from the InputMap, so a
#     remap in Options is followed), as a token such as "a", "rb", "rt", "dpad_down".
#   - style_for_joy_name(name): which label set to draw - Xbox (LB / RB / LT / RT) or Steam Deck / Steam Controller (L1 / R1 / L2 / R2).
#   - texture(token, style): the art, assets/ui/glyphs/<token>.png (original; tools/make_controller_glyphs.py draws them).
#   - text(token, style): the same button as words, for places that cannot show a picture.
# ==============================================================================
extends RefCounted

enum Style { XBOX, DECK }

const DIR := "res://assets/ui/glyphs/"

# Godot's joypad button indices (SDL game-controller layout).
const BUTTON_TOKENS := {
	0: "a", 1: "b", 2: "x", 3: "y", 4: "view", 6: "menu", 7: "l3", 8: "r3", 9: "lb", 10: "rb",
	11: "dpad_up", 12: "dpad_down", 13: "dpad_left", 14: "dpad_right",
}
# Trigger axes (the sticks have no single-button glyph).
const AXIS_TOKENS := {4: "lt", 5: "rt"}

# The Deck / Steam Controller label for the shoulder buttons and triggers.
const DECK_ALIASES := {"lb": "l1", "rb": "r1", "lt": "l2", "rt": "r2"}

const TEXT_XBOX := {
	"a": "A", "b": "B", "x": "X", "y": "Y", "view": "View", "menu": "Menu", "l3": "L3", "r3": "R3", "lb": "LB", "rb": "RB",
	"lt": "LT", "rt": "RT", "dpad_up": "D-pad Up", "dpad_down": "D-pad Down", "dpad_left": "D-pad Left", "dpad_right": "D-pad Right",
}

static var _cache: Dictionary = {}


## Xbox or Deck labels from a controller's reported name. On a Steam Deck (Steam sets SteamDeck=1) its own controller is the
## input unless another brand of pad is clearly the one in use.
static func style_for_joy_name(joy_name: String) -> int:
	var n: String = joy_name.to_lower()
	if n.contains("steam deck") or n.contains("steam controller") or n.contains("neptune") or n.contains("jupiter"):
		return Style.DECK
	if OS.get_environment("SteamDeck") == "1" and not (n.contains("xbox") and not n.contains("360")) \
			and not n.contains("dualsense") and not n.contains("dualshock") and not n.contains("playstation") and not n.contains("nintendo"):
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


## Resolve a token for a style (shoulders/triggers carry the Deck's own labels there).
static func resolved_token(token: String, style: int) -> String:
	if style == Style.DECK and DECK_ALIASES.has(token):
		return DECK_ALIASES[token]
	return token


static func texture(token: String, style: int) -> Texture2D:
	var t: String = resolved_token(token, style)
	if t == "":
		return null
	if not _cache.has(t):
		var path: String = DIR + t + ".png"
		_cache[t] = load(path) if ResourceLoader.exists(path) else null
	return _cache[t] as Texture2D


static func text(token: String, style: int) -> String:
	var t: String = resolved_token(token, style)
	var deck_text := {"l1": "L1", "r1": "R1", "l2": "L2", "r2": "R2"}
	if deck_text.has(t):
		return deck_text[t]
	return TEXT_XBOX.get(t, t.to_upper())


const AXIS_TEXT := {0: "Left Stick %s", 1: "Left Stick %s", 2: "Right Stick %s", 3: "Right Stick %s"}


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
