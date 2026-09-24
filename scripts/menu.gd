extends CanvasLayer
## Title menu: Play > Solo / Multiplayer > Host via Steam, plus a Settings
## page (key rebinding and mouse sensitivity). Join is by Steam invite only,
## so the Multiplayer page has a single action plus help text.

@export_file("*.tscn") var game_scene: String = "res://scenes/kitchen.tscn"

@onready var main_page: Control = %MainPage
@onready var play_page: Control = %PlayPage
@onready var multiplayer_page: Control = %MultiplayerPage
@onready var settings_page: Control = %SettingsPage
@onready var play_button: Button = %PlayButton
@onready var settings_button: Button = %SettingsButton
@onready var quit_button: Button = %QuitButton
@onready var solo_button: Button = %SoloButton
@onready var multiplayer_button: Button = %MultiplayerButton
@onready var play_back_button: Button = %PlayBackButton
@onready var host_button: Button = %HostButton
@onready var multiplayer_back_button: Button = %MultiplayerBackButton
@onready var status_label: Label = %StatusLabel


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	play_button.pressed.connect(func() -> void: _show_page(play_page))
	settings_button.pressed.connect(func() -> void: _show_page(settings_page))
	settings_page.back_pressed.connect(func() -> void: _show_page(main_page))
	quit_button.pressed.connect(_on_quit_pressed)
	solo_button.pressed.connect(_on_solo_pressed)
	multiplayer_button.pressed.connect(func() -> void: _show_page(multiplayer_page))
	play_back_button.pressed.connect(func() -> void: _show_page(main_page))
	host_button.pressed.connect(_on_host_pressed)
	multiplayer_back_button.pressed.connect(func() -> void: _show_page(play_page))
	_refresh_host_button()
	if NetSession.last_message != "":
		status_label.text = NetSession.last_message
		NetSession.last_message = ""
	elif SteamManager.is_ready():
		status_label.text = "Steam ready as %s." % SteamManager.persona_name()
	else:
		status_label.text = "Steam not detected: solo only"
	NetSession.session_ended.connect(_on_session_ended)
	_show_page(main_page)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if multiplayer_page.visible:
			_show_page(play_page)
		elif play_page.visible or settings_page.visible:
			_show_page(main_page)


func _show_page(page: Control) -> void:
	for candidate: Control in [main_page, play_page, multiplayer_page, settings_page]:
		candidate.visible = candidate == page


func _refresh_host_button() -> void:
	host_button.disabled = not SteamManager.is_ready()


func _on_session_ended(reason: String) -> void:
	status_label.text = reason
	_refresh_host_button()
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
