class_name ItemSpawner
extends Node3D

@export var item_scene: PackedScene
@export var spawn_on_ready: bool = true

var _last_spawned: Node = null


func _ready() -> void:
	if spawn_on_ready:
		call_deferred("spawn")


func spawn() -> Node:
	if item_scene == null:
		return null
	var instance: Node = item_scene.instantiate()
	get_parent().add_child(instance)
	if instance is Node3D:
		(instance as Node3D).global_position = global_position
	_last_spawned = instance
	return instance
