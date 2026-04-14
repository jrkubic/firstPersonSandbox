extends CharacterBody3D

@export var move_speed := 8.0
@export var acceleration := 40.0
@export var friction := 30.0
@export var air_control := 0.3
@export var jump_velocity := 9.0
@export var gravity := 25.0
@export var mouse_sensitivity := 0.003
@export_range(-89.0, 0.0) var min_pitch := -85.0
@export_range(0.0, 89.0) var max_pitch := 85.0

@onready var head: Node3D = $Head


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	call_deferred("_register_debug_watches")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		head.rotate_x(-event.relative.y * mouse_sensitivity)
		head.rotation.x = clamp(
			head.rotation.x,
			deg_to_rad(min_pitch),
			deg_to_rad(max_pitch),
		)
	elif event.is_action_pressed("toggle_mouse_captured"):
		Input.mouse_mode = (
			Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED
		)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta

	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	var input_dir := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_back") - Input.get_action_strength("move_forward"),
	)
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()

	var control := 1.0 if is_on_floor() else air_control
	if direction != Vector3.ZERO:
		velocity.x = move_toward(velocity.x, direction.x * move_speed, acceleration * control * delta)
		velocity.z = move_toward(velocity.z, direction.z * move_speed, acceleration * control * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, friction * control * delta)
		velocity.z = move_toward(velocity.z, 0.0, friction * control * delta)

	move_and_slide()


func _register_debug_watches() -> void:
	var overlay: Node = get_tree().get_first_node_in_group("debug_overlay")
	if overlay == null:
		return
	var grab: GrabController = $Head/Camera3D/GrabController
	overlay.watch("held", Callable(grab, "held_body_name"))
	overlay.watch("egg.state", func() -> String:
		var f: FoodItem = get_tree().get_first_node_in_group("food") as FoodItem
		return f.state_name() if f else "-")
	overlay.watch("egg.progress", func() -> String:
		var f: FoodItem = get_tree().get_first_node_in_group("food") as FoodItem
		return "%.2f" % f.cook_progress if f else "-")
	overlay.watch("pan.on_stove", func() -> String:
		var p: Pan = get_tree().get_first_node_in_group("pan") as Pan
		return p.on_stove_text() if p else "-")
