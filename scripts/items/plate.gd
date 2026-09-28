class_name Plate
extends RigidBody3D

@onready var container: FoodContainer = $FoodContainer


func _ready() -> void:
	add_to_group(Groups.GRABBABLE)
	add_to_group(Groups.PLATE)


## Runs after the physics step with this plate's updated transform, so
## attached food is placed on the plate's current position rather than one
## tick behind it (FoodItem._physics_process is the fallback for a sleeping
## plate, which gets no _integrate_forces; both compute the same target).
func _integrate_forces(_state: PhysicsDirectBodyState3D) -> void:
	if not NetSession.is_authority():
		return
	for food in container.get_contents():
		if is_instance_valid(food) and food.plated_on == get_path():
			food.follow_plate()


func get_contents() -> Array[FoodItem]:
	return container.get_contents()


## True while any food resting on this plate is being held by a player.
func has_held_contents() -> bool:
	for food in get_contents():
		if is_instance_valid(food) and food.is_in_group(Groups.HELD):
			return true
	return false
