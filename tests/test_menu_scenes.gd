extends Node
## Instantiates every menu/UI scene with a valid profile loaded, lets it run a few
## frames and frees it. Runtime script errors surface as "SCRIPT ERROR" lines, which
## tests/run_tests.sh treats as failures.

const SCENES: Array[String] = [
	"res://scenes/MainMenu.tscn",
	"res://scenes/CharacterSelection.tscn",
	"res://scenes/ProfileScreen.tscn",
	"res://scenes/OptionsScreen.tscn",
	"res://scenes/CodexScreen.tscn",
	"res://scenes/AlchemistStore.tscn",
	"res://scenes/VirtualKeyboard.tscn",
]


func _ready() -> void:
	if OS.get_environment(StoragePaths.ENV_OVERRIDE) == "":
		printerr("FAIL: refusing to run without PURGATORY_SAVE_ROOT")
		get_tree().quit(2)
		return
	SaveManager.load_slot(0)
	SaveManager.create_initial_identity("MenuTester", "mage")
	SaveManager.load_slot(1)
	SaveManager.create_initial_identity("MenuBarb", "barbarian")
	var fails := 0
	for path in SCENES:
		var packed := load(path) as PackedScene
		if packed == null:
			printerr("FAIL: cannot load " + path)
			fails += 1
			continue
		var inst := packed.instantiate()
		add_child(inst)
		for i in 10:
			await get_tree().process_frame
		if not is_instance_valid(inst):
			printerr("FAIL: scene freed itself during startup: " + path)
			fails += 1
			continue
		inst.queue_free()
		await get_tree().process_frame
	print("test_menu_scenes: %d scenes, %d failures" % [SCENES.size(), fails])
	get_tree().quit(1 if fails > 0 else 0)
