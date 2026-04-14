class_name DeliveryZone
extends Area3D

@export_node_path("OrderSystem") var order_system_path: NodePath

signal delivered

@onready var _order_system: OrderSystem = get_node(order_system_path)


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node) -> void:
	if not body is Plate:
		return
	var plate: Plate = body
	if not _order_system.check_delivery(plate):
		return
	delivered.emit()
	for food in plate.get_contents():
		if is_instance_valid(food):
			food.queue_free()
	plate.queue_free()
