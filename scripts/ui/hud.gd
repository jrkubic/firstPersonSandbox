extends CanvasLayer

@export_node_path("DeliveryZone") var delivery_zone_path: NodePath

@onready var delivered_label: Label = $DeliveredLabel

var _delivered_count: int = 0


func _ready() -> void:
	var zone: DeliveryZone = get_node(delivery_zone_path)
	zone.delivered.connect(_on_delivered)
	_refresh_label()


func _on_delivered() -> void:
	_delivered_count += 1
	_refresh_label()


func _refresh_label() -> void:
	delivered_label.text = "Delivered: %d" % _delivered_count
