extends Node
## A banner shown just before the pause menu opens must not stay frozen on screen over the PAUSED title (found rendering the in-run screens at 2560x1080).

var _fails: int = 0
var _checks: int = 0


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: " + label)


func _ready() -> void:
	var toast := CanvasLayer.new()
	toast.set_script(load("res://scripts/hud_toast.gd"))
	add_child(toast)
	await get_tree().process_frame
	toast.banner("SURVIVE 30 DAYS", 3.0)
	for i in 12:
		await get_tree().process_frame
	var banner: Label = toast.get_node("Banner")
	_check(banner.visible and banner.modulate.a > 0.5, "the banner is showing")
	get_tree().paused = true
	await get_tree().process_frame
	_check(not banner.visible, "paused: the banner is hidden (it cannot overlap the pause menu)")
	get_tree().paused = false
	await get_tree().process_frame
	_check(banner.visible, "resumed: the banner carries on")
	toast._banner_t = 100.0   # long finished
	await get_tree().process_frame
	_check(not banner.visible, "a finished banner is gone")
	get_tree().paused = true
	await get_tree().process_frame
	get_tree().paused = false
	await get_tree().process_frame
	_check(not banner.visible, "pausing after it finished does not bring it back")
	print("test_toast_pause: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
