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
	reset.text = "Reset to defaults"
	reset.add_theme_font_size_override("font_size", 24)
	reset.pressed.connect(func() -> void: Settings.reset_to_defaults())
	buttons.add_child(reset)
	_expose(reset)
	var back := Button.new()
	back.name = "SettingsBackButton"
	back.text = "Back"
	back.add_theme_font_size_override("font_size", 24)
	back.pressed.connect(func() -> void:
		_stop_listening()
		back_pressed.emit())
	buttons.add_child(back)
	_expose(back)


## Lets the menu (and its test) find a code-built button as %Name. Nodes made
## in code have no owner, so borrow this page's scene root; must run after the
## node is in the tree under that owner.
func _expose(node: Node) -> void:
	if owner == null:
		return
	node.owner = owner
	node.unique_name_in_owner = true


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
