extends SceneTree
## Two-process ENet replication test entry point. Run via tests/run_net_test.ps1
## or by hand (see net_test_body.gd). Split from the body for the same reason
## as smoke_test.gd: the body names class_name scripts that name autoloads.

const BODY_SCRIPT: String = "res://tests/net_test_body.gd"


func _initialize() -> void:
	var body_script: GDScript = load(BODY_SCRIPT) as GDScript
	if body_script == null:
		printerr("FAIL launcher: could not load %s" % BODY_SCRIPT)
		quit(1)
		return
	var body: Node = body_script.new() as Node
	body.name = "NetTest"
	root.add_child(body)
