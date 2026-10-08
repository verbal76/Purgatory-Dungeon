# ==============================================================================
# File Name: app_lifecycle.gd
# Path: res://scripts/touch/app_lifecycle.gd
#
# Description:
#   Android lifecycle handling (touch platforms only). Home, the app switcher, the lock screen, a
#   phone call or the notification shade all send the app to the background, and Android may then
#   reclaim the process without a further warning. On the way out we:
#     1. write the character profile and the settings to disk (so a reclaimed process loses at most
#        the current dungeon, never progress/unlocks),
#     2. pause a live run behind the pause menu, so the player returns to a frozen game rather than
#        one that kept running (or a stuck input),
#     3. let go of every touch (TouchControls releases its own fingers on the same notifications, and again on the way
#        back: a finger that lifted while we were away never delivered its release).
#   Coming back needs nothing: the process, the generated dungeon and the music player are the
#   same objects, so nothing is rebuilt (no regeneration, no second splash, no second music start).
# ==============================================================================
class_name AppLifecycle
extends Node

signal backgrounded
signal foregrounded

var background_count: int = 0
var in_background: bool = false


static func install(tree: SceneTree) -> Node:
	var n: Node = (load("res://scripts/touch/app_lifecycle.gd") as GDScript).new()
	n.name = "AppLifecycle"
	n.process_mode = Node.PROCESS_MODE_ALWAYS
	tree.root.add_child.call_deferred(n)
	return n


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT:
			on_background()
		NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN:
			on_foreground()


## Public so tests can drive the same path as the OS notification.
func on_background() -> void:
	if in_background:
		return
	in_background = true
	background_count += 1
	get_tree().call_group(TouchControls.GROUP, "release_all")
	if SaveManager != null and not SaveManager.current_profile.is_empty():
		SaveManager.save_profile()
	if SettingsManager != null:
		SettingsManager.save_settings()
	if _run_in_progress():
		get_tree().call_group("pause_menu", "open_menu")
	backgrounded.emit()


func on_foreground() -> void:
	if not in_background:
		return
	in_background = false
	# A finger that lifted while we were away never delivered its release: nothing it owned may stay down.
	get_tree().call_group(TouchControls.GROUP, "release_all")
	foregrounded.emit()


# A dungeon with a living player (not the death screen, not a menu).
func _run_in_progress() -> bool:
	for p in get_tree().get_nodes_in_group("player"):
		if "_is_dead" in p and not p._is_dead:
			return true
	return false
