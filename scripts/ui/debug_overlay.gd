extends CanvasLayer

@onready var label: Label = $Label

var _watched: Dictionary = {}


func _ready() -> void:
	visible = false
	add_to_group("debug_overlay")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_overlay"):
		visible = not visible


func _process(_delta: float) -> void:
	if not visible:
		return
	var lines: Array[String] = []
	for key in _watched.keys():
		var getter: Callable = _watched[key]
		var value: Variant = getter.call() if getter.is_valid() else "<invalid>"
		lines.append("%s: %s" % [key, value])
	label.text = "\n".join(lines)


func watch(key: String, getter: Callable) -> void:
	_watched[key] = getter


func unwatch(key: String) -> void:
	_watched.erase(key)
