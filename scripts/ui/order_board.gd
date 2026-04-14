extends Label3D

@export_node_path("OrderSystem") var order_system_path: NodePath


func _ready() -> void:
	var system: OrderSystem = get_node(order_system_path)
	if system:
		text = system.current_order_text()
