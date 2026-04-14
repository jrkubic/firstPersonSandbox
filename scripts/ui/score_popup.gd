class_name ScorePopup
extends Label3D

@export var lifetime: float = 1.0
@export var rise_distance: float = 1.0

var _elapsed: float = 0.0


func _process(delta: float) -> void:
	_elapsed += delta
	var t: float = _elapsed / lifetime
	if t >= 1.0:
		queue_free()
		return
	position.y += (rise_distance / lifetime) * delta
	modulate.a = 1.0 - t
