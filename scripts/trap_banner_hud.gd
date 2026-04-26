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

const ACCENT_COLORS : Dictionary = {
	"reversed_view"     : Color(0.55, 0.20, 0.90),  # purple
	"heavy_gravity"     : Color(0.20, 0.45, 0.95),  # blue
	"drunk"             : Color(0.95, 0.70, 0.10),  # amber
	"reversed_controls" : Color(1.00, 0.40, 0.05),  # orange
	"acid_pool"         : Color(0.25, 0.90, 0.15),  # green
	"fireball_mine"     : Color(1.00, 0.12, 0.05),  # red
	"schizophrenia"     : Color(0.60, 0.00, 0.85),  # violet
	"jumpscare"         : Color(1.00, 0.10, 0.10),  # bright red
}

const DISPLAY_NAMES : Dictionary = {
	"reversed_view"     : "REVERSED VIEW",
	"heavy_gravity"     : "HEAVY GRAVITY",
	"drunk"             : "INTOXICATED",
	"reversed_controls" : "CONTROLS REVERSED",
	"acid_pool"         : "ACID BURNS",
	"fireball_mine"     : "FIREBALL MINE",
	"schizophrenia"     : "HALLUCINATIONS",
	"jumpscare"         : "JUMPSCARE",
}

# { banner_node : { "timer": float, "countdown": bool, "dur_label": Label } }
var _banners   : Dictionary = {}
var _vbox      : VBoxContainer = null


func _ready() -> void:
	layer = 6   # Above HUD (5), below loading screen / jumpscare

	var root_ctrl := Control.new()
	root_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root_ctrl)

	_vbox = VBoxContainer.new()
	# Anchor the VBox to the bottom of the screen, full width.
	# GROW_DIRECTION_BEGIN makes it grow UPWARD as children are added.
	_vbox.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_vbox.grow_vertical   = Control.GROW_DIRECTION_BEGIN
	_vbox.mouse_filter    = Control.MOUSE_FILTER_IGNORE
	root_ctrl.add_child(_vbox)


# ── Public API ────────────────────────────────────────────────────────────────
#
# effect      — trap effect ID (must match trap_manager.gd constants)
# dur_secs    — >0: live countdown; 0: instant effect (shows 4 s); <0: day-based (shows 5 s)
# day_count   — only used when dur_secs < 0 (e.g. effect_day_duration)

func show_trap(effect: String, dur_secs: float, day_count: int = 1) -> void:
	var display : String = DISPLAY_NAMES.get(effect, effect.to_upper().replace("_", " "))
	var accent  : Color  = ACCENT_COLORS.get(effect, Color(0.9, 0.2, 0.1))

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

	var banner    := _build_banner(display, dur_text, accent)
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

func _build_banner(title: String, dur_text: String, accent: Color) -> PanelContainer:
	# ── Outer panel ───────────────────────────────────────────────────────────
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(0.0, 54.0)
	panel.mouse_filter        = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.02, 0.02, 0.90)
	style.set_border_width_all(1)
	style.border_color = accent.darkened(0.35)
	style.set_corner_radius_all(0)
	panel.add_theme_stylebox_override("panel", style)

	# ── Inner HBox ────────────────────────────────────────────────────────────
	var hbox := HBoxContainer.new()
	hbox.name             = "HBox"
	hbox.alignment        = BoxContainer.ALIGNMENT_BEGIN
	hbox.mouse_filter     = Control.MOUSE_FILTER_IGNORE
	panel.add_child(hbox)

	# Left accent stripe
	var bar := ColorRect.new()
	bar.color                    = accent
	bar.custom_minimum_size      = Vector2(7.0, 0.0)
	bar.size_flags_vertical      = Control.SIZE_FILL
	hbox.add_child(bar)

	# Left inner padding
	var pad_l := Control.new()
	pad_l.custom_minimum_size = Vector2(12.0, 0.0)
	hbox.add_child(pad_l)

	# Title label (⚠ + trap name)
	var title_lbl := Label.new()
	title_lbl.text               = "  ⚠   " + title
	title_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.add_theme_font_size_override("font_size", 16)
	title_lbl.add_theme_color_override("font_color", Color(1.0, 0.92, 0.82, 1.0))
	hbox.add_child(title_lbl)

	# Duration label (right side)
	var dur_lbl := Label.new()
	dur_lbl.name                  = "DurLabel"
	dur_lbl.text                  = dur_text
	dur_lbl.vertical_alignment    = VERTICAL_ALIGNMENT_CENTER
	dur_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_RIGHT
	dur_lbl.add_theme_font_size_override("font_size", 15)
	dur_lbl.add_theme_color_override("font_color", accent.lightened(0.25))
	hbox.add_child(dur_lbl)

	# Right padding
	var pad_r := Control.new()
	pad_r.custom_minimum_size = Vector2(18.0, 0.0)
	hbox.add_child(pad_r)

	return panel
