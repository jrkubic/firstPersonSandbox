class_name Recipe
extends Resource
## One order the kitchen can ask for. A plate satisfies it when its contents
## are exactly these ingredient tags (one FoodItem per entry), every one of
## them COOKED. Extra food or a burned item rejects the plate.

@export var id: StringName = &""
## Text shown on the order board.
@export var ticket: String = ""
## recipe_tag of each required FoodItem, e.g. ["egg", "bread"].
@export var ingredients: PackedStringArray = PackedStringArray()


func matches(contents: Array[FoodItem]) -> bool:
	if contents.size() != ingredients.size():
		return false
	var needed: Array = Array(ingredients)
	for food in contents:
		if not is_instance_valid(food) or food.state != FoodItem.State.COOKED:
			return false
		var at: int = needed.find(food.recipe_tag)
		if at < 0:
			return false
		needed.remove_at(at)
	return needed.is_empty()
