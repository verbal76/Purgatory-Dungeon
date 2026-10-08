# ============================================================
#  FILE: trap_banner_hud.gd
#  PATH: res://scripts/trap_banner_hud.gd
#  USED BY: trap_manager.gd — call show_trap() in _apply_effect()
#  DESCRIPTION: Stacking bottom-of-screen banners that appear
#               whenever a trap is triggered. Each banner shows
#               the trap name and remaining duration.
#               Banners grow upward from the screen bottom —
#               multiple active traps cover progressively more
#               of the lower screen.
# ============================================================

extends CanvasLayer

# Traps are hostile, so every banner shares one semantic look (blood-edged iron plate, bone name, ember
# duration) instead of a colour per trap. The name is what tells traps apart.
const DISPLAY_NAMES : Dictionary = {
	"reversed_view"     : "Reversed view",
	"heavy_gravity"     : "Heavy gravity",
	"drunk"             : "Intoxicated",
	"reversed_controls" : "Controls reversed",
	"acid_pool"         : "Acid burns",
	"fireball_mine"     : "Fireball mine",
	"schizophrenia"     : "Hallucinations",
	"jumpscare"         : "Jumpscare",
}

const BANNER_WIDTH  : float = 420.0
const BANNER_HEIGHT : float = 48.0

# { banner_node : { "timer": float, "countdown": bool, "dur_label": Label } }
var _banners   : Dictionary = {}
var _vbox      : VBoxContainer = null


func _ready() -> void:
	layer = 6   # Above HUD (5), below loading screen / jumpscare

	var root_ctrl := Control.new()
	root_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	PUI.adopt(root_ctrl)   # a CanvasLayer child does not inherit the root theme
	add_child(root_ctrl)

	_vbox = VBoxContainer.new()
	# Anchor the VBox to the bottom centre of the screen: compact plates, never a full-width bar.
	# GROW_DIRECTION_BEGIN makes it grow UPWARD as children are added.
	_vbox.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_vbox.offset_left     = -BANNER_WIDTH * 0.5
	_vbox.offset_right    = BANNER_WIDTH * 0.5
	_vbox.offset_top      = -float(PUI.S6)
	_vbox.offset_bottom   = -float(PUI.S6)
	_vbox.grow_vertical   = Control.GROW_DIRECTION_BEGIN
	_vbox.mouse_filter    = Control.MOUSE_FILTER_IGNORE
	_vbox.add_theme_constant_override("separation", PUI.S2)
	root_ctrl.add_child(_vbox)


# ── Public API ────────────────────────────────────────────────────────────────
#
# effect      — trap effect ID (must match trap_manager.gd constants)
# dur_secs    — >0: live countdown; 0: instant effect (shows 4 s); <0: day-based (shows 5 s)
# day_count   — only used when dur_secs < 0 (e.g. effect_day_duration)

func show_trap(effect: String, dur_secs: float, day_count: int = 1) -> void:
	var display : String = DISPLAY_NAMES.get(effect, effect.to_upper().replace("_", " "))

	var dur_text    : String = ""
	var display_dur : float  = 0.0
	var countdown   : bool   = false

	if dur_secs > 0.0:
		dur_text    = "%ds" % int(ceili(dur_secs))
		display_dur = dur_secs
		countdown   = true
	elif dur_secs < 0.0:
		var plural  : String = "s" if day_count != 1 else ""
		dur_text    = "%d day%s" % [day_count, plural]
		display_dur = 5.0
		countdown   = false
	else:
		dur_text    = "Active!"
		display_dur = 4.0
		countdown   = false

	var banner    := _build_banner(display, dur_text)
	_vbox.add_child(banner)

	var dur_label : Label = banner.get_node_or_null("HBox/DurLabel")
	_banners[banner] = {
		"timer":     display_dur,
		"countdown": countdown,
		"dur_label": dur_label,
	}


func _process(delta: float) -> void:
	for banner in _banners.keys():
		if not is_instance_valid(banner):
			_banners.erase(banner)
			continue

		var data = _banners[banner]
		data["timer"] -= delta

		if data["countdown"] and data["dur_label"] != null:
			var t : float = maxf(0.0, data["timer"])
			(data["dur_label"] as Label).text = "%ds" % int(ceili(t))

		if data["timer"] <= 0.0:
			_dismiss(banner)


func _dismiss(banner : Node) -> void:
	_banners.erase(banner)
	# clip_contents=true so the panel doesn't visually overflow while collapsing.
	if banner is Control:
		(banner as Control).clip_contents = true
	var tw := create_tween()
	# Step 1 — fade out the banner content.
	tw.tween_property(banner, "modulate:a", 0.0, 0.22)
	# Step 2 — collapse the height to zero. VBoxContainer sees the shrinking
	# minimum size and reflows immediately, dropping the banners above downward.
	tw.tween_property(banner, "custom_minimum_size:y", 0.0, 0.18)
	tw.finished.connect(banner.queue_free)


# ── Banner builder ────────────────────────────────────────────────────────────

func _build_banner(title: String, dur_text: String) -> PanelContainer:
	# A tiny iron plate (translucent, blood edge); the dungeon stays visible around it.
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(0.0, BANNER_HEIGHT)
	panel.mouse_filter        = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _plate_style())

	var hbox := HBoxContainer.new()
	hbox.name             = "HBox"
	hbox.mouse_filter     = Control.MOUSE_FILTER_IGNORE
	hbox.add_theme_constant_override("separation", PUI.S4)
	panel.add_child(hbox)

	var title_lbl := PUI.label(title, "HudValue")
	title_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(title_lbl)

	var dur_lbl := PUI.label(dur_text, "HudValue")
	dur_lbl.name                  = "DurLabel"
	dur_lbl.vertical_alignment    = VERTICAL_ALIGNMENT_CENTER
	dur_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_RIGHT
	dur_lbl.add_theme_color_override("font_color", PUI.EMBER_BRIGHT)
	dur_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(dur_lbl)

	return panel


# Built once; the iron material is cached in PUI, only the margins are tightened for a compact plate.
var _plate: StyleBoxTexture = null

func _plate_style() -> StyleBoxTexture:
	if _plate == null:
		_plate = PUI.box(Color(0.06, 0.04, 0.035, 0.80), PUI.BLOOD, Color(0.04, 0.03, 0.025, 0.86), 0.04, 0.25, 0.02)
		_plate.content_margin_left = PUI.S4
		_plate.content_margin_right = PUI.S4
		_plate.content_margin_top = PUI.S2
		_plate.content_margin_bottom = PUI.S2
	return _plate
