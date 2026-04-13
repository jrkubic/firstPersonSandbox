extends CanvasLayer

@export_file("*.tscn") var game_scene: String = "res://scenes/world.tscn"

@onready var start_button: Button = $Control/MarginContainer/VBoxContainer/StartButton
@onready var quit_button: Button = $Control/MarginContainer/VBoxContainer/QuitButton


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	start_button.pressed.connect(_on_start_pressed)
	quit_button.pressed.connect(_on_quit_pressed)


func _on_start_pressed() -> void:
	get_tree().change_scene_to_file(game_scene)


func _on_quit_pressed() -> void:
	get_tree().quit()
