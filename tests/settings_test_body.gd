extends Node
## Headless checks for the Settings autoload: defaults, rebinding, conflict
## swap, reset, save and load through a temp config file. Never touches the
## developer's real user://settings.cfg.

const TEMP_CONFIG: String = "user://settings_test.cfg"
const EXPECTED_CHECKS: int = 10

var _passed: int = 0
var _failed: int = 0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	Settings.config_path = TEMP_CONFIG
	_remove_temp()
	Settings.reset_to_defaults()

	_check("defaults.interact_e", Settings.key_for(&"interact") == KEY_E,
		"interact=%s" % Settings.key_name(&"interact"))
	_check("defaults.walk_shift", Settings.key_for(&"walk") == KEY_SHIFT,
		"walk=%s" % Settings.key_name(&"walk"))

	Settings.bind(&"interact", KEY_G)
	_check("bind.updates_settings", Settings.key_for(&"interact") == KEY_G,
		"interact=%s" % Settings.key_name(&"interact"))
	_check("bind.updates_inputmap", _inputmap_has(&"interact", KEY_G) and not _inputmap_has(&"interact", KEY_E),
		"InputMap interact events=%s" % str(InputMap.action_get_events(&"interact")))

	# Conflict: throw (F) takes G, so interact gets F back.
	Settings.bind(&"throw", KEY_G)
	_check("bind.swaps_on_conflict",
		Settings.key_for(&"throw") == KEY_G and Settings.key_for(&"interact") == KEY_F,
		"throw=%s interact=%s" % [Settings.key_name(&"throw"), Settings.key_name(&"interact")])

	var saved := ConfigFile.new()
	var err: Error = saved.load(TEMP_CONFIG)
	_check("save.written", err == OK and int(saved.get_value("controls", "throw", 0)) == KEY_G,
		"load err=%d throw=%s" % [err, str(saved.get_value("controls", "throw", null))])

	Settings.mouse_sensitivity = 0.004
	saved.load(TEMP_CONFIG)
	_check("save.sensitivity", is_equal_approx(float(saved.get_value("mouse", "sensitivity", 0.0)), 0.004),
		"sensitivity=%s" % str(saved.get_value("mouse", "sensitivity", null)))

	Settings.reset_to_defaults()
	_check("reset.restores", Settings.key_for(&"interact") == KEY_E and Settings.key_for(&"throw") == KEY_F
		and is_equal_approx(Settings.mouse_sensitivity, Settings.DEFAULT_SENSITIVITY),
		"interact=%s throw=%s sens=%f" % [Settings.key_name(&"interact"), Settings.key_name(&"throw"), Settings.mouse_sensitivity])

	# Load: write a config by hand, then load it.
	var handmade := ConfigFile.new()
	handmade.set_value("controls", "interact", KEY_H)
	handmade.set_value("mouse", "sensitivity", 0.001)
	handmade.save(TEMP_CONFIG)
	Settings.load_settings()
	_check("load.applies", Settings.key_for(&"interact") == KEY_H and _inputmap_has(&"interact", KEY_H)
		and is_equal_approx(Settings.mouse_sensitivity, 0.001),
		"interact=%s sens=%f" % [Settings.key_name(&"interact"), Settings.mouse_sensitivity])
	_check("load.ignores_unknown_action", not Settings.REBINDABLE.has(&"pause"), "pause must not be rebindable")

	Settings.reset_to_defaults()
	_remove_temp()
	_finish()


func _inputmap_has(action: StringName, key: Key) -> bool:
	for event: InputEvent in InputMap.action_get_events(action):
		if event is InputEventKey and (event as InputEventKey).physical_keycode == key:
			return true
	return false


func _remove_temp() -> void:
	var absolute: String = ProjectSettings.globalize_path(TEMP_CONFIG)
	if FileAccess.file_exists(absolute):
		DirAccess.remove_absolute(absolute)


func _finish() -> void:
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
