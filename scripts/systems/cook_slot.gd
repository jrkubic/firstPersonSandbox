class_name CookSlot
extends Area3D

@export_node_path("Pan") var pan_path: NodePath

var _foods: Array[FoodItem] = []
@onready var _pan: Pan = get_node(pan_path)


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _physics_process(delta: float) -> void:
	if _foods.is_empty():
		return
	if not _pan.is_on_stove():
		return
	for food in _foods:
		if not is_instance_valid(food):
			continue
		if food.is_in_group(Groups.HELD):
			continue
		# Food resting on a plate (FoodContainer) is served, not cooking, even
		# if the plate is set down on the pan.
		if food.is_contained():
			continue
		food.tick_cook(delta)


## True while the food overlaps this slot's volume (ticked or not).
func has_food(food: FoodItem) -> bool:
	return _foods.has(food)


func _on_body_entered(body: Node) -> void:
	if body is FoodItem and not _foods.has(body):
		_foods.append(body)


func _on_body_exited(body: Node) -> void:
	if body is FoodItem:
		_foods.erase(body)
