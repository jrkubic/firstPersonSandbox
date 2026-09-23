extends CanvasLayer

@export_file("*.tscn") var game_scene: String = "res://scenes/kitchen.tscn"

@onready var solo_button: Button = $Control/MarginContainer/VBoxContainer/StartButton
@onready var host_button: Button = $Control/MarginContainer/VBoxContainer/HostButton
@onready var quit_button: Button = $Control/MarginContainer/VBoxContainer/QuitButton
@onready var status_label: Label = $Control/MarginContainer/VBoxContainer/StatusLabel


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	solo_button.pressed.connect(_on_solo_pressed)
	host_button.pressed.connect(_on_host_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	host_button.disabled = not SteamManager.is_ready()
	if NetSession.last_message != "":
		status_label.text = NetSession.last_message
		NetSession.last_message = ""
	elif SteamManager.is_ready():
		status_label.text = "Steam ready as %s. Accept a friend's invite or host." % SteamManager.persona_name()
	else:
		status_label.text = "Steam not detected: solo only"
	NetSession.session_ended.connect(_on_session_ended)


func _on_session_ended(reason: String) -> void:
	status_label.text = reason
	host_button.disabled = not SteamManager.is_ready()
	NetSession.last_message = ""


func _on_solo_pressed() -> void:
	NetSession.leave()
	get_tree().change_scene_to_file(game_scene)


func _on_host_pressed() -> void:
	status_label.text = "Creating Steam lobby..."
	host_button.disabled = true
	NetSession.host_steam()


func _on_quit_pressed() -> void:
	NetSession.leave()
	get_tree().quit()
