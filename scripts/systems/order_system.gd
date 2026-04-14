class_name OrderSystem
extends Node

@export var recipe_tag: String = "egg"
@export var required_count: int = 1


func current_order_text() -> String:
	return "%d× %s(COOKED)" % [required_count, recipe_tag]


func check_delivery(plate: Plate) -> bool:
	if plate == null:
		return false
	var contents: Array[FoodItem] = plate.get_contents()
	if contents.size() != required_count:
		return false
	for f in contents:
		if not is_instance_valid(f):
			return false
		if f.recipe_tag != recipe_tag:
			return false
		if f.state != FoodItem.State.COOKED:
			return false
	return true
