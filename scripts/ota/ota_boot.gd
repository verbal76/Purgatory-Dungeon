# ==============================================================================
# File Name: ota_boot.gd
# Path: res://scripts/ota/ota_boot.gd
#
# Description:
#   Autoload #1 (must stay first in project.godot). At process start it decides which stored update, if
#   any, to overlay on the native pack, verifies it completely, and mounts it with
#   ProjectSettings.load_resource_pack(). Because it runs in _init() of the FIRST autoload, every later
#   autoload and the main scene already see the updated scripts, scenes and data.
#
#   Rules (docs/OTA.md "Failure and rollback behaviour"):
#     - Every failure ends in "run the last known-good update, or the native build". Never a crash,
#       never a half-applied state: this class only ever mounts something that fully verified.
#     - boot_attempts is written to disk BEFORE the pack is mounted, so a crash during startup is counted.
#       An unconfirmed update gets MAX_BOOT_ATTEMPTS launches; then it is quarantined.
#     - An update becomes "known good" only after the main menu has been reached and the game has stayed
#       up for HEALTHY_AFTER_SEC (confirm_health()).
#     - Saves and settings are never written; they are copied to ota/backups/ before an update is first
#       activated.
#   boot() is pure orchestration over injected inputs so tests can drive every path with a fake mounter.
# ==============================================================================
extends Node

var _confirm_timer: float = 0.0


func _init() -> void:
	OtaRuntime.reset()
	var identity: Dictionary = OtaIdentity.current()
	var pem: String = OtaIdentity.trust_pem()
	OtaRuntime.channel_configured = OtaIdentity.channel_url() != ""
	var off: String = OtaIdentity.off_reason(identity, pem)
	if off != "":
		OtaRuntime.disabled_reason = off
		return
	OtaRuntime.enabled = true
	var save_root: String = StoragePaths.root()
	var result: Dictionary = OtaCore.boot(OtaStore.root(), identity, pem, _mount, save_root)
	OtaCore.apply_result(result)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(OtaRuntime.enabled and OtaRuntime.active_seq > 0 and not OtaRuntime.confirmed)


func _process(delta: float) -> void:
	# Healthy = past the studio splash (the main menu or a game scene is up) and still running.
	var scene: Node = get_tree().current_scene
	if scene == null or scene.scene_file_path == OtaConst.SPLASH_SCENE:
		_confirm_timer = 0.0
		return
	_confirm_timer += delta
	if _confirm_timer >= OtaConst.HEALTHY_AFTER_SEC:
		OtaCore.confirm_health(OtaStore.root())
		set_process(false)


func _mount(pck_path: String) -> bool:
	return ProjectSettings.load_resource_pack(pck_path, true)
