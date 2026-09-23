# Kitchen QoL Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or subagent-driven-development) to implement this plan task-by-task.

**Goal:** Hold Shift to walk (half speed) so plates can be carried under control, and add a trash can that destroys any unheld item dropped in and has that item's own spawner produce a replacement.

**Architecture:** Walking is a `walk` input action read only by the owning peer in `Player._physics_process`; it scales the same `speed` the crouch multiplier scales, so replication is untouched. The trash can is a `StaticBody3D` bin with a ring of thin wall segments and a `TrashZone` `Area3D` inside; the zone runs on the authority only, polls its overlapping items each physics tick like `DeliveryZone`, bins anything not held, and asks the item's producing `ItemSpawner` (recorded as node metadata at spawn) to spawn again. Freed and spawned items replicate through the existing `MultiplayerSpawner`.

**Tech Stack:** Godot 4.7.2, GDScript, Jolt.

---

## Conventions

- Root `C:\Projects\firstPersonSandbox`, branch `kitchen-qol`.
- `GODOT` = `C:\Users\Jake\Downloads\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe`.
- Smoke: `& $GODOT --headless --path . --script res://tests/smoke_test.gd` (today `SUMMARY: 94 passed, 0 failed, 1 xfailed`, `EXPECTED_CHECKS = 95` in `tests/smoke_test_body.gd`).
- Net: `powershell -ExecutionPolicy Bypass -File tests/run_net_test.ps1` → `NET TEST PASSED`.
- Menu: `& $GODOT --headless --path . --script res://tests/menu_test.gd` → `SUMMARY: 16 passed, 0 failed`.
- Smoke checks live in `tests/smoke_test_body.gd`, a Node body: SceneTree calls are `get_tree().`-prefixed; helpers `_check`, `_step`, `_wait_until`, `_teleport`, `_press_action`, `_set_action`, `_first_food` exist.
- Commit per task; trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Stage files explicitly.

---

### Task 1: Shift to walk

**Files:**
- Modify: `project.godot` (`walk` action)
- Modify: `scripts/player.gd`
- Modify: `tests/smoke_test_body.gd` (2 checks; `EXPECTED_CHECKS` 95 → 97)
- Modify: `README.md` (controls row)

**Step 1: Failing checks**

In `tests/smoke_test_body.gd` add a call `await _check_walk()` in `_run()` after `await _check_occupied_slot(pan)` (it must be last so far: it moves the player and puts it back). Set `EXPECTED_CHECKS = 97`. Add the check function:

```gdscript
## Hold "walk" and "move_right": the player settles at half speed; release
## walk and it settles at full speed. Strafes along +x from the spawn point,
## which has ~6 m of clear floor, then returns to the spawn point.
func _check_walk() -> void:
	var start: Vector3 = _player.global_position
	_set_action("walk", true)
	_set_action("move_right", true)
	await _step(20)
	var walking_speed: float = Vector2(_player.velocity.x, _player.velocity.z).length()
	var expected_walk: float = _player.move_speed * _player.walk_speed_multiplier
	_check("walk.half_speed", absf(walking_speed - expected_walk) < 0.3,
		"speed=%.2f expected=%.2f" % [walking_speed, expected_walk])
	_set_action("walk", false)
	await _step(20)
	var running_speed: float = Vector2(_player.velocity.x, _player.velocity.z).length()
	_check("walk.full_speed_after_release", absf(running_speed - _player.move_speed) < 0.3,
		"speed=%.2f expected=%.2f" % [running_speed, _player.move_speed])
	_set_action("move_right", false)
	await _step(5)
	_player.global_position = start
	_player.velocity = Vector3.ZERO
	await _step(2)
```

Run the smoke test: expect a parse error on `walk_speed_multiplier` (the failing state).

**Step 2: Input action**

In `project.godot` `[input]`, add after the `crouch` block:

```
walk={
"deadzone": 0.2,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":4194325,"key_label":0,"unicode":0,"location":0,"echo":false,"script":null)
]
}
```

(4194325 is `KEY_SHIFT`; `device -1` = any keyboard, matching `crouch`.)

**Step 3: Player**

In `scripts/player.gd`:
- Under `@export_group("Crouch")`'s block add a new group:

```gdscript
@export_group("Walk")
## move_speed is multiplied by this while "walk" (Shift) is held. Meant for
## carrying plates without launching what's on them.
@export var walk_speed_multiplier := 0.5
```

- In `_physics_process`, replace the `speed` line with:

```gdscript
	var speed: float = move_speed * (crouch_speed_multiplier if crouched else 1.0)
	if Input.is_action_pressed("walk"):
		speed *= walk_speed_multiplier
```

- Add `func is_walking() -> bool: return is_multiplayer_authority() and Input.is_action_pressed("walk")` and an overlay watch `overlay.watch("walking", func() -> String: return str(is_walking()))` after the `crouched` watch.

**Step 4: Run smoke** → `SUMMARY: 96 passed, 0 failed, 1 xfailed`.

**Step 5: README** controls table: add a row `| Shift    | Walk (hold): half speed for carrying plates |`. Debug overlay list: add `walking`. Smoke test check list: add `walk.*` (2).

**Step 6: Commit** `Hold Shift to walk at half speed`.

---

### Task 2: Trash can

**Files:**
- Create: `scenes/trash_can.tscn`, `scripts/systems/trash_zone.gd`
- Modify: `scripts/systems/item_spawner.gd` (metadata + `replace()`)
- Modify: `scenes/kitchen.tscn` (instance the bin)
- Modify: `tests/smoke_test_body.gd` (7 checks; `EXPECTED_CHECKS` 97 → 104)
- Modify: `README.md`, `docs/WALKTHROUGH.md`

**Step 1: Failing checks**

Add `await _check_trash()` as the last call in `_run()` (after `_check_walk()`), `EXPECTED_CHECKS = 104`, and:

```gdscript
const TRASH_ZONE_POS: Vector3 = Vector3(4.0, 0.5, 1.5)  # inside the bin, see scenes/trash_can.tscn

## Anything unheld dropped in the bin is freed and its own spawner produces a
## replacement; a held item is safe until released.
func _check_trash() -> void:
	var egg: FoodItem = _first_food()
	var plate: Plate = get_tree().get_first_node_in_group("plate") as Plate
	var pan: Pan = get_tree().get_first_node_in_group("pan") as Pan
	if not _check("trash.setup", egg != null and plate != null and pan != null and not _grab.is_holding(),
			"egg=%s plate=%s pan=%s holding=%s" % [egg != null, plate != null, pan != null, _grab.is_holding()]):
		return

	# Held egg: safe inside the bin until released.
	egg.add_to_group("held")
	_teleport(egg, TRASH_ZONE_POS)
	await _step(30)
	_check("trash.held_survives", is_instance_valid(egg), "held egg was binned")
	egg.remove_from_group("held")
	var freed: int = await _wait_until(func() -> bool: return not is_instance_valid(egg), 30)
	_check("trash.egg_freed", freed >= 0, "released egg still alive after 30 frames")
	await _step(5)
	var new_egg: FoodItem = _first_food()
	_check("trash.egg_replaced",
		new_egg != null and get_tree().get_nodes_in_group("food").size() == 1
		and not _egg_spawner.is_slot_free(),
		"eggs=%d slot_free=%s" % [get_tree().get_nodes_in_group("food").size(), _egg_spawner.is_slot_free()])

	# Pan: binned and replaced on the stove even though pans never refill on delivery.
	_teleport(pan, TRASH_ZONE_POS)
	var pan_freed: int = await _wait_until(func() -> bool: return not is_instance_valid(pan), 30)
	_check("trash.pan_freed", pan_freed >= 0, "pan still alive after 30 frames")
	await _step(30)
	var new_pan: Pan = get_tree().get_first_node_in_group("pan") as Pan
	_check("trash.pan_replaced",
		new_pan != null and get_tree().get_nodes_in_group("pan").size() == 1 and new_pan.is_on_stove(),
		"pans=%d on_stove=%s" % [get_tree().get_nodes_in_group("pan").size(),
			new_pan.is_on_stove() if new_pan else false])

	# Plate with nothing on it.
	_teleport(plate, TRASH_ZONE_POS)
	var plate_freed: int = await _wait_until(func() -> bool: return not is_instance_valid(plate), 30)
	await _step(5)
	_check("trash.plate_replaced",
		plate_freed >= 0 and get_tree().get_nodes_in_group("plate").size() == 1
		and not _plate_spawner.is_slot_free(),
		"freed=%s plates=%d" % [plate_freed >= 0, get_tree().get_nodes_in_group("plate").size()])
```

Run the smoke test: expect `trash.held_survives` to pass and the rest to fail (nothing frees anything yet), with the count line reporting 104.

**Step 2: ItemSpawner remembers what it made**

In `scripts/systems/item_spawner.gd`:
- In `spawn()`, right after `instance.name = ...`: `instance.set_meta(&"spawner_path", get_path())`.
- Add:

```gdscript
## Called by TrashZone after binning an item this spawner produced. Spawns a
## replacement next frame if the binned item was this spawner's current one
## (an older, already-replaced item does not trigger a second spawn).
func replace(binned: Node) -> void:
	if binned == _last_spawned:
		call_deferred("spawn")
```

**Step 3: The zone script `scripts/systems/trash_zone.gd`**

```gdscript
class_name TrashZone
extends Area3D
## Bins any grabbable item resting inside it. Authority only: it frees the
## item (the MultiplayerSpawner despawns it on clients) and asks the spawner
## that produced it (Node metadata "spawner_path") to spawn a replacement.
## Held items, and plates whose food is held, are left alone until released,
## the same rule DeliveryZone uses.

signal trashed(item_name: String)

var _inside: Array[RigidBody3D] = []


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _physics_process(_delta: float) -> void:
	if not NetSession.is_authority() or _inside.is_empty():
		return
	for body in _inside.duplicate():
		if not is_instance_valid(body) or body.is_queued_for_deletion():
			_inside.erase(body)
			continue
		if body.is_in_group(Groups.HELD) or _has_held_contents(body):
			continue
		_bin(body)


func _has_held_contents(body: RigidBody3D) -> bool:
	if body is Plate:
		for food in (body as Plate).get_contents():
			if is_instance_valid(food) and food.is_in_group(Groups.HELD):
				return true
	return false


func _on_body_entered(body: Node) -> void:
	if body is RigidBody3D and body.is_in_group(Groups.GRABBABLE) and not _inside.has(body):
		_inside.append(body)


func _on_body_exited(body: Node) -> void:
	if body is RigidBody3D:
		_inside.erase(body)


func _bin(body: RigidBody3D) -> void:
	_inside.erase(body)
	var spawner_path: NodePath = body.get_meta(&"spawner_path", NodePath()) as NodePath
	var spawner: ItemSpawner = get_node_or_null(spawner_path) as ItemSpawner if not spawner_path.is_empty() else null
	trashed.emit(body.name)
	body.queue_free()
	if spawner != null:
		spawner.replace(body)
```

**Step 4: The bin scene `scenes/trash_can.tscn`**

A dark green cylinder with an open top: eight thin wall segments and a floor disc for collision (so items really drop in and stay), the zone filling the inside. Collision layer World (1), mask default; the zone on no layer with mask Items (4).

```
[gd_scene load_steps=8 format=3]

[ext_resource type="Script" path="res://scripts/systems/trash_zone.gd" id="1_trash_zone"]

[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_bin"]
albedo_color = Color(0.2, 0.36, 0.24, 1)

[sub_resource type="CylinderMesh" id="CylinderMesh_bin"]
material = SubResource("StandardMaterial3D_bin")
top_radius = 0.36
bottom_radius = 0.32
height = 0.9

[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_hole"]
albedo_color = Color(0.05, 0.05, 0.05, 1)

[sub_resource type="CylinderMesh" id="CylinderMesh_hole"]
material = SubResource("StandardMaterial3D_hole")
top_radius = 0.3
bottom_radius = 0.3
height = 0.02

[sub_resource type="BoxShape3D" id="BoxShape3D_wall"]
size = Vector3(0.28, 0.9, 0.03)

[sub_resource type="CylinderShape3D" id="CylinderShape3D_floor"]
radius = 0.32
height = 0.05

[sub_resource type="BoxShape3D" id="BoxShape3D_zone"]
size = Vector3(0.5, 0.7, 0.5)

[node name="TrashCan" type="StaticBody3D"]

[node name="Body" type="MeshInstance3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.45, 0)
mesh = SubResource("CylinderMesh_bin")

[node name="Hole" type="MeshInstance3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.91, 0)
mesh = SubResource("CylinderMesh_hole")

[node name="Floor" type="CollisionShape3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.025, 0)
shape = SubResource("CylinderShape3D_floor")

[node name="Wall0" type="CollisionShape3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.45, 0.33)
shape = SubResource("BoxShape3D_wall")

[node name="Wall1" type="CollisionShape3D" parent="."]
transform = Transform3D(0.707107, 0, 0.707107, 0, 1, 0, -0.707107, 0, 0.707107, 0.233345, 0.45, 0.233345)
shape = SubResource("BoxShape3D_wall")

[node name="Wall2" type="CollisionShape3D" parent="."]
transform = Transform3D(0, 0, 1, 0, 1, 0, -1, 0, 0, 0.33, 0.45, 0)
shape = SubResource("BoxShape3D_wall")

[node name="Wall3" type="CollisionShape3D" parent="."]
transform = Transform3D(-0.707107, 0, 0.707107, 0, 1, 0, -0.707107, 0, -0.707107, 0.233345, 0.45, -0.233345)
shape = SubResource("BoxShape3D_wall")

[node name="Wall4" type="CollisionShape3D" parent="."]
transform = Transform3D(-1, 0, 0, 0, 1, 0, 0, 0, -1, 0, 0.45, -0.33)
shape = SubResource("BoxShape3D_wall")

[node name="Wall5" type="CollisionShape3D" parent="."]
transform = Transform3D(-0.707107, 0, -0.707107, 0, 1, 0, 0.707107, 0, -0.707107, -0.233345, 0.45, -0.233345)
shape = SubResource("BoxShape3D_wall")

[node name="Wall6" type="CollisionShape3D" parent="."]
transform = Transform3D(0, 0, -1, 0, 1, 0, 1, 0, 0, -0.33, 0.45, 0)
shape = SubResource("BoxShape3D_wall")

[node name="Wall7" type="CollisionShape3D" parent="."]
transform = Transform3D(0.707107, 0, -0.707107, 0, 1, 0, 0.707107, 0, 0.707107, -0.233345, 0.45, 0.233345)
shape = SubResource("BoxShape3D_wall")

[node name="TrashZone" type="Area3D" parent="."]
collision_layer = 0
collision_mask = 4
script = ExtResource("1_trash_zone")

[node name="CollisionShape3D" type="CollisionShape3D" parent="TrashZone"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.5, 0)
shape = SubResource("BoxShape3D_zone")
```

Wall segments: each is a 0.28 m wide, 0.03 m thick box tangent to a circle of radius 0.33 at 45° steps; the `Transform3D` basis rows above are the rotation matrices for 0°, 45°, 90°, ... about Y (Godot's column-major text order: `xx, xy, xz, yx, yy, yz, zx, zy, zz, ox, oy, oz`). If any segment looks misplaced in the editor later, it is fine to rebuild the ring there; the smoke test only needs an item teleported to `TRASH_ZONE_POS` to stay inside the zone for a few frames, which the floor disc guarantees.

**Step 5: Place it in the kitchen**

`scenes/kitchen.tscn`: add `[ext_resource type="PackedScene" path="res://scenes/trash_can.tscn" id="20_trash_can"]` after the `19_lobby_panel` line and, after the `PlateRack` block (before `OrderSystem`):

```
[node name="TrashCan" parent="." instance=ExtResource("20_trash_can")]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 4, 0, 1.5)
```

(4.0, 0, 1.5) is beside the plate rack, clear of the spawn points and the pass. `TRASH_ZONE_POS` (4.0, 0.5, 1.5) is inside the zone box (0.15–0.85 m).

**Step 6: Run everything**

Smoke → `SUMMARY: 103 passed, 0 failed, 1 xfailed`. Net → `NET TEST PASSED` (unchanged checks; the zone is authority-only and freed/spawned items replicate). Menu → 16/0.

If `trash.egg_replaced` fails with `slot_free=true`: `replace()` compared against a stale `_last_spawned`; make sure `spawn()` runs deferred after `queue_free` so `_last_spawned` is reassigned. If `trash.pan_replaced` reports `on_stove=false`, give the pan 30 more frames to settle or check `PanSpawner`'s `spawn_parent_path`.

**Step 7: Docs**

`README.md`: How to play gets a line: "Drop anything into the green bin by the plate rack to trash it; a fresh one appears at its station." Project layout: `scenes/trash_can.tscn`, `scripts/systems/trash_zone.gd`. Smoke check list: `walk.*` (2), `trash.*` (7); total 104. `docs/WALKTHROUGH.md` symptom table: "Item vanished" → the trash zone (`TrashZone`, authority only).

**Step 8: Commit** `Trash can: bins unheld items, their spawner replaces them`.
