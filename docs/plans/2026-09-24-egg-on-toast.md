# Egg on Toast Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or subagent-driven-development) to implement this plan task-by-task.

**Goal:** Recipes as data with a random single ticket, plus bread and a two-slot toaster so "Egg on Toast" can be cooked, plated and delivered in solo and co-op.

**Architecture:** See `docs/plans/2026-09-24-egg-on-toast-design.md`. Task 1 makes `CookSlot` heat-source-agnostic and turns `OrderSystem` into a recipe-list system with a replicated `current_index` (existing fried-egg behaviour preserved, tests made egg-specific). Task 2 adds bread, the toaster counter and the egg-on-toast recipe with smoke and net coverage.

**Tech Stack:** Godot 4.7.2, GDScript, Jolt, custom `Resource`.

---

## Conventions

- Root `C:\Projects\firstPersonSandbox`, branch `toast`. `GODOT` = `C:\Users\Jake\Downloads\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe`.
- Suites today: smoke `SUMMARY: 106 passed, 0 failed, 1 xfailed` (`EXPECTED_CHECKS = 107`), net host 11 / client 23, menu 21, settings 11.
- Test bodies are Nodes with `get_tree().`-prefixed SceneTree calls. Stage files explicitly; commit per task with the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- The `food` group will contain bread after Task 2. Every lookup of "the egg" must filter by `recipe_tag == "egg"`; Task 1 introduces the helpers so Task 2 cannot break the old checks.

---

### Task 1: Recipes as data, heat-agnostic cook slot, egg-specific lookups

**Files:**
- Create: `scripts/recipes/recipe.gd`, `resources/recipes/fried_egg.tres`, `resources/recipes/egg_on_toast.tres`
- Modify: `scripts/systems/order_system.gd` (rewrite), `scripts/systems/cook_slot.gd`, `scripts/systems/kitchen_loop.gd`, `scripts/systems/kitchen_net.gd`, `scenes/sync/orders_sync.tres`, `scripts/player.gd` (overlay watches), `scripts/ui/order_board.gd` (no change needed if it calls `current_order_text()`), `tests/smoke_test_body.gd`, `tests/net_test_body.gd`

**Step 1: Failing checks**

`tests/smoke_test_body.gd`:
- Add helpers next to `_first_food`:

```gdscript
## Every FoodItem with the given recipe tag (bread shares the "food" group).
func _foods_tagged(tag: String) -> Array[FoodItem]:
	var out: Array[FoodItem] = []
	for node in get_tree().get_nodes_in_group("food"):
		var food: FoodItem = node as FoodItem
		if food != null and food.recipe_tag == tag:
			out.append(food)
	return out


func _first_food() -> FoodItem:
	var eggs: Array[FoodItem] = _foods_tagged("egg")
	return eggs[0] if not eggs.is_empty() else null
```

- Replace every `get_tree().get_nodes_in_group("food").size()` with `_foods_tagged("egg").size()` (there are several: `boot.items`, `deliver.fresh_egg`, `deliver.respawn`, `trash.egg_replaced`, and any others; grep for `"food"`). The `boot.items` detail string should print `eggs=`.
- In `_check_boot`, right after `_order_system` is found, add `_order_system.randomize_orders = false` (keeps the ticket on recipe 0 for the whole run) and a new check after `boot.not_holding`:

```gdscript
	_check("boot.order_fried_egg",
		_order_system.current_index == 0 and _order_system.current_order_text() == "1× Fried Egg",
		"index=%d text=%s" % [_order_system.current_index, _order_system.current_order_text()])
```

- Add a new check group `await _check_orders()` right after `_check_occupied_slot(pan)` in `_run()`:

```gdscript
## Recipe data: set_current swaps the ticket, check_delivery matches the
## plate's tags exactly and only when everything is COOKED.
func _check_orders() -> void:
	var plate: Plate = get_tree().get_first_node_in_group("plate") as Plate
	var egg: FoodItem = _first_food()
	if not _check("orders.setup", plate != null and egg != null, "no plate or egg"):
		return
	_order_system.set_current(1)
	_check("orders.ticket_switches", _order_system.current_order_text() == "1× Egg on Toast",
		"text=%s" % _order_system.current_order_text())
	var cooked: bool = await _cook_until_cooked(egg, get_tree().get_first_node_in_group("pan") as Pan)
	_teleport(plate, PASS_PLATE_POS)
	await _step(10)
	_teleport(egg, PASS_EGG_POS)
	await _step(10)
	_check("orders.egg_only_rejected_for_toast", cooked and not _order_system.check_delivery(plate),
		"cooked=%s accepted=%s" % [cooked, _order_system.check_delivery(plate)])
	_order_system.set_current(0)
	_check("orders.egg_only_accepted_for_fried_egg", _order_system.check_delivery(plate),
		"fried egg plate rejected: %s" % plate.container.contents_text())
	# Leave the plate and egg where they are: DeliveryZone will deliver them
	# now that the ticket matches, which the next frames absorb.
	await _step(30)
```

Set `EXPECTED_CHECKS = 112` (107 + `boot.order_fried_egg` + 4 `orders.*`).

Note: the delivery at the end of `_check_orders` increments `deliveries_made`; `_check_walk` and `_check_trash` follow and do not depend on the count, but `_check_trash` re-fetches its plate/egg, which is fine after the respawn (wait: give it `await _step(30)` as written so the respawn has landed). If `deliveries_made` reaches the goal of 3 during the run the tree pauses (WON): count how many deliveries the existing groups make (two: `deliver.*` and `held_no_deliver.*`); this third one would WIN. To avoid that, before `_check_orders` set `_loop.delivery_goal = 99` in `_check_boot` (right after `_loop` is found) so the smoke run never wins.

`tests/net_test_body.gd`:
- Replace both `get_tree().get_first_node_in_group("food") as FoodItem` lookups with an egg-tag helper (add the same `_foods_tagged` helper and `_first_egg()`), and the `client.sees_egg` wait to use it.
- Host: right after `host.client_player_spawned`, add `_kitchen.get_node("OrderSystem").set_current(1)` and, after the run-start check, `_check("host.order_index", _orders.current_index == 1, ...)` where `_orders` is fetched in `_load_kitchen`. Client: after `client.names_synced`, add:

```gdscript
	var order_synced: int = await _wait_until(
		func() -> bool: return _orders.current_index == 1, PHYSICS_TPS * 10)
	_check("client.order_index_syncs", order_synced >= 0, "index=%d" % _orders.current_index)
	var board: Label3D = _kitchen.get_node("OrderBoard/TicketLabel") as Label3D
	await get_tree().process_frame
	_check("client.order_board_text", board.text == "1× Egg on Toast", "board=%s" % board.text)
```

`EXPECTED_CHECKS` → `{"host": 12, "client": 25}`. The host must also set `randomize_orders = false` right after loading the kitchen so the delivery in the host timeline does not re-draw recipe 1 (the client's index check runs before the delivery either way; keep it deterministic).

Run the smoke test: expect a parse error on `randomize_orders` / `current_index` (the failing state).

**Step 2: `Recipe` resource and the two recipes**

`scripts/recipes/recipe.gd`:

```gdscript
class_name Recipe
extends Resource
## One order the kitchen can ask for. A plate satisfies it when its contents
## are exactly these ingredient tags (one FoodItem per entry), every one of
## them COOKED. Extra food or a burned item rejects the plate.

@export var id: StringName = &""
## Text shown on the order board.
@export var ticket: String = ""
## recipe_tag of each required FoodItem, e.g. ["egg", "bread"].
@export var ingredients: PackedStringArray = PackedStringArray()


func matches(contents: Array[FoodItem]) -> bool:
	if contents.size() != ingredients.size():
		return false
	var needed: Array = Array(ingredients)
	for food in contents:
		if not is_instance_valid(food) or food.state != FoodItem.State.COOKED:
			return false
		var at: int = needed.find(food.recipe_tag)
		if at < 0:
			return false
		needed.remove_at(at)
	return needed.is_empty()
```

`resources/recipes/fried_egg.tres`:

```
[gd_resource type="Resource" script_class="Recipe" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/recipes/recipe.gd" id="1_recipe"]

[resource]
script = ExtResource("1_recipe")
id = &"fried_egg"
ticket = "1× Fried Egg"
ingredients = PackedStringArray("egg")
```

`resources/recipes/egg_on_toast.tres`: same with `id = &"egg_on_toast"`, `ticket = "1× Egg on Toast"`, `ingredients = PackedStringArray("egg", "bread")`.

**Step 3: `OrderSystem` rewrite**

```gdscript
class_name OrderSystem
extends Node
## The order board's brain: a list of Recipe resources, one current ticket.
## The authority draws the next ticket after each delivery (KitchenLoop) and
## on reset; current_index replicates on change (orders_sync.tres) and rides
## KitchenNet's late-join full-state RPC.

const RECIPE_PATHS: PackedStringArray = PackedStringArray([
	"res://resources/recipes/fried_egg.tres",
	"res://resources/recipes/egg_on_toast.tres",
])

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
```

`scenes/sync/orders_sync.tres`: replace the two properties with a single `properties/0/path = NodePath(".:current_index")`, `spawn = true`, `replication_mode = 2`.

**Step 4: Callers**

- `scripts/systems/kitchen_loop.gd`: add `@export_node_path("OrderSystem") var order_system_path: NodePath = NodePath("../OrderSystem")` and `@onready var _orders: OrderSystem = get_node(order_system_path)`; in `_on_delivered`, after `deliveries_made += 1` and before the WON check, call `_orders.draw_next()`; in `reset()` call `_orders.reset()`. (The kitchen scene's KitchenLoop node needs no new property since the default path resolves.)
- `scripts/systems/kitchen_net.gd`: `_on_peer_connected` RPCs `_orders.current_index` in place of `recipe_tag, required_count`; `_apply_full_state(new_mode, loop_state, deliveries, elapsed, order_index: int)` sets `_orders.set_current(order_index)`. Update the signature at both the definition and the call.
- `scripts/systems/cook_slot.gd`: make the heat source optional:

```gdscript
@export_node_path("Pan") var pan_path: NodePath
## Stations with their own heat (the toaster) tick whenever food is in the slot.
@export var always_hot: bool = false

var _pan: Pan


func _ready() -> void:
	if not pan_path.is_empty():
		_pan = get_node_or_null(pan_path) as Pan
	...


func _is_heating() -> bool:
	return always_hot or (_pan != null and _pan.is_on_stove())
```

and in `_physics_process` replace `if not _pan.is_on_stove(): return` with `if not _is_heating(): return`.

- `scripts/player.gd` overlay watches `egg.state`, `egg.seconds`, `egg.progress`: look up the first food whose `recipe_tag == "egg"` (add a small `_first_egg()` helper in player.gd) instead of the first `food` group node.
- `scripts/ui/order_board.gd`: unchanged (it calls `current_order_text()`).

**Step 5: Run** smoke → `SUMMARY: 111 passed, 0 failed, 1 xfailed`; net → host 12 / client 25; menu and settings unchanged. If `boot.items` counts change because of `_foods_tagged`, the detail string will say so.

**Step 6: Commit** `Recipes as data: OrderSystem picks from a list, CookSlot heat-agnostic`.

---

### Task 2: Bread, toaster counter, egg on toast

**Files:**
- Create: `scenes/items/bread.tscn`, `scenes/toaster.tscn`
- Modify: `scenes/kitchen.tscn` (ToasterCounter with toaster + bread spawner; replicator list), `tests/smoke_test_body.gd`, `README.md`, `docs/WALKTHROUGH.md`, `tests/README.md`

**Step 1: Failing checks**

`tests/smoke_test_body.gd`: in `boot.items` also require `_foods_tagged("bread").size() == 1` (print `breads=`), and add `await _check_toast()` after `_check_orders()`; `EXPECTED_CHECKS = 121` (112 + 9):

```gdscript
const TOASTER_SLOT_A: Vector3 = Vector3(0.24, 1.36, -2.0)   # see scenes/toaster.tscn placement
const TOASTER_SLOT_B: Vector3 = Vector3(-0.02, 1.36, -2.0)
const PASS_BREAD_POS: Vector3 = Vector3(0.15, 1.12, 3.0)

## Bread toasts in the toaster's slots without any pan or stove, burns if
## left, and an egg-on-toast plate delivers when the ticket asks for it.
func _check_toast() -> void:
	var bread: FoodItem = _foods_tagged("bread")[0] if not _foods_tagged("bread").is_empty() else null
	if not _check("toast.setup", bread != null and bread.state == FoodItem.State.RAW,
			"bread=%s" % (bread.state_name() if bread else "<none>")):
		return
	_teleport(bread, TOASTER_SLOT_A)
	var toasting: int = await _wait_until(
		func() -> bool: return bread.state == FoodItem.State.COOKING, 20)
	_check("toast.starts_without_stove", toasting >= 0, "state=%s after 20 frames" % bread.state_name())
	var budget: int = int(bread.cook_duration * PHYSICS_TPS * 1.5) + 10
	var toasted: int = await _wait_until(
		func() -> bool: return bread.state == FoodItem.State.COOKED, budget)
	_check("toast.cooks", toasted >= 0, "state=%s" % bread.state_name())
	# Plate it with a cooked egg for Egg on Toast.
	var plate: Plate = get_tree().get_first_node_in_group("plate") as Plate
	var egg: FoodItem = _first_food()
	var pan: Pan = get_tree().get_first_node_in_group("pan") as Pan
	var egg_cooked: bool = await _cook_until_cooked(egg, pan)
	_order_system.set_current(1)
	_teleport(plate, PASS_PLATE_POS)
	await _step(10)
	_teleport(bread, PASS_BREAD_POS)
	await _step(10)
	_check("toast.toast_only_rejected", egg_cooked and not _order_system.check_delivery(plate),
		"accepted a toast-only plate: %s" % plate.container.contents_text())
	_teleport(egg, PASS_EGG_POS + Vector3(0.0, 0.05, 0.0))
	var before: int = _delivered_count
	var delivered: int = await _wait_until(func() -> bool: return _delivered_count > before, 60)
	_check("toast.egg_on_toast_delivers", delivered >= 0, "no delivery within 60 frames: %s" % plate.container.contents_text())
	await _step(30)
	_check("toast.bread_respawns", _foods_tagged("bread").size() == 1 and _foods_tagged("bread")[0].state == FoodItem.State.RAW,
		"breads=%d" % _foods_tagged("bread").size())
	# Burn: a fresh slice left in the slot goes past COOKED to BURNED.
	var slice: FoodItem = _foods_tagged("bread")[0]
	_teleport(slice, TOASTER_SLOT_B)
	var burn_budget: int = int((slice.cook_duration + slice.burn_duration) * PHYSICS_TPS * 1.5)
	var burned: int = await _wait_until(func() -> bool: return slice.state == FoodItem.State.BURNED, burn_budget)
	_check("toast.burns", burned >= 0, "state=%s" % slice.state_name())
	# Binned bread is replaced.
	_teleport(slice, TRASH_ZONE_POS)
	var slice_ref: WeakRef = weakref(slice)
	var freed: int = await _wait_until(func() -> bool: return slice_ref.get_ref() == null, 30)
	await _step(5)
	_check("toast.trash_replaces", freed >= 0 and _foods_tagged("bread").size() == 1,
		"freed=%s breads=%d" % [freed >= 0, _foods_tagged("bread").size()])
	_order_system.set_current(0)
	_check("toast.ticket_back", _order_system.current_order_text() == "1× Fried Egg", "text=%s" % _order_system.current_order_text())
```

Run the smoke test: `boot.items` fails on `breads=0`, the rest of `toast.*` fail or skip (the failing state).

**Step 2: Bread scene `scenes/items/bread.tscn`**

```
[gd_scene load_steps=6 format=3]

[ext_resource type="Script" path="res://scripts/items/food_item.gd" id="1_food"]
[ext_resource type="Script" path="res://scripts/net/net_body.gd" id="2_net_body"]
[ext_resource type="SceneReplicationConfig" path="res://scenes/sync/egg_sync.tres" id="3_sync"]

[sub_resource type="BoxShape3D" id="BoxShape3D_bread"]
size = Vector3(0.14, 0.035, 0.14)

[sub_resource type="BoxMesh" id="BoxMesh_bread"]
size = Vector3(0.14, 0.035, 0.14)

[node name="Bread" type="RigidBody3D"]
collision_layer = 4
collision_mask = 7
mass = 0.08
continuous_cd = true
script = ExtResource("1_food")
recipe_tag = "bread"
cook_duration = 3.0
burn_duration = 3.0
raw_color = Color(0.93, 0.85, 0.68, 1)
cooked_color = Color(0.72, 0.45, 0.2, 1)
burned_color = Color(0.12, 0.09, 0.07, 1)

[node name="CollisionShape3D" type="CollisionShape3D" parent="."]
shape = SubResource("BoxShape3D_bread")

[node name="MeshInstance3D" type="MeshInstance3D" parent="."]
mesh = SubResource("BoxMesh_bread")

[node name="NetBody" type="Node" parent="."]
script = ExtResource("2_net_body")

[node name="MultiplayerSynchronizer" type="MultiplayerSynchronizer" parent="."]
replication_interval = 0.033
delta_interval = 0.033
replication_config = ExtResource("3_sync")
```

(`egg_sync.tres` is reused: same properties exist on every FoodItem.)

**Step 3: Toaster scene `scenes/toaster.tscn`**

A dark box with a rim so slices stay on top, a divider, and two always-hot cook slots covering each half. Body top is at local y = 0.25.

```
[gd_scene load_steps=7 format=3]

[ext_resource type="Script" path="res://scripts/systems/cook_slot.gd" id="1_cook_slot"]

[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_body"]
albedo_color = Color(0.3, 0.3, 0.33, 1)

[sub_resource type="BoxMesh" id="BoxMesh_body"]
material = SubResource("StandardMaterial3D_body")
size = Vector3(0.56, 0.25, 0.32)

[sub_resource type="BoxShape3D" id="BoxShape3D_body"]
size = Vector3(0.56, 0.25, 0.32)

[sub_resource type="BoxShape3D" id="BoxShape3D_rim_x"]
size = Vector3(0.56, 0.06, 0.02)

[sub_resource type="BoxShape3D" id="BoxShape3D_rim_z"]
size = Vector3(0.02, 0.06, 0.32)

[sub_resource type="BoxShape3D" id="BoxShape3D_slot"]
size = Vector3(0.24, 0.14, 0.28)

[node name="Toaster" type="StaticBody3D"]

[node name="Body" type="MeshInstance3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.125, 0)
mesh = SubResource("BoxMesh_body")

[node name="BodyCollision" type="CollisionShape3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.125, 0)
shape = SubResource("BoxShape3D_body")

[node name="RimN" type="CollisionShape3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.28, -0.15)
shape = SubResource("BoxShape3D_rim_x")

[node name="RimS" type="CollisionShape3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.28, 0.15)
shape = SubResource("BoxShape3D_rim_x")

[node name="RimE" type="CollisionShape3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0.27, 0.28, 0)
shape = SubResource("BoxShape3D_rim_z")

[node name="RimW" type="CollisionShape3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, -0.27, 0.28, 0)
shape = SubResource("BoxShape3D_rim_z")

[node name="Divider" type="CollisionShape3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.28, 0)
shape = SubResource("BoxShape3D_rim_z")

[node name="SlotA" type="Area3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0.135, 0.32, 0)
collision_layer = 0
collision_mask = 4
script = ExtResource("1_cook_slot")
always_hot = true

[node name="CollisionShape3D" type="CollisionShape3D" parent="SlotA"]
shape = SubResource("BoxShape3D_slot")

[node name="SlotB" type="Area3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, -0.135, 0.32, 0)
collision_layer = 0
collision_mask = 4
script = ExtResource("1_cook_slot")
always_hot = true

[node name="CollisionShape3D" type="CollisionShape3D" parent="SlotB"]
shape = SubResource("BoxShape3D_slot")
```

Add rim meshes only if you want them visible; collision is what matters. Give the rims a `MeshInstance3D` with a matching `BoxMesh` if time allows (grey-box).

**Step 4: Kitchen scene**

In `scenes/kitchen.tscn`:
- ext_resources: `[ext_resource type="PackedScene" path="res://scenes/toaster.tscn" id="21_toaster"]`, `[ext_resource type="PackedScene" path="res://scenes/items/bread.tscn" id="22_bread"]`.
- `ItemReplicator._spawnable_scenes`: append `"res://scenes/items/bread.tscn"`.
- After the `Stove` block, a new counter (same box shape/mesh as the counter, `BoxShape3D_counter_stove` / `BoxMesh_counter`):

```
[node name="ToasterCounter" type="StaticBody3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, -2)

[node name="CollisionShape3D" type="CollisionShape3D" parent="ToasterCounter"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.5, 0)
shape = SubResource("BoxShape3D_counter_stove")

[node name="MeshInstance3D" type="MeshInstance3D" parent="ToasterCounter"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.5, 0)
mesh = SubResource("BoxMesh_counter")

[node name="Toaster" parent="ToasterCounter" instance=ExtResource("21_toaster")]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0.11, 1, 0)

[node name="BreadSpawner" type="Node3D" parent="ToasterCounter"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, -0.5, 1.15, 0)
script = ExtResource("9_item_spawner")
item_scene = ExtResource("22_bread")
spawn_parent_path = NodePath("../../Items")
```

Toaster slots then sit at global x = 0.11 ± 0.135 → 0.245 and -0.025, y = 1.0 + 0.32 = 1.32, z = -2: `TOASTER_SLOT_A` (0.24, 1.36, -2.0) and `TOASTER_SLOT_B` (-0.02, 1.36, -2.0) drop a slice just above each slot's centre so it lands on the body top (1.25) inside the rim.

**Step 5: Run** smoke → `SUMMARY: 120 passed, 0 failed, 1 xfailed`. If `toast.starts_without_stove` fails, print the slice's global position: it should rest at y ≈ 1.27 inside the slot box (y 1.25–1.39); if it fell off, the rim transforms are wrong. Net → host 12 / client 25. Menu / settings unchanged.

**Step 6: Docs**

`README.md`: How to play gains an "Egg on Toast" paragraph (bread crate on the north counter, toaster with two slots, toast in ~3 s, burns if left; the ticket on the wall picks a recipe at random after each delivery); Project layout adds `scripts/recipes/recipe.gd`, `resources/recipes/*.tres`, `scenes/items/bread.tscn`, `scenes/toaster.tscn`; smoke list adds `boot.order_fried_egg`, `orders.*` (4), `toast.*` (9), total 121; net counts 12/25; Known limitations drops "Only one recipe" and says two recipes, no ticket queue or expiry yet. `docs/WALKTHROUGH.md`: overlay `order` now shows the ticket text; symptom "plate not accepted" → check the ticket's ingredient list vs `contents_text()`. `tests/README.md`: new rows.

**Step 7: Commit** `Bread and toaster: Egg on Toast recipe with random single ticket`.
