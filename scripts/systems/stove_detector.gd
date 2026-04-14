class_name StoveDetector
extends Area3D

var _overlapping_stoves: int = 0


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func is_on_stove() -> bool:
	return _overlapping_stoves > 0


func _on_body_entered(body: Node) -> void:
	if body.is_in_group("stove"):
		_overlapping_stoves += 1


func _on_body_exited(body: Node) -> void:
	if body.is_in_group("stove"):
		_overlapping_stoves = max(0, _overlapping_stoves - 1)
