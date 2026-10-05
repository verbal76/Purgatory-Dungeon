# Dev utility (not shipped): renders ONE in-run overlay on a fake "dungeon" backdrop so it can be
# screenshotted without the full game. Pick it with the OVERLAY env var:
#   buff_common | buff_rare | buff_legendary | buff_hud | died | runend | chest | chest_locked
#   portal_hint | portal_announce | traps | globe_curse | globe_blessing
# Used with tools/ui_shot.gd:
#   OVERLAY=died ... --script tools/ui_shot.gd -- res://tools/overlay_preview.tscn out.png 60
extends Control

const FAKE_BUFFS := {
	"common": {"name": "Thick Skin", "ranking": "common", "description": "Gain +20 maximum health.", "tradeoff": null},
	"rare": {"name": "Glass Cannon", "ranking": "rare", "description": "Deal 30% more damage with every attack.",
		"tradeoff": {"description": "-25% movement speed."}},
	"legendary": {"name": "Brute Apocalypse", "ranking": "legendary", "description": "Become the living flame that the dungeon fears.",
		"tradeoff": {"description": "-15 max health."}},
}

var _which: String = ""


func _ready() -> void:
	_which = OS.get_environment("OVERLAY")
	# fake dungeon backdrop: warm stone with a few darker blocks
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.20, 0.17, 0.14)
	add_child(bg)
	for i in 9:
		var r := ColorRect.new()
		r.color = Color(0.10 + 0.02 * (i % 3), 0.085, 0.07)
		r.position = Vector2(60 + i * 150, 120 + (i % 4) * 90)
		r.size = Vector2(120, 260 - (i % 3) * 40)
		bg.add_child(r)
	call_deferred("_setup")


func _setup() -> void:
	match _which:
		"buff_common", "buff_rare", "buff_legendary":
			var kind: String = _which.trim_prefix("buff_")
			BuffManager._slot_pool = [FAKE_BUFFS[kind]]
			BuffManager._slot_index = 0
			BuffManager._show_slot_ui()
		"buff_hud":
			BuffManager._hud_layer.visible = true
			BuffManager._active_buffs = [
				{"name": "Thick Skin", "description": "Gain +20 maximum health.", "duration_type": "permanent"},
				{"name": "Swift Feet", "description": "+10% movement speed.", "duration_type": "permanent"},
				{"name": "Berserk", "description": "+40% damage.", "duration_type": "seconds", "_remaining": 74.0, "_duration_type": "seconds", "value": 0.4},
				{"name": "Heavy Legs", "description": "-25% movement speed.", "duration_type": "days", "_remaining": 2.0, "_duration_type": "days", "value": -0.25},
			]
			BuffManager._hud_dirty = true
		"died":
			var s := CanvasLayer.new()
			s.set_script(load("res://scripts/you_died_screen.gd"))
			add_child(s)
			# jump past the fade: overlay mostly opaque, title pulsing, prompts fully shown
			s._phase = 1
			s._timer = 0.25
			s._prompt_timer = 3.0
			s._overlay.color.a = 0.9
		"runend":
			var s2 := CanvasLayer.new()
			s2.set_script(load("res://scripts/run_end_screen.gd"))
			add_child(s2)
			s2.setup(null)
			s2._fade_rect.color.a = 1.0
			s2._choice_root.visible = true
			s2._first_button.grab_focus()
		"chest", "chest_locked":
			SaveManager.current_profile = {"keys": {"bronze": 1 if _which == "chest" else 0, "silver": 0, "gold": 0}}
			var c := StaticBody3D.new()
			c.set_script(load("res://scripts/chest.gd"))
			add_child(c)
			c._player_in_range = true
			c._refresh_prompt()
			c._prompt_layer.visible = true
		"portal_hint", "portal_announce":
			var p := Node3D.new()
			p.set_script(load("res://scripts/portal_manager.gd"))
			add_child(p)
			if _which == "portal_hint":
				p._show_not_ready_hint(7)
			else:
				p._show_announce(Vector3.ZERO)
		"traps":
			var t := CanvasLayer.new()
			t.set_script(load("res://scripts/trap_banner_hud.gd"))
			add_child(t)
			t.show_trap("reversed_controls", 30.0)
			t.show_trap("acid_pool", 12.0)
			t.show_trap("heavy_gravity", -1.0, 2)
			t.show_trap("jumpscare", 0.0)
		"globe_curse":
			GlobeManager._set_alert(GlobeManager.ALERT_TEXT, GlobeManager.ALERT_COLOR)
			GlobeManager.show_globe_alert()
		"globe_blessing":
			GlobeManager.announce_collection({"name": "Vitality Surge", "value": 25})
	if _which.begins_with("globe"):
		GlobeManager._alert_timer = 0.6   # fully faded in


func _process(_delta: float) -> void:
	if _which.begins_with("globe"):
		GlobeManager._alert_timer = 0.8   # hold the alert fully visible for the screenshot
