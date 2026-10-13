# ==============================================================================
# File Name: physics_util.gd
# Path: res://scripts/physics_util.gd
#
# Description:
#   Almost every body in the game (player, enemies, props, chests, walls) shares
#   collision layer 1, so a ray with mask 1 is NOT "static geometry only" even though
#   several call sites say so. ray_world() casts a ray that only stops on level
#   geometry: hits on characters, rigid props, and chests are skipped by excluding
#   them and re-casting (bounded, and only costs extra when something is in the way).
# ==============================================================================
class_name PhysicsUtil
extends RefCounted

const MAX_SKIPS : int = 4


## True for colliders that count as level geometry (walls, floors, door plugs).
static func is_world_geometry(collider: Object) -> bool:
	return collider is StaticBody3D and not (collider as Node).is_in_group("chest")


## intersect_ray that ignores non-geometry bodies. `extra_exclude` is added for this
## cast only; the query's own exclude list is restored afterwards.
static func ray_world(space: PhysicsDirectSpaceState3D, query: PhysicsRayQueryParameters3D,
		extra_exclude: Array[RID] = []) -> Dictionary:
	var original: Array[RID] = []
	original.assign(query.exclude)
	var working: Array[RID] = []
	working.assign(original)
	working.append_array(extra_exclude)
	query.exclude = working
	var result: Dictionary = space.intersect_ray(query)
	var skips: int = 0
	while not result.is_empty() and not is_world_geometry(result.get("collider")) and skips < MAX_SKIPS:
		working.append(result.get("rid"))
		query.exclude = working
		result = space.intersect_ray(query)
		skips += 1
	query.exclude = original
	return result
