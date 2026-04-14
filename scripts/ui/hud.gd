extends CanvasLayer

@export_node_path("DeliveryZone") var delivery_zone_path: NodePath
@export var popup_scene: PackedScene
@export var popup_offset: Vector3 = Vector3(0, 0.5, 0)

@onready var delivered_label: Label = $DeliveredLabel

var _zone: DeliveryZone
var _delivered_count: int = 0


func _ready() -> void:
	_zone = get_node(delivery_zone_path)
	_zone.delivered.connect(_on_delivered)
	_refresh_label()


func _on_delivered() -> void:
	_delivered_count += 1
	_refresh_label()
	_spawn_popup()


func _spawn_popup() -> void:
	if popup_scene == null or _zone == null:
		return
	var popup: Node3D = popup_scene.instantiate()
	get_tree().current_scene.add_child(popup)
	popup.global_position = _zone.global_position + popup_offset


func _refresh_label() -> void:
	delivered_label.text = "Delivered: %d" % _delivered_count
