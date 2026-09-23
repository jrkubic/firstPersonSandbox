class_name ItemSpawner
extends Node3D
## Produces one item (egg, plate, pan) at its own position. Only the
## authority spawns; the kitchen's MultiplayerSpawner replicates the result.
## Every spawner is in the "spawner" group so KitchenLoop can refill them.

@export var item_scene: PackedScene
@export var spawn_on_ready: bool = true
## Refilled after a delivery when its slot is free (pans are not).
@export var refill_on_delivery: bool = true
## Spawns only while the kitchen has at least this many players, so extra
## ingredient stations appear for bigger groups.
@export var min_players: int = 1
## Node spawned items are added under. Leave empty to use the current scene
## root, falling back to this spawner's parent (headless runs).
@export_node_path("Node") var spawn_parent_path: NodePath
## Radius (m) around the spawn point within which the last spawned item still
## counts as occupying this slot. See is_slot_free().
@export var slot_radius: float = 0.35

## Per-item serial so replicated node names never collide across spawners.
static var _serial: int = 0

var _last_spawned: Node = null


func _ready() -> void:
	add_to_group(Groups.SPAWNER)
	if spawn_on_ready and NetSession.is_authority():
		call_deferred("spawn")


func spawn() -> Node:
	if item_scene == null or not NetSession.is_authority():
		return null
	if _player_count() < min_players:
		return null
	var instance: Node = item_scene.instantiate()
	_serial += 1
	instance.name = "%s%d" % [instance.name, _serial]
	instance.set_meta(&"spawner_path", get_path())
	var parent: Node = _get_spawn_parent()
	if instance is Node3D:
		var local: Vector3 = global_position
		if parent is Node3D:
			local = (parent as Node3D).global_transform.affine_inverse() * global_position
		(instance as Node3D).position = local
	parent.add_child(instance)
	_last_spawned = instance
	return instance


## True when nothing this spawner produced is still sitting in its slot: the
## last spawned item was freed (or is about to be), is being held, or has
## been carried farther than slot_radius from the spawn point.
func is_slot_free() -> bool:
	if not is_instance_valid(_last_spawned) or _last_spawned.is_queued_for_deletion():
		return true
	if _last_spawned.is_in_group(Groups.HELD):
		return true
	var item: Node3D = _last_spawned as Node3D
	if item == null:
		return false
	return item.global_position.distance_to(global_position) > slot_radius


## True once this spawner has produced anything, even if it has since left.
func has_spawned() -> bool:
	return _last_spawned != null


## Called by TrashZone after binning an item this spawner produced. Spawns a
## replacement next frame if the binned item was this spawner's current one
## (an older, already-replaced item does not trigger a second spawn).
func replace(binned: Node) -> void:
	if binned == _last_spawned:
		call_deferred("spawn")


func _player_count() -> int:
	var net: KitchenNet = get_tree().get_first_node_in_group(Groups.KITCHEN_NET) as KitchenNet
	return net.player_count() if net else 1


func _get_spawn_parent() -> Node:
	if not spawn_parent_path.is_empty():
		var target: Node = get_node_or_null(spawn_parent_path)
		if target != null:
			return target
	if is_inside_tree() and get_tree().current_scene != null:
		return get_tree().current_scene
	return get_parent()
