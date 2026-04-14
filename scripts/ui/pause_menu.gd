extends CanvasLayer

@export_file("*.tscn") var menu_scene: String = "res://scenes/menu.tscn"

@onready var resume_button: Button = $MarginContainer/VBoxContainer/ResumeButton
@onready var menu_button: Button = $MarginContainer/VBoxContainer/MenuButton
@onready var quit_button: Button = $MarginContainer/VBoxContainer/QuitButton


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	visible = false
	resume_button.pressed.connect(_on_resume_pressed)
	menu_button.pressed.connect(_on_menu_pressed)
	quit_button.pressed.connect(_on_quit_pressed)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if visible:
			_resume()
		else:
			_pause()


func _pause() -> void:
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = true


func _resume() -> void:
	visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_resume_pressed() -> void:
	_resume()


func _on_menu_pressed() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file(menu_scene)


func _on_quit_pressed() -> void:
	get_tree().quit()
