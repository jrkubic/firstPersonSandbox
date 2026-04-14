class_name DeliveryZone
extends Area3D

@export_node_path("OrderSystem") var order_system_path: NodePath

signal delivered

@onready var _order_system: OrderSystem = get_node(order_system_path)

var _plates_inside: Array[Plate] = []


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _physics_process(_delta: float) -> void:
	if _plates_inside.is_empty():
		return
	for plate in _plates_inside.duplicate():
		if not is_instance_valid(plate):
			_plates_inside.erase(plate)
			continue
		if plate.is_in_group("held"):
			continue
		if _has_held_contents(plate):
			continue
		if _order_system.check_delivery(plate):
			_deliver(plate)


func _has_held_contents(plate: Plate) -> bool:
	for food in plate.get_contents():
		if is_instance_valid(food) and food.is_in_group("held"):
			return true
	return false


func _on_body_entered(body: Node) -> void:
	if body is Plate and not _plates_inside.has(body):
		_plates_inside.append(body)


func _on_body_exited(body: Node) -> void:
	if body is Plate:
		_plates_inside.erase(body)


func _deliver(plate: Plate) -> void:
	_plates_inside.erase(plate)
	delivered.emit()
	for food in plate.get_contents():
		if is_instance_valid(food):
			food.queue_free()
	plate.queue_free()
