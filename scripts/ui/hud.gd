extends CanvasLayer

@export_node_path("DeliveryZone") var delivery_zone_path: NodePath
@export_node_path("KitchenLoop") var kitchen_loop_path: NodePath
@export var popup_scene: PackedScene
@export var popup_offset: Vector3 = Vector3(0, 0.5, 0)

@onready var delivered_label: Label = $DeliveredLabel
@onready var timer_label: Label = $TimerLabel

var _zone: DeliveryZone
var _kitchen_loop: KitchenLoop


func _ready() -> void:
	_zone = get_node(delivery_zone_path)
	_kitchen_loop = get_node(kitchen_loop_path)
	_zone.delivered.connect(_on_delivered)
	_refresh_delivered_label()
	_refresh_timer_label()


func _process(_delta: float) -> void:
	_refresh_timer_label()


func _on_delivered() -> void:
	call_deferred("_refresh_delivered_label")
	_spawn_popup()


func _spawn_popup() -> void:
	if popup_scene == null or _zone == null:
		return
	var popup: Node3D = popup_scene.instantiate()
	get_tree().current_scene.add_child(popup)
	popup.global_position = _zone.global_position + popup_offset


func _refresh_delivered_label() -> void:
	if _kitchen_loop == null:
		return
	delivered_label.text = "Delivered: %d/%d" % [_kitchen_loop.deliveries_made, _kitchen_loop.delivery_goal]


func _refresh_timer_label() -> void:
	if _kitchen_loop == null:
		return
	var t: float = max(0.0, _kitchen_loop.time_remaining)
	var minutes: int = int(t) / 60
	var seconds: int = int(t) % 60
	timer_label.text = "%d:%02d" % [minutes, seconds]
