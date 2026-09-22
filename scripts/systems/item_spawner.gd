class_name ItemSpawner
extends Node3D

@export var item_scene: PackedScene
@export var spawn_on_ready: bool = true
## Node that spawned items are added under. Leave empty to use the current
## scene root; when there is no current scene (e.g. a headless test that
## instantiates the kitchen directly under root) the spawner's parent is used.
@export_node_path("Node") var spawn_parent_path: NodePath
## Radius (m) around the spawn point within which the last spawned item still
## counts as occupying this slot. See is_slot_free().
@export var slot_radius: float = 0.35

var _last_spawned: Node = null


func _ready() -> void:
	if spawn_on_ready:
		call_deferred("spawn")


func spawn() -> Node:
	if item_scene == null:
		return null
	var instance: Node = item_scene.instantiate()
	_get_spawn_parent().add_child(instance)
	if instance is Node3D:
		(instance as Node3D).global_position = global_position
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


func _get_spawn_parent() -> Node:
	if not spawn_parent_path.is_empty():
		var target: Node = get_node_or_null(spawn_parent_path)
		if target != null:
			return target
	if is_inside_tree() and get_tree().current_scene != null:
		return get_tree().current_scene
	return get_parent()
