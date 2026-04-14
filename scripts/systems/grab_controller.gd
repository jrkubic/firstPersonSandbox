class_name GrabController
extends Node3D

@export var grab_range: float = 4.0
@export var break_distance: float = 1.75
@export var throw_speed: float = 22.0
@export var pull_strength: float = 25.0
@export var max_pull_speed: float = 20.0
@export var orientation_stiffness: float = 25.0
@export var max_angular_speed: float = 20.0

@export_node_path("Node3D") var hold_target_path: NodePath
@export_node_path("Camera3D") var camera_path: NodePath
@export_node_path("CollisionObject3D") var exclude_body_path: NodePath

var _held_body: RigidBody3D = null
var _cached_gravity_scale: float = 1.0

@onready var hold_target: Node3D = get_node(hold_target_path)
@onready var camera: Camera3D = get_node(camera_path)
@onready var _exclude_body: CollisionObject3D = (
	get_node_or_null(exclude_body_path) as CollisionObject3D
	if not exclude_body_path.is_empty()
	else null
)


func is_holding() -> bool:
	return is_instance_valid(_held_body)


func held_body_name() -> String:
	if not is_instance_valid(_held_body):
		return "<none>"
	return _held_body.name


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact"):
		if is_holding():
			_release()
		else:
			_try_grab()
	elif event.is_action_pressed("throw") and is_holding():
		_throw()


func _physics_process(_delta: float) -> void:
	if not is_instance_valid(_held_body):
		_held_body = null
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
	_apply_orientation_control()


func _apply_orientation_control() -> void:
	var target_quat: Quaternion = Quaternion(hold_target.global_transform.basis.orthonormalized())
	var current_quat: Quaternion = Quaternion(_held_body.global_transform.basis.orthonormalized())
	var rot_diff: Quaternion = target_quat * current_quat.inverse()
	if rot_diff.w < 0.0:
		rot_diff = Quaternion(-rot_diff.x, -rot_diff.y, -rot_diff.z, -rot_diff.w)
	var desired_angular: Vector3 = Vector3(rot_diff.x, rot_diff.y, rot_diff.z) * 2.0 * orientation_stiffness
	if desired_angular.length() > max_angular_speed:
		desired_angular = desired_angular.normalized() * max_angular_speed
	_held_body.angular_velocity = desired_angular


func _try_grab() -> void:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var from: Vector3 = camera.global_position
	var to: Vector3 = from + (-camera.global_transform.basis.z) * grab_range
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_bodies = true
	if _exclude_body:
		query.exclude = [_exclude_body.get_rid()]
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return
	var collider := hit["collider"] as RigidBody3D
	if collider == null or not collider.is_in_group("grabbable"):
		return
	_cached_gravity_scale = collider.gravity_scale
	_held_body = collider
	_held_body.gravity_scale = 0.0
	_held_body.add_to_group("held")
	if _exclude_body:
		_held_body.add_collision_exception_with(_exclude_body)


func _release() -> void:
	if is_instance_valid(_held_body):
		_held_body.gravity_scale = _cached_gravity_scale
		_held_body.remove_from_group("held")
		if _exclude_body:
			_held_body.remove_collision_exception_with(_exclude_body)
	_held_body = null


func _throw() -> void:
	if not is_instance_valid(_held_body):
		_held_body = null
		return
	var body: RigidBody3D = _held_body
	var forward: Vector3 = -camera.global_transform.basis.z
	_release()
	body.linear_velocity = forward * throw_speed
