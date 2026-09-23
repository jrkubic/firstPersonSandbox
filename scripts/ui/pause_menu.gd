extends CanvasLayer
## Escape menu. Offline it pauses the tree; online it only releases the
## mouse (pausing would stall replication), and the host gets Invite and
## Start Run here because the mouse is captured while playing.

@export_file("*.tscn") var menu_scene: String = "res://scenes/menu.tscn"

@onready var resume_button: Button = $MarginContainer/VBoxContainer/ResumeButton
@onready var invite_button: Button = $MarginContainer/VBoxContainer/InviteButton
@onready var start_run_button: Button = $MarginContainer/VBoxContainer/StartRunButton
@onready var menu_button: Button = $MarginContainer/VBoxContainer/MenuButton
@onready var quit_button: Button = $MarginContainer/VBoxContainer/QuitButton

var _net: KitchenNet


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	visible = false
	_net = get_tree().get_first_node_in_group(Groups.KITCHEN_NET) as KitchenNet
	resume_button.pressed.connect(_resume)
	invite_button.pressed.connect(_on_invite_pressed)
	start_run_button.pressed.connect(_on_start_run_pressed)
	menu_button.pressed.connect(_on_menu_pressed)
	quit_button.pressed.connect(_on_quit_pressed)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if visible:
			_resume()
		else:
			_pause()


func _pause() -> void:
	var host: bool = NetSession.role == NetSession.Role.HOST
	invite_button.visible = host and SteamManager.is_ready()
	start_run_button.visible = host and _net != null and _net.is_practice()
	menu_button.text = "Leave" if NetSession.is_online() else "Main Menu"
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if not NetSession.is_online():
		get_tree().paused = true


func _resume() -> void:
	visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_invite_pressed() -> void:
	SteamManager.open_invite_dialog(NetSession.lobby_id)


func _on_start_run_pressed() -> void:
	_resume()
	if _net:
		_net.start_run()


func _on_menu_pressed() -> void:
	get_tree().paused = false
	NetSession.leave()
	get_tree().change_scene_to_file(menu_scene)


func _on_quit_pressed() -> void:
	NetSession.leave()
	get_tree().quit()
