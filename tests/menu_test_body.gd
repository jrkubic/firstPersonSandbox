extends Node
## Headless checks for scenes/menu.tscn: page flow, button wiring, status
## text, and (Task B) that the diorama builds and animates. Steam is never
## available headless, so the Multiplayer page must show Host disabled.

const MENU_SCENE: String = "res://scenes/menu.tscn"
const WATCHDOG_SECONDS: float = 60.0
const EXPECTED_CHECKS: int = 21

var _passed: int = 0
var _failed: int = 0
var _start_msec: int = 0
var _finished: bool = false
var _menu: CanvasLayer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_start_msec = Time.get_ticks_msec()
	_run.call_deferred()


func _process(_delta: float) -> void:
	if _finished:
		return
	if float(Time.get_ticks_msec() - _start_msec) / 1000.0 > WATCHDOG_SECONDS:
		print("FAIL watchdog: did not finish within %.0f s" % WATCHDOG_SECONDS)
		_failed += 1
		_finish()


func _run() -> void:
	var packed: PackedScene = load(MENU_SCENE)
	if packed == null:
		_check("menu.load", false, "could not load %s" % MENU_SCENE)
		_finish()
		return
	_menu = packed.instantiate() as CanvasLayer
	get_tree().root.add_child(_menu)
	get_tree().current_scene = _menu
	await get_tree().process_frame

	var main_page: Control = _menu.get_node_or_null("%MainPage") as Control
	var play_page: Control = _menu.get_node_or_null("%PlayPage") as Control
	var mp_page: Control = _menu.get_node_or_null("%MultiplayerPage") as Control
	var status: Label = _menu.get_node_or_null("%StatusLabel") as Label
	if not _check("menu.pages_exist",
			main_page != null and play_page != null and mp_page != null and status != null,
			"missing unique-named page or StatusLabel"):
		_finish()
		return
	_check("menu.main_first", main_page.visible and not play_page.visible and not mp_page.visible,
		"main=%s play=%s mp=%s" % [main_page.visible, play_page.visible, mp_page.visible])
	_check("menu.status_offline", status.text == "Steam not detected: solo only",
		"status=%s" % status.text)

	_press("%PlayButton")
	_check("menu.play_opens_play_page", play_page.visible and not main_page.visible,
		"play=%s main=%s" % [play_page.visible, main_page.visible])
	_press("%PlayBackButton")
	_check("menu.play_back", main_page.visible and not play_page.visible, "back did not return to main")

	_press("%PlayButton")
	_press("%MultiplayerButton")
	_check("menu.multiplayer_opens_mp_page", mp_page.visible and not play_page.visible,
		"mp=%s play=%s" % [mp_page.visible, play_page.visible])
	var host: Button = _menu.get_node("%HostButton") as Button
	_check("menu.host_disabled_without_steam", host.disabled, "Host enabled with no Steam")
	_check("menu.host_text", host.text == "Host via Steam", "host text=%s" % host.text)
	_press("%MultiplayerBackButton")
	_check("menu.mp_back", play_page.visible and not mp_page.visible, "back did not return to play page")

	var solo: Button = _menu.get_node("%SoloButton") as Button
	_check("menu.solo_wired", solo.pressed.get_connections().size() == 1,
		"solo connections=%d" % solo.pressed.get_connections().size())
	var quit: Button = _menu.get_node("%QuitButton") as Button
	_check("menu.quit_wired", quit.pressed.get_connections().size() == 1,
		"quit connections=%d" % quit.pressed.get_connections().size())
	_check("menu.host_wired", host.pressed.get_connections().size() == 1,
		"host connections=%d" % host.pressed.get_connections().size())

	# Settings page: opens, lists every rebindable action, rebinds by key press,
	# resets. Uses a temp config so the developer's bindings are untouched.
	Settings.config_path = "user://menu_test_settings.cfg"
	Settings.reset_to_defaults()
	var settings_page: Control = _menu.get_node_or_null("%SettingsPage") as Control
	_press("%SettingsButton")
	_check("settings.opens", settings_page != null and settings_page.visible and not main_page.visible,
		"settings=%s main=%s" % [settings_page != null and settings_page.visible, main_page.visible])
	var rows: Node = settings_page.get_node("Rows")
	_check("settings.one_row_per_action", rows.get_child_count() == Settings.REBINDABLE.size() * 2,
		"grid children=%d" % rows.get_child_count())
	var interact_button: Button = settings_page.key_button(&"interact")
	_check("settings.shows_current_key", interact_button != null and interact_button.text == "E",
		"text=%s" % (interact_button.text if interact_button else "<null>"))
	interact_button.pressed.emit()
	var press := InputEventKey.new()
	press.physical_keycode = KEY_G
	press.pressed = true
	Input.parse_input_event(press)
	await get_tree().process_frame
	_check("settings.rebinds_on_key", Settings.key_for(&"interact") == KEY_G and interact_button.text == "G",
		"interact=%s button=%s" % [Settings.key_name(&"interact"), interact_button.text])
	_press("%ResetButton")
	_check("settings.reset", Settings.key_for(&"interact") == KEY_E and interact_button.text == "E",
		"interact=%s button=%s" % [Settings.key_name(&"interact"), interact_button.text])
	_press("%SettingsBackButton")
	var temp_absolute: String = ProjectSettings.globalize_path(Settings.config_path)
	if FileAccess.file_exists(temp_absolute):
		DirAccess.remove_absolute(temp_absolute)

	var diorama: Node3D = _menu.get_node_or_null("Background/MenuDiorama") as Node3D
	if _check("diorama.present", diorama != null, "Background/MenuDiorama missing"):
		var chefs: Array[Node] = diorama.get_node("Chefs").get_children()
		_check("diorama.three_chefs", chefs.size() == 3, "chefs=%d" % chefs.size())
		var camera: Camera3D = diorama.get_node_or_null("Camera3D") as Camera3D
		_check("diorama.camera_current", camera != null and camera.current, "no current camera")
		var before: Array[Vector3] = []
		for chef: Node in chefs:
			before.append((chef as Node3D).global_position)
		for i in range(90):
			await get_tree().process_frame
		var moved: int = 0
		for i in range(chefs.size()):
			if (chefs[i] as Node3D).global_position.distance_to(before[i]) > 0.05:
				moved += 1
		_check("diorama.chefs_move", moved >= 2, "only %d chefs moved in 90 frames" % moved)
	else:
		_check("diorama.three_chefs", false, "skipped")
		_check("diorama.camera_current", false, "skipped")
		_check("diorama.chefs_move", false, "skipped")

	_finish()


func _press(unique_name: String) -> void:
	var button: Button = _menu.get_node(unique_name) as Button
	button.pressed.emit()


func _finish() -> void:
	_finished = true
	var total: int = _passed + _failed
	if total != EXPECTED_CHECKS:
		_failed += 1
		print("FAIL summary.count: %d checks ran, expected %d" % [total, EXPECTED_CHECKS])
	print("SUMMARY: %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _check(check_name: String, ok: bool, detail: String = "") -> bool:
	if ok:
		_passed += 1
		print("PASS %s" % check_name)
	else:
		_failed += 1
		print("FAIL %s: %s" % [check_name, detail])
	return ok
