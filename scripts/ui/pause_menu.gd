extends CanvasLayer
## Escape menu. Offline it pauses the tree; online it only releases the
## mouse (pausing would stall replication), and the host gets Invite and
## Start Run here because the mouse is captured while playing. Settings opens
## the controls page in place of the buttons; Escape backs out one level.

@export_file("*.tscn") var menu_scene: String = "res://scenes/menu.tscn"
## Escape is ignored while the end screen is showing.
@export_node_path("CanvasLayer") var end_screen_path: NodePath

@onready var buttons: Control = %VBoxContainer
@onready var settings_page: Control = %SettingsPage
@onready var resume_button: Button = $MarginContainer/VBoxContainer/ResumeButton
@onready var invite_button: Button = $MarginContainer/VBoxContainer/InviteButton
@onready var start_run_button: Button = $MarginContainer/VBoxContainer/StartRunButton
@onready var settings_button: Button = %SettingsButton
@onready var menu_button: Button = $MarginContainer/VBoxContainer/MenuButton
@onready var quit_button: Button = $MarginContainer/VBoxContainer/QuitButton

var _net: KitchenNet
var _end_screen: CanvasLayer


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	visible = false
	_net = get_tree().get_first_node_in_group(Groups.KITCHEN_NET) as KitchenNet
	if not end_screen_path.is_empty():
		_end_screen = get_node_or_null(end_screen_path) as CanvasLayer
	resume_button.pressed.connect(_resume)
	invite_button.pressed.connect(_on_invite_pressed)
	start_run_button.pressed.connect(_on_start_run_pressed)
	settings_button.pressed.connect(_show_settings)
	settings_page.back_pressed.connect(_show_buttons)
	menu_button.pressed.connect(_on_menu_pressed)
	quit_button.pressed.connect(_on_quit_pressed)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if _end_screen != null and _end_screen.visible:
			return
		if visible and settings_page.visible:
			# One level back. While the page is listening for a key it
			# consumes Escape itself in _input, so this never fires then.
			_show_buttons()
			return
		if visible:
			_resume()
		else:
			_pause()


func _show_settings() -> void:
	buttons.visible = false
	settings_page.visible = true


func _show_buttons() -> void:
	settings_page.visible = false
	buttons.visible = true


func _pause() -> void:
	_show_buttons()
	var host: bool = NetSession.role == NetSession.Role.HOST
	invite_button.visible = host and SteamManager.is_ready()
	start_run_button.visible = host and _net != null and _net.is_practice()
	menu_button.text = "Leave" if NetSession.is_online() else "Main Menu"
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if not NetSession.is_online():
		get_tree().paused = true


func _resume() -> void:
	_show_buttons()
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
