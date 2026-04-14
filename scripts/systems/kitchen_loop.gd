class_name KitchenLoop
extends Node

enum State { PLAYING, WON }

@export_node_path("DeliveryZone") var delivery_zone_path: NodePath
@export_node_path("ItemSpawner") var plate_spawner_path: NodePath
@export_node_path("ItemSpawner") var egg_spawner_path: NodePath

@export var delivery_goal: int = 3
@export var star_3_threshold: float = 45.0
@export var star_2_threshold: float = 70.0

signal game_won(elapsed_time: float, stars: int)

var state: State = State.PLAYING
var elapsed_time: float = 0.0
var deliveries_made: int = 0


func _ready() -> void:
	var zone: DeliveryZone = get_node(delivery_zone_path)
	zone.delivered.connect(_on_delivered)


func _process(delta: float) -> void:
	if state != State.PLAYING:
		return
	elapsed_time += delta


func get_stars() -> int:
	if elapsed_time <= star_3_threshold:
		return 3
	if elapsed_time <= star_2_threshold:
		return 2
	return 1


func _on_delivered() -> void:
	if state != State.PLAYING:
		return
	deliveries_made += 1
	if deliveries_made >= delivery_goal:
		state = State.WON
		game_won.emit(elapsed_time, get_stars())
		return
	_respawn_items()


func _respawn_items() -> void:
	var plate_spawner: ItemSpawner = get_node(plate_spawner_path)
	plate_spawner.spawn()
	await get_tree().process_frame
	var egg_spawner: ItemSpawner = get_node(egg_spawner_path)
	if get_tree().get_nodes_in_group("food").is_empty():
		egg_spawner.spawn()
