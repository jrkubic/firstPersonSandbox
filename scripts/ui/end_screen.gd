extends CanvasLayer
## Shown when KitchenLoop reaches WON. Polls the replicated state so it
## works on clients, where game_won never fires. Play Again and Back to
## Practice reset the kitchen in place (host only); Leave drops the session.

@export_file("*.tscn") var menu_scene: String = "res://scenes/menu.tscn"
@export_node_path("KitchenLoop") var kitchen_loop_path: NodePath

@onready var title_label: Label = $MarginContainer/VBoxContainer/TitleLabel
@onready var stars_label: Label = $MarginContainer/VBoxContainer/StarsLabel
@onready var time_label: Label = $MarginContainer/VBoxContainer/TimeLabel
@onready var play_again_button: Button = $MarginContainer/VBoxContainer/PlayAgainButton
@onready var practice_button: Button = $MarginContainer/VBoxContainer/PracticeButton
@onready var menu_button: Button = $MarginContainer/VBoxContainer/MenuButton
@onready var quit_button: Button = $MarginContainer/VBoxContainer/QuitButton

var _loop: KitchenLoop
var _net: KitchenNet


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	visible = false
	_loop = get_node(kitchen_loop_path)
	_net = get_tree().get_first_node_in_group(Groups.KITCHEN_NET) as KitchenNet
	play_again_button.pressed.connect(_on_play_again_pressed)
	practice_button.pressed.connect(_on_practice_pressed)
	menu_button.pressed.connect(_on_menu_pressed)
	quit_button.pressed.connect(_on_quit_pressed)


func _process(_delta: float) -> void:
	var won: bool = _loop.state == KitchenLoop.State.WON
	if won and not visible:
		_show()
	elif not won and visible:
		_hide()


func _show() -> void:
	var stars: int = _loop.get_stars()
	title_label.text = "Service Complete"
	stars_label.text = _stars_text(stars)
	time_label.text = "Time: %s" % _format_time(_loop.elapsed_time)
	var host: bool = NetSession.is_authority()
	play_again_button.visible = host
	practice_button.visible = host and NetSession.is_online()
	menu_button.text = "Leave" if NetSession.is_online() else "Main Menu"
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if not NetSession.is_online():
		get_tree().paused = true


func _hide() -> void:
	visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_play_again_pressed() -> void:
	if _net:
		_net.start_run()


func _on_practice_pressed() -> void:
	if _net:
		_net.return_to_practice()


func _on_menu_pressed() -> void:
	get_tree().paused = false
	NetSession.leave()
	get_tree().change_scene_to_file(menu_scene)


func _on_quit_pressed() -> void:
	NetSession.leave()
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
