# Dev utility for tools/ui_shot.gd: seeds a scratch profile / codex and shows the Alchemist or the Codex.
# Env: PARCH_TARGET=alchemist|codex  PARCH_POTIONS=n  PARCH_RUNS=n  PARCH_CODEX=n  PARCH_PAGE=1|2  PARCH_CLASS=barbarian|mage
# (Run with PURGATORY_SAVE_ROOT pointing at a scratch directory.)
extends Control


func _ready() -> void:
	# ui_shot always stretches to 1280x720; the Windows game runs 1:1, so drop the stretch for desktop shots.
	if not TouchControls.is_touch_platform():
		get_tree().root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var cls := OS.get_environment("PARCH_CLASS") if OS.get_environment("PARCH_CLASS") != "" else "mage"
	SaveManager.load_slot(0)
	SaveManager.create_initial_identity("Shot", cls, "medium")
	SaveManager.current_profile["meta_currency"] = int(OS.get_environment("PARCH_POTIONS"))
	SaveManager.current_profile["run_count"] = int(OS.get_environment("PARCH_RUNS"))
	CodexManager._total_completions = int(OS.get_environment("PARCH_CODEX"))
	var path := "res://scenes/CodexScreen.tscn" if OS.get_environment("PARCH_TARGET") == "codex" else "res://scenes/AlchemistStore.tscn"
	var inst := (load(path) as PackedScene).instantiate()
	add_child(inst)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	if OS.get_environment("PARCH_PAGE") == "2" and inst.has_method("_on_next_page"):
		await get_tree().process_frame
		inst._on_next_page()
