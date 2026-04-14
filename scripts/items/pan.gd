class_name Pan
extends RigidBody3D

@onready var stove_detector: StoveDetector = $StoveDetector


func _ready() -> void:
	add_to_group("grabbable")
	add_to_group("pan")


func is_on_stove() -> bool:
	return stove_detector.is_on_stove()


func on_stove_text() -> String:
	return "true" if is_on_stove() else "false"
