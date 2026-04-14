class_name Plate
extends RigidBody3D

@onready var container: FoodContainer = $FoodContainer


func _ready() -> void:
	add_to_group("grabbable")
	add_to_group("plate")


func get_contents() -> Array[FoodItem]:
	return container.get_contents()
