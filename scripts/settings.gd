extends Node
## Player-configurable controls, autoloaded as Settings. Owns the truth for
## one key per rebindable action and the mouse sensitivity, applies them to
## the InputMap, and persists them to user://settings.cfg. Gameplay reads
## actions by name, so rebinding needs no other code changes.
##
## Escape (the "pause" action) is deliberately not rebindable so the menus
## can always be backed out of.

signal controls_changed

const REBINDABLE: Array[StringName] = [
	&"move_forward", &"move_back", &"move_left", &"move_right",
	&"jump", &"crouch", &"walk", &"interact", &"throw", &"debug_overlay",
]
const ACTION_LABELS: Dictionary = {
	&"move_forward": "Move forward",
	&"move_back": "Move back",
	&"move_left": "Move left",
	&"move_right": "Move right",
	&"jump": "Jump",
	&"crouch": "Crouch",
	&"walk": "Walk",
	&"interact": "Grab / release",
	&"throw": "Throw",
	&"debug_overlay": "Debug overlay",
}
const DEFAULT_SENSITIVITY: float = 0.0022
const MIN_SENSITIVITY: float = 0.0005
const MAX_SENSITIVITY: float = 0.006

## Where settings are stored. Tests point this at a temp file.
var config_path: String = "user://settings.cfg"

var mouse_sensitivity: float = DEFAULT_SENSITIVITY:
	set(value):
		mouse_sensitivity = clampf(value, MIN_SENSITIVITY, MAX_SENSITIVITY)
		save()
		controls_changed.emit()

# action -> physical keycode as the project ships it (captured before any
# saved settings are applied), so Reset can restore them.
var _defaults: Dictionary = {}


func _ready() -> void:
	for action: StringName in REBINDABLE:
		_defaults[action] = key_for(action)
	load_settings()


## The physical key bound to action, or KEY_NONE.
func key_for(action: StringName) -> Key:
	for event: InputEvent in InputMap.action_get_events(action):
		if event is InputEventKey:
			var key_event := event as InputEventKey
			return key_event.physical_keycode if key_event.physical_keycode != KEY_NONE else key_event.keycode
	return KEY_NONE


## Human-readable name for the key bound to action ("E", "Shift", "Unbound").
func key_name(action: StringName) -> String:
	var key: Key = key_for(action)
	if key == KEY_NONE:
		return "Unbound"
	# The headless display server cannot map physical keys to the current
	# layout (it logs an error per call), so fall back to the physical key.
	var label_key: Key = KEY_NONE
	if DisplayServer.get_name() != "headless":
		label_key = DisplayServer.keyboard_get_keycode_from_physical(key)
	return OS.get_keycode_string(label_key if label_key != KEY_NONE else key)


## Binds key to action. If another rebindable action already uses key, the
## two actions swap keys so nothing is left unbound. Saves and notifies.
func bind(action: StringName, key: Key) -> void:
	if not REBINDABLE.has(action) or key == KEY_NONE:
		return
	var previous: Key = key_for(action)
	for other: StringName in REBINDABLE:
		if other != action and key_for(other) == key:
			_apply(other, previous)
	_apply(action, key)
	save()
	controls_changed.emit()


func reset_to_defaults() -> void:
	for action: StringName in REBINDABLE:
		_apply(action, _defaults[action])
	mouse_sensitivity = DEFAULT_SENSITIVITY  # setter saves and emits


func load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(config_path) != OK:
		return
	# ConfigFile.get_value treats a null default as "no default" and logs an
	# error for every missing key, so test presence first.
	for action: StringName in REBINDABLE:
		if not config.has_section_key("controls", String(action)):
			continue
		var stored: Variant = config.get_value("controls", String(action))
		if stored is int and int(stored) != KEY_NONE:
			_apply(action, int(stored) as Key)
	var sensitivity: Variant = null
	if config.has_section_key("mouse", "sensitivity"):
		sensitivity = config.get_value("mouse", "sensitivity")
	if sensitivity is float:
		mouse_sensitivity = float(sensitivity)  # setter clamps, saves, emits
	else:
		controls_changed.emit()


func save() -> void:
	var config := ConfigFile.new()
	for action: StringName in REBINDABLE:
		config.set_value("controls", String(action), int(key_for(action)))
	config.set_value("mouse", "sensitivity", mouse_sensitivity)
	config.save(config_path)


func _apply(action: StringName, key: Key) -> void:
	InputMap.action_erase_events(action)
	if key == KEY_NONE:
		return
	var event := InputEventKey.new()
	event.physical_keycode = key
	InputMap.action_add_event(action, event)
