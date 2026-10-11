# ==============================================================================
# File Name: juice.gd
# Path: res://scripts/juice.gd
#
# Description:
#   Game-feel helpers shared by every system (static, no class_name so an OTA can ship it): one place to read the player's
#   comfort settings and one thin call surface to the pooled effect nodes. Nothing here allocates per call; the bursts, lights
#   and numbers are reused nodes owned by the effect pool (vfx_pool.gd), which the main game file adds to every run.
#
#   Comfort: Options > "Screen Shake" (0-100, default 50) scales camera shake, FOV punch, hit-stop and screen kicks;
#   0 turns every one of them off (reduced motion). Optional second setting "Vibration" (haptics, mobile).
# ==============================================================================
extends RefCounted

const POOL_GROUP := "vfx_pool"

## 0 = all motion effects off, 1 = the designed amount (slider 50), up to 2 at slider 100.
static func motion_scale() -> float:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or not tree.root.has_node("SettingsManager"):
		return 1.0
	return clampf(float(tree.root.get_node("SettingsManager").get_setting("ShakeSlider", 50.0)) / 50.0, 0.0, 2.0)


const PoolScript := preload("res://scripts/vfx_pool.gd")


const ToastScript := preload("res://scripts/hud_toast.gd")


## Called once by the main game file while the loading screen is up: builds the pool (and the banner layer) so no run-time hitch
## happens later.
static func ensure_pool(parent: Node) -> Node:
	var p := pool()
	if p != null and is_instance_valid(p):
		return p
	p = PoolScript.new()
	p.name = "VfxPool"
	parent.add_child(p)
	var t := ToastScript.new()
	t.name = "HudToast"
	parent.add_child(t)
	return p


static func _toast() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.get_first_node_in_group("hud_toast")


## A centred message that pops in, holds and fades (day change, "Room sealed"). No-op when the run has no banner layer.
static func banner(text: String, seconds: float = 2.2, color: Color = Color(0, 0, 0, 0)) -> void:
	var t := _toast()
	if t != null:
		t.banner(text, seconds, color)


## The persistent line under the banner ("Sealed: 3 left"); "" clears it.
static func counter(text: String) -> void:
	var t := _toast()
	if t != null:
		t.counter(text)


static func pool() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.get_first_node_in_group(POOL_GROUP)


## A pooled particle burst. `preset` is a name from vfx_pool.gd PRESETS. `dir` biases the spray (default up).
static func burst(preset: String, pos: Vector3, dir: Vector3 = Vector3.UP, scale: float = 1.0) -> void:
	var p := pool()
	if p != null:
		p.burst(preset, pos, dir, scale)


## A pooled short light flash (shares the scene's light budget: three at most, 0.1-0.3 s each).
static func flash(pos: Vector3, color: Color, energy: float = 3.0, seconds: float = 0.18, light_range: float = 5.0) -> void:
	var p := pool()
	if p != null:
		p.flash(pos, color, energy, seconds, light_range)


## A floating number / word at a world position (pooled Label3D).
static func number(pos: Vector3, text: String, color: Color = Color(1, 1, 1, 1), size: float = 1.0) -> void:
	var p := pool()
	if p != null:
		p.number(pos, text, color, size)


static func haptic(ms: int, amp: float = -1.0) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.root.has_node("AudioManager"):
		tree.root.get_node("AudioManager").haptic(ms, amp)


## The player's camera effects node (shake, FOV punch, kicks, hit-stop, vignette flashes), or null.
static func cam_fx(player: Node) -> Node:
	if player == null:
		return null
	return player.get_node_or_null("CameraFx")
