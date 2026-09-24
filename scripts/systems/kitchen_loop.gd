class_name KitchenLoop
extends Node
## Run state: count-up timer, delivery goal, star rating. Authority only
## advances it; a later task replicates it to clients.

enum State { PLAYING, WON }

@export_node_path("DeliveryZone") var delivery_zone_path: NodePath
@export_node_path("OrderSystem") var order_system_path: NodePath = NodePath("../OrderSystem")

@export var delivery_goal: int = 3
@export var star_3_threshold: float = 45.0
@export var star_2_threshold: float = 70.0
## Practice: deliveries still respawn items but never end the run, and the
## timer stays at zero.
var practice: bool = false

signal game_won(elapsed_time: float, stars: int)

var state: State = State.PLAYING
var elapsed_time: float = 0.0
var deliveries_made: int = 0

@onready var _orders: OrderSystem = get_node(order_system_path)


func _ready() -> void:
	var zone: DeliveryZone = get_node(delivery_zone_path)
	zone.delivered.connect(_on_delivered)


func _process(delta: float) -> void:
	if not NetSession.is_authority():
		return
	if state != State.PLAYING or practice:
		return
	elapsed_time += delta


func get_stars() -> int:
	if elapsed_time <= star_3_threshold:
		return 3
	if elapsed_time <= star_2_threshold:
		return 2
	return 1


func reset() -> void:
	state = State.PLAYING
	elapsed_time = 0.0
	deliveries_made = 0
	_orders.reset()


func _on_delivered() -> void:
	if not NetSession.is_authority() or state != State.PLAYING:
		return
	deliveries_made += 1
	_orders.draw_next()
	if not practice and deliveries_made >= delivery_goal:
		state = State.WON
		game_won.emit(elapsed_time, get_stars())
		return
	_respawn_items()


## Refills each refillable spawner whose slot is empty. Waits one frame so
## the items DeliveryZone just queue_free'd are gone before the checks run.
func _respawn_items() -> void:
	await get_tree().process_frame
	for node in get_tree().get_nodes_in_group(Groups.SPAWNER):
		var spawner: ItemSpawner = node as ItemSpawner
		if spawner.refill_on_delivery and spawner.is_slot_free():
			spawner.spawn()
