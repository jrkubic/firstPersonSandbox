class_name OrderSystem
extends Node
## The order board's brain: a list of Recipe resources, one current ticket.
## The authority draws the next ticket after each delivery (KitchenLoop) and
## on reset; current_index replicates on change (orders_sync.tres) and rides
## KitchenNet's late-join full-state RPC.

const RECIPE_PATHS: Array[String] = [
	"res://resources/recipes/fried_egg.tres",
	"res://resources/recipes/egg_on_toast.tres",
]

## Off in tests: the ticket then stays put until set_current() is called.
@export var randomize_orders: bool = true

var recipes: Array[Recipe] = []
## Replicated. Index into recipes; 0 is always the fried egg.
var current_index: int = 0

var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	for path in RECIPE_PATHS:
		var recipe: Recipe = load(path) as Recipe
		if recipe != null:
			recipes.append(recipe)
	_rng.randomize()


func current_recipe() -> Recipe:
	if recipes.is_empty():
		return null
	return recipes[clampi(current_index, 0, recipes.size() - 1)]


func current_order_text() -> String:
	var recipe: Recipe = current_recipe()
	return recipe.ticket if recipe else "-"


func check_delivery(plate: Plate) -> bool:
	if plate == null:
		return false
	var recipe: Recipe = current_recipe()
	return recipe != null and recipe.matches(plate.get_contents())


## Authority only. Picks a random recipe different from the current one
## (when there is more than one). No-op unless randomize_orders.
func draw_next() -> void:
	if not randomize_orders or recipes.size() < 2:
		return
	var next: int = _rng.randi_range(0, recipes.size() - 2)
	if next >= current_index:
		next += 1
	current_index = next


func set_current(index: int) -> void:
	current_index = clampi(index, 0, maxi(recipes.size() - 1, 0))


func reset() -> void:
	current_index = 0
	draw_next()
