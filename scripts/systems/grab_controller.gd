class_name GrabController
extends Node3D

@export var grab_range: float = 2.5
@export var break_distance: float = 1.75
@export var throw_impulse: float = 8.0
@export var pull_strength: float = 25.0
@export var max_pull_speed: float = 20.0
@export var angular_damping_per_second: float = 10.0

@export_node_path("Node3D") var hold_target_path: NodePath
@export_node_path("Camera3D") var camera_path: NodePath

var _held_body: RigidBody3D = null

@onready var hold_target: Node3D = get_node(hold_target_path)
@onready var camera: Camera3D = get_node(camera_path)


func is_holding() -> bool:
	return _held_body != null


func held_body_name() -> String:
	return _held_body.name if _held_body else "<none>"


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact"):
		if is_holding():
			_release()
		else:
			_try_grab()
	elif event.is_action_pressed("throw") and is_holding():
		_throw()


func _physics_process(delta: float) -> void:
	if not is_holding():
		return
	var to_target: Vector3 = hold_target.global_position - _held_body.global_position
	var distance: float = to_target.length()
	if distance > break_distance:
		_release()
		return
	var desired_velocity: Vector3 = to_target * pull_strength
	if desired_velocity.length() > max_pull_speed:
		desired_velocity = desired_velocity.normalized() * max_pull_speed
	_held_body.linear_velocity = desired_velocity
	_held_body.angular_velocity = _held_body.angular_velocity.lerp(Vector3.ZERO, clamp(angular_damping_per_second * delta, 0.0, 1.0))


func _try_grab() -> void:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var from: Vector3 = camera.global_position
	var to: Vector3 = from + (-camera.global_transform.basis.z) * grab_range
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_bodies = true
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return
	var body: Variant = hit.get("collider")
	if not body is RigidBody3D:
		return
	if not body.is_in_group("grabbable"):
		return
	_held_body = body
	_held_body.gravity_scale = 0.0


func _release() -> void:
	if _held_body:
		_held_body.gravity_scale = 1.0
	_held_body = null


func _throw() -> void:
	if _held_body == null:
		return
	var body: RigidBody3D = _held_body
	var forward: Vector3 = -camera.global_transform.basis.z
	_release()
	body.apply_central_impulse(forward * throw_impulse)
