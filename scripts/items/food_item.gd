class_name FoodItem
extends RigidBody3D

enum State { RAW, COOKING, COOKED, BURNED }

@export var recipe_tag: String = "egg"
@export var cook_duration: float = 1.5  # seconds from RAW to COOKED
@export var burn_duration: float = 1.5  # seconds from COOKED to BURNED

@export var raw_color: Color = Color(1.0, 1.0, 0.95)
@export var cooked_color: Color = Color(0.95, 0.75, 0.25)
@export var burned_color: Color = Color(0.1, 0.1, 0.1)

signal state_changed(new_state: State)

var state: State = State.RAW
var cook_progress: float = 0.0  # 0..1 is cook phase, 1..2 is burn phase

@onready var mesh: MeshInstance3D = $MeshInstance3D
var _material: StandardMaterial3D


func _ready() -> void:
	add_to_group("grabbable")
	add_to_group("food")
	_ensure_material()
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
