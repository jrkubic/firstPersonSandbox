class_name NetBody
extends Node
## Replication helper parented to every networked RigidBody3D item (egg,
## pan, plate). The item's MultiplayerSynchronizer streams this node's
## properties from the host:
##  - net_position / net_rotation: sampled from the body every physics tick
##    on the host; on clients the frozen body eases toward them and snaps
##    when the error exceeds snap_distance (respawn, teleport).
##  - held_by: peer id of the player holding the item, or NOBODY. Written by
##    the host's GrabController; clients mirror it into the "held" group and
##    a collision exception with their own player.

const NOBODY: int = -1

@export var snap_distance: float = 1.0
## Exponential approach rate toward the last received transform.
@export var smoothing: float = 20.0

var net_position: Vector3 = Vector3.ZERO:
	set(value):
		net_position = value
		_received = true
var net_rotation: Vector3 = Vector3.ZERO
var held_by: int = NOBODY:
	set(value):
		var previous: int = held_by
		held_by = value
		if _body != null and not NetSession.is_authority():
			_apply_held_by(previous)

var _body: RigidBody3D
var _received: bool = false


static func of(body: Node) -> NetBody:
	return body.get_node_or_null("NetBody") as NetBody


func _ready() -> void:
	_body = get_parent() as RigidBody3D
	if NetSession.is_authority():
		net_position = _body.global_position
		net_rotation = _body.global_rotation
		_received = false
		return
	_body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	_body.freeze = true
	if held_by != NOBODY:
		_apply_held_by(NOBODY)


func _physics_process(delta: float) -> void:
	if NetSession.is_authority():
		net_position = _body.global_position
		net_rotation = _body.global_rotation
		return
	if not _received:
		return
	var target_basis := Basis.from_euler(net_rotation)
	if _body.global_position.distance_to(net_position) > snap_distance:
		_body.global_transform = Transform3D(target_basis, net_position)
		return
	var weight: float = 1.0 - exp(-smoothing * delta)
	var from_quat := Quaternion(_body.global_basis.orthonormalized())
	var to_quat := Quaternion(target_basis)
	_body.global_transform = Transform3D(
		Basis(from_quat.slerp(to_quat, weight)),
		_body.global_position.lerp(net_position, weight))


func _apply_held_by(previous: int) -> void:
	if held_by == NOBODY:
		_body.remove_from_group(Groups.HELD)
	else:
		_body.add_to_group(Groups.HELD)
	var me: int = multiplayer.get_unique_id()
	var my_player: Player = _local_player()
	if my_player == null:
		return
	if previous == me and held_by != me:
		_body.remove_collision_exception_with(my_player)
	elif held_by == me and previous != me:
		_body.add_collision_exception_with(my_player)


func _local_player() -> Player:
	var net: KitchenNet = get_tree().get_first_node_in_group(Groups.KITCHEN_NET) as KitchenNet
	return net.get_player(multiplayer.get_unique_id()) if net else null
