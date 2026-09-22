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

@onready var mesh: MeshInstance3D = $MeshInstance3D
var _material: StandardMaterial3D


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
	if not NetSession.is_authority():
		_update_color()


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
