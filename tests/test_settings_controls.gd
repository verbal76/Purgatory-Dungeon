extends Node
## A damaged settings.json must never strip default key bindings, and valid remaps must apply.

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _key_events(action: String) -> int:
	var n := 0
	for e in InputMap.action_get_events(action):
		if e is InputEventKey or e is InputEventMouseButton:   # attack/block default to mouse buttons
			n += 1
	return n


func _has_key(action: String, keycode: int) -> bool:
	for e in InputMap.action_get_events(action):
		if e is InputEventKey and (int(e.keycode) == keycode or int(e.physical_keycode) == keycode):
			return true
	return false


func _ready() -> void:
	var before := {}
	for a in ["jump", "attack", "move_left", "move_forward", "kick", "block", "move_back"]:
		before[a] = _key_events(a)
		_check(before[a] > 0, "%s starts with a key binding" % a)

	SettingsManager.gameplay_settings["controls"] = {
		"jump":         {"keyboard": {"type": "bogus"}},                    # unknown type
		"attack":       [],                                                 # wrong shape
		"move_left":    {"keyboard": {"type": "key"}},                      # key with no codes
		"move_forward": 5,                                                  # wrong shape
		"kick":         {"keyboard": {"type": "key", "keycode": "abc", "physical_keycode": null}},   # non-numeric
		"nonexistent_action": {"keyboard": {"type": "key", "keycode": 65}},
		"move_back":    {"keyboard": {"type": "key", "keycode": KEY_Z, "physical_keycode": KEY_Z}},  # valid remap
		"block":        {"keyboard": "not a dict"},
	}
	SettingsManager._apply_custom_controls()
	for a in ["jump", "attack", "move_left", "move_forward", "kick", "block"]:
		_check(_key_events(a) == before[a], "damaged entry for %s keeps its default key bindings (%d -> %d)" % [a, before[a], _key_events(a)])
	_check(_has_key("move_back", KEY_Z), "a valid remap is applied")

	SettingsManager.gameplay_settings["controls"] = "garbage"
	SettingsManager._apply_custom_controls()
	_check(_has_key("move_back", KEY_Z), "non-dictionary controls section is ignored without error")

	print("test_settings_controls: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
