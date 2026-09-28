# Plated Is Final Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or subagent-driven-development) to implement this plan task-by-task.

**Goal:** Food that comes to rest on a plate is attached to it: it rides with the plate when the plate is carried, thrown or set down, cannot be picked off, and leaves only when the plate is delivered, binned or the kitchen resets.

## Design

- **Attach.** On the authority, a plate's `FoodContainer` watches the food overlapping it. A food that is not held, not already plated, has been inside for a few ticks and is nearly at rest relative to the plate gets attached: it becomes a frozen kinematic body, ignores collisions with its plate, and every physics tick the host places it at a fixed offset in the plate's frame. Burned food attaches too (a bad plate goes in the bin).
- **Never detaches.** The only way off a plate is the plate being freed (delivery, trash, reset). A plated food whose plate vanishes for any other reason falls back to a free rigid body (safety net, not a feature).
- **Grabbing.** Aiming at plated food grabs the plate: both the ray and the assist redirect a plated `FoodItem` to its plate, on every peer. The host also refuses a direct request for plated food (`Reject.PLATED`).
- **Cooking and delivery.** Plated food already counts as contained, so a plate set on the pan does not re-cook it; delivery reads plate contents as before; the trash zone bins a plate together with everything attached to it and each item's own spawner replaces it.
- **Replication.** `FoodItem.plated_on` (the plate's `NodePath`, empty when free) is synced `on_change` and included in spawn state, so clients redirect grabs and late joiners see plated food. Positions already flow from the host through `NetBody`; the frozen client copies just keep following.
- **Tests.** The existing checks that lifted an egg off a plate change to prove the opposite; a new `plating.*` group covers attach, grab redirect, host rejection, riding along, and trash-with-plate.

**Tech Stack:** Godot 4.7.2, GDScript, Jolt, `MultiplayerSynchronizer`.

---

## Conventions

- Root `C:\Projects\firstPersonSandbox`, branch `plating` (HEAD 8defff2). `GODOT` = `C:\Users\Jake\Downloads\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe`.
- Suites today: smoke `SUMMARY: 129 passed, 0 failed, 1 xfailed` (`EXPECTED_CHECKS = 130`), net host 12 / client 26, menu 21, settings 11.
- Stage files explicitly; one commit for the whole task with the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Physics facts: `_teleport` in the smoke body sets `global_transform` on a body; for an attached food the host re-places it on the next physics tick, which is exactly what the "stays plated" checks rely on. Attached food is `freeze = true` with `FREEZE_MODE_KINEMATIC`; moving it by transform still updates Area3D overlaps, so it stays listed in the plate's container and in the trash zone.

---

### Task 1: Attach food to plates

**Files:**
- Modify: `scripts/items/food_item.gd`, `scripts/systems/food_container.gd`, `scripts/systems/grab_controller.gd`, `scripts/systems/trash_zone.gd`, `scenes/sync/egg_sync.tres`, `tests/smoke_test_body.gd`, `README.md`, `docs/WALKTHROUGH.md`, `tests/README.md`

**Step 1: Failing checks**

`tests/smoke_test_body.gd`:

(a) In `_check_plate_on_pan`, replace everything from the comment `# Lifting the egg off the plate hands it back to the stove` to the end of the function with:

```gdscript
	# Plated is final: moving the plate carries the egg, and the egg cannot be
	# lifted off. The plate ends up in the delivery zone with a cooked egg, so
	# it delivers and the kitchen respawns a free egg for the next checks.
	_teleport(plate, PASS_PLATE_POS)
	await _step(15)
	_check("plate_on_pan.rides_with_plate",
		egg.is_plated() and plate.get_contents().has(egg) and _horizontal_distance(egg, plate) < 0.2,
		"plated=%s dist=%.2f contents=%s" % [egg.is_plated(), _horizontal_distance(egg, plate), plate.container.contents_text()])
	_teleport(egg, pan.global_position + EGG_IN_PAN_OFFSET)  # try to lift it off
	await _step(5)
	_check("plate_on_pan.stays_plated", egg.is_plated() and _horizontal_distance(egg, plate) < 0.2,
		"plated=%s egg %.2f m from the plate" % [egg.is_plated(), _horizontal_distance(egg, plate)])
	var before_delivery: int = _delivered_count
	var fired: int = await _wait_until(func() -> bool: return _delivered_count > before_delivery, 60)
	_check("plate_on_pan.delivers", fired >= 0, "plate with a cooked egg did not deliver")
	await _step(30)
```

(that group goes from 9 checks to 10). Because this adds a delivery before `_check_held_egg`, change `held_egg.count` to expect `deliveries_made == 4`.

(b) Add `await _check_plating()` right after `await _check_trash()` in `_run()`, and the group:

```gdscript
## Plated is final: food at rest on a plate attaches, aiming at it grabs the
## plate, the host refuses a direct grab of plated food, the food rides with
## the plate, and binning the plate bins and replaces the food too.
func _check_plating() -> void:
	var plate: Plate = get_tree().get_first_node_in_group("plate") as Plate
	var egg: FoodItem = _first_food()
	if not _check("plating.setup", plate != null and egg != null and not _grab.is_holding()
			and not egg.is_plated(), "plate=%s egg=%s" % [plate != null, egg != null]):
		return
	# Plate on the counter, egg dropped onto it.
	_teleport(plate, COUNTER_PAN_POS + Vector3(0.0, 0.05, 0.4))
	await _step(10)
	_teleport(egg, plate.global_position + EGG_ON_PLATE_OFFSET)
	var attached: int = await _wait_until(func() -> bool: return egg.is_plated(), 40)
	_check("plating.attaches", attached >= 0 and egg.plated_on == plate.get_path() and egg.freeze,
		"plated=%s on=%s freeze=%s" % [egg.is_plated(), str(egg.plated_on), egg.freeze])
	# Direct request for the plated egg is refused; nothing is held.
	_grab.request_grab(egg.get_path())
	await _step(3)
	_check("plating.direct_grab_refused",
		not _grab.is_holding() and _grab.last_reject == GrabController.Reject.PLATED,
		"holding=%s reject=%d" % [_grab.is_holding(), _grab.last_reject])
	# Aiming at the plated egg grabs the plate.
	var forward: Vector3 = -_camera.global_transform.basis.z
	var in_front: Vector3 = _camera.global_position + forward * 1.0
	_teleport(plate, in_front - Vector3(0.0, 0.09, 0.0))
	await _step(10)
	_press_action("interact")
	var held: int = await _wait_until(func() -> bool: return _grab.is_holding(), 5)
	_check("plating.aim_grabs_plate", held >= 0 and _grab.held_body_name() == plate.name,
		"held=%s expected=%s" % [_grab.held_body_name(), plate.name])
	_check("plating.rides_in_hand", egg.is_plated() and _horizontal_distance(egg, plate) < 0.2,
		"plated=%s dist=%.2f" % [egg.is_plated(), _horizontal_distance(egg, plate)])
	_press_action("interact")
	await _step(5)
	# Bin the plate: the egg goes with it and both stations refill.
	_teleport(plate, TRASH_ZONE_POS)
	var plate_ref: WeakRef = weakref(plate)
	var egg_ref: WeakRef = weakref(egg)
	var both_gone: int = await _wait_until(
		func() -> bool: return plate_ref.get_ref() == null and egg_ref.get_ref() == null, 40)
	await _step(5)
	_check("plating.trash_takes_both",
		both_gone >= 0 and get_tree().get_nodes_in_group("plate").size() == 1 and _foods_tagged("egg").size() == 1,
		"gone=%s plates=%d eggs=%d" % [both_gone >= 0, get_tree().get_nodes_in_group("plate").size(), _foods_tagged("egg").size()])
```

Set `EXPECTED_CHECKS = 137` (130 + 1 + 6). Run the smoke test: parse error on `is_plated` (the failing state).

**Step 2: `FoodItem`**

Add to `scripts/items/food_item.gd`:

```gdscript
## Path of the plate this food is attached to, or empty. Written by the
## authority when the food comes to rest on a plate; replicated on change
## (egg_sync.tres) so clients redirect grabs to the plate. Plated is final:
## it only clears when the plate is freed.
var plated_on: NodePath = NodePath()

# Authority-side attachment state.
var _plate: RigidBody3D = null
var _plate_offset: Transform3D = Transform3D.IDENTITY


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


func _physics_process(_delta: float) -> void:
	if not NetSession.is_authority() or not is_plated():
		return
	if not is_instance_valid(_plate) or _plate.is_queued_for_deletion():
		_detach()
		return
	global_transform = _plate.global_transform * _plate_offset
```

`FoodItem` already has `_process` (client colour); keep both.

**Step 3: `FoodContainer` attaches resting food**

In `scripts/systems/food_container.gd` add:

```gdscript
## Ticks a food has to sit inside, nearly at rest relative to the plate,
## before it is attached (so food flying through is not glued mid-air).
const SETTLE_TICKS: int = 5
const SETTLE_SPEED: float = 1.0

var _settle: Dictionary = {}  # FoodItem -> consecutive settled ticks


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
```

Also erase the food from `_settle` in `_on_body_exited`.

**Step 4: Grab redirect and rejection**

`scripts/systems/grab_controller.gd`:
- `enum Reject { NONE, TAKEN, OUT_OF_REACH, NOT_GRABBABLE, PLATED }`.
- Add:

```gdscript
## Plated food is part of its plate: aiming at it grabs the plate.
func _redirect_plated(body: RigidBody3D) -> RigidBody3D:
	if body is FoodItem and (body as FoodItem).is_plated():
		var plate: RigidBody3D = body.get_node_or_null((body as FoodItem).plated_on) as RigidBody3D
		if plate != null and plate.is_in_group(Groups.GRABBABLE):
			return plate
	return body
```

- In `_find_ray_candidate`, `return _redirect_plated(collider)` instead of `return collider`; in `_find_assist_candidate`, `return _redirect_plated(best)` (and treat `best` the same for the line-of-sight check as today).
- In `_validate_grab`, after the `NOT_GRABBABLE` check: `if body is FoodItem and (body as FoodItem).is_plated(): return Reject.PLATED`.

**Step 5: Trash bins plated food with its plate**

`scripts/systems/trash_zone.gd` `_bin(body)`: before `body.queue_free()`, if `body is Plate`, loop `(body as Plate).get_contents()` and for each valid food that `is_plated()` call `_bin(food)` (guard: `_inside.erase(food)` happens inside `_bin`; make `_bin` tolerate a body already queued for deletion by returning early when `body.is_queued_for_deletion()`).

**Step 6: Replication**

`scenes/sync/egg_sync.tres`: append

```
properties/5/path = NodePath(".:plated_on")
properties/5/spawn = true
properties/5/replication_mode = 2
```

If Godot refuses to replicate a `NodePath` property (error on sync), switch `plated_on` to a `String` (`str(plate.get_path())`) and adapt `is_plated`/redirect with `NodePath(plated_on)`; report which.

**Step 7: Run** smoke → `SUMMARY: 136 passed, 0 failed, 1 xfailed`. Net → host 12 / client 26 (the host's delivery now attaches the egg first; it still delivers). Menu, settings unchanged.

Failure guide: `plate_on_pan.rides_with_plate` false with `plated=false`: the egg never settled (check `SETTLE_SPEED` against the plate's residual velocity after `_teleport`; `_teleport` zeroes it). `plating.aim_grabs_plate` holding the egg instead: the redirect is missing in the assist path. `occupied.delivered` or `deliver.signal` timing out: attachment delayed the delivery past the wait; bump those waits to 90 frames and say so. `held_egg.blocked` failing: a held egg must never attach; confirm the `HELD` check in `FoodContainer`.

**Step 8: Docs**

`README.md`: How to play gets "Plated is final: once food settles on a plate it stays there; carry, throw or bin the plate, and aim at the food to grab the plate." Smoke list: `plate_on_pan.*` now 10 checks, `plating.*` (6), total 137. `docs/WALKTHROUGH.md`: symptom "egg won't come off the plate" → by design (`FoodItem.plated_on`). `tests/README.md`: `plating.*` row.

**Step 9: Commit** `Plated is final: food attaches to its plate, grabs redirect to the plate`.
