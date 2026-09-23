extends SceneTree
## Headless menu test entry point (launcher + body split, see smoke_test.gd).
##   Godot_console.exe --headless --path . --script res://tests/menu_test.gd

const BODY_SCRIPT: String = "res://tests/menu_test_body.gd"


func _initialize() -> void:
	var body_script: GDScript = load(BODY_SCRIPT) as GDScript
	if body_script == null:
		printerr("FAIL launcher: could not load %s" % BODY_SCRIPT)
		quit(1)
		return
	var body: Node = body_script.new() as Node
	body.name = "MenuTest"
	root.add_child(body)
