# ==============================================================================
# File Name: vfx_pool.gd
# Path: res://scripts/vfx_pool.gd
#
# Description:
#   The shared effect pool every run owns (added by the main game file during loading, group "vfx_pool"): pre-built one-shot
#   GPUParticles3D bursts per preset, a few short light flashes and floating Label3D numbers, all REUSED (restart() / re-aim /
#   re-text), so combat, pickups, traps and props can juice freely without creating a node at run time (project pooling rule).
#
#   Mobile budget: 6-16 particles per burst, 0.2-0.9 s lifetimes, unshaded quads sharing one mesh and one material per preset,
#   no per-particle lights, three flash lights at most (they count against the scene's light budget for 0.1-0.3 s).
# ==============================================================================
extends Node3D

const TEX := "res://addons/kenney_particle_pack/"
const PER_PRESET := 4
const LIGHTS := 3
const NUMBERS := 14

# name -> {tex, amount, life, vmin, vmax, spread, grav, size0, size1, c0, c1, add, flat, size}
const PRESETS := {
	"dust":   {"tex": "dirt_01.png",   "amount": 10, "life": 0.55, "vmin": 1.0, "vmax": 2.6, "spread": 75.0, "grav": Vector3(0, -0.8, 0), "s0": 0.22, "s1": 0.5,  "c0": Color(0.62, 0.56, 0.48, 0.6), "c1": Color(0.5, 0.45, 0.4, 0.0), "add": false},
	"poof":   {"tex": "smoke_01.png",  "amount": 8,  "life": 0.7,  "vmin": 0.5, "vmax": 1.4, "spread": 180.0, "grav": Vector3(0, 0.35, 0), "s0": 0.35, "s1": 1.1, "c0": Color(0.75, 0.72, 0.7, 0.5), "c1": Color(0.45, 0.43, 0.42, 0.0), "add": false},
	"spark":  {"tex": "spark_05.png",  "amount": 12, "life": 0.32, "vmin": 3.0, "vmax": 6.5, "spread": 55.0, "grav": Vector3(0, -9, 0), "s0": 0.16, "s1": 0.04, "c0": Color(1.0, 0.85, 0.35, 1.0), "c1": Color(1.0, 0.4, 0.1, 0.0), "add": true},
	"hit":    {"tex": "spark_05.png",  "amount": 10, "life": 0.26, "vmin": 2.5, "vmax": 5.5, "spread": 80.0, "grav": Vector3(0, -7, 0), "s0": 0.18, "s1": 0.05, "c0": Color(1.0, 0.45, 0.25, 1.0), "c1": Color(0.7, 0.05, 0.05, 0.0), "add": true},
	"block":  {"tex": "spark_05.png",  "amount": 10, "life": 0.26, "vmin": 3.0, "vmax": 6.0, "spread": 75.0, "grav": Vector3(0, -6, 0), "s0": 0.18, "s1": 0.05, "c0": Color(0.85, 0.95, 1.0, 1.0), "c1": Color(0.45, 0.65, 1.0, 0.0), "add": true},
	"magic":  {"tex": "magic_04.png",  "amount": 14, "life": 0.7,  "vmin": 0.8, "vmax": 2.6, "spread": 180.0, "grav": Vector3(0, 0.6, 0), "s0": 0.22, "s1": 0.05, "c0": Color(0.85, 0.5, 1.0, 1.0), "c1": Color(0.4, 0.1, 0.7, 0.0), "add": true},
	"heal":   {"tex": "circle_05.png", "amount": 10, "life": 0.7,  "vmin": 0.8, "vmax": 1.8, "spread": 35.0, "grav": Vector3(0, 1.6, 0), "s0": 0.16, "s1": 0.04, "c0": Color(0.55, 1.0, 0.6, 1.0), "c1": Color(0.1, 0.8, 0.3, 0.0), "add": true},
	"gold":   {"tex": "star_01.png",   "amount": 10, "life": 0.65, "vmin": 2.0, "vmax": 4.2, "spread": 60.0, "grav": Vector3(0, -6, 0), "s0": 0.2, "s1": 0.05, "c0": Color(1.0, 0.9, 0.4, 1.0), "c1": Color(1.0, 0.6, 0.1, 0.0), "add": true},
	"ember":  {"tex": "flame_06.png",  "amount": 6,  "life": 0.9,  "vmin": 0.5, "vmax": 1.4, "spread": 40.0, "grav": Vector3(0, 1.3, 0), "s0": 0.2, "s1": 0.04, "c0": Color(1.0, 0.7, 0.25, 0.9), "c1": Color(1.0, 0.25, 0.05, 0.0), "add": true},
	"soul":   {"tex": "twirl_01.png",  "amount": 8,  "life": 0.9,  "vmin": 0.6, "vmax": 1.6, "spread": 30.0, "grav": Vector3(0, 1.0, 0), "s0": 0.25, "s1": 0.08, "c0": Color(0.8, 0.85, 1.0, 0.7), "c1": Color(0.4, 0.45, 0.9, 0.0), "add": true},
	"ring_red":   {"tex": "circle_03.png", "amount": 1, "life": 0.45, "vmin": 0.0, "vmax": 0.0, "spread": 0.0, "grav": Vector3.ZERO, "s0": 0.4, "s1": 3.2, "c0": Color(1.0, 0.25, 0.1, 0.85), "c1": Color(1.0, 0.1, 0.05, 0.0), "add": true, "flat": true},
	"ring_white": {"tex": "circle_03.png", "amount": 1, "life": 0.4,  "vmin": 0.0, "vmax": 0.0, "spread": 0.0, "grav": Vector3.ZERO, "s0": 0.3, "s1": 2.6, "c0": Color(1.0, 1.0, 1.0, 0.8), "c1": Color(1.0, 0.9, 0.7, 0.0), "add": true, "flat": true},
	"ring_green": {"tex": "circle_03.png", "amount": 1, "life": 0.5,  "vmin": 0.0, "vmax": 0.0, "spread": 0.0, "grav": Vector3.ZERO, "s0": 0.3, "s1": 2.2, "c0": Color(0.4, 1.0, 0.5, 0.8), "c1": Color(0.1, 0.8, 0.3, 0.0), "add": true, "flat": true},
}

var _bursts: Dictionary = {}     # preset -> Array[GPUParticles3D]
var _burst_i: Dictionary = {}
var _lights: Array[OmniLight3D] = []
var _light_t: PackedFloat32Array = PackedFloat32Array()
var _light_e: PackedFloat32Array = PackedFloat32Array()
var _light_dur: PackedFloat32Array = PackedFloat32Array()
var _light_i: int = 0
var _labels: Array[Label3D] = []
var _label_t: PackedFloat32Array = PackedFloat32Array()
var _label_i: int = 0


func _ready() -> void:
	add_to_group("vfx_pool")
	process_mode = Node.PROCESS_MODE_PAUSABLE
	top_level = true
	for name in PRESETS:
		_build_preset(name)
	for i in LIGHTS:
		var l := OmniLight3D.new()
		l.visible = false
		l.shadow_enabled = false
		l.light_energy = 0.0
		add_child(l)
		_lights.append(l)
		_light_t.append(0.0)
		_light_e.append(0.0)
		_light_dur.append(0.2)
	for i in NUMBERS:
		var lb := Label3D.new()
		lb.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lb.no_depth_test = true
		lb.fixed_size = false
		lb.pixel_size = 0.0065
		lb.outline_size = 10
		lb.outline_modulate = Color(0.02, 0.01, 0.01, 0.9)
		lb.font = PUI.font("display_bold")
		lb.font_size = 40
		lb.render_priority = 5
		lb.visible = false
		add_child(lb)
		_labels.append(lb)
		_label_t.append(0.0)
	set_process(false)


func _build_preset(name: String) -> void:
	var d: Dictionary = PRESETS[name]
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE
	var flat: bool = bool(d.get("flat", false))
	if flat:
		mesh.orientation = PlaneMesh.FACE_Y
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = load(TEX + String(d["tex"])) as Texture2D
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if bool(d["add"]) else BaseMaterial3D.BLEND_MODE_MIX
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	if not flat:
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		mat.billboard_keep_scale = true
	mesh.material = mat
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3.UP
	pm.spread = float(d["spread"])
	pm.initial_velocity_min = float(d["vmin"])
	pm.initial_velocity_max = float(d["vmax"])
	pm.gravity = d["grav"]
	pm.scale_min = float(d["s0"])
	pm.scale_max = float(d["s0"]) * 1.25
	var sc := Curve.new()
	sc.add_point(Vector2(0.0, 1.0))
	sc.add_point(Vector2(1.0, float(d["s1"]) / maxf(float(d["s0"]), 0.001)))
	var sct := CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	var grad := Gradient.new()
	grad.set_color(0, d["c0"])
	grad.set_color(1, d["c1"])
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt
	if not flat and float(d["spread"]) > 0.0:
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		pm.emission_sphere_radius = 0.12
	var arr: Array = []
	for i in PER_PRESET:
		var p := GPUParticles3D.new()
		p.emitting = false
		p.one_shot = true
		p.explosiveness = 1.0
		p.amount = int(d["amount"])
		p.lifetime = float(d["life"])
		p.local_coords = false
		p.process_material = pm
		p.draw_pass_1 = mesh
		p.visibility_aabb = AABB(Vector3(-6, -3, -6), Vector3(12, 8, 12))
		p.fixed_fps = 0
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(p)
		arr.append(p)
	_bursts[name] = arr
	_burst_i[name] = 0


func burst(preset: String, pos: Vector3, dir: Vector3 = Vector3.UP, scale: float = 1.0) -> void:
	if not _bursts.has(preset):
		return
	var arr: Array = _bursts[preset]
	var i: int = int(_burst_i[preset])
	_burst_i[preset] = (i + 1) % arr.size()
	var p: GPUParticles3D = arr[i]
	var d := dir.normalized() if dir.length_squared() > 0.0001 else Vector3.UP
	var b := Basis(Quaternion(Vector3.UP, d))
	p.global_transform = Transform3D(b, pos)
	p.amount_ratio = clampf(scale, 0.25, 1.0)
	p.restart()
	p.emitting = true


func flash(pos: Vector3, color: Color, energy: float, seconds: float, light_range: float) -> void:
	if _lights.is_empty():
		return
	var i := _light_i
	_light_i = (_light_i + 1) % _lights.size()
	var l: OmniLight3D = _lights[i]
	l.global_position = pos
	l.light_color = color
	l.omni_range = light_range
	l.light_energy = energy
	l.visible = true
	_light_e[i] = energy
	_light_t[i] = seconds
	_light_dur[i] = maxf(seconds, 0.05)
	set_process(true)


func number(pos: Vector3, text: String, color: Color, size: float) -> void:
	if _labels.is_empty():
		return
	var i := _label_i
	_label_i = (_label_i + 1) % _labels.size()
	var lb: Label3D = _labels[i]
	lb.text = text
	lb.modulate = color
	lb.scale = Vector3.ONE * size
	lb.global_position = pos + Vector3(randf_range(-0.25, 0.25), 0.0, randf_range(-0.25, 0.25))
	lb.visible = true
	_label_t[i] = 0.75
	set_process(true)


func _process(delta: float) -> void:
	var live := false
	for i in _lights.size():
		if _light_t[i] > 0.0:
			_light_t[i] -= delta
			var l := _lights[i]
			if _light_t[i] <= 0.0:
				l.visible = false
				l.light_energy = 0.0
			else:
				l.light_energy = _light_e[i] * (_light_t[i] / _light_dur[i])
				live = true
	for i in _labels.size():
		if _label_t[i] > 0.0:
			_label_t[i] -= delta
			var lb := _labels[i]
			if _label_t[i] <= 0.0:
				lb.visible = false
			else:
				var t: float = 1.0 - _label_t[i] / 0.75
				lb.position.y += (1.6 - t * 1.2) * delta
				lb.modulate.a = clampf((1.0 - t) * 2.2, 0.0, 1.0)
				live = true
	if not live:
		set_process(false)
