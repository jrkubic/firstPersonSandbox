class_name Player
extends CharacterBody3D
## First-person player. Named after the peer that owns it ("1" for the host
## or solo); that peer alone reads input, moves the body and looks through
## the camera. Other peers receive position, rotation, head transform and the
## crouch flag from the MultiplayerSynchronizer in player.tscn.

@export var move_speed := 8.0
@export var acceleration := 40.0
@export var friction := 30.0
@export var air_control := 0.3
@export var jump_velocity := 9.0
@export var gravity := 25.0
@export var mouse_sensitivity := 0.0022
@export_range(-89.0, 0.0) var min_pitch := -85.0
@export_range(0.0, 89.0) var max_pitch := 85.0

@export_group("Crouch")
## Metres added to the Head's standing Y while crouched (negative = lower).
@export var crouch_height_offset := -0.6
## move_speed is multiplied by this while crouched.
@export var crouch_speed_multiplier := 0.55
## Exponential rate of the Head height lerp; higher snaps faster.
@export var crouch_lerp_speed := 12.0
## Total CapsuleShape3D height while crouched (standing height comes from the scene).
@export var crouch_capsule_height := 1.3

## The stand-up probe's bottom is lifted this far off the floor so resting on
## the ground never counts as an obstruction; its top stays at standing height.
const STAND_PROBE_LIFT: float = 0.05

## Replicated on change. The setter resizes the capsule so remote copies
## block the right volume.
var crouched: bool = false:
	set(value):
		if crouched == value:
			return
		crouched = value
		_resize_capsule(value)

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var grab_controller: GrabController = $Head/Camera3D/GrabController
@onready var skin: MeshInstance3D = $Skin
@onready var crosshair: CanvasLayer = $Crosshair

var _standing_head_y: float = 0.0
var _standing_shape_y: float = 0.0
var _standing_capsule_height: float = 0.0
# Runtime copy of the scene's capsule; mutating the shared resource would
# resize every instance of player.tscn (and dirty the editor's copy).
var _capsule: CapsuleShape3D
# Standing-sized capsule used only for the ceiling clearance query.
var _stand_probe: CapsuleShape3D


func _enter_tree() -> void:
	# Before _ready and before the MultiplayerSynchronizer initialises, so
	# it knows which peer sends and which receive.
	if name.is_valid_int():
		set_multiplayer_authority(name.to_int())


func _ready() -> void:
	_standing_head_y = head.position.y
	_standing_shape_y = collision_shape.position.y
	_capsule = (collision_shape.shape as CapsuleShape3D).duplicate() as CapsuleShape3D
	collision_shape.shape = _capsule
	_standing_capsule_height = _capsule.height
	_stand_probe = CapsuleShape3D.new()
	_stand_probe.radius = _capsule.radius
	_stand_probe.height = _standing_capsule_height - STAND_PROBE_LIFT * 2.0
	if crouched:
		_resize_capsule(true)  # spawn state may have arrived before _ready

	var mine: bool = is_multiplayer_authority()
	camera.current = mine
	crosshair.visible = mine
	skin.visible = not mine
	if mine:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		call_deferred("_register_debug_watches")


func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		head.rotate_x(-event.relative.y * mouse_sensitivity)
		head.rotation.x = clamp(
			head.rotation.x,
			deg_to_rad(min_pitch),
			deg_to_rad(max_pitch),
		)


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	_update_crouch(delta)

	if not is_on_floor():
		velocity.y -= gravity * delta

	# Design choice: no jumping while crouched. A crouch-jump would let the
	# shorter capsule slip onto counters and under geometry the standing
	# player is meant to be blocked by; stand up first.
	if Input.is_action_just_pressed("jump") and is_on_floor() and not crouched:
		velocity.y = jump_velocity

	var input_dir := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_back") - Input.get_action_strength("move_forward"),
	)
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()

	var speed: float = move_speed * (crouch_speed_multiplier if crouched else 1.0)
	var control := 1.0 if is_on_floor() else air_control
	if direction != Vector3.ZERO:
		velocity.x = move_toward(velocity.x, direction.x * speed, acceleration * control * delta)
		velocity.z = move_toward(velocity.z, direction.z * speed, acceleration * control * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, friction * control * delta)
		velocity.z = move_toward(velocity.z, 0.0, friction * control * delta)

	move_and_slide()


func is_crouched() -> bool:
	return crouched


## Moves this body on its owning peer. The host calls send_teleport; the
## RPC lands on whichever peer owns the node.
func send_teleport(pos: Vector3) -> void:
	if is_multiplayer_authority():
		teleport(pos)
	else:
		teleport.rpc_id(get_multiplayer_authority(), pos)


# Non-RPC callers on the host must go through send_teleport: a direct call
# inside another RPC handler would see the remote sender id and be rejected.
@rpc("any_peer", "reliable")
func teleport(pos: Vector3) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return  # only the host may move players
	global_position = pos
	velocity = Vector3.ZERO


## Crouch is a held action: down while "crouch" is pressed, up as soon as it is
## released AND there is headroom. The capsule switches size instantly (physics
## needs a definite shape); only the Head eases toward its target height.
func _update_crouch(delta: float) -> void:
	var wants_crouch: bool = Input.is_action_pressed("crouch")
	if wants_crouch and not crouched:
		crouched = true
	elif not wants_crouch and crouched and _has_stand_clearance():
		crouched = false

	var target_head_y: float = _standing_head_y + (crouch_height_offset if crouched else 0.0)
	var weight: float = 1.0 - exp(-crouch_lerp_speed * delta)
	head.position.y = lerpf(head.position.y, target_head_y, weight)


## Resizes the capsule and shifts CollisionShape3D so its bottom stays on the
## same floor level (centre = standing centre minus half the height change).
func _resize_capsule(is_crouched_now: bool) -> void:
	if _capsule == null:
		return
	var height: float = crouch_capsule_height if is_crouched_now else _standing_capsule_height
	_capsule.height = height
	collision_shape.position.y = _standing_shape_y - (_standing_capsule_height - height) * 0.5


## True when a standing-height capsule fits at the player's position. Bodies in
## the "held" group are ignored so a carried pan cannot pin the player crouched.
func _has_stand_clearance() -> bool:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _stand_probe
	query.transform = global_transform * Transform3D(
		Basis.IDENTITY, Vector3(0.0, _standing_shape_y + STAND_PROBE_LIFT, 0.0))
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]
	var hits: Array[Dictionary] = get_world_3d().direct_space_state.intersect_shape(query, 8)
	for hit: Dictionary in hits:
		var collider: Node = hit.get("collider") as Node
		if collider == null or not collider.is_in_group(Groups.HELD):
			return false
	return true


func _register_debug_watches() -> void:
	var overlay: Node = get_tree().get_first_node_in_group(Groups.DEBUG_OVERLAY)
	if overlay == null:
		return
	var grab: GrabController = grab_controller
	overlay.watch("held", Callable(grab, "held_body_name"))
	overlay.watch("crouched", func() -> String: return str(crouched))
	overlay.watch("egg.state", func() -> String:
		var f: FoodItem = get_tree().get_first_node_in_group(Groups.FOOD) as FoodItem
		return f.state_name() if f else "-")
	overlay.watch("egg.seconds", func() -> String:
		var f: FoodItem = get_tree().get_first_node_in_group(Groups.FOOD) as FoodItem
		return "%.1fs" % f.cook_elapsed_seconds() if f else "-")
	overlay.watch("egg.progress", func() -> String:
		var f: FoodItem = get_tree().get_first_node_in_group(Groups.FOOD) as FoodItem
		return "%.2f" % f.cook_progress if f else "-")
	overlay.watch("pan.on_stove", func() -> String:
		var p: Pan = get_tree().get_first_node_in_group(Groups.PAN) as Pan
		return p.on_stove_text() if p else "-")
	overlay.watch("plate.contents", func() -> String:
		var pl: Plate = get_tree().get_first_node_in_group(Groups.PLATE) as Plate
		return pl.container.contents_text() if pl else "-")
	var orders: OrderSystem = get_node_or_null("/root/Kitchen/OrderSystem") as OrderSystem
	if orders:
		overlay.watch("order", Callable(orders, "current_order_text"))
