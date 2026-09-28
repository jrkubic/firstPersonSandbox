class_name FoodItem
extends RigidBody3D

enum State { RAW, COOKING, COOKED, BURNED }

@export var recipe_tag: String = "egg"
@export var cook_duration: float = 4.0  # seconds from RAW to COOKED
@export var burn_duration: float = 4.0  # seconds from COOKED to BURNED

@export var raw_color: Color = Color(1.0, 1.0, 0.95)
@export var cooked_color: Color = Color(0.95, 0.75, 0.25)
@export var burned_color: Color = Color(0.1, 0.1, 0.1)

signal state_changed(new_state: State)

var state: State = State.RAW
var cook_progress: float = 0.0  # 0..1 is cook phase, 1..2 is burn phase
# Engine ticks (msec) at the last state transition; 0 until the first one.
var last_state_change_msec: int = 0
# Number of FoodContainers (plates) this food currently rests in. Maintained
# by FoodContainer on enter/exit; never negative. See is_contained().
var containers: int = 0
## Path of the plate this food is attached to, or empty. Written by the
## authority when the food comes to rest on a plate; replicated on change
## (egg_sync.tres) so clients redirect grabs to the plate. Plated is final:
## it only clears when the plate is freed.
var plated_on: NodePath = NodePath()

# Authority-side attachment state.
var _plate: RigidBody3D = null
var _plate_offset: Transform3D = Transform3D.IDENTITY

@onready var mesh: MeshInstance3D = $MeshInstance3D
var _material: StandardMaterial3D
var _painted_progress: float = -1.0


func _ready() -> void:
	add_to_group(Groups.GRABBABLE)
	add_to_group(Groups.FOOD)
	# Jolt would put an egg resting in a held pan or plate to sleep, leaving it
	# hanging in mid-air when the container is pulled away from under it.
	can_sleep = false
	# state_changed is the public hook for VFX/audio/scoring subscribers.
	# This local listener keeps it exercised and feeds seconds_since_state_change().
	state_changed.connect(_on_state_changed)
	_ensure_material()
	_update_color()


func _process(_delta: float) -> void:
	# Clients never tick_cook; cook_progress arrives from the host, so the
	# colour has to follow it here.
	if not NetSession.is_authority() and cook_progress != _painted_progress:
		_update_color()
		_painted_progress = cook_progress


func _physics_process(_delta: float) -> void:
	if not NetSession.is_authority() or not is_plated():
		return
	if not is_instance_valid(_plate) or _plate.is_queued_for_deletion():
		_detach()
		return
	global_transform = _plate.global_transform * _plate_offset


func is_plated() -> bool:
	return not plated_on.is_empty()


## Authority only. Freezes this food and pins it to the plate at its current
## offset; from now on it moves only with the plate.
func attach_to_plate(plate: RigidBody3D) -> void:
	if is_plated() or plate == null:
		return
	_plate = plate
	_plate_offset = plate.global_transform.affine_inverse() * global_transform
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	add_collision_exception_with(plate)
	plated_on = plate.get_path()


## Safety net: the plate vanished without freeing this food (should not
## happen; delivery, trash and reset free both). Back to a free rigid body.
func _detach() -> void:
	if is_instance_valid(_plate):
		remove_collision_exception_with(_plate)
	_plate = null
	plated_on = NodePath()
	freeze = false


func tick_cook(delta: float) -> void:
	if state == State.BURNED:
		return
	var rate: float = 1.0 / cook_duration if cook_progress < 1.0 else 1.0 / burn_duration
	cook_progress += rate * delta
	var new_state: State = state
	if cook_progress >= 2.0:
		cook_progress = 2.0
		new_state = State.BURNED
	elif cook_progress >= 1.0:
		new_state = State.COOKED
	else:
		new_state = State.COOKING
	if new_state != state:
		state = new_state
		state_changed.emit(state)
	_update_color()


func state_name() -> String:
	return State.keys()[state]


## Real seconds of heat this food has received, converted back from the
## normalized cook_progress (0..1 = cook phase over cook_duration, 1..2 =
## burn phase over burn_duration). Read-only: cook_progress stays the
## source of truth for state transitions and colour.
func cook_elapsed_seconds() -> float:
	if cook_progress <= 1.0:
		return cook_progress * cook_duration
	return cook_duration + (cook_progress - 1.0) * burn_duration


## True while resting in at least one FoodContainer (a plate). CookSlot
## skips contained food so a plated meal set on the pan does not re-cook.
func is_contained() -> bool:
	return containers > 0


## Seconds since the last RAW/COOKING/COOKED/BURNED transition, or -1.0 if
## none has happened yet. Intended for overlays and future timing feedback.
func seconds_since_state_change() -> float:
	if last_state_change_msec == 0:
		return -1.0
	return float(Time.get_ticks_msec() - last_state_change_msec) / 1000.0


func _on_state_changed(_new_state: State) -> void:
	last_state_change_msec = Time.get_ticks_msec()


func _ensure_material() -> void:
	var override: Material = mesh.get_surface_override_material(0)
	if override is StandardMaterial3D:
		_material = override
		return
	var unique := StandardMaterial3D.new()
	mesh.set_surface_override_material(0, unique)
	_material = unique


func _update_color() -> void:
	if _material == null:
		return
	var c: Color
	if cook_progress <= 1.0:
		c = raw_color.lerp(cooked_color, cook_progress)
	else:
		c = cooked_color.lerp(burned_color, cook_progress - 1.0)
	_material.albedo_color = c
