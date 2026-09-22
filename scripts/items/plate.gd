class_name Plate
extends RigidBody3D

@onready var container: FoodContainer = $FoodContainer


func _ready() -> void:
	add_to_group(Groups.GRABBABLE)
	add_to_group(Groups.PLATE)


func get_contents() -> Array[FoodItem]:
	return container.get_contents()
