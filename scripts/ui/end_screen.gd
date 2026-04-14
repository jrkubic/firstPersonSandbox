extends CanvasLayer

@export_file("*.tscn") var menu_scene: String = "res://scenes/menu.tscn"
@export_node_path("KitchenLoop") var kitchen_loop_path: NodePath

@onready var title_label: Label = $MarginContainer/VBoxContainer/TitleLabel
@onready var stars_label: Label = $MarginContainer/VBoxContainer/StarsLabel
@onready var time_label: Label = $MarginContainer/VBoxContainer/TimeLabel
@onready var play_again_button: Button = $MarginContainer/VBoxContainer/PlayAgainButton
@onready var menu_button: Button = $MarginContainer/VBoxContainer/MenuButton
@onready var quit_button: Button = $MarginContainer/VBoxContainer/QuitButton


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	visible = false
	var loop: KitchenLoop = get_node(kitchen_loop_path)
	loop.game_won.connect(_on_game_won)
	play_again_button.pressed.connect(_on_play_again_pressed)
	menu_button.pressed.connect(_on_menu_pressed)
	quit_button.pressed.connect(_on_quit_pressed)


func _on_game_won(elapsed_time: float, stars: int) -> void:
	title_label.text = "Service Complete"
	stars_label.text = _stars_text(stars)
	time_label.text = "Time: %s" % _format_time(elapsed_time)
	_show()


func _show() -> void:
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = true


func _on_play_again_pressed() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()


func _on_menu_pressed() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file(menu_scene)


func _on_quit_pressed() -> void:
	get_tree().quit()


func _stars_text(stars: int) -> String:
	var filled: String = "★".repeat(stars)
	var empty: String = "☆".repeat(3 - stars)
	return filled + empty


func _format_time(seconds: float) -> String:
	var t: int = int(seconds)
	var m: int = t / 60
	var s: int = t % 60
	return "%d:%02d" % [m, s]
