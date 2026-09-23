extends Label3D

@export_node_path("OrderSystem") var order_system_path: NodePath

var _system: OrderSystem


func _ready() -> void:
	_system = get_node(order_system_path)


func _process(_delta: float) -> void:
	# recipe_tag / required_count replicate to clients after _ready.
	if _system:
		text = _system.current_order_text()
