# Controls Settings Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or subagent-driven-development) to implement this plan task-by-task.

**Goal:** A Settings page on the main menu where the player rebinds one key per gameplay action and sets mouse sensitivity, persisted to `user://settings.cfg` and applied at boot.

**Architecture:** A `Settings` autoload owns the truth: it captures the project's default bindings at boot, loads the config file, rewrites the `InputMap` for each rebindable action, and saves on every change. Gameplay code already reads actions by name, so only the mouse sensitivity read in `Player` changes. The UI is a `SettingsPage` `VBoxContainer` built in code (one row per action, a slider, Reset and Back) that lives as a fourth page inside `scenes/menu.tscn`; while a row is listening for a key, the page consumes input in `_input` so the menu's Escape handler cannot fire.

**Tech Stack:** Godot 4.7.2, GDScript, `InputMap`, `ConfigFile`.

---

## Conventions

- Root `C:\Projects\firstPersonSandbox`, branch `settings`.
- `GODOT` = `C:\Users\Jake\Downloads\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe`.
- Existing tests: smoke (`103 passed, 0 failed, 1 xfailed`), net (`NET TEST PASSED`), menu (`16 passed`). Headless tests are a SceneTree launcher + Node body (`tests/menu_test.gd` + `tests/menu_test_body.gd` is the template to copy).
- The `Settings` autoload loads the real `user://settings.cfg` at boot. Every test that touches settings must first set `Settings.config_path` to a temp file and call `Settings.reset_to_defaults()`, and delete that temp file at the end, so the developer's own bindings are never read or clobbered.
- Commit per task with the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; stage files explicitly.

---

### Task 1: `Settings` autoload with rebinding, persistence and a headless test

**Files:**
- Create: `scripts/settings.gd`, `tests/settings_test.gd`, `tests/settings_test_body.gd`
- Modify: `project.godot` (`[autoload]`), `scripts/player.gd` (sensitivity read)

**Step 1: The failing test**

`tests/settings_test.gd`:

```gdscript
extends SceneTree
## Headless settings test entry point (launcher + body, see smoke_test.gd).
##   Godot_console.exe --headless --path . --script res://tests/settings_test.gd

const BODY_SCRIPT: String = "res://tests/settings_test_body.gd"


func _initialize() -> void:
	var body_script: GDScript = load(BODY_SCRIPT) as GDScript
	if body_script == null:
		printerr("FAIL launcher: could not load %s" % BODY_SCRIPT)
		quit(1)
		return
	var body: Node = body_script.new() as Node
	body.name = "SettingsTest"
	root.add_child(body)
```

`tests/settings_test_body.gd`:

```gdscript
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
```

Run `& $GODOT --headless --path . --script res://tests/settings_test.gd`: expect a compile error naming `Settings` (the failing state).

**Step 2: The autoload `scripts/settings.gd`**

```gdscript
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
	var label_key: Key = DisplayServer.keyboard_get_keycode_from_physical(key)
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
	for action: StringName in REBINDABLE:
		var stored: Variant = config.get_value("controls", String(action), null)
		if stored is int and int(stored) != KEY_NONE:
			_apply(action, int(stored) as Key)
	var sensitivity: Variant = config.get_value("mouse", "sensitivity", null)
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
```

Note: `_defaults` are captured from the `InputMap` as the project ships it; `crouch` ships with two keys (Ctrl and C), and `key_for` returns the first, so after any rebind or reset crouch has one key. Acceptable per the design.

**Step 3: Register and use it**

`project.godot` `[autoload]`: add `Settings="*res://scripts/settings.gd"` as the first entry.

`scripts/player.gd`: replace the two `mouse_sensitivity` uses in `_unhandled_input` with `Settings.mouse_sensitivity`, delete the `@export var mouse_sensitivity := 0.0022` line, and update the README's debug/controls text if it mentions the export (it says "mouse sensitivity exported on Player" in the old design doc only; README does not).

**Step 4: Run**

Settings test → `SUMMARY: 10 passed, 0 failed`. Smoke → `103 passed, 0 failed, 1 xfailed` (the smoke and net test bodies must add `"Settings"` to their `_ensure_autoloads` list only if they rely on it; they do not, and the engine adds autoloads before `_initialize`, so no change). Net → `NET TEST PASSED`.

**Step 5: Commit** `Settings autoload: rebindable keys, mouse sensitivity, user://settings.cfg`.

---

### Task 2: Settings page in the menu

**Files:**
- Create: `scripts/ui/settings_page.gd`
- Modify: `scenes/menu.tscn` (SettingsButton on MainPage; SettingsPage node), `scripts/menu.gd`
- Modify: `tests/menu_test_body.gd` (`EXPECTED_CHECKS` 16 → 21)
- Modify: `README.md`, `tests/README.md`

**Step 1: Failing checks**

In `tests/menu_test_body.gd`, before the `diorama` block, add (and set `EXPECTED_CHECKS = 21`):

```gdscript
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
```

Run the menu test: expect a parse error on `key_button` / missing nodes.

**Step 2: The page script `scripts/ui/settings_page.gd`**

```gdscript
extends VBoxContainer
## Controls settings page: one row per rebindable action (label + key
## button), a mouse sensitivity slider, Reset and Back. Click a key button and
## press a key to rebind; Escape cancels the listen. Attach to a VBoxContainer
## named SettingsPage inside the menu; it builds its own children.

signal back_pressed

const LISTENING_TEXT: String = "Press a key..."

var _buttons: Dictionary = {}   # action -> Button
var _listening: StringName = &""
var _rows: GridContainer
var _slider: HSlider
var _slider_label: Label


func _ready() -> void:
	_build()
	Settings.controls_changed.connect(_refresh)
	_refresh()


func key_button(action: StringName) -> Button:
	return _buttons.get(action) as Button


func _build() -> void:
	var title := Label.new()
	title.text = "Controls"
	title.add_theme_font_size_override("font_size", 34)
	add_child(title)

	_rows = GridContainer.new()
	_rows.name = "Rows"
	_rows.columns = 2
	_rows.add_theme_constant_override("h_separation", 24)
	add_child(_rows)
	for action: StringName in Settings.REBINDABLE:
		var label := Label.new()
		label.text = Settings.ACTION_LABELS.get(action, String(action))
		label.add_theme_font_size_override("font_size", 22)
		_rows.add_child(label)
		var button := Button.new()
		button.custom_minimum_size = Vector2(160, 0)
		button.add_theme_font_size_override("font_size", 22)
		button.pressed.connect(_on_key_button_pressed.bind(action))
		_rows.add_child(button)
		_buttons[action] = button

	var sensitivity_row := HBoxContainer.new()
	add_child(sensitivity_row)
	var sensitivity_label := Label.new()
	sensitivity_label.text = "Mouse sensitivity"
	sensitivity_label.add_theme_font_size_override("font_size", 22)
	sensitivity_row.add_child(sensitivity_label)
	_slider = HSlider.new()
	_slider.custom_minimum_size = Vector2(240, 0)
	_slider.min_value = Settings.MIN_SENSITIVITY
	_slider.max_value = Settings.MAX_SENSITIVITY
	_slider.step = 0.0001
	_slider.value_changed.connect(func(value: float) -> void: Settings.mouse_sensitivity = value)
	sensitivity_row.add_child(_slider)
	_slider_label = Label.new()
	_slider_label.add_theme_font_size_override("font_size", 22)
	sensitivity_row.add_child(_slider_label)

	var buttons := HBoxContainer.new()
	add_child(buttons)
	var reset := Button.new()
	reset.name = "ResetButton"
	reset.unique_name_in_owner = false
	reset.text = "Reset to defaults"
	reset.add_theme_font_size_override("font_size", 24)
	reset.pressed.connect(func() -> void: Settings.reset_to_defaults())
	buttons.add_child(reset)
	var back := Button.new()
	back.name = "SettingsBackButton"
	back.text = "Back"
	back.add_theme_font_size_override("font_size", 24)
	back.pressed.connect(func() -> void:
		_stop_listening()
		back_pressed.emit())
	buttons.add_child(back)


func _refresh() -> void:
	for action: StringName in _buttons:
		var button: Button = _buttons[action]
		button.text = LISTENING_TEXT if action == _listening else Settings.key_name(action)
	if _slider:
		_slider.set_value_no_signal(Settings.mouse_sensitivity)
		_slider_label.text = "%.4f" % Settings.mouse_sensitivity


func _on_key_button_pressed(action: StringName) -> void:
	_listening = action
	_refresh()


func _stop_listening() -> void:
	_listening = &""
	_refresh()


## Captures the next key while a row is listening. Runs before the menu's
## _unhandled_input, and marks the event handled so Escape only cancels here.
func _input(event: InputEvent) -> void:
	if _listening == &"" or not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	get_viewport().set_input_as_handled()
	if key_event.keycode == KEY_ESCAPE or key_event.physical_keycode == KEY_ESCAPE:
		_stop_listening()
		return
	var key: Key = key_event.physical_keycode if key_event.physical_keycode != KEY_NONE else key_event.keycode
	var action: StringName = _listening
	_listening = &""
	Settings.bind(action, key)  # emits controls_changed -> _refresh
```

The Reset and Back buttons are found by the test through `%ResetButton` / `%SettingsBackButton`, so they need `unique_name_in_owner = true` **and** the owner must be the menu scene root. Nodes created in code have no owner; set it: after `buttons.add_child(reset)` do `reset.owner = owner` and the same for `back`, then set `unique_name_in_owner = true` on both (remove the `= false` line above). If `owner` is null at `_ready` time in the test (the page is part of the packed menu scene, so it is set), fall back: the test may instead use `settings_page.get_node("HBoxContainer2/ResetButton")`; prefer the unique-name path and verify.

**Step 3: Menu scene and script**

`scenes/menu.tscn`:
- On `MainPage`, insert a `SettingsButton` between `PlayButton` and `QuitButton`, copying the full button style block, `unique_name_in_owner = true`, `text = "Settings"`.
- After the `MultiplayerPage` block (before `StatusLabel`), add:

```
[node name="SettingsPage" type="VBoxContainer" parent="Control/MarginContainer/VBoxContainer"]
unique_name_in_owner = true
visible = false
layout_mode = 2
script = ExtResource("4_settings_page")
```

with `[ext_resource type="Script" path="res://scripts/ui/settings_page.gd" id="4_settings_page"]` added to the header.

`scripts/menu.gd`: add `@onready var settings_page: Control = %SettingsPage` and `@onready var settings_button: Button = %SettingsButton`; in `_ready` connect `settings_button.pressed` to show `settings_page` and `settings_page.back_pressed` to show `main_page`; include `settings_page` in `_show_page`'s list; in `_unhandled_input` handle `settings_page.visible` → `_show_page(main_page)`.

**Step 4: Run** menu test → `SUMMARY: 21 passed, 0 failed`; settings test 10/0; smoke 103/0/1; net passes.

**Step 5: Docs**

`README.md`: How to play gets a `Settings` paragraph (main menu > Settings: click a key, press the new one; conflicts swap; Reset; sensitivity slider; stored in `%APPDATA%\Godot\app_userdata\firstPersonSandbox\settings.cfg`). Controls table gets a note "all rebindable in Settings except Escape". Automated tests: settings test (10) and menu 21. Project layout: `scripts/settings.gd`, `scripts/ui/settings_page.gd`, `tests/settings_test*.gd`. `tests/README.md`: settings test section; menu count.

**Step 6: Commit** `Settings page: rebind keys, mouse sensitivity, reset`.
