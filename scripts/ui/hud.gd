extends CanvasLayer
## Delivered counter and timer. Reads KitchenLoop every frame so it works
## on clients, where the delivered signal never fires; the +1 popup keys
## off the replicated counter going up.

@export_node_path("DeliveryZone") var delivery_zone_path: NodePath
@export_node_path("KitchenLoop") var kitchen_loop_path: NodePath
@export var popup_scene: PackedScene
@export var popup_offset: Vector3 = Vector3(0, 0.5, 0)

@onready var delivered_label: Label = $DeliveredLabel
@onready var timer_label: Label = $TimerLabel

var _zone: DeliveryZone
var _kitchen_loop: KitchenLoop
var _last_deliveries: int = 0


func _ready() -> void:
	_zone = get_node(delivery_zone_path)
	_kitchen_loop = get_node(kitchen_loop_path)
	_last_deliveries = _kitchen_loop.deliveries_made
	_refresh()


func _process(_delta: float) -> void:
	if _kitchen_loop.deliveries_made > _last_deliveries:
		_spawn_popup()
	_last_deliveries = _kitchen_loop.deliveries_made
	_refresh()


func _spawn_popup() -> void:
	if popup_scene == null or _zone == null:
		return
	var popup: Node3D = popup_scene.instantiate()
	get_tree().current_scene.add_child(popup)
	popup.global_position = _zone.global_position + popup_offset


func _refresh() -> void:
	if _kitchen_loop.practice:
		delivered_label.text = "Practice  Delivered: %d" % _kitchen_loop.deliveries_made
		timer_label.text = "--:--"
		return
	delivered_label.text = "Delivered: %d/%d" % [_kitchen_loop.deliveries_made, _kitchen_loop.delivery_goal]
	var t: float = _kitchen_loop.elapsed_time
	timer_label.text = "%d:%02d" % [int(t) / 60, int(t) % 60]
