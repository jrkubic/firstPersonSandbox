class_name CookSlot
extends Area3D

@export_node_path("Pan") var pan_path: NodePath
## Stations with their own heat (the toaster) tick whenever food is in the slot.
@export var always_hot: bool = false

var _foods: Array[FoodItem] = []
var _pan: Pan


func _ready() -> void:
	if not pan_path.is_empty():
		_pan = get_node_or_null(pan_path) as Pan
	if not always_hot and _pan == null:
		push_warning("CookSlot %s has no heat source: set pan_path or always_hot" % get_path())
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _physics_process(delta: float) -> void:
	if not NetSession.is_authority():
		return
	if _foods.is_empty():
		return
	if not _is_heating():
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


func _is_heating() -> bool:
	return always_hot or (_pan != null and _pan.is_on_stove())


func _on_body_entered(body: Node) -> void:
	if body is FoodItem and not _foods.has(body):
		_foods.append(body)


func _on_body_exited(body: Node) -> void:
	if body is FoodItem:
		_foods.erase(body)
