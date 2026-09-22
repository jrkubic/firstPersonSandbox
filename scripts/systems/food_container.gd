class_name FoodContainer
extends Area3D

var _foods: Array[FoodItem] = []


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	tree_exiting.connect(_release_all)


## body_exited does not fire for bodies still inside when this area is
## freed, so drop the containment count of any food left on the plate.
func _release_all() -> void:
	for food in _foods:
		if is_instance_valid(food):
			food.containers = maxi(0, food.containers - 1)
	_foods.clear()


func get_contents() -> Array[FoodItem]:
	return _foods.duplicate()


func contents_text() -> String:
	if _foods.is_empty():
		return "empty"
	var parts: Array[String] = []
	for f in _foods:
		if not is_instance_valid(f):
			continue
		parts.append("%s(%s)" % [f.recipe_tag, f.state_name()])
	return ", ".join(parts)


# Enter/exit are kept symmetric (guarded by _foods membership) so each
# FoodItem.containers increment is matched by exactly one decrement.
func _on_body_entered(body: Node) -> void:
	if body is FoodItem and not _foods.has(body):
		var food: FoodItem = body as FoodItem
		_foods.append(food)
		food.containers += 1


func _on_body_exited(body: Node) -> void:
	if body is FoodItem and _foods.has(body):
		var food: FoodItem = body as FoodItem
		_foods.erase(food)
		food.containers = maxi(0, food.containers - 1)
