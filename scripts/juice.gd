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


## Ambient dust motes: ONE GPUParticles3D that rides with the player (world-space particles in a 14 x 5 x 14 m box around them, ~48 in
## flight, 9 s lives, drifting). Faint and unlit, they give the still air depth in torchlight. Built once per player.
static func make_motes() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "DustMotes"
	p.amount = 48
	p.lifetime = 9.0
	p.preprocess = 9.0   # the air is already full when the run starts
	p.local_coords = false
	p.fixed_fps = 15
	p.visibility_aabb = AABB(Vector3(-9, -3, -9), Vector3(18, 7, 18))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(7.0, 2.5, 7.0)
	pm.direction = Vector3(0.3, 0.1, 0.2)
	pm.spread = 180.0
	pm.initial_velocity_min = 0.03
	pm.initial_velocity_max = 0.12
	pm.gravity = Vector3(0.0, -0.01, 0.0)
	pm.scale_min = 0.5
	pm.scale_max = 1.2
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.9, 0.7, 0.0))
	grad.add_point(0.25, Color(1.0, 0.9, 0.7, 0.35))
	grad.add_point(0.75, Color(1.0, 0.9, 0.7, 0.35))
	grad.set_color(grad.get_point_count() - 1, Color(1.0, 0.9, 0.7, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt
	p.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.05, 0.05)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.albedo_texture = load("res://addons/kenney_particle_pack/circle_05.png") as Texture2D
	mat.disable_receive_shadows = true
	q.material = mat
	p.draw_pass_1 = q
	p.position = Vector3(0.0, 1.6, 0.0)
	return p
