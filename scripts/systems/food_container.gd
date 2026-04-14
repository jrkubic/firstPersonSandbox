class_name FoodContainer
extends Area3D

var _foods: Array[FoodItem] = []


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


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


func _on_body_entered(body: Node) -> void:
	if body is FoodItem and not _foods.has(body):
		_foods.append(body)


func _on_body_exited(body: Node) -> void:
	if body is FoodItem:
		_foods.erase(body)
