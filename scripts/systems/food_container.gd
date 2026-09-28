class_name FoodContainer
extends Area3D

## Ticks a food has to sit inside, nearly at rest relative to the plate,
## before it is attached (so food flying through is not glued mid-air).
const SETTLE_TICKS: int = 5
const SETTLE_SPEED: float = 1.0

var _foods: Array[FoodItem] = []
var _settle: Dictionary[FoodItem, int] = {}  # consecutive settled ticks


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	tree_exiting.connect(_release_all)


func _physics_process(_delta: float) -> void:
	if not NetSession.is_authority():
		return
	var plate: RigidBody3D = get_parent() as RigidBody3D
	if plate == null:
		return
	for food in _foods:
		if not is_instance_valid(food) or food.is_plated() or food.is_in_group(Groups.HELD):
			_settle.erase(food)
			continue
		var relative: float = (food.linear_velocity - plate.linear_velocity).length()
		if relative > SETTLE_SPEED:
			_settle[food] = 0
			continue
		_settle[food] = int(_settle.get(food, 0)) + 1
		if int(_settle[food]) >= SETTLE_TICKS:
			_settle.erase(food)
			food.attach_to_plate(plate)


## body_exited does not fire for bodies still inside when this area is
## freed, so drop the containment count of any food left on the plate.
func _release_all() -> void:
	for food in _foods:
		if is_instance_valid(food):
			food.containers = maxi(0, food.containers - 1)
	_foods.clear()
	_settle.clear()


func get_contents() -> Array[FoodItem]:
	return _foods.duplicate()


func contents_text() -> String:
	if _foods.is_empty():
		return "empty"
	var parts: Array[String] = []
	for f in _foods:
		if not is_instance_valid(f):
			continue
		parts.append("%s(%s)" % [f.recipe_tag, f.state_name()])
	return ", ".join(parts)


# Enter/exit are kept symmetric (guarded by _foods membership) so each
# FoodItem.containers increment is matched by exactly one decrement.
func _on_body_entered(body: Node) -> void:
	if body is FoodItem and not _foods.has(body):
		var food: FoodItem = body as FoodItem
		_foods.append(food)
		food.containers += 1


func _on_body_exited(body: Node) -> void:
	if body is FoodItem and _foods.has(body):
		var food: FoodItem = body as FoodItem
		_foods.erase(food)
		_settle.erase(food)
		food.containers = maxi(0, food.containers - 1)
