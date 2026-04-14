extends Node

@export_node_path("DeliveryZone") var delivery_zone_path: NodePath
@export_node_path("ItemSpawner") var plate_spawner_path: NodePath
@export_node_path("ItemSpawner") var egg_spawner_path: NodePath


func _ready() -> void:
	var zone: DeliveryZone = get_node(delivery_zone_path)
	zone.delivered.connect(_on_delivered)


func _on_delivered() -> void:
	var plate_spawner: ItemSpawner = get_node(plate_spawner_path)
	plate_spawner.spawn()
	var egg_spawner: ItemSpawner = get_node(egg_spawner_path)
	if get_tree().get_nodes_in_group("food").is_empty():
		egg_spawner.spawn()
