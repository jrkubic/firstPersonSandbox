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

@export_group("Grab assist")
## When the precise centre ray misses, sweep a small sphere along the aim
## line so fiddly items (egg radius 0.07) can still be picked up.
@export var grab_assist_enabled: bool = true
## Radius of the assist sphere in metres. Larger is more forgiving.
@export var grab_assist_radius: float = 0.12

## Spacing of the assist sphere samples along the aim line, in metres.
const GRAB_ASSIST_STEP: float = 0.25

## Physics layers (see [layer_names] in project.godot): 1 = World, 4 = Items.
## Grab queries only consider Items; the line-of-sight ray also has to see
## World so walls and counters can block a grab.
const LAYER_WORLD: int = 1
const LAYER_ITEMS: int = 4

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
	var candidate: RigidBody3D = _find_ray_candidate()
	if candidate == null and grab_assist_enabled:
		candidate = _find_assist_candidate()
	if candidate == null:
		return
	_cached_gravity_scale = candidate.gravity_scale
	_held_body = candidate
	_held_body.gravity_scale = 0.0
	_held_body.add_to_group(Groups.HELD)
	if _exclude_body:
		_held_body.add_collision_exception_with(_exclude_body)


## Precise attempt: a single ray from the camera along its forward axis.
## Returns the grabbable body it hits, or null.
func _find_ray_candidate() -> RigidBody3D:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var from: Vector3 = camera.global_position
	var to: Vector3 = from + (-camera.global_transform.basis.z) * grab_range
	# World is included so a wall or counter between the camera and an item
	# stops the ray (a StaticBody3D hit is simply not a grabbable RigidBody3D).
	var query := PhysicsRayQueryParameters3D.create(from, to, LAYER_WORLD | LAYER_ITEMS)
	query.collide_with_bodies = true
	if _exclude_body:
		query.exclude = [_exclude_body.get_rid()]
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return null
	var collider := hit["collider"] as RigidBody3D
	if collider == null or not collider.is_in_group(Groups.GRABBABLE):
		return null
	return collider


## Forgiving attempt: overlap a sphere of grab_assist_radius at sample
## points every GRAB_ASSIST_STEP metres along the aim line, stopping at the
## first sample that contains a grabbable body. Among the bodies in that
## sample the one closest to the aim line wins. A candidate is only
## accepted if the camera has a clear line of sight to it, so the assist
## never grabs through walls or counters.
func _find_assist_candidate() -> RigidBody3D:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var from: Vector3 = camera.global_position
	var forward: Vector3 = -camera.global_transform.basis.z
	var sphere := SphereShape3D.new()
	sphere.radius = grab_assist_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.collision_mask = LAYER_ITEMS
	query.collide_with_bodies = true
	query.collide_with_areas = false
	if _exclude_body:
		query.exclude = [_exclude_body.get_rid()]
	var distance: float = GRAB_ASSIST_STEP
	while distance <= grab_range:
		query.transform = Transform3D(Basis.IDENTITY, from + forward * distance)
		var best: RigidBody3D = null
		var best_offset: float = INF
		for result: Dictionary in space.intersect_shape(query):
			var body := result["collider"] as RigidBody3D
			if body == null or not body.is_in_group(Groups.GRABBABLE):
				continue
			var to_body: Vector3 = body.global_position - from
			var offset: float = (to_body - forward * to_body.dot(forward)).length()
			if offset < best_offset and _has_line_of_sight(from, body):
				best = body
				best_offset = offset
		if best != null:
			return best
		distance += GRAB_ASSIST_STEP
	return null


## True when a ray from `from` to the body's origin reaches it without
## touching any other body (the player and the body itself are ignored).
func _has_line_of_sight(from: Vector3, body: RigidBody3D) -> bool:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		from, body.global_position, LAYER_WORLD | LAYER_ITEMS)
	query.collide_with_bodies = true
	var exclude: Array[RID] = [body.get_rid()]
	if _exclude_body:
		exclude.append(_exclude_body.get_rid())
	query.exclude = exclude
	return space.intersect_ray(query).is_empty()


func _release() -> void:
	if is_instance_valid(_held_body):
		_held_body.gravity_scale = _cached_gravity_scale
		_held_body.remove_from_group(Groups.HELD)
		if _exclude_body:
			_held_body.remove_collision_exception_with(_exclude_body)
	_held_body = null


## Drops whatever this controller holds (peer left, kitchen reset).
func force_release() -> void:
	_release()


func _throw() -> void:
	if not is_instance_valid(_held_body):
		_held_body = null
		return
	var body: RigidBody3D = _held_body
	var forward: Vector3 = -camera.global_transform.basis.z
	_release()
	body.linear_velocity = forward * throw_speed
