class_name Plate
extends RigidBody3D

@onready var container: FoodContainer = $FoodContainer


func _ready() -> void:
	add_to_group(Groups.GRABBABLE)
	add_to_group(Groups.PLATE)


func get_contents() -> Array[FoodItem]:
	return container.get_contents()


## True while any food resting on this plate is being held by a player.
func has_held_contents() -> bool:
	for food in get_contents():
		if is_instance_valid(food) and food.is_in_group(Groups.HELD):
			return true
	return false
