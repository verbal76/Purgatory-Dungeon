# ============================================================
#  FILE: key_pickup.gd
#  PATH: res://scripts/key_pickup.gd
#  SPAWNED BY: brute_ai.gd / mage_ai.gd on enemy death (rare roll).
#  DESCRIPTION: Small bobbing Area3D that contains a key mesh +
#               coloured glow. On player contact, it adds a key
#               of the matching colour to PlayerWallet and frees
#               itself. Keys persist across runs via SaveManager.
# ============================================================

extends Area3D

const MESH_BY_COLOR : Dictionary = {
	"bronze": "res://addons/props/chests and keys/SM_KeyBronze.fbx",
	"silver": "res://addons/props/chests and keys/SM_KeySilver.fbx",
	"gold":   "res://addons/props/chests and keys/SM_KeyGold.fbx",
}
const GLOW_BY_COLOR : Dictionary = {
	"bronze": Color(0.95, 0.55, 0.25),
	"silver": Color(0.90, 0.90, 0.95),
	"gold":   Color(1.00, 0.85, 0.25),
}

# Set by the spawner BEFORE add_child so _ready picks up the colour.
var _color : String = "bronze"

var _bob_offset : float = 0.0
var _base_y : float = 0.0
var _mesh_root : Node3D = null


func _ready() -> void:
	collision_layer = 0
	collision_mask  = 0xFFFFFFFF
	# Deferred — _ready() can fire while the parent (chest) is mid-signal,
	# at which point direct writes to monitoring/monitorable are blocked.
	set_deferred("monitoring", true)
	set_deferred("monitorable", false)

	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.6
	shape.shape = sphere
	add_child(shape)

	var path : String = MESH_BY_COLOR.get(_color, MESH_BY_COLOR["bronze"])
	if ResourceLoader.exists(path):
		var fbx_scene := load(path) as PackedScene
		if fbx_scene != null:
			_mesh_root = fbx_scene.instantiate() as Node3D
			if _mesh_root != null:
				_mesh_root.scale = Vector3(0.6, 0.6, 0.6)
				add_child(_mesh_root)

	var glow := OmniLight3D.new()
	glow.light_color    = GLOW_BY_COLOR.get(_color, Color.WHITE)
	glow.omni_range     = 2.0
	glow.light_energy   = 1.2
	glow.shadow_enabled = false
	add_child(glow)

	body_entered.connect(_on_body_entered)
	_bob_offset = randf() * TAU
	_base_y = global_position.y


func _process(delta: float) -> void:
	var t : float = Time.get_ticks_msec() * 0.001
	# Small vertical bob + slow Y spin for readability.
	global_position.y = _base_y + sin(t * 2.0 + _bob_offset) * 0.12
	rotation.y += delta * 1.5
	if _mesh_root != null:
		_mesh_root.rotation.y += delta * 1.0


func _on_body_entered(body: Node) -> void:
	if body == null or not body.is_in_group("player"):
		return
	if has_node("/root/PlayerWallet"):
		PlayerWallet.add_key(_color)
	if has_node("/root/AudioManager") and AudioManager.has_method("play_buff_choice"):
		AudioManager.play_buff_choice()
	queue_free()
