extends SceneTree
## Headless smoke test entry point. Run from the project root:
##   Godot_console.exe --headless --path . --script res://tests/smoke_test.gd
##
## A --script MainLoop is compiled before the autoloads are registered, and
## the compile pulls in every class_name it types (KitchenLoop, ItemSpawner,
## KitchenNet, ...). Those scripts name NetSession, which does not exist as a
## global yet at that point, so compiling them here fails with "Identifier not
## found: NetSession". The checks therefore live in smoke_test_body.gd, a Node
## loaded from _initialize, by which time the autoloads are on root.
##
## The body script must not be named at compile time (no type annotation).

const BODY_SCRIPT: String = "res://tests/smoke_test_body.gd"


func _initialize() -> void:
	var body_script: GDScript = load(BODY_SCRIPT) as GDScript
	var body: Node = body_script.new() as Node
	body.name = "SmokeTest"
	root.add_child(body)
