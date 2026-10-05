# ==============================================================================
# File Name: hud_vitals.gd
# Path: res://scripts/ui/hud_vitals.gd
# Description: The top-left vitals of the in-run HUD, shared by the Barbarian and the Mage:
#       [ health bar (PUIBar, crimson) ]  142 / 150
#       [ ability bar (PUIBar, ember)  ]  Rapid attack  3.2s
#   Text is only rewritten when the displayed value changes (the players call set_health / set_ability from
#   physics ticks), and nothing here allocates per call once built.
#   Layout: anchored top-left, offset by HudKit.origin() (safe area on phones); never intercepts input.
# ==============================================================================
class_name HudVitals
extends Control

enum Ability { READY, CHARGING, RELEASE, ACTIVE, COOLDOWN }

const LOW_FRACTION := 0.25   # at or below this the value turns blood-red (colour + number, never colour alone)

var health_bar: PUIBar = null
var health_label: Label = null
var ability_bar: PUIBar = null
var ability_label: Label = null

var _box: VBoxContainer = null
var _hp_cur: int = -1
var _hp_max: int = -1
var _low: bool = false
var _mode: int = -1
var _mode_n: int = -1


func _init() -> void:
	name = "Vitals"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", HudKit.ROW_GAP)
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_box)

	var hp_row := HBoxContainer.new()
	hp_row.custom_minimum_size.y = HudKit.ROW_HEALTH_H
	hp_row.add_theme_constant_override("separation", PUI.S3)
	_box.add_child(hp_row)
	health_bar = PUIBar.make(Vector2(HudKit.BAR_W, HudKit.HEALTH_BAR_H), PUI.BLOOD_BRIGHT)
	health_bar.fill_bottom = PUI.BLOOD
	health_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hp_row.add_child(health_bar)
	health_label = HudKit.value_label("")
	health_label.custom_minimum_size.x = 120.0   # "1000 / 1000" must not nudge the cluster
	health_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_row.add_child(health_label)

	var ab_row := HBoxContainer.new()
	ab_row.custom_minimum_size.y = HudKit.ROW_ABILITY_H
	ab_row.add_theme_constant_override("separation", PUI.S3)
	_box.add_child(ab_row)
	ability_bar = PUIBar.make(Vector2(HudKit.BAR_W, HudKit.ABILITY_BAR_H), PUI.EMBER)
	ability_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ab_row.add_child(ability_bar)
	ability_label = HudKit.caption_label("")
	ability_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ab_row.add_child(ability_label)


func _ready() -> void:
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_place):
		vp.size_changed.connect(_place)
	_place()


func _place() -> void:
	_box.position = HudKit.origin(get_viewport())


func set_health(current: float, max_val: float) -> void:
	var frac: float = clampf(current / max_val, 0.0, 1.0) if max_val > 0.0 else 0.0
	health_bar.set_value(frac)
	var c: int = int(current)
	var m: int = int(max_val)
	if c != _hp_cur or m != _hp_max:
		_hp_cur = c
		_hp_max = m
		health_label.text = "%d / %d" % [c, m]
	var low: bool = frac <= LOW_FRACTION
	if low != _low:
		_low = low
		if low:
			health_label.add_theme_color_override("font_color", PUI.BLOOD_BRIGHT)
		else:
			health_label.remove_theme_color_override("font_color")


## frac: 0..1 fill. mode: Ability.*. secs: remaining seconds (ACTIVE: shown to 0.1 s, COOLDOWN: whole seconds).
func set_ability(frac: float, mode: int, secs: float = 0.0) -> void:
	ability_bar.set_value(frac)
	var n: int = 0
	if mode == Ability.ACTIVE:
		n = int(round(secs * 10.0))
	elif mode == Ability.COOLDOWN:
		n = int(round(secs))
	if mode == _mode and n == _mode_n:
		return
	if mode != _mode:
		match mode:
			Ability.COOLDOWN:
				ability_bar.set_fill(PUI.EMBER_DEEP)
			Ability.RELEASE, Ability.ACTIVE:
				ability_bar.set_fill(PUI.EMBER_BRIGHT)
			_:
				ability_bar.set_fill(PUI.EMBER)
	_mode = mode
	_mode_n = n
	match mode:
		Ability.CHARGING:
			ability_label.text = "Charging..."
		Ability.RELEASE:
			ability_label.text = "Release!"
		Ability.ACTIVE:
			ability_label.text = "Rapid attack  %.1fs" % (float(n) / 10.0)
		Ability.COOLDOWN:
			ability_label.text = "Cooldown  %ds" % n
		_:
			ability_label.text = ""
